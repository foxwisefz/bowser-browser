"""Real release integration tests. BOWSER_TEST_RELEASE must name a built release.
Runs only with disposable homes, local Unix sockets and an ephemeral X port.
"""
import asyncio
import importlib.machinery
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
hostmod = importlib.machinery.SourceFileLoader('backend_host', str(ROOT / 'bin/backend-host')).load_module()
update = importlib.machinery.SourceFileLoader('backend_update', str(ROOT / 'bin/apply-update')).load_module()

class ProtocolTests(unittest.TestCase):
    def test_runtime_process_in_generation_blocks_native_activation(self):
        manifest = dict(home='/tmp/test-home', bundle='/tmp/Bowser.app', runtime='/tmp/app')
        self.assertTrue(update.busy(manifest, '/tmp/test-home/releases/abc/brain/erts-16/bin/beam.smp'))

@unittest.skipUnless(os.environ.get('BOWSER_TEST_RELEASE'), 'requires an actual built release')
class ReleaseTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bh.', dir='/tmp')
        self.home = Path(self.temp.name)
        self.runtime = self.home / 'app'
        self.runtime.mkdir()
        shutil.copytree(os.environ['BOWSER_TEST_RELEASE'], self.runtime / 'brain')
        (self.runtime / 'HANDOFF.json').write_text('{"protocol":1,"state_schema":3}')
        (self.home / 'mods').mkdir()
        (self.home / 'mods/Counter.ex').write_text('''
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
        self.server = await asyncio.start_unix_server(self.native, path=str(self.home / 'brain.sock'))
        self.env = patch.dict(os.environ, {'BOWSER_X_PORT': '0'})
        self.env.start()
        self.host = hostmod.Host(self.home, self.runtime)
        self.running = asyncio.create_task(self.host.run())
        await hostmod.until(lambda: (self.home / 'agent.sock').exists(), 25)
        await hostmod.until(lambda: (self.home / 'init-count').exists(), 5)
        await asyncio.sleep(.1)

    async def native(self, reader, writer):
        self.native_writer = writer
        hostmod.send(writer, dict(op='hello', v=1, webviews=[1, 2], active=2,
            tabs=[dict(id=1, url='https://fixture.invalid/work', profile='work'),
                  dict(id=2, url='https://fixture.invalid/personal', profile='personal')]))
        try:
            while True:
                msg = await hostmod.receive(reader)
                self.commands.append(msg)
                if msg.get('op') == 'get_cookies':
                    hostmod.send(writer, dict(op='cookies_result', id=msg['id'], cookies=[]))
                elif msg.get('op') in ('eval_js', 'native_screenshot', 'native_click'):
                    hostmod.send(writer, dict(op='js_result', id=msg['id'], ok=True,
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
        hostmod.send(self.native_writer, dict(op='event', event='counter', id='fixture_button'))

    async def asyncTearDown(self):
        self.host.done.set()
        await asyncio.wait_for(self.running, 10)
        self.server.close()
        await self.server.wait_closed()
        self.env.stop()
        self.temp.cleanup()

    async def test_native_verification_replies_survive_relay_id_translation(self):
        for tool, args in [('native_screenshot', {}), ('native_click', {'x': 12, 'y': 20})]:
            reply = await self.tool(tool, webview=2, **args)
            self.assertTrue(reply['ok'], reply)
            command = next(c for c in reversed(self.commands) if c.get('op') == tool)
            self.assertIn('id', command)

    async def test_installer_handoff_preserves_mod_heap_profiles_and_host_connection(self):
        for _ in range(3): self.event()
        await self.count(3)
        old = self.host.active
        core_before = (await old.call('status'))['core']
        native = self.native_writer
        stage = self.home / 'stage'
        shutil.copytree(self.runtime, stage / 'runtime')
        manifest = dict(home=str(self.home), stage=str(stage), runtime=str(self.runtime), bundle=str(self.home / 'Bowser.app'))
        # Emit throughout warmup and the actual freeze/restore boundary.
        sent = 3
        stop = asyncio.Event()
        async def traffic():
            nonlocal sent
            while not stop.is_set():
                self.event(); sent += 1
                await asyncio.sleep(.02)
        task = asyncio.create_task(traffic())
        try:
            passed = await asyncio.to_thread(update.live_update, manifest)
        finally:
            stop.set(); await task
        self.assertTrue(passed, manifest.get('deferred_reason'))
        await self.count(sent)
        self.assertIsNot(old, self.host.active)
        self.assertIs(native, self.native_writer)
        self.assertIsNotNone(old.process.returncode)
        self.assertEqual((self.home / 'init-count').read_text(), 'init\n')
        self.assertTrue(any(m.get('op') == 'chrome' and m.get('id') == 'fixture_button' for m in self.commands))
        tabs = await self.tool('list_tabs')
        self.assertEqual(tabs['active'], 2)
        self.assertEqual(len(tabs['tabs']), 2)
        state = await self.host.active.call('status')
        self.assertEqual(state['profiles'], {'1': 'work', '2': 'personal'})
        self.assertFalse(state['restoring'])
        self.assertEqual(state['core'], core_before)
        result = json.loads((self.home / 'backend/last-update.json').read_text())
        self.assertLess(result['handoff_ms'], 1000)
        forbidden = {'navigate', 'open_tab', 'close_tab', 'activate_tab', 'reload'}
        self.assertFalse([m for m in self.commands if m.get('op') in forbidden])
        print('REAL RELEASE HANDOFF:', result, 'counter=', sent)

    async def test_core_only_session_updates_and_keeps_deck_and_menu_controls(self):
        (self.home / 'mods/Counter.ex').unlink()
        await asyncio.sleep(.7)
        old = self.host.active
        before = (await old.call('status'))['core']
        releases = self.home / 'releases'
        releases.mkdir()
        candidate = releases / 'core-only'
        shutil.copytree(self.runtime, candidate)
        result = await self.host.update(candidate)
        self.assertTrue(result['ok'])
        self.assertLess(result['handoff_ms'], 1000)
        after = (await self.host.active.call('status'))['core']
        self.assertEqual(before, after)
        self.assertEqual(after['tab_deck']['order'], [1, 2])
        self.assertEqual(after['tab_deck']['active'], 2)
        self.assertIn('panel:edge_dock', after['panel_menu']['menu'])
        hostmod.send(self.native_writer, dict(op='event', event='surface', surface='edge_dock', id='select', value='1'))
        await hostmod.until(lambda: any(m.get('op') == 'activate_tab' and m.get('webview') == 1 for m in self.commands), 2)
        hostmod.send(self.native_writer, dict(op='event', event='chrome_click', id='panel:edge_dock'))
        await asyncio.sleep(.05)
        after_toggle = (await self.host.active.call('status'))['core']
        self.assertFalse(after_toggle['panel_menu']['menu']['panel:edge_dock']['checked'])
        print('CORE-ONLY HANDOFF:', result)

    async def test_candidate_death_rolls_back_before_authority(self):
        self.event(); await self.count(1)
        releases = self.home / 'releases'
        releases.mkdir()
        candidate = releases / 'bad'
        shutil.copytree(self.runtime, candidate)
        old = self.host.active
        boot = self.host.boot
        async def die_after_warmup(runtime):
            gen = await boot(runtime)
            gen.process.kill()
            await gen.process.wait()
            return gen
        self.host.boot = die_after_warmup
        with self.assertRaises(Exception):
            await self.host.update(candidate)
        self.assertIs(self.host.active, old)
        self.event(); await self.count(2)
        self.assertEqual((self.home / 'init-count').read_text(), 'init\n')
        self.assertFalse((self.home / 'backend/active.json').exists())

    async def test_legacy_mod_defers_before_warming_candidate(self):
        (self.home / 'mods/Legacy.ex').write_text("defmodule LegacyHandoffFixture do\n use BowserBrain.Mod\nend\n")
        await asyncio.sleep(.7)
        releases = self.home / 'releases'
        releases.mkdir()
        candidate = releases / 'legacy'
        shutil.copytree(self.runtime, candidate)
        children = len(self.host.children)
        with self.assertRaisesRegex(RuntimeError, 'safe handoff contract'):
            await self.host.update(candidate)
        self.assertEqual(len(self.host.children), children)
        self.assertFalse(self.host.paused)
        self.event(); await self.count(1)

    async def test_buffer_disk_failure_resumes_old_backend_without_losing_events(self):
        import sqlite3
        self.event(); await self.count(1)
        releases = self.home / 'releases'
        releases.mkdir()
        candidate = releases / 'disk-full'
        shutil.copytree(self.runtime, candidate)
        old = self.host.active
        db = self.host.db
        class FullDisk:
            def execute(_, sql, *args):
                if sql.startswith('insert'):
                    raise sqlite3.OperationalError('fixture disk full')
                return db.execute(sql, *args)
            def commit(_): return db.commit()
            def close(_): return db.close()
        self.host.db = FullDisk()
        boot = self.host.boot
        async def slow_restore(runtime):
            gen = await boot(runtime)
            call = gen.call
            async def slow(op, **values):
                if op == 'restore':
                    self.event()
                    await asyncio.sleep(.1)
                return await call(op, **values)
            gen.call = slow
            return gen
        self.host.boot = slow_restore
        with self.assertRaises(asyncio.CancelledError):
            await self.host.update(candidate)
        self.assertIs(self.host.active, old)
        self.assertFalse(self.host.paused)
        await self.count(2)
        self.assertFalse((self.home / 'backend/active.json').exists())

    async def test_quit_releases_all_backends_without_closing_native_server(self):
        hostmod.send(self.native_writer, {'op': 'app_quit'})
        await asyncio.wait_for(self.running, 5)
        self.assertTrue(all(g.process.returncode is not None for g in self.host.children))
        self.assertFalse((self.home / 'backend/host.sock').exists())
        self.assertTrue(self.server.is_serving())

    async def test_incompatible_release_never_pauses_active_backend(self):
        releases = self.home / 'releases'
        releases.mkdir()
        candidate = releases / 'incompatible'
        candidate.mkdir()
        (candidate / 'HANDOFF.json').write_text('{"protocol":999,"state_schema":3}')
        old = self.host.active
        with self.assertRaisesRegex(RuntimeError, 'incompatible'):
            await self.host.update(candidate)
        self.assertFalse(self.host.paused)
        self.assertIs(old, self.host.active)
        self.event(); await self.count(1)

if __name__ == '__main__':
    unittest.main()
