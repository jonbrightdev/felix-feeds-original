const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const MAX_BODY = 2_000_000;
const PAGE_SIZE = 40;
const json = (body, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' },
});
export async function deviceAuthorized(request, env) {
  const token = request.headers.get('Authorization')?.match(/^Bearer ([a-f0-9]{64})$/)?.[1];
  if (!token) return false;
  const digest = [...new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)))].map(x => x.toString(16).padStart(2, '0')).join('');
  // Compare every byte and both keys; avoid early-exit string comparison.
  let accepted = 0;
  for (const expected of [env.DEVICE_B_KEY_HASH, env.DEVICE_A_KEY_HASH]) {
    let difference = 0;
    if (typeof expected !== 'string' || expected.length !== 64) continue;
    for (let i = 0; i < 64; i++) difference |= digest.charCodeAt(i) ^ expected.charCodeAt(i);
    accepted |= Number(difference === 0);
  }
  return accepted !== 0;
}
function validatePacket(p) {
  if (!p || !UUID.test(p.id) || !UUID.test(p.device) || typeof p.counter !== 'string' || !/^[1-9][0-9]{0,18}$/.test(p.counter)
    || BigInt(p.counter) > 9223372036854775807n || typeof p.ciphertext !== 'string'
    || p.ciphertext.length < 40 || p.ciphertext.length > 120000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(p.ciphertext)) throw new Error('Invalid packet');
  return { id: p.id, counter: p.counter.padStart(19, '0'), device: p.device, ciphertext: p.ciphertext };
}
async function readBounded(request) {
  if (Number(request.headers.get('Content-Length')) > MAX_BODY) throw new Error('Oversize');
  const reader = request.body?.getReader();
  if (!reader) throw new Error('Missing body');
  const chunks = []; let length = 0;
  while (true) {
    const { done, value } = await reader.read(); if (done) break;
    length += value.byteLength;
    if (length > MAX_BODY) { await reader.cancel(); throw new Error('Oversize'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/' && request.method === 'GET') return new Response('Private family feeding sync. Open Felix Feeds on a paired iPhone.', { headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } });
    const table = ({ '/api/sync': 'packets', '/api/observations': 'observation_packets', '/api/pumping': 'pumping_packets' })[url.pathname];
    if (!table) return json({ error: 'Not found' }, 404);
    if (!(await deviceAuthorized(request, env))) return json({ error: 'Unauthorized' }, 401);
    if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
    if (!(request.headers.get('Content-Type') ?? '').startsWith('application/json')) return json({ error: 'JSON required' }, 415);
    let body, records;
    try {
      body = await readBounded(request);
      if (!Array.isArray(body.records) || body.records.length > 10 || (body.cursor != null && !UUID.test(body.cursor))) throw new Error('Invalid batch');
      records = body.records.map(validatePacket);
      if (new Set(records.map(p => p.id)).size !== records.length) throw new Error('Duplicate packet');
    } catch { return json({ error: 'Invalid sync request' }, 400); }
    try {
      if (records.length) await env.DB.batch(records.map(p => env.DB.prepare(`INSERT INTO ${table} (id,counter,device,ciphertext) VALUES (?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET counter=excluded.counter,device=excluded.device,ciphertext=excluded.ciphertext
        WHERE excluded.counter > ${table}.counter OR (excluded.counter = ${table}.counter AND excluded.device > ${table}.device)`)
        .bind(p.id, p.counter, p.device, p.ciphertext)));
      const { results } = await env.DB.prepare(`SELECT id,counter,device,ciphertext FROM ${table} WHERE id > ? ORDER BY id LIMIT ?`)
        .bind(body.cursor ?? '', PAGE_SIZE + 1).all();
      const page = results.slice(0, PAGE_SIZE).map(p => ({ ...p, counter: p.counter.replace(/^0+/, '') }));
      return json({ records: page, nextCursor: results.length > PAGE_SIZE ? page.at(-1).id : null });
    } catch { return json({ error: 'Sync temporarily unavailable' }, 503); }
  },
};
