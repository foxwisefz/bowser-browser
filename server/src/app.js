import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { APIError, registration } from './validation.js';

const headers = { 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Cache-Control': 'no-store' };
const files = { '/': ['index.html', 'text/html; charset=utf-8'], '/index.html': ['index.html', 'text/html; charset=utf-8'],
  '/terms.html': ['terms.html', 'text/html; charset=utf-8'], '/styles.css': ['styles.css', 'text/css'],
  '/legal.css': ['legal.css', 'text/css'], '/script.js': ['script.js', 'text/javascript'], '/app-icon.webp': ['app-icon.webp', 'image/webp'] };
function json(res, status, body) { res.writeHead(status, { ...headers, 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); }
export async function readJSON(req) {
  if (!/^application\/json(?:\s*;\s*charset=utf-8)?$/i.test(req.headers['content-type'] || '')) throw new APIError(415, 'unsupported_media_type');
  if (req.headers['content-encoding'] && req.headers['content-encoding'] !== 'identity') throw new APIError(415, 'unsupported_encoding');
  return new Promise((resolve, reject) => {
    let size = 0; const chunks = []; let failed = false;
    req.on('data', chunk => {
      if (failed) return;
      size += chunk.length;
      if (size > 16_384) { failed = true; reject(new APIError(413, 'request_too_large')); return; }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (failed) return;
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
      catch { reject(new APIError(400, 'invalid_json')); }
    });
    req.on('error', reject);
    req.on('aborted', () => reject(new APIError(400, 'incomplete_request')));
  });
}
// Bounded in-memory limiter. Forwarded headers are intentionally ignored;
// only the configured reverse proxy may supply the client address.
export class RateLimit {
  constructor(limit = 20, maxKeys = 10000) { this.limit = limit; this.maxKeys = maxKeys; this.clients = new Map(); }
  accept(key, now) {
    const window = Math.floor(now / 60000);
    if (this.window !== window) { this.window = window; this.clients.clear(); }
    const count = this.clients.get(key) || 0;
    if (count >= this.limit || (!count && this.clients.size >= this.maxKeys)) return false;
    this.clients.set(key, count + 1); return true;
  }
}
export function createApp({ store, website, termsVersions = [], now = Date.now, trustedProxy, limit = new RateLimit(), routes = {} }) {
  // Exact allowlist: no file paths derived from incoming URLs, no private DB or
  // source files can be served, and a missing website fails startup.
  const assets = Object.fromEntries(Object.entries(files).map(([url, [file, type]]) => [url, { data: readFileSync(resolve(website, file)), type }]));
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 15000, headersTimeout: 10000 }, async (req, res) => {
    try {
      const path = new URL(req.url, 'http://localhost').pathname;
      if (path === '/healthz' && req.method === 'GET') { json(res, 200, { ok: true }); return; }
      if (req.method === 'GET' || req.method === 'HEAD') {
        const asset = assets[path];
        if (asset) {
          res.writeHead(200, { ...headers, 'Content-Type': asset.type, 'Content-Length': asset.data.length });
          res.end(req.method === 'HEAD' ? undefined : asset.data); return;
        }
      }
      if (path !== '/v1/registrations' && !routes[path]) throw new APIError(404, 'not_found');
      if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); throw new APIError(405, 'method_not_allowed'); }
      const remote = req.socket.remoteAddress;
      const client = trustedProxy && remote === trustedProxy ? req.headers['x-real-ip'] || remote : remote;
      if (!limit.accept(client, now())) { res.setHeader('Retry-After', '60'); throw new APIError(429, 'rate_limited'); }
      if (routes[path]) { await routes[path](req, res, { json, now }); return; }
      if (!termsVersions.length) throw new APIError(503, 'registration_unavailable');
      const body = registration(await readJSON(req), req.headers['idempotency-key'], termsVersions, now());
      const result = store.register(body, now());
      json(res, result.created ? 201 : 200, { registrationID: result.registrationID });
    } catch (error) {
      // Never reflect payloads, SQL errors, email addresses or credentials.
      if (!res.headersSent && !res.destroyed) json(res, error instanceof APIError ? error.status : 500,
        { error: { code: error instanceof APIError ? error.code : 'internal_error' } });
      else res.destroy();
    }
  });
  server.maxHeadersCount = 40;
  server.maxRequestsPerSocket = 100;
  return server;
}
