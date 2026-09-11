import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.js';
import { createApp, RateLimit } from '../src/app.js';

const website = fileURLToPath(new URL('../../website/', import.meta.url));
const now = Date.parse('2026-09-11T10:00:00Z');
function payload() { return { requestID: randomUUID(), email: 'person@example.com', termsVersion: 'fixture-v1',
  acceptedAt: '2026-09-11T09:59:00Z', trainingConsent: false,
  device: { model: 'Mac14,5', architecture: 'arm64', macOSVersion: '15.0', appVersion: 'test', appBuild: '42' } }; }
async function fixture(t, options = {}) {
  const root = mkdtempSync(join(tmpdir(), 'bowser-api-'));
  const path = join(root, 'data.sqlite');
  const store = new Store(path);
  const server = createApp({ store, website, termsVersions: ['fixture-v1'], now: () => now, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  t.after(async () => { await new Promise(resolve => server.close(resolve)); store.close(); rmSync(root, { recursive: true, force: true }); });
  return { store, path, url, post: (body, headers = {}) => fetch(url + '/v1/registrations', { method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Idempotency-Key': body.requestID, ...headers }, body: JSON.stringify(body) }) };
}
test('native payload persists client/server times and concurrent retries return one registration', async t => {
  const f = await fixture(t); const body = payload();
  const replies = await Promise.all(Array.from({ length: 8 }, () => f.post(body)));
  assert.equal(replies.filter(r => r.status === 201).length, 1);
  const ids = await Promise.all(replies.map(async r => (await r.json()).registrationID));
  assert.equal(new Set(ids).size, 1);
  const row = f.store.db.prepare('SELECT * FROM registrations').get();
  assert.equal(row.received_at, new Date(now).toISOString());
  assert.equal(JSON.parse(row.payload).acceptedAt, '2026-09-11T09:59:00.000Z');
  assert.equal(row.training_consent, 0);
  const reopened = new Store(f.path);
  assert.equal(reopened.db.prepare('SELECT registration_id FROM registrations').get().registration_id, ids[0]);
  reopened.close();
  const changed = await f.post({ ...body, trainingConsent: true });
  assert.equal(changed.status, 409);
  assert.equal((await changed.json()).error.code, 'idempotency_conflict');
});
test('rejects unknown fields, unsupported terms, malformed identities and dates without persistence', async t => {
  const f = await fixture(t);
  for (const change of [ { serialNumber: 'secret' }, { privacyVersion: 'removed' }, { trainingConsent: 'yes' },
    { device: { ...payload().device, hardwareUUID: 'secret' } }, { email: 'a@@b.com' },
    { acceptedAt: '2026-02-30T09:00:00Z' }, { acceptedAt: '2026-09-12T09:00:00Z' } ]) {
    const r = await f.post({ ...payload(), ...change }); assert.equal(r.status, 400);
    assert.deepEqual(await r.json(), { error: { code: 'invalid_request' } });
  }
  assert.equal((await f.post({ ...payload(), termsVersion: 'old' })).status, 422);
  assert.equal((await f.post(payload(), { 'Idempotency-Key': randomUUID() })).status, 400);
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM registrations').get().n, 0);
});
test('allows Swift optional device and does not use email as verified identity', async t => {
  const f = await fixture(t); const first = payload(); delete first.device;
  const a = await (await f.post(first)).json();
  const b = await (await f.post({ ...first, requestID: randomUUID() })).json();
  assert.notEqual(a.registrationID, b.registrationID);
});
test('rate limits cannot be bypassed with arbitrary forwarding headers', async t => {
  const f = await fixture(t, { limit: new RateLimit(2) });
  assert.equal((await f.post(payload())).status, 201);
  assert.equal((await f.post(payload())).status, 201);
  const rejected = await f.post(payload(), { 'X-Real-IP': '1.2.3.4', 'X-Forwarded-For': '5.6.7.8' });
  assert.equal(rejected.status, 429); assert.equal(rejected.headers.get('retry-after'), '60');
});
test('serves only public files, enforces body limits and stays unavailable without effective Terms', async t => {
  const f = await fixture(t, { termsVersions: [] });
  assert.equal((await f.post(payload())).status, 503);
  assert.equal((await fetch(f.url + '/')).status, 200);
  assert.equal((await fetch(f.url + '/terms.html')).status, 200);
  for (const path of ['/privacy.html', '/src/main.js', '/data.sqlite', '/%2e%2e/server/src/main.js']) assert.equal((await fetch(f.url + path)).status, 404);
  const enabled = await fixture(t);
  assert.equal((await enabled.post({ ...payload(), email: 'x'.repeat(17000) })).status, 413);
  const bad = await fetch(enabled.url + '/v1/registrations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{' });
  assert.equal(bad.status, 400);
  assert.equal((await fetch(enabled.url + '/v1/registrations')).status, 405);
});
