#!/usr/bin/env python3
"""Exercise production hostname/path routing against a local stub upstream."""
from pathlib import Path
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

SERVER = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def check():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'Caddyfile'
        config = (SERVER / 'deploy/bowser.caddy').read_text()
        for host in ['bowser.app', 'www.bowser.app', 'api.bowser.app']:
            config = re.sub(r'^' + re.escape(host) + r' \{', 'http://' + host + ' {', config, flags=re.M)
        config = config.replace('bowser:8080', '127.0.0.1:8080').replace('health_interval 15s', 'health_interval 100ms')
        path.write_text('{\n admin off\n}\n' + config + '\n:8080 {\n respond "upstream" 200\n}\n')
        container = subprocess.check_output(['docker', 'run', '-d', '--rm', '-p', '127.0.0.1::80',
            '-v', f'{path}:/etc/caddy/Caddyfile:ro', 'caddy:2'], text=True).strip()
        try:
            port = subprocess.check_output(['docker', 'port', container, '80/tcp'], text=True).strip().split(':')[-1]
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            def request(host, route):
                req = urllib.request.Request(f'http://127.0.0.1:{port}{route}', headers={'Host': host})
                try:
                    response = opener.open(req, timeout=2)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    return response.status, response.headers, response.read()
            # Each reverse_proxy handler has its own active health-check state.
            # A ready marketing handler does not imply a ready API handler.
            for host, route in [('www.bowser.app', '/'), ('api.bowser.app', '/healthz')]:
                deadline = time.monotonic() + 15
                last = 'no response'
                while time.monotonic() < deadline:
                    try:
                        status, _, body = request(host, route)
                        last = f'HTTP {status}: {body!r}'
                        if status == 200 and body == b'upstream':
                            break
                    except (OSError, urllib.error.URLError) as error:
                        last = str(error)
                    time.sleep(0.1)
                else:
                    raise AssertionError(f'{host}{route} did not become ready: {last}')

            def expect(host, route, expected):
                status, _, body = request(host, route)
                assert status == expected, f'{host}{route}: expected {expected}, got {status}: {body!r}'
                if expected == 200:
                    assert body == b'upstream', (host, route, body)

            status, headers, _ = request('bowser.app', '/hello?x=1')
            assert status == 301 and headers['Location'] == 'https://www.bowser.app/hello?x=1'
            for route in ['/', '/Bowser.dmg', '/terms.html']:
                expect('www.bowser.app', route, 200)
                expect('api.bowser.app', route, 404)
            for route in ['/healthz', '/v1/registrations', '/v1/events', '/updates/stable.json', '/updates/Bowser.dmg']:
                expect('api.bowser.app', route, 200)
                expect('www.bowser.app', route, 404)
            print('Caddy apex redirect and marketing/API route separation passed')
        except Exception:
            subprocess.run(['docker', 'logs', container], check=False)
            raise
        finally:
            subprocess.run(['docker', 'rm', '-f', container], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    check()
