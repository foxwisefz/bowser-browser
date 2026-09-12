"""Exercise the publication gate without credentials or an Apple submission."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/notarize'


class NotarizationGateTests(unittest.TestCase):
    def check_submission(self, status, submit_exit=0, staple_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root / 'xcrun'
            fake.write_text('''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['CALLS'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
if sys.argv[1:3] == ['notarytool', 'submit']:
    print(json.dumps({'id':'fixture', 'status':os.environ['STATUS']}))
    sys.exit(int(os.environ['SUBMIT_EXIT']))
if sys.argv[1:3] == ['stapler', 'staple']:
    sys.exit(int(os.environ['STAPLE_EXIT']))
''')
            fake.chmod(0o755)
            calls = root / 'calls'
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       BOWSER_NOTARY_PROFILE='fixture', BOWSER_SIGN_KEYCHAIN='',
                       CALLS=str(calls), STATUS=status, SUBMIT_EXIT=str(submit_exit),
                       STAPLE_EXIT=str(staple_exit))
            result = subprocess.run([str(SCRIPT), 'fixture.zip', 'fixture.app'],
                                    env=env, capture_output=True, text=True)
            return result.returncode, [json.loads(x)[:2] for x in calls.read_text().splitlines()]

    def test_accepted_submission_staples_and_validates(self):
        code, calls = self.check_submission('Accepted')
        self.assertEqual(code, 0)
        self.assertEqual(calls, [['notarytool', 'submit'], ['stapler', 'staple'], ['stapler', 'validate']])

    def test_rejection_or_timeout_never_staples(self):
        for status, code in [('Invalid', 0), ('In Progress', 1)]:
            with self.subTest(status=status):
                result, calls = self.check_submission(status, submit_exit=code)
                self.assertNotEqual(result, 0)
                self.assertEqual(calls, [['notarytool', 'submit']])

    def test_failed_staple_fails_release(self):
        code, calls = self.check_submission('Accepted', staple_exit=1)
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, [['notarytool', 'submit'], ['stapler', 'staple']])
