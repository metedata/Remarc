CREATE TABLE IF NOT EXISTS launch_waitlist (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL COLLATE NOCASE UNIQUE
    CHECK (length(email) BETWEEN 3 AND 254),
  status TEXT NOT NULL DEFAULT 'awaiting_launch'
    CHECK (status IN ('awaiting_launch', 'notified', 'unsubscribed', 'suppressed')),
  source TEXT NOT NULL DEFAULT 'countdown-landing',
  consent_version TEXT NOT NULL,
  consent_text TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  notified_at TEXT,
  unsubscribed_at TEXT
);

CREATE INDEX IF NOT EXISTS launch_waitlist_status_created_at
  ON launch_waitlist (status, created_at);
