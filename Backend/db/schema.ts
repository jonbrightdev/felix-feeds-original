import { sqliteTable, text, integer } from 'drizzle-orm/sqlite-core';
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

// Routing metadata and opaque timer ciphertext; never the display/history keys.
export const activityHistory = sqliteTable('live_activity_history', {
  id: integer('id').primaryKey(),
  version: integer('version').notNull(),
});
export const activityState = sqliteTable('live_activity_state', {
  id: integer('id').primaryKey(),
  historyVersion: integer('history_version').notNull(),
  ciphertext: text('ciphertext').notNull(),
  timestamp: integer('timestamp').notNull(),
});
export const activityDevices = sqliteTable('live_activity_devices', {
  slot: text('slot').primaryKey(),
  registration: integer('registration').notNull(),
  activityID: text('activity_id'),
  token: text('token'),
  environment: text('environment'),
  expiresAt: integer('expires_at').notNull().default(0),
  deliveredVersion: integer('delivered_version').notNull().default(-1),
});
