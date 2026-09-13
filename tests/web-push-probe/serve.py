import http.server
import json
import pathlib
import sys

PAGE = b'''<html><body>Isolated Bowser push probe<script>
const report = (event, value) => window.webkit.messageHandlers.probe.postMessage({event,value});
(async () => {
  report('apis', {secure:isSecureContext, notification:typeof Notification, push:typeof PushManager, worker:typeof navigator.serviceWorker});
  try {
    await navigator.serviceWorker.register('/sw.js');
    const registration = await navigator.serviceWorker.ready;
    report('worker_active', registration.active.state);
    report('permission', Notification.permission);
    const pair = await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'}, true, ['sign','verify']);
    const key = await crypto.subtle.exportKey('raw',pair.publicKey);
    try {
      const result = await Promise.race([
        registration.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:new Uint8Array(key)}),
        new Promise((_,reject) => setTimeout(() => reject(new Error('subscription timeout')),5000))]);
      report('subscription', result.toJSON());
    } catch(e) { report('subscription_error', {name:e.name,message:e.message}); }
    report('ready', true);
  } catch(e) { report('setup_error', {name:e.name,message:e.message}); }
})();
</script></body></html>'''
WORKER = b'''
self.addEventListener('install', e => e.waitUntil(self.skipWaiting()));
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('push', e => e.waitUntil((async () => {
  await fetch('/evidence', {method:'POST',body:JSON.stringify({event:'worker_push',payload:e.data?.text(),clients:(await clients.matchAll({type:'window',includeUncontrolled:true})).length})});
  try { await self.registration.showNotification('Bowser probe', {body:'Local test only'}); }
  catch(error) { await fetch('/evidence',{method:'POST',body:JSON.stringify({event:'notification_error',message:error.message})}); }
})()));
self.addEventListener('notificationclick', e => e.waitUntil(fetch('/evidence',{method:'POST',body:JSON.stringify({event:'worker_notificationclick'})})));
'''
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = WORKER if self.path == '/sw.js' else PAGE
        self.send_response(200)
        self.send_header('Content-Type', 'text/javascript' if self.path == '/sw.js' else 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        data = self.rfile.read(min(int(self.headers.get('Content-Length', 0)), 8192))
        print(data.decode(), flush=True)
        self.send_response(204)
        self.end_headers()
    def log_message(self, *args): pass

server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
