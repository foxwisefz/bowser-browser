"""Test-only candidate that dies or stalls after the old generation freezes."""
import asyncio
import json
import os
from pathlib import Path
import struct
import sys

async def client(reader, writer):
    size, = struct.unpack('>I', await reader.readexactly(4))
    message = json.loads(await reader.readexactly(size))
    if message['op'] == 'restore':
        if sys.argv[1] == 'die': os._exit(1)
        (Path(os.environ['BOWSER_HOME']) / 'restore.marker').touch()
        await asyncio.sleep(5)
    reply = json.dumps(dict(ok=True, schema=3)).encode()
    writer.write(struct.pack('>I', len(reply)) + reply)
    await writer.drain()
    writer.close()

async def main():
    server = await asyncio.start_unix_server(client, path=str(Path(os.environ['BOWSER_RELAY_DIR']) / 'control.sock'))
    async with server: await server.serve_forever()

asyncio.run(main())
