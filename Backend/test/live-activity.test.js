import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup, caregiverA, caregiverB, packet } from '../test-support/fixture.js';
import { handleActivity, historyDigest, deliverActivities } from '../worker/live-activity.js';

const ciphertext = Buffer.alloc(240, 37).toString('base64');
const registration = (revision = 1, token = 'ab'.repeat(32)) => ({ action: 'register', registration: revision,
  activityID: 'synthetic-activity', token, environment: 'development', expiresAt: Math.floor(Date.now() / 1000) + 3600 });
const publish = async records => ({ action: 'publish', digest: await historyDigest(records), ciphertext });
async function pushSetup() {
  const fixture = await setup();
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']);
  const der = await crypto.subtle.exportKey('pkcs8', pair.privateKey);
  Object.assign(fixture.env, { APNS_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${Buffer.from(der).toString('base64')}\n-----END PRIVATE KEY-----`,
    APNS_KEY_ID: 'SYNTHETIC1', APNS_TEAM_ID: 'SYNTHETIC2', APNS_BUNDLE_ID: 'com.jonbright.FelixFeeds' });
  const sends = [];
  const send = async (url, options) => { sends.push({ url, options }); return new Response(null, { status: 200 }); };
  const activity = (body, slot = 'a', sender = send) => handleActivity(new Request('https://sync.example/api/live-activity', {
    method: 'POST', body: JSON.stringify(body),
  }), fixture.env, slot, r => r.json(), sender);
  return { ...fixture, sends, send, activity, publicKey: pair.publicKey };
}

test('activity route requires the existing device authentication and never trusts a supplied slot', async () => {
  const { call, db } = await setup();
  assert.equal((await call(registration(), '', '/api/live-activity')).status, 401);
  assert.equal((await call({ ...registration(), slot: 'b' }, caregiverA, '/api/live-activity')).status, 200);
  assert.equal(db.prepare('SELECT slot FROM live_activity_devices').get().slot, 'a');
  assert.equal((await call({ ...registration(), token: 'secret/non-hex' }, caregiverB, '/api/live-activity')).status, 400);
});

test('one phone publishes an encrypted glance and the other receives a correctly signed ActivityKit push', async () => {
  const { call, activity, sends, publicKey, db } = await pushSetup();
  await activity(registration(), 'b');
  const feed = packet(); await call({ records: [feed] });
  assert.equal((await activity(await publish([feed]))).status, 200);
  assert.equal(sends.length, 1);
  const { url, options } = sends[0];
  assert.ok(url.startsWith('https://api.sandbox.push.apple.com/3/device/'));
  assert.equal(options.headers['apns-topic'], 'com.jonbright.FelixFeeds.push-type.liveactivity');
  assert.equal(options.headers['apns-push-type'], 'liveactivity');
  assert.equal(options.headers['apns-priority'], '10');
  assert.equal(options.redirect, 'error');
  const body = JSON.parse(options.body);
  assert.equal(body.aps.event, 'update');
  assert.equal(body.aps['content-state'].encryptedSnapshot, ciphertext);
  assert.equal(body.aps['content-state'].startedAt, 0); // Actual start time stays encrypted.
  assert.ok(Buffer.byteLength(options.body) < 4096);
  const jwt = options.headers.authorization.slice(7), [header, claims, signature] = jwt.split('.');
  assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'ES256');
  assert.equal(JSON.parse(Buffer.from(claims, 'base64url')).iss, 'SYNTHETIC2');
  assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, publicKey,
    Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${claims}`)));
  assert.deepEqual(Object.keys(db.prepare('SELECT * FROM live_activity_state').get()).sort(), ['ciphertext', 'history_version', 'id', 'timestamp']);
  await activity(await publish([feed]));
  assert.equal(sends.length, 1, 'same-history sync does not push again');
});

test('stale snapshots are rejected after concurrent inserts, corrections and tombstones', async () => {
  const { call, activity, sends } = await pushSetup();
  await activity(registration(), 'b');
  const first = packet(); await call({ records: [first] });
  await activity(await publish([first]));
  const second = packet(); await call({ records: [second] });
  assert.equal((await activity(await publish([first]))).status, 409);
  assert.equal(sends.length, 1);
  await activity(await publish([first, second]));
  const corrected = { ...second, counter: '2' }; await call({ records: [corrected] });
  assert.equal((await activity(await publish([first, second]))).status, 409);
  await activity(await publish([first, corrected]));
  const timestamps = sends.map(s => JSON.parse(s.options.body).aps.timestamp);
  assert.ok(timestamps[0] < timestamps[1] && timestamps[1] < timestamps[2]);
});

test('compare-and-swap rejects a feed arriving between inventory validation and snapshot commit', async () => {
  const { call, activity, env, db } = await pushSetup();
  const first = packet(), next = packet(); await call({ records: [first] });
  const original = env.DB.batch; let batches = 0;
  env.DB.batch = async statements => {
    // The first batch initialises the singleton; the second is the snapshot CAS.
    if (++batches === 2) await call({ records: [next] });
    return original(statements);
  };
  assert.equal((await activity(await publish([first]))).status, 409);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM live_activity_state').get().n, 0);
});

test('upgrading an existing history initialises ordering without changing saved packets', async () => {
  const { call, activity, db, sends } = await pushSetup();
  const feed = packet(); await call({ records: [feed] });
  // The production migration starts with existing packets and no generation row.
  db.exec('DELETE FROM live_activity_history');
  await activity(registration(), 'b');
  assert.equal((await activity(await publish([feed]))).status, 200);
  const corrected = { ...feed, counter: '2' }; await call({ records: [corrected] });
  assert.equal((await activity(await publish([corrected]))).status, 200);
  assert.equal(sends.length, 2);
  assert.deepEqual((await (await call()).json()).records, [corrected]);
});

test('a failed push remains pending and retries without a second feed upload', async () => {
  const { call, activity, env, db, sends, send } = await pushSetup();
  await activity(registration(), 'b');
  const feed = packet(); await call({ records: [feed] });
  assert.equal((await activity(await publish([feed]), 'a', async () => new Response('{}', { status: 503 }))).status, 503);
  assert.equal(db.prepare("SELECT delivered_version FROM live_activity_devices WHERE slot='b'").get().delivered_version, -1);
  assert.equal(await deliverActivities(env, send), true);
  assert.equal(sends.length, 1);
  assert.ok(db.prepare("SELECT delivered_version FROM live_activity_devices WHERE slot='b'").get().delivered_version > 0);
  assert.deepEqual((await (await call()).json()).records, [feed]);
});

test('token rotation, unregister tombstones, expiry, and invalid APNs tokens are respected', async () => {
  const { activity, env, db, sends, send } = await pushSetup();
  await activity(registration(2), 'b');
  await activity(registration(1, 'cd'.repeat(32)), 'b');
  assert.equal(db.prepare("SELECT token FROM live_activity_devices WHERE slot='b'").get().token, registration().token);
  await activity({ action: 'unregister', registration: 3 }, 'b');
  await activity(registration(2), 'b');
  assert.equal(db.prepare("SELECT token FROM live_activity_devices WHERE slot='b'").get().token, null);
  await activity(await publish([]));
  const invalid = await activity(registration(4), 'b', async () => new Response('{"reason":"Unregistered"}', { status: 410 }));
  assert.equal((await invalid.json()).registered, false, 'a rejected token must not report a ready registration');
  assert.equal(db.prepare("SELECT token FROM live_activity_devices WHERE slot='b'").get().token, null);
  await activity(registration(5), 'b');
  db.prepare("UPDATE live_activity_devices SET expires_at=0, delivered_version=-1 WHERE slot='b'").run();
  const before = sends.length; await deliverActivities(env, send);
  assert.equal(sends.length, before);
});

test('an old APNs failure cannot erase a new token registered during delivery', async () => {
  const { activity, db } = await pushSetup();
  await activity(registration(), 'b');
  const rotated = 'cd'.repeat(32);
  await activity(await publish([]), 'a', async () => {
    await activity(registration(2, rotated), 'b');
    return new Response('{"reason":"Unregistered"}', { status: 410 });
  });
  assert.equal(db.prepare("SELECT token FROM live_activity_devices WHERE slot='b'").get().token, rotated);
});

test('missing push configuration and migration do not break ordinary encrypted history sync', async () => {
  const { call, db } = await setup();
  assert.deepEqual(await (await call(registration(), caregiverA, '/api/live-activity')).json(), { ready: false });
  db.exec('DROP TRIGGER live_activity_feed_insert; DROP TRIGGER live_activity_feed_update; DROP TABLE live_activity_devices; DROP TABLE live_activity_history; DROP TABLE live_activity_state;');
  assert.equal((await call(registration(), caregiverA, '/api/live-activity')).status, 503);
  const feed = packet(); assert.equal((await call({ records: [feed] })).status, 200);
});

// Same fixed wire fixture as LiveActivitySnapshotTests.swift.
test('revision digest agrees with Swift across ordering and Int64 counters', async () => {
  const device = '11111111-1111-4111-8111-111111111111';
  const records = [
    { id: '22222222-2222-4222-8222-222222222222', counter: '9223372036854775806', device },
    { id: device, counter: '0000000000000000002', device },
  ];
  assert.equal(await historyDigest(records), '6c23e4702ab92341b18726615f26f2921938609a084049d67ca067d741276bbf');
});
