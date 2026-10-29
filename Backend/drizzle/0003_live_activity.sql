CREATE TABLE live_activity_history (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  version INTEGER NOT NULL
);
--> statement-breakpoint
CREATE TRIGGER live_activity_feed_insert AFTER INSERT ON packets BEGIN
  INSERT INTO live_activity_history (id, version) VALUES (1, 1)
    ON CONFLICT(id) DO UPDATE SET version = version + 1;
END;
--> statement-breakpoint
CREATE TRIGGER live_activity_feed_update AFTER UPDATE ON packets BEGIN
  INSERT INTO live_activity_history (id, version) VALUES (1, 1)
    ON CONFLICT(id) DO UPDATE SET version = version + 1;
END;
--> statement-breakpoint
CREATE TABLE live_activity_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  history_version INTEGER NOT NULL,
  ciphertext TEXT NOT NULL,
  timestamp INTEGER NOT NULL
);
--> statement-breakpoint
CREATE TABLE live_activity_devices (
  slot TEXT PRIMARY KEY CHECK (slot IN ('a', 'b')),
  registration INTEGER NOT NULL,
  activity_id TEXT,
  token TEXT,
  environment TEXT,
  expires_at INTEGER NOT NULL DEFAULT 0,
  delivered_version INTEGER NOT NULL DEFAULT -1
);
