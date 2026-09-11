"""Black-box tests of the compiled helper with disposable real BEAM releases.
Python is a developer test runner only; none of it is installed with Bowser.
"""
import asyncio
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import struct
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'shell/.build/debug/BowserBackendHost'
TOOL = ROOT / 'shell/.build/debug/BowserRuntimeTool'

async def receive(reader):
    size, = struct.unpack('>I', await reader.readexactly(4))
    return json.loads(await reader.readexactly(size))

def send(writer, message):
    data = json.dumps(message).encode()
    writer.write(struct.pack('>I', len(data)) + data)

async def request(path, message):
    reader, writer = await asyncio.open_unix_connection(str(path))
    try:
        send(writer, message)
        return await asyncio.wait_for(receive(reader), 30)
    finally:
        writer.close()
        await writer.wait_closed()

async def until(predicate, timeout=20):
    async def check():
        while not predicate(): await asyncio.sleep(.01)
    await asyncio.wait_for(check(), timeout)

class StartupTests(unittest.TestCase):
    def test_mobile_state_schema_is_rejected_before_starting_backend(self):
        with tempfile.TemporaryDirectory(prefix='bs.', dir='/tmp') as directory:
            root = Path(directory)
            runtime = root / 'app'
            runtime.mkdir()
            (runtime / 'HANDOFF.json').write_text('{"protocol":1,"state_schema":3}')
            result = subprocess.run([str(HOST), str(root), str(runtime)],
                                    capture_output=True, text=True, timeout=3)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('incompatible', result.stderr)
            self.assertFalse((root / 'backend/host.sock').exists())

    def test_invalid_release_exits_and_releases_socket(self):
        with tempfile.TemporaryDirectory(prefix='bs.',dir='/tmp') as directory:
            root=Path(directory); runtime=root/'app'; runtime.mkdir()
            (runtime/'HANDOFF.json').write_text('{"protocol":999,"state_schema":4}')
            result=subprocess.run([str(HOST),str(root),str(runtime)],capture_output=True,text=True,timeout=3,env={**os.environ,'PATH':'/nonexistent'})
            self.assertNotEqual(result.returncode,0)
            self.assertIn('incompatible',result.stderr)
            self.assertFalse((root/'backend/host.sock').exists())

@unittest.skipUnless(os.environ.get('BOWSER_TEST_RELEASE'), 'requires an actual built release')
class ReleaseTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bh.', dir='/tmp')
        self.home = Path(self.temp.name)
        self.runtime = self.home / 'app'
        self.runtime.mkdir()
        shutil.copytree(os.environ['BOWSER_TEST_RELEASE'], self.runtime / 'brain')
        (self.runtime / 'HANDOFF.json').write_text('{"protocol":1,"state_schema":4}')
        (self.home / 'mods').mkdir()
        (self.home / 'mods/Counter.ex').write_text('''
# bowser-profile: personal
        defmodule HandoffCounter do
          use BowserBrain.Mod, handoff: true
          def init_mod(_) do
            File.write!(Path.join(BowserBrain.Paths.home(), "init-count"), "init\\n", [:append])
            BowserBrain.Bridge.cast_msg(%{op: "chrome", chrome: "add_button", id: "fixture_button"})
            %{count: 0}
          end
          def handle_event(%{"event" => "counter"}, state) do
            next = %{state | count: state.count + 1}
            BowserBrain.Store.put(__MODULE__, "count", next.count)
            next
          end
          def handle_event(_, state), do: state
        end
        ''')
        self.native_writer = None
        self.commands = []
        self.connections = 0
        self.server = await asyncio.start_unix_server(self.native, path=str(self.home / 'brain.sock'))
        self.log = open(self.home / 'host.log', 'wb')
        self.process = await asyncio.create_subprocess_exec(str(HOST), str(self.home), str(self.runtime),
            env={**os.environ, 'BOWSER_X_PORT': '0', 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}, stdout=self.log, stderr=self.log)
        await until(lambda: (self.home / 'agent.sock').exists() or self.process.returncode is not None)
        self.assertIsNone(self.process.returncode, (self.home / 'host.log').read_text())
        await until(lambda: (self.home / 'init-count').exists())
        await asyncio.sleep(.1)

    async def native(self, reader, writer):
        self.connections += 1
        self.native_writer = writer
        send(writer, dict(op='hello', v=1, webviews=[1, 2], active=2,
            tabs=[dict(id=1, url='https://fixture.invalid/work', profile='work'),
                  dict(id=2, url='https://fixture.invalid/personal', profile='personal')]))
        try:
            while True:
                msg = await receive(reader)
                self.commands.append(msg)
                if msg.get('op') == 'get_cookies':
                    send(writer, dict(op='cookies_result', id=msg['id'], cookies=[]))
                elif msg.get('op') in ('eval_js', 'native_screenshot', 'native_click'):
                    send(writer, dict(op='js_result', id=msg['id'], ok=True,
                        value={} if msg['op'].startswith('native_') else None))
        except (ConnectionError, asyncio.IncompleteReadError):
            pass
        finally:
            writer.close()

    async def tool(self, tool, **args):
        reader, writer = await asyncio.open_unix_connection(str(self.home / 'agent.sock'))
        writer.write(json.dumps(dict(tool=tool, args=args)).encode() + b'\n')
        try:
            return json.loads(await asyncio.wait_for(reader.readline(), 3))
        finally:
            writer.close()
            await writer.wait_closed()

    async def count(self, wanted):
        async def check():
            while True:
                value = await self.tool('store_get', mod='HandoffCounter', key='count')
                if value.get('value') == wanted:
                    return
                await asyncio.sleep(.02)
        await asyncio.wait_for(check(), 5)
        # Give the closed external connection's serving task time to exit.
        await asyncio.sleep(.03)

    def event(self):
        send(self.native_writer, dict(op='event', event='counter', id='fixture_button', profile='personal'))

    async def asyncTearDown(self):
        if self.process.returncode is None:
            try: await self.control('stop')
            except (OSError, asyncio.IncompleteReadError): self.process.terminate()
            await asyncio.wait_for(self.process.wait(), 10)
        self.server.close(); await self.server.wait_closed()
        self.log.close()
        self.temp.cleanup()

    async def control(self, op, **values):
        return await request(self.home / 'backend/host.sock', dict(op=op, **values))

    async def generation_status(self):
        # Only one active control endpoint after each settled operation.
        endpoints = list((self.home / 'backend').glob('g*/control.sock'))
        self.assertEqual(len(endpoints), 1)
        return await request(endpoints[0], dict(op='status'))

    def candidate(self, name='next'):
        target = self.home / 'releases' / name
        shutil.copytree(self.runtime, target)
        return target

    async def test_native_verification_replies_survive_relay_id_translation(self):
        for tool, args in [('native_screenshot', {}), ('native_click', {'x': 12, 'y': 20})]:
            reply = await self.tool(tool, webview=2, **args)
            self.assertTrue(reply['ok'], reply)
            self.assertIn('id', next(c for c in reversed(self.commands) if c.get('op') == tool))

    async def test_installer_handoff_preserves_mod_heap_profiles_and_host_connection(self):
        for _ in range(3): self.event()
        await self.count(3)
        core_before = (await self.generation_status())['core']
        stage = self.home / 'stage'
        shutil.copytree(self.runtime, stage / 'runtime')
        pending = self.home / 'updates/pending.json'
        pending.parent.mkdir()
        pending.write_text(json.dumps(dict(home=str(self.home), stage=str(stage), runtime=str(self.runtime), bundle=str(self.home / 'Bowser.app'))))
        sent = 3
        stop = asyncio.Event()
        async def traffic():
            nonlocal sent
            while not stop.is_set():
                self.event(); sent += 1
                await asyncio.sleep(.02)
        task = asyncio.create_task(traffic())
        try:
            process = await asyncio.create_subprocess_exec(str(TOOL), 'apply-update', str(pending), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            stdout, stderr = await process.communicate()
            self.assertEqual(process.returncode, 0, stderr.decode())
            self.assertTrue(json.loads(pending.read_text()).get('backend_applied'), stdout.decode())
        finally:
            stop.set(); await task
        await self.count(sent)
        self.assertEqual(self.connections, 1)
        self.assertEqual((self.home / 'init-count').read_text(), 'init\n')
        state = await self.generation_status()
        self.assertEqual(state['profiles'], {'1': 'work', '2': 'personal'})
        self.assertFalse(state['restoring'])
        self.assertEqual(state['core'], core_before)
        result = json.loads((self.home / 'backend/last-update.json').read_text())
        self.assertLess(result['handoff_ms'], 1000)
        forbidden = {'navigate', 'open_tab', 'close_tab', 'activate_tab', 'reload'}
        self.assertFalse([m for m in self.commands if m.get('op') in forbidden])
        print('NATIVE REAL RELEASE HANDOFF:', result, 'counter=', sent)

    async def test_core_only_session_updates_and_keeps_deck_and_menu_controls(self):
        (self.home / 'mods/Counter.ex').unlink()
        await asyncio.sleep(.7)
        before = (await self.generation_status())['core']
        result = await self.control('update', runtime=str(self.candidate()))
        self.assertTrue(result['ok'], result)
        after = (await self.generation_status())['core']
        self.assertEqual(before, after)
        self.assertEqual(after['tab_deck']['order'], [1, 2])
        self.assertEqual(after['tab_deck']['active'], 2)
        send(self.native_writer, dict(op='event', event='surface', surface='edge_dock', id='select', value='1'))
        await until(lambda: any(m.get('op') == 'activate_tab' and m.get('webview') == 1 for m in self.commands), 2)
        send(self.native_writer, dict(op='event', event='chrome_click', id='panel:edge_dock'))
        await asyncio.sleep(.05)
        self.assertFalse((await self.generation_status())['core']['panel_menu']['menu']['panel:edge_dock']['checked'])

    async def test_legacy_mod_defers_before_warming_candidate(self):
        (self.home / 'mods/Legacy.ex').write_text("defmodule LegacyHandoffFixture do\n use BowserBrain.Mod\nend\n")
        await asyncio.sleep(.7)
        result = await self.control('update', runtime=str(self.candidate()))
        self.assertFalse(result['ok'])
        self.assertIn('safe handoff contract', result['error'])
        self.assertEqual(len(list((self.home / 'backend').glob('g*'))), 1)
        self.event(); await self.count(1)

    async def test_quit_releases_backend_without_closing_native_server(self):
        send(self.native_writer, {'op': 'app_quit'})
        self.assertEqual(await asyncio.wait_for(self.process.wait(), 10), 0)
        self.assertFalse((self.home / 'backend/host.sock').exists())
        self.assertFalse(list((self.home / 'backend').glob('g*')))
        self.assertTrue(self.server.is_serving())

    async def test_incompatible_release_never_pauses_active_backend(self):
        candidate = self.candidate()
        (candidate / 'HANDOFF.json').write_text('{"protocol":999,"state_schema":4}')
        result = await self.control('update', runtime=str(candidate))
        self.assertFalse(result['ok']); self.assertIn('incompatible', result['error'])
        self.event(); await self.count(1)

    async def test_duplicate_host_does_not_steal_socket_or_spawn_brain(self):
        other = await asyncio.create_subprocess_exec(str(HOST), str(self.home), str(self.runtime))
        self.assertEqual(await asyncio.wait_for(other.wait(), 3), 0)
        status = await self.control('status')
        self.assertEqual(status['pid'], self.process.pid)
        self.assertEqual(status['implementation'], 'swift')
        self.assertEqual(self.connections, 1)

    async def test_crashed_beam_is_replaced_without_reconnecting_native(self):
        rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,comm='], text=True).splitlines()
        children = [int(parts[0]) for row in rows if len(parts := row.split(None, 2)) == 3 and int(parts[1]) == self.process.pid]
        self.assertEqual(len(children), 1)
        os.kill(children[0], signal.SIGKILL)
        await until(lambda: (self.home / 'init-count').read_text().count('init') == 2)
        self.assertEqual(self.connections, 1)
        self.assertEqual((await self.control('status'))['pid'], self.process.pid)
        self.event(); await self.count(1)

    async def test_installed_launcher_starts_and_stops_native_host(self):
        await self.control('stop'); await asyncio.wait_for(self.process.wait(), 10)
        binaries=self.runtime/'bin'; binaries.mkdir()
        shutil.copy2(ROOT/'bin/bowser',binaries/'bowser')
        shutil.copy2(HOST,binaries/'backend-host')
        shutil.copy2(TOOL,binaries/'detach')
        env={**os.environ,'BOWSER_HOME':str(self.home),'BOWSER_APP_DIR':str(self.runtime),'BOWSER_X_PORT':'0','PATH':'/usr/bin:/bin:/usr/sbin:/sbin'}
        try:
            launcher=await asyncio.create_subprocess_exec(str(binaries/'bowser'),'start-brain',env=env,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
            stdout,stderr=await asyncio.wait_for(launcher.communicate(),15)
            self.assertEqual(launcher.returncode,0,stderr.decode())
            await until(lambda: (self.home/'init-count').read_text().count('init')==2)
            self.assertEqual((await self.control('status'))['implementation'],'swift')
            self.event(); await self.count(1)
        finally:
            stop=await asyncio.create_subprocess_exec(str(binaries/'bowser'),'stop-brain',env=env)
            await asyncio.wait_for(stop.wait(),15)
        self.assertFalse((self.home/'backend/host.sock').exists())
        self.assertFalse(list((self.home/'backend').glob('g*')))

    async def test_signal_shutdown_reaps_owned_children(self):
        self.process.terminate()
        await asyncio.wait_for(self.process.wait(), 10)
        self.assertFalse((self.home / 'backend/host.sock').exists())
        self.assertFalse(list((self.home / 'backend').glob('g*')))
        self.assertTrue(self.server.is_serving())

    def fake_candidate(self, mode):
        target = self.home / 'releases' / mode
        (target / 'brain/bin').mkdir(parents=True)
        (target / 'HANDOFF.json').write_text('{"protocol":1,"state_schema":4}')
        script = ROOT / 'tests/fixtures/handoff_candidate.py'
        executable = target / 'brain/bin/bowser_brain'
        executable.write_text('#!/bin/sh\nexec /usr/bin/python3 "' + str(script) + '" ' + mode + '\n')
        executable.chmod(0o755)
        return target

    async def test_candidate_death_rolls_back_before_authority(self):
        self.event(); await self.count(1)
        result = await self.control('update', runtime=str(self.fake_candidate('die')))
        self.assertFalse(result['ok'])
        self.event(); await self.count(2)
        self.assertEqual((self.home / 'init-count').read_text(), 'init\n')
        self.assertFalse((self.home / 'backend/active.json').exists())
        self.assertTrue((self.home / 'backend/last-rollback.json').exists())

    async def test_journal_failure_resumes_old_backend_without_losing_events(self):
        self.event(); await self.count(1)
        task = asyncio.create_task(self.control('update', runtime=str(self.fake_candidate('slow'))))
        await until(lambda: (self.home / 'restore.marker').exists())
        journal = self.home / 'backend/handoff.journal'
        journal.unlink(); journal.mkdir()  # Real filesystem write failure, no mocked host internals.
        self.event()
        result = await task
        self.assertFalse(result['ok'])
        await self.count(2)
        self.assertFalse((self.home / 'backend/active.json').exists())
        self.assertTrue((self.home / 'backend/last-rollback.json').exists())

if __name__ == '__main__': unittest.main()
