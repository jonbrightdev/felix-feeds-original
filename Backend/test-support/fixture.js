import { DatabaseSync } from 'node:sqlite';
import { readFileSync, readdirSync } from 'node:fs';
import worker from '../worker/index.js';
export const caregiverB = 'a'.repeat(64), caregiverA = 'b'.repeat(64);
const hash = async value => Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))).toString('hex');
const device = '11111111-1111-4111-8111-111111111111';
export const packet = (id = crypto.randomUUID(), counter = '1', origin = device) => ({ id, counter, device: origin, ciphertext: Buffer.alloc(64, 37).toString('base64') });
export async function setup() {
  const db = new DatabaseSync(':memory:');
  for (const file of readdirSync(new URL('../drizzle/', import.meta.url)).filter(f => f.endsWith('.sql')).sort()) db.exec(readFileSync(new URL('../drizzle/' + file, import.meta.url), 'utf8'));
  const binding = {
    prepare(sql) {
      return { bind(...values) {
        return { all: async () => ({ results: db.prepare(sql).all(...values) }), execute: () => db.prepare(sql).run(...values) };
      } };
    },
    async batch(statements) { db.exec('BEGIN'); try { const result = statements.map(s => s.execute()); db.exec('COMMIT'); return result; } catch (e) { db.exec('ROLLBACK'); throw e; } },
  };
  const env = { DB: binding, DEVICE_B_KEY_HASH: await hash(caregiverB), DEVICE_A_KEY_HASH: await hash(caregiverA) };
  const call = (body = { records: [] }, token = caregiverB, path = '/api/sync') => worker.fetch(new Request('https://sync.example' + path, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body),
  }), env);
  return { db, env, call };
}
