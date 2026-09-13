import http.server
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Content-Disposition', 'attachment; filename="resource-download.bin"')
        self.send_header('Content-Length', str(1024 * 1024))
        self.end_headers()
        try:
            for _ in range(64):
                self.wfile.write(b'x' * 16384)
                self.wfile.flush()
                time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def log_message(self, *args):
        pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'download-url').write_text(f'http://127.0.0.1:{server.server_port}/download')
server.serve_forever()
