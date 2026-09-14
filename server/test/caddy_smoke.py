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
            for attempt in range(50):
                try:
                    status, _, _ = request('www.bowser.app', '/')
                    if status == 200:
                        break
                    time.sleep(0.1)
                except (OSError, urllib.error.URLError):
                    time.sleep(0.1)
            status, headers, _ = request('bowser.app', '/hello?x=1')
            assert status == 301 and headers['Location'] == 'https://www.bowser.app/hello?x=1'
            for route in ['/', '/Bowser.dmg', '/terms.html']:
                assert request('www.bowser.app', route)[0] == 200, (route, request('www.bowser.app', route))
                assert request('api.bowser.app', route)[0] == 404, route
            for route in ['/healthz', '/v1/registrations', '/v1/events', '/updates/stable.json', '/updates/Bowser.dmg']:
                assert request('api.bowser.app', route)[0] == 200, route
                assert request('www.bowser.app', route)[0] == 404, route
            print('Caddy apex redirect and marketing/API route separation passed')
        finally:
            subprocess.run(['docker', 'rm', '-f', container], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    check()
