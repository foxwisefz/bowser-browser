#!/usr/bin/env python3
"""Disposable controller for the real Bowser bridge; never talks to the installed app."""
import json
import os
from pathlib import Path
import socket
import struct
import sys

home, generation = Path(sys.argv[1]), int(sys.argv[2])
if not str(home).startswith(('/tmp/bowser-handoff.', '/private/tmp/bowser-handoff.')):
    raise SystemExit('Refusing a non-fixture socket')
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect(str(home / 'brain.sock'))

def receive_exact(size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise SystemExit('Host disconnected')
        data.extend(part)
    return data

while True:
    size = struct.unpack('!I', receive_exact(4))[0]
    if size > 64 * 1024 * 1024:
        raise SystemExit('Invalid frame')
    message = json.loads(receive_exact(size))
    if message.get('op') == 'hello':
        if message.get('v') != 1 or len(message['webviews']) != 1:
            raise SystemExit('Unexpected fixture protocol or views')
        command = dict(op='eval_js', id=generation, webview=message['webviews'][0],
            code="window.controllerGeneration=%d;document.getElementById('generation').textContent='Controller %d';window.controllerGeneration" % (generation, generation))
        payload = json.dumps(command).encode()
        sock.sendall(struct.pack('!I', len(payload)) + payload)
    if message.get('op') == 'js_result' and message.get('id') == generation:
        if not message.get('ok') or message.get('value') != generation:
            raise SystemExit('Generation change failed: ' + repr(message))
        (home / ('ready-%d.json' % generation)).write_text(json.dumps(dict(pid=os.getpid(), generation=generation)))
        sock.settimeout(None)
