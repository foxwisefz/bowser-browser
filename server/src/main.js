import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Store } from './store.js';
import { createApp } from './app.js';

process.umask(0o077);
const store = new Store(resolve(process.env.BOWSER_DATABASE || 'data/bowser.sqlite'));
const server = createApp({ store, website: fileURLToPath(new URL('../../website/', import.meta.url)),
  termsVersions: (process.env.BOWSER_TERMS_VERSIONS || '').split(',').map(s => s.trim()).filter(Boolean),
  trustedProxy: process.env.BOWSER_TRUSTED_PROXY });
server.listen(Number(process.env.PORT || 8080), process.env.HOST || '127.0.0.1', () => console.log('Bowser service ready'));
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
  server.close(() => { store.close(); process.exit(0); });
  server.closeIdleConnections();
  setTimeout(() => process.exit(1), 20000).unref();
});
