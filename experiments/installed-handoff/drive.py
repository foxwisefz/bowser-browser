"""Exercise the shipped updater/relay with the disposable native video host."""
import asyncio
import importlib.machinery
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time

HOME, REPO = map(Path, sys.argv[1:])
assert HOME.name.startswith('bowser-handoff.')
hostmod = importlib.machinery.SourceFileLoader('installed_backend', str(REPO / 'bin/backend-host')).load_module()
update = importlib.machinery.SourceFileLoader('installed_update', str(REPO / 'bin/apply-update')).load_module()
os.environ['BOWSER_X_PORT'] = '0'

async def main():
    runtime = HOME / 'app'
    runtime.mkdir()
    shutil.copytree(REPO / 'beam/_build/prod/rel/bowser_brain', runtime / 'brain')
    (runtime / 'HANDOFF.json').write_text('{"protocol":1,"state_schema":2}')
    (HOME / 'mods').mkdir()
    (HOME / 'mods/Receipt.ex').write_text('''
    defmodule InstalledReceipt do
      use BowserBrain.Mod, handoff: true
      def init_mod(_), do: %{count: 0}
      def handle_event(%{"payload" => %{"kind" => "handoff_probe", "sequence" => seq}}, state) do
        next = %{state | count: state.count + 1}
        File.open!(Path.join(BowserBrain.Paths.home(), "receipts.jsonl"), [:append, :binary], fn f ->
          IO.binwrite(f, JSON.encode!(%{sequence: seq, count: next.count}) <> "\\n")
          :file.sync(f)
        end)
        next
      end
      def handle_event(_, state), do: state
    end
    ''')
    host = hostmod.Host(HOME, runtime)
    running = asyncio.create_task(host.run())
    owner = asyncio.current_task()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, owner.cancel)
    try:
        await hostmod.until(lambda: (HOME / 'agent.sock').exists(), 25)
        await asyncio.sleep(.3)
        (HOME / 'initial-ready').touch()
        await hostmod.until(lambda: (HOME / 'run-backend-test').exists(), 120)
        stage = HOME / 'stage'
        shutil.copytree(runtime, stage / 'runtime')
        manifest = dict(home=str(HOME), stage=str(stage), runtime=str(runtime), bundle=str(HOME / 'Bowser.app'))
        assert await asyncio.to_thread(update.live_update, manifest), manifest
        result = json.loads((HOME / 'backend/last-update.json').read_text())
        await asyncio.sleep(1)
        old = host.active
        bad = HOME / 'releases/bad'
        shutil.copytree(runtime, bad)
        boot = host.boot
        async def broken(runtime):
            candidate = await boot(runtime)
            # Fail after receiving a checkpoint and attaching, but before gaining
            # event/command authority. This tests the shipped rollback boundary.
            call = candidate.call
            async def fail(op, **values):
                reply = await call(op, **values)
                if op == 'restore':
                    candidate.process.kill()
                    await candidate.process.wait()
                return reply
            candidate.call = fail
            return candidate
        host.boot = broken
        start = time.monotonic()
        try:
            await host.update(bad)
        except Exception:
            pass
        else:
            raise AssertionError('candidate should have failed')
        assert host.active is old
        rollback = (time.monotonic() - start) * 1000
        rollback_gap = json.loads((HOME / 'backend/last-rollback.json').read_text())['rollback_ms']
        assert rollback_gap < 1000, rollback_gap
        await asyncio.sleep(1)
        (HOME / 'stop-probes').touch()
        await hostmod.until(lambda: (HOME / 'probes-stopped').exists(), 5)
        await asyncio.sleep(.3)
        receipts = [json.loads(line) for line in (HOME / 'receipts.jsonl').read_text().splitlines()]
        assert [r['sequence'] for r in receipts] == list(range(1, len(receipts) + 1))
        assert [r['count'] for r in receipts] == list(range(1, len(receipts) + 1))
        result.update(probesCaptured=len(receipts), rollbackIncludingWarmupMS=rollback, rollbackGapMS=rollback_gap,
                      modHeapPreserved=True, exactOrderedReceipts=True,
                      scope='Shipped installer live_update and backend-host with full release and stateful mod')
        (HOME / 'backend-result.json').write_text(json.dumps(result, indent=2))
        await asyncio.sleep(3)
    except Exception as error:
        (HOME / 'backend-failure.txt').write_text(repr(error))
        raise
    finally:
        host.done.set()
        await running

asyncio.run(main())
