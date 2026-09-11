import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Store } from '../src/store.js';

const root = fileURLToPath(new URL('../../', import.meta.url));
test('operator backup restores registrations and attribution secrets; existing backups are protected', t => {
  const directory = mkdtempSync(join(tmpdir(), 'bowser-ops-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const db = join(directory, 'live.sqlite'), backup = join(directory, 'snapshot.sqlite');
  const live = new Store(db);
  const { registrationID } = live.register({ requestID: randomUUID(), trainingConsent: false }, Date.now());
  const token = live.telemetryToken(registrationID);
  execFileSync(process.execPath, ['server/src/admin.js', 'backup', backup], { cwd: root, env: { ...process.env, BOWSER_DATABASE: db } });
  const restored = new Store(backup);
  assert.equal(restored.authenticateTelemetry(token), registrationID);
  assert.equal(restored.db.prepare('PRAGMA integrity_check').get().integrity_check, 'ok');
  restored.close();
  assert.throws(() => execFileSync(process.execPath, ['server/src/admin.js', 'backup', backup], { cwd: root,
    env: { ...process.env, BOWSER_DATABASE: db }, stdio: 'pipe' }));
  live.close();
});
test('real entry point boots with safe defaults and shuts down cleanly', { timeout: 5000 }, async t => {
  const directory = mkdtempSync(join(tmpdir(), 'bowser-main-'));
  const child = spawn(process.execPath, ['server/src/main.js'], { cwd: root,
    env: { ...process.env, PORT: '0', HOST: '127.0.0.1', BOWSER_DATABASE: join(directory, 'data.sqlite'),
      BOWSER_TLS_CERT: '', BOWSER_TLS_KEY: '', BOWSER_DOWNLOAD_PATH: '', BOWSER_TELEMETRY_ENABLED: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); rmSync(directory, { recursive: true, force: true }); });
  await new Promise((resolve, reject) => {
    child.stdout.on('data', data => { if (String(data).includes('service ready')) resolve(); });
    child.on('error', reject);
    child.on('exit', code => reject(new Error(`service exited before readiness: ${code}`)));
  });
  const exited = once(child, 'exit'); child.kill('SIGTERM');
  assert.equal((await exited)[0], 0);
});
