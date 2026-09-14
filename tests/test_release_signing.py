"""Exercise the release setup script with a disposable, simulated keychain."""
import base64
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/setup-release-signing'
NAME = 'Developer ID Application: Fixture Company (TESTTEAM01)'
DIGEST = 'A' * 40


class ReleaseSigningTests(unittest.TestCase):
    def run_setup(self, identities, name=NAME):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for tool, body in {
                'security': '#!/bin/bash\nif [ "$1" = find-identity ]; then printf "%s\\n" "$FIXTURE_IDENTITIES"; fi\n',
                'xcrun': '#!/bin/bash\ntouch "$RUNNER_TEMP/notary-called"\n',
            }.items():
                file = root / tool
                file.write_text(body)
                file.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ['PATH'],
                       RUNNER_TEMP=str(root), GITHUB_ENV=str(root / 'env'),
                       APPLE_CERTIFICATE_BASE64=base64.b64encode(b'fixture').decode(),
                       APPLE_CERTIFICATE_PASSWORD='fixture', APPLE_SIGN_IDENTITY=name,
                       APPLE_ID='fixture@example.invalid', APPLE_TEAM_ID='TESTTEAM01',
                       APPLE_APP_SPECIFIC_PASSWORD='fixture', FIXTURE_IDENTITIES=identities)
            result = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)
            return (result, (root / 'env').read_text() if (root / 'env').exists() else '',
                    (root / 'notary-called').exists(), (root / 'bowser-signing.p12').exists())

    def test_matching_identity_exports_fingerprint(self):
        result, values, notary, certificate = self.run_setup(f'1) {DIGEST} "{NAME}"', NAME + ' ')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('BOWSER_SIGN_IDENTITY=' + DIGEST, values)
        self.assertIn('BOWSER_SIGN_KEYCHAIN=', values)
        self.assertTrue(notary)
        self.assertFalse(certificate)

    def test_missing_private_key_fails_before_notarization(self):
        result, values, notary, certificate = self.run_setup('0 valid identities found')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('private key', result.stderr)
        self.assertFalse(values or notary or certificate)

    def test_wrong_identity_is_not_silently_selected(self):
        result, values, notary, certificate = self.run_setup(f'1) {DIGEST} "Developer ID Application: Another Company (OTHERTEAM1)"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exactly one', result.stderr)
        self.assertFalse(values or notary or certificate)


if __name__ == '__main__':
    unittest.main()
