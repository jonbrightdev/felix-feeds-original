import { sqliteTable, text } from 'drizzle-orm/sqlite-core';
// No feed contents or family encryption keys are stored in this database.
export const packets = sqliteTable('packets', {
  id: text('id').primaryKey(),
  counter: text('counter').notNull(),
  device: text('device').notNull(),
  ciphertext: text('ciphertext').notNull(),
});
// Separate encrypted observations keep older feed-only apps compatible.
export const observations = sqliteTable('observation_packets', {
  id: text('id').primaryKey(),
  counter: text('counter').notNull(),
  device: text('device').notNull(),
  ciphertext: text('ciphertext').notNull(),
});
// Pumping sessions are a third isolated collection; older apps never request it.
export const pumping = sqliteTable('pumping_packets', {
  id: text('id').primaryKey(),
  counter: text('counter').notNull(),
  device: text('device').notNull(),
  ciphertext: text('ciphertext').notNull(),
});
