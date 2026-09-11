import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { request } from 'node:https';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { Store } from '../src/store.js';
import { createApp } from '../src/app.js';

test('native-shaped registration succeeds over certificate-verified HTTPS; downloads stream from configured artifact', async t => {
  const root = mkdtempSync(join(tmpdir(), 'bowser-tls-'));
  const key = join(root, 'key.pem'), cert = join(root, 'cert.pem');
  const config = join(root, 'openssl.cnf');
  writeFileSync(config, '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-keyout', key, '-out', cert, '-config', config], { stdio: 'ignore' });
  const archive = join(root, 'Bowser.zip'); writeFileSync(archive, 'PKfixture');
  const store = new Store(':memory:');
  const server = createApp({ store, website: fileURLToPath(new URL('../../website/', import.meta.url)),
    termsVersions: ['fixture'], tls: { key: readFileSync(key), cert: readFileSync(cert) }, download: archive });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await new Promise(resolve => server.close(resolve)); store.close(); rmSync(root, { recursive: true, force: true }); });
  const send = (path, body) => new Promise((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port: server.address().port, path, ca: readFileSync(cert),
      method: body ? 'POST' : 'GET', headers: body ? { 'Content-Type': 'application/json', 'Idempotency-Key': body.requestID } : {} }, res => {
      let data = ''; res.on('data', chunk => data += chunk); res.on('end', () => resolve({ status: res.statusCode, data }));
    });
    req.on('error', reject); req.end(body ? JSON.stringify(body) : undefined);
  });
  const response = await send('/v1/registrations', { requestID: randomUUID(), email: 'fixture@example.com', termsVersion: 'fixture', acceptedAt: new Date().toISOString(), trainingConsent: false });
  assert.equal(response.status, 201);
  assert.match(JSON.parse(response.data).telemetryToken, /^[a-f0-9-]+\.[A-Za-z0-9_-]+$/);
  assert.deepEqual(await send('/Bowser.zip'), { status: 200, data: 'PKfixture' });
});
