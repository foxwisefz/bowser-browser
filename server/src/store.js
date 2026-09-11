import { DatabaseSync } from 'node:sqlite';
import { createHash, randomUUID } from 'node:crypto';
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
      ) STRICT;`);
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
  close() { this.db.close(); }
}
