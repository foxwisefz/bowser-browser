import { resolve } from 'node:path';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Store } from './store.js';
import { createApp } from './app.js';
import { telemetryRoute } from './telemetry.js';

process.umask(0o077);
const cert = process.env.BOWSER_TLS_CERT;
const key = process.env.BOWSER_TLS_KEY;
if (Boolean(cert) !== Boolean(key)) throw new Error('Both TLS certificate and key are required');
const host = process.env.HOST || '127.0.0.1';
if (!cert && !['127.0.0.1', '::1', 'localhost'].includes(host)) throw new Error('Direct public listeners require TLS; keep reverse-proxy HTTP on loopback');
const store = new Store(resolve(process.env.BOWSER_DATABASE || 'data/bowser.sqlite'));
const server = createApp({ store, tls: cert ? { cert: readFileSync(cert), key: readFileSync(key) } : undefined,
  download: process.env.BOWSER_DOWNLOAD_PATH, website: fileURLToPath(new URL('../../website/', import.meta.url)),
  termsVersions: (process.env.BOWSER_TERMS_VERSIONS || '').split(',').map(s => s.trim()).filter(Boolean),
  trustedProxy: process.env.BOWSER_TRUSTED_PROXY,
  routes: { '/v1/events': telemetryRoute(store, { enabled: process.env.BOWSER_TELEMETRY_ENABLED === '1',
    retentionDays: Number(process.env.BOWSER_EVENT_RETENTION_DAYS) }) } });
store.prune(Date.now());
const pruning = setInterval(() => {
  try { store.prune(Date.now()); } catch { console.error('Event retention cleanup failed'); }
}, 60000).unref();
server.listen(Number(process.env.PORT || 8080), host, () => console.log('Bowser service ready'));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  server.close(() => { clearInterval(pruning); store.close(); process.exit(0); });
  server.closeIdleConnections();
  setTimeout(() => process.exit(1), 20000).unref();
});
