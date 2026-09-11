import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.js';
import { createApp, RateLimit } from '../src/app.js';
import { telemetryRoute } from '../src/telemetry.js';

const now = Date.parse('2026-09-11T10:00:00Z');
const website = fileURLToPath(new URL('../../website/', import.meta.url));
function event(name = 'crash', properties = { category: 'native' }) {
  return { eventID: randomUUID(), name, occurredAt: new Date(now).toISOString(),
    properties: { appVersion: '1.0', appBuild: '42', ...properties } };
}
async function fixture(t, options = {}) {
  const store = new Store(':memory:');
  const server = createApp({ store, website, now: () => now, limit: new RateLimit(100),
    routes: { '/v1/events': telemetryRoute(store, { enabled: true, retentionDays: 7, ...options }) } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); store.close(); });
  return { store, post: (events, token) => fetch(`http://127.0.0.1:${server.address().port}/v1/events`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify({ events }) }) };
}
test('only the three approved event types are stored; batch retries deduplicate', async t => {
  const f = await fixture(t);
  const batch = [event(), event('registration_completed', {}), event('modsmith_outcome', { operation: 'create', outcome: 'failed', failureCategory: 'provider', durationMs: 123 })];
  assert.deepEqual(await (await f.post(batch)).json(), { accepted: 3, duplicates: 0 });
  assert.deepEqual(await (await f.post(batch)).json(), { accepted: 0, duplicates: 3 });
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM events').get().n, 3);
  assert.equal(f.store.db.prepare('SELECT registration_id FROM events LIMIT 1').get().registration_id, null);
});
test('no raw page, prompt, generated code or crash log fields are accepted', async t => {
  const f = await fixture(t);
  for (const field of ['url', 'prompt', 'code', 'stack', 'message', 'email']) {
    const r = await f.post([event('crash', { category: 'native', [field]: 'private' })]);
    assert.equal(r.status, 400);
    assert.equal(JSON.stringify(await r.json()).includes('private'), false);
  }
  assert.equal((await f.post([event('page_view', {})])).status, 400);
  assert.equal((await f.post([event('crash', { category: 'free text' })])).status, 400);
  assert.equal((await f.post([event('modsmith_outcome', { operation: 'create', outcome: 'succeeded', durationMs: -1 })])).status, 400);
  assert.equal((await f.post(Array.from({ length: 26 }, () => event()))).status, 400);
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM events').get().n, 0);
});
test('conflicting event IDs roll back the entire batch', async t => {
  const f = await fixture(t); const original = event();
  await f.post([original]);
  const changed = { ...original, properties: { ...original.properties, category: 'backend' } };
  assert.equal((await f.post([event(), changed])).status, 409);
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM events').get().n, 1);
});
test('registration tokens only attribute telemetry; deletion revokes and cascades', async t => {
  const f = await fixture(t);
  const payload = { requestID: randomUUID(), email: 'fixture@example.com', termsVersion: 'fixture', acceptedAt: new Date(now).toISOString(), trainingConsent: true };
  const { registrationID } = f.store.register(payload, now);
  const token = f.store.telemetryToken(registrationID);
  assert.equal((await f.post([event()], token)).status, 202);
  assert.equal(f.store.db.prepare('SELECT registration_id FROM events').get().registration_id, registrationID);
  assert.equal((await f.post([event()], token + 'bad')).status, 401);
  assert.equal(f.store.withdrawTraining(registrationID, now + 1000), 1);
  assert.equal(f.store.register(payload, now + 2000).registrationID, registrationID);
  assert.equal(f.store.db.prepare('SELECT training_consent FROM registrations').get().training_consent, 0);
  assert.equal(f.store.deleteRegistration(registrationID), 1);
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM events').get().n, 0);
  assert.equal((await f.post([event()], token)).status, 401);
});
test('retention expires events and cannot be omitted when ingestion is enabled', async t => {
  const f = await fixture(t);
  await f.post([event()]);
  assert.equal(f.store.prune(now + 7 * 86400000 - 1), 0);
  assert.equal(f.store.prune(now + 7 * 86400000), 1);
  const old = { ...event(), occurredAt: new Date(now - 8 * 86400000).toISOString() };
  assert.equal((await f.post([old])).status, 400);
  assert.throws(() => telemetryRoute(f.store, { enabled: true }), /RETENTION/);
  const disabled = await fixture(t, { enabled: false });
  assert.equal((await disabled.post([event()])).status, 503);
});
