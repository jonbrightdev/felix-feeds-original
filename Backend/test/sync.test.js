import { test } from 'node:test';
import assert from 'node:assert/strict';
import { setup, caregiverA, caregiverB, packet } from '../test-support/fixture.js';
test('requires a paired device key; accepts either phone', async () => {
  const { call } = await setup();
  assert.equal((await call(undefined, '')).status, 401);
  assert.equal((await call(undefined, 'c'.repeat(64))).status, 401);
  assert.equal((await call(undefined, caregiverB)).status, 200);
  assert.equal((await call(undefined, caregiverA)).status, 200);
});
test('validates whole batch before writing any row', async () => {
  const { call, db } = await setup();
  assert.equal((await call({ records: [packet(), { ...packet(), counter: '9223372036854775808' }] })).status, 400);
  assert.equal(db.prepare('SELECT COUNT(*) AS count FROM packets').get().count, 0);
  assert.equal((await call({ records: Array.from({ length: 11 }, () => packet()) })).status, 400);
  const p = packet(); assert.equal((await call({ records: [p, p] })).status, 400);
});
test('older offline writes never overwrite newer records; ties converge by device', async () => {
  const { call } = await setup();
  const old = packet(); const latest = { ...old, counter: '10', ciphertext: Buffer.alloc(64, 78).toString('base64') };
  await call({ records: [latest] }); await call({ records: [old] }, caregiverA);
  assert.deepEqual((await (await call()).json()).records, [latest]);
  const winner = { ...latest, device: 'ffffffff-ffff-4fff-8fff-ffffffffffff' };
  await call({ records: [winner] }); await call({ records: [latest] });
  assert.deepEqual((await (await call()).json()).records, [winner]);
});
test('Int64 counters retain exact ordering beyond JavaScript safe integers', async () => {
  const { call } = await setup(); const p = packet();
  const newer = { ...p, counter: '9223372036854775806' };
  await call({ records: [newer] }); await call({ records: [{ ...p, counter: '9007199254740993' }] });
  assert.equal((await (await call()).json()).records[0].counter, newer.counter);
});
test('pagination returns all encrypted records once; payload is opaque', async () => {
  const { call, db } = await setup(); const records = Array.from({ length: 45 }, () => packet());
  for (let i = 0; i < records.length; i += 10) assert.equal((await call({ records: records.slice(i, i + 10) })).status, 200);
  const first = await (await call()).json(); assert.equal(first.records.length, 40); assert.ok(first.nextCursor);
  const second = await (await call({ records: [], cursor: first.nextCursor })).json();
  assert.equal(second.records.length, 5); assert.equal(second.nextCursor, null);
  assert.equal(new Set([...first.records, ...second.records].map(r => r.id)).size, 45);
  assert.deepEqual(Object.keys(db.prepare('SELECT * FROM packets LIMIT 1').get()).sort(), ['ciphertext', 'counter', 'device', 'id']);
});
test('database outages return a retryable error without leaking details', async () => {
  const { call, env } = await setup(); env.DB.prepare = () => { throw new Error('secret backend details'); };
  const response = await call(); assert.equal(response.status, 503);
  assert.equal((await response.json()).error, 'Sync temporarily unavailable');
});

test('observations are encrypted packets isolated from the legacy feed endpoint', async () => {
  const { call } = await setup(); const observation = packet(), feed = packet();
  assert.equal((await call({ records: [observation] }, caregiverB, '/api/observations')).status, 200);
  assert.deepEqual((await (await call()).json()).records, []);
  await call({ records: [feed] });
  assert.deepEqual((await (await call(undefined, caregiverA, '/api/observations')).json()).records, [observation]);
  assert.deepEqual((await (await call()).json()).records, [feed]);
  assert.equal((await call(undefined, '', '/api/observations')).status, 401);
});
test('observation corrections use the same stale-write protection and full-batch validation', async () => {
  const { call } = await setup(); const original = packet(); const latest = { ...original, counter: '3' };
  await call({ records: [latest] }, caregiverB, '/api/observations');
  await call({ records: [original] }, caregiverA, '/api/observations');
  assert.deepEqual((await (await call(undefined, caregiverB, '/api/observations')).json()).records, [latest]);
  assert.equal((await call({ records: [packet(), { ...packet(), counter: '-1' }] }, caregiverB, '/api/observations')).status, 400);
  assert.equal((await (await call(undefined, caregiverB, '/api/observations')).json()).records.length, 1);
});
test('pumping sessions are a third isolated encrypted collection with stale-write protection', async () => {
  const { call } = await setup(); const session = packet(), observation = packet(), feed = packet();
  assert.equal((await call({ records: [session] }, caregiverA, '/api/pumping')).status, 200);
  await call({ records: [observation] }, caregiverB, '/api/observations'); await call({ records: [feed] });
  assert.deepEqual((await (await call(undefined, caregiverB, '/api/pumping')).json()).records, [session]);
  assert.deepEqual((await (await call(undefined, caregiverB, '/api/observations')).json()).records, [observation]);
  assert.deepEqual((await (await call()).json()).records, [feed]);
  const latest = { ...session, counter: '4' };
  await call({ records: [latest] }, caregiverB, '/api/pumping'); await call({ records: [session] }, caregiverA, '/api/pumping');
  assert.deepEqual((await (await call(undefined, caregiverB, '/api/pumping')).json()).records, [latest]);
  assert.equal((await call({ records: [packet(), { ...packet(), counter: '0' }] }, caregiverB, '/api/pumping')).status, 400);
  assert.equal((await (await call(undefined, caregiverB, '/api/pumping')).json()).records.length, 1);
  assert.equal((await call(undefined, '', '/api/pumping')).status, 401);
});
