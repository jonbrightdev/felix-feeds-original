// The relay never holds the display key. Stored snapshots and APNs payloads
// contain only AES-GCM ciphertext, alongside routing and ordering metadata.
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
});
const rows = async (env, sql, ...args) => (await env.DB.prepare(sql).bind(...args).all()).results;
const write = (env, sql, ...args) => env.DB.batch([env.DB.prepare(sql).bind(...args)]);
const nowSeconds = () => Math.floor(Date.now() / 1000);

export async function historyDigest(records) {
  const inventory = [...records].sort((a, b) => a.id.localeCompare(b.id)).map(p =>
    `${p.id}/${p.counter.replace(/^0+/, '')}/${p.device}\n`).join('');
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(inventory)))].map(x => x.toString(16).padStart(2, '0')).join('');
}

function configured(env) {
  return typeof env.APNS_PRIVATE_KEY === 'string' && /^[A-Z0-9]{10}$/.test(env.APNS_KEY_ID ?? '') &&
    /^[A-Z0-9]{10}$/.test(env.APNS_TEAM_ID ?? '') && env.APNS_BUNDLE_ID === 'com.jonbright.FelixFeeds';
}
const base64url = bytes => btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
let cachedJWT;
async function providerToken(env, now) {
  if (cachedJWT?.key === env.APNS_PRIVATE_KEY && cachedJWT.id === env.APNS_KEY_ID &&
      cachedJWT.team === env.APNS_TEAM_ID && now - cachedJWT.issuedAt < 3000 && now >= cachedJWT.issuedAt) return cachedJWT.value;
  const encode = value => base64url(new TextEncoder().encode(JSON.stringify(value)));
  const unsigned = `${encode({ alg: 'ES256', kid: env.APNS_KEY_ID })}.${encode({ iss: env.APNS_TEAM_ID, iat: now })}`;
  const pem = env.APNS_PRIVATE_KEY.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(unsigned));
  const value = `${unsigned}.${base64url(new Uint8Array(signature))}`;
  cachedJWT = { key: env.APNS_PRIVATE_KEY, id: env.APNS_KEY_ID, team: env.APNS_TEAM_ID, issuedAt: now, value };
  return value;
}

export function activityPayload(state) {
  return { aps: { timestamp: state.timestamp, event: 'update', 'content-state': {
    // Defaults retain decoding compatibility. The extension uses only the
    // authenticated snapshot, including an explicit empty-history state.
    startedAt: 0, detail: '', isFeeding: false, isPaused: false, encryptedSnapshot: state.ciphertext,
  } } };
}

// Durable latest-state outbox, retried on requests and by the host scheduler.
export async function deliverActivities(env, send = fetch) {
  if (!configured(env)) return false;
  const [state] = await rows(env, `SELECT s.* FROM live_activity_state s JOIN live_activity_history h
    ON s.history_version = h.version WHERE s.id = 1 AND h.id = 1`);
  if (!state) return true;
  const now = nowSeconds();
  const devices = await rows(env, `SELECT * FROM live_activity_devices
    WHERE token IS NOT NULL AND expires_at > ? AND delivered_version < ?`, now, state.history_version);
  let success = true;
  for (const device of devices) {
    try {
      const jwt = await providerToken(env, now);
      const origin = device.environment === 'development' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
      const response = await send(`${origin}/3/device/${device.token}`, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10000),
        headers: { authorization: `bearer ${jwt}`, 'content-type': 'application/json',
          'apns-push-type': 'liveactivity', 'apns-topic': `${env.APNS_BUNDLE_ID}.push-type.liveactivity`,
          'apns-priority': '10', 'apns-expiration': String(device.expires_at), 'apns-collapse-id': 'feeding-timer' },
        body: JSON.stringify(activityPayload(state)),
      });
      if (response.ok) {
        await write(env, `UPDATE live_activity_devices SET delivered_version = MAX(delivered_version, ?)
          WHERE slot = ? AND registration = ? AND token = ?`, state.history_version, device.slot, device.registration, device.token);
      } else {
        const reason = (await response.json().catch(() => ({}))).reason;
        if (response.status === 410 || (response.status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(reason))) {
          await write(env, `UPDATE live_activity_devices SET token = NULL WHERE slot = ? AND registration = ? AND token = ?`,
            device.slot, device.registration, device.token);
        } else {
          if (reason === 'ExpiredProviderToken') cachedJWT = undefined;
          success = false;
        }
      }
    } catch { success = false; } // Never log tokens, credentials or provider errors.
  }
  return success;
}

export async function handleActivity(request, env, slot, readBody, send = fetch) {
  let body;
  try { body = await readBody(request); } catch { return json({ error: 'Invalid activity request' }, 400); }
  if (!body || !['register', 'unregister', 'publish'].includes(body.action)) return json({ error: 'Invalid activity request' }, 400);
  try {
    if (body.action === 'register' || body.action === 'unregister') {
      if (!Number.isSafeInteger(body.registration) || body.registration <= 0) return json({ error: 'Invalid registration' }, 400);
      const enabled = body.action === 'register';
      if (enabled && (typeof body.token !== 'string' || !/^[0-9a-f]{32,512}$/.test(body.token) || body.token.length % 2 ||
        typeof body.activityID !== 'string' || !/^[A-Za-z0-9-]{1,128}$/.test(body.activityID) ||
        !['development', 'production'].includes(body.environment) || !Number.isSafeInteger(body.expiresAt) ||
        body.expiresAt <= nowSeconds() || body.expiresAt > nowSeconds() + 8 * 3600 + 300)) return json({ error: 'Invalid registration' }, 400);
      // An unregister tombstone prevents late requests from re-enabling pushes.
      await write(env, `INSERT INTO live_activity_devices
        (slot, registration, activity_id, token, environment, expires_at, delivered_version) VALUES (?, ?, ?, ?, ?, ?, -1)
        ON CONFLICT(slot) DO UPDATE SET registration = excluded.registration, activity_id = excluded.activity_id,
          token = excluded.token, environment = excluded.environment, expires_at = excluded.expires_at,
          delivered_version = CASE WHEN live_activity_devices.token = excluded.token THEN live_activity_devices.delivered_version ELSE -1 END
        WHERE excluded.registration > live_activity_devices.registration`, slot, body.registration,
        enabled ? body.activityID : null, enabled ? body.token : null, enabled ? body.environment : null,
        enabled ? Math.min(body.expiresAt, nowSeconds() + 8 * 3600) : 0);
      if (!enabled) return json({ ready: configured(env) });
    } else {
      if (typeof body.digest !== 'string' || !/^[a-f0-9]{64}$/.test(body.digest) ||
          typeof body.ciphertext !== 'string' || body.ciphertext.length < 40 || body.ciphertext.length > 2500 ||
          !/^[A-Za-z0-9+/]+={0,2}$/.test(body.ciphertext)) return json({ error: 'Invalid snapshot' }, 400);
      // Initialise existing or empty histories lazily; migrations contain only schema.
      await write(env, 'INSERT OR IGNORE INTO live_activity_history (id, version) VALUES (1, 0)');
      const [generation] = await rows(env, 'SELECT version FROM live_activity_history WHERE id = 1');
      const inventory = await rows(env, 'SELECT id, counter, device FROM packets ORDER BY id');
      if (await historyDigest(inventory) !== body.digest) return json({ error: 'History changed; sync again' }, 409);
      // CAS closes the race with a concurrent upload. Same-history retries do
      // not generate more pushes; all updates have monotonic APNs timestamps.
      await write(env, `INSERT INTO live_activity_state (id, history_version, ciphertext, timestamp)
        SELECT 1, version, ?, ? FROM live_activity_history WHERE id = 1 AND version = ?
        ON CONFLICT(id) DO UPDATE SET history_version = excluded.history_version, ciphertext = excluded.ciphertext,
          timestamp = MAX(excluded.timestamp, live_activity_state.timestamp + 1)
        WHERE excluded.history_version > live_activity_state.history_version`, body.ciphertext, nowSeconds(), generation.version);
      const [current] = await rows(env, `SELECT s.history_version FROM live_activity_state s JOIN live_activity_history h
        ON s.history_version = h.version WHERE s.id = 1 AND h.id = 1`);
      if (!current || current.history_version !== generation.version) return json({ error: 'History changed; sync again' }, 409);
      // The publisher already reconciled its local activity. Do not echo an
      // older server glance over a more recent offline save on that phone.
      await write(env, `UPDATE live_activity_devices SET delivered_version = MAX(delivered_version, ?)
        WHERE slot = ?`, generation.version, slot);
    }
    if (!configured(env)) return json({ ready: false });
    const delivered = await deliverActivities(env, send);
    if (body.action === 'register') {
      const [current] = await rows(env, 'SELECT token, expires_at FROM live_activity_devices WHERE slot = ?', slot);
      return json({ ready: true, delivered, registered: current?.token === body.token && current.expires_at > nowSeconds() }, delivered ? 200 : 503);
    }
    return json({ ready: true, delivered }, delivered ? 200 : 503);
  } catch { return json({ error: 'Timer updates temporarily unavailable' }, 503); }
}
