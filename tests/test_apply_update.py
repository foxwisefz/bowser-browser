import importlib.machinery
import tempfile
import unittest
from pathlib import Path

update = importlib.machinery.SourceFileLoader('apply_update', str(Path(__file__).resolve().parents[1] / 'bin/apply-update')).load_module()

class UpdateTests(unittest.TestCase):
    def test_running_host_or_brain_prevents_activation(self):
        m = dict(bundle='/tmp/Bowser.app', runtime='/tmp/runtime')
        for process in ['/tmp/Bowser.app/Contents/MacOS/Bowser', '/tmp/runtime/brain/erts-1/bin/beam.smp',
                        str(Path.home() / 'Applications/Bowser Apps/site.app/Contents/MacOS/launch')]:
            self.assertTrue(update.busy(m, process))
        self.assertFalse(update.busy(m, '/usr/bin/python3\n/tmp/Other.app/Contents/MacOS/Other'))

    def test_activation_preserves_previous_pair(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            m = dict(stage=str(root / 'stage'), runtime=str(root / 'runtime'), bundle=str(root / 'Bowser.app'))
            for key in ('runtime', 'bundle'):
                target = Path(m[key]); target.mkdir(); (target / 'version').write_text('old')
                source = root / 'stage' / key; source.mkdir(parents=True); (source / 'version').write_text('new')
            update.activate(m)
            for key in ('runtime', 'bundle'):
                target = Path(m[key])
                self.assertEqual((target / 'version').read_text(), 'new')
                self.assertEqual((target.with_name(target.name + '.previous') / 'version').read_text(), 'old')

    def test_failed_second_swap_rolls_back_runtime(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            m = dict(stage=str(root / 'stage'), runtime=str(root / 'runtime'), bundle=str(root / 'Bowser.app'))
            for key in ('runtime', 'bundle'):
                target = Path(m[key]); target.mkdir(); (target / 'version').write_text('old')
                source = root / 'stage' / key; source.mkdir(parents=True); (source / 'version').write_text('new')
            rename = Path.rename
            def fail(source, target):
                if source == root / 'stage/bundle': raise OSError('fixture failure')
                return rename(source, target)
            with patch.object(Path, 'rename', fail):
                with self.assertRaises(OSError): update.activate(m)
            for key in ('runtime', 'bundle'):
                self.assertEqual((Path(m[key]) / 'version').read_text(), 'old')
                self.assertEqual((root / 'stage' / key / 'version').read_text(), 'new')

    def test_busy_main_leaves_manifest_and_does_not_swap(self):
        import json
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            pending = Path(directory) / 'pending.json'
            pending.write_text(json.dumps(dict(stage='unused', runtime='unused', bundle='unused')))
            with patch('sys.argv', ['apply-update', str(pending)]), patch.object(update, 'busy', return_value=True), patch.object(update, 'activate') as activate:
                update.main()
                activate.assert_not_called()
            self.assertTrue(pending.exists())

    def test_partial_updates_preserve_previously_staged_components(self):
        import json
        for shell_only in (True, False):
            with self.subTest(shell_only=shell_only), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                pending = root / 'pending.json'
                old, new = root / 'old', root / 'new'
                for stage in (old, new):
                    (stage / 'runtime/brain').mkdir(parents=True)
                    (stage / 'runtime/brain/version').write_text(stage.name)
                (old / 'bundle').mkdir()
                (old / 'bundle/version').write_text('old-pending-shell')
                manifest = dict(runtime=str(root / 'live-runtime'), bundle=str(root / 'live.app'))
                pending.write_text(json.dumps(dict(manifest, stage=str(old))))
                update.publish(pending, dict(manifest, stage=str(new)), shell_only=shell_only, brain_only=not shell_only)
                self.assertEqual(json.loads(pending.read_text())['stage'], str(new))
                if shell_only:
                    self.assertEqual((new / 'runtime/brain/version').read_text(), 'old')
                else:
                    self.assertEqual((new / 'bundle/version').read_text(), 'old-pending-shell')
                    self.assertEqual((new / 'runtime/brain/version').read_text(), 'new')
                self.assertFalse(old.exists())

if __name__ == '__main__': unittest.main()
