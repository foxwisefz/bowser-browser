import { DatabaseSync } from 'node:sqlite';
import { createHash, randomUUID, randomBytes, createHmac, timingSafeEqual } from 'node:crypto';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { APIError } from './validation.js';

export function digest(value) { return createHash('sha256').update(JSON.stringify(value)).digest('hex'); }
export class Store {
  constructor(path) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path, { timeout: 2000 });
    if (path !== ':memory:') chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
      CREATE TABLE IF NOT EXISTS registrations (
        request_id TEXT PRIMARY KEY, registration_id TEXT NOT NULL UNIQUE,
        payload_hash TEXT NOT NULL, payload TEXT NOT NULL, received_at TEXT NOT NULL,
        training_consent INTEGER NOT NULL CHECK(training_consent IN (0,1)),
        consent_updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT;
      CREATE TABLE IF NOT EXISTS events (
        event_id TEXT PRIMARY KEY, registration_id TEXT REFERENCES registrations(registration_id) ON DELETE CASCADE,
        name TEXT NOT NULL, payload_hash TEXT NOT NULL, payload TEXT NOT NULL,
        received_at TEXT NOT NULL, expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS events_expiry ON events(expires_at);`);
    this.db.prepare('INSERT OR IGNORE INTO metadata VALUES(?,?)').run('telemetry_secret', randomBytes(32).toString('hex'));
    this.secret = this.db.prepare('SELECT value FROM metadata WHERE key=?').get('telemetry_secret').value;
  }
  register(payload, now) {
    const hash = digest(payload);
    // The unique request ID and immediate transaction also cover multiple
    // processes sharing one local database, not just this JS event loop.
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const existing = this.db.prepare('SELECT registration_id, payload_hash FROM registrations WHERE request_id=?').get(payload.requestID);
      if (existing) {
        if (existing.payload_hash !== hash) throw new APIError(409, 'idempotency_conflict');
        this.db.exec('COMMIT');
        return { registrationID: existing.registration_id, created: false };
      }
      const registrationID = randomUUID();
      const received = new Date(now).toISOString();
      this.db.prepare('INSERT INTO registrations VALUES(?,?,?,?,?,?,?)').run(payload.requestID, registrationID, hash,
        JSON.stringify(payload), received, Number(payload.trainingConsent), received);
      this.db.exec('COMMIT');
      return { registrationID, created: true };
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  telemetryToken(registrationID) {
    return registrationID + '.' + createHmac('sha256', this.secret).update(registrationID).digest('base64url');
  }
  authenticateTelemetry(token) {
    const match = /^([a-f0-9-]{36})\.([A-Za-z0-9_-]{43})$/.exec(token);
    if (!match) return null;
    const expected = Buffer.from(this.telemetryToken(match[1]));
    const actual = Buffer.from(token);
    if (expected.length !== actual.length || !timingSafeEqual(expected, actual)) return null;
    return this.db.prepare('SELECT registration_id FROM registrations WHERE registration_id=?').get(match[1])?.registration_id || null;
  }
  saveEvents(events, registrationID, now, retentionDays) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      this.prune(now);
      let accepted = 0;
      for (const event of events) {
        const hash = digest({ registrationID, event });
        const old = this.db.prepare('SELECT payload_hash FROM events WHERE event_id=?').get(event.eventID);
        if (old) {
          if (old.payload_hash !== hash) throw new APIError(409, 'idempotency_conflict');
          continue;
        }
        this.db.prepare('INSERT INTO events VALUES(?,?,?,?,?,?,?)').run(event.eventID, registrationID, event.name, hash,
          JSON.stringify(event), new Date(now).toISOString(), now + retentionDays * 86400000);
        accepted++;
      }
      this.db.exec('COMMIT');
      return { accepted, duplicates: events.length - accepted };
    } catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  prune(now) { return this.db.prepare('DELETE FROM events WHERE expires_at <= ?').run(now).changes; }
  withdrawTraining(registrationID, now) {
    // Keep original acceptance immutable for retry comparisons; withdrawal
    // changes the current permission and must never be undone by a retry.
    return this.db.prepare('UPDATE registrations SET training_consent=0, consent_updated_at=? WHERE registration_id=?')
      .run(new Date(now).toISOString(), registrationID).changes;
  }
  deleteRegistration(registrationID) {
    return this.db.prepare('DELETE FROM registrations WHERE registration_id=?').run(registrationID).changes;
  }
  close() { this.db.close(); }
}
