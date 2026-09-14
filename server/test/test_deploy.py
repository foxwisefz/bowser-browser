"""Run the remote deployment protocol against a fake Docker CLI."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import runpy
import shlex
from unittest.mock import patch
import unittest

SERVER = Path(__file__).resolve().parents[1]
IMAGE = 'ghcr.io/foxwisefz/bowser-browser/server@sha256:' + 'a' * 64


class DeployTests(unittest.TestCase):
    def run_deploy(self, fail=False, existing=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / 'deployment with spaces'
            target.mkdir()
            if existing:
                (target / '.env').write_text('OPERATOR_VALUE=preserve\n')
                (target / 'image.env').write_text('old digest\n')
                (target / 'compose.yaml').write_text('old compose\n')
            tools = root / 'bin'
            tools.mkdir()
            (tools / 'flock').write_text('#!/bin/sh\nexit 0\n')
            (tools / 'docker').write_text('''#!/bin/bash
printf '%s\\n' "$*" >> "$TEST_LOG"
if [[ "$1" = login ]]; then
  read -r token
  [[ "$token" = fixture-token ]] || exit 2
  printf '%s' "$DOCKER_CONFIG" > "$TEST_CONFIG"
  touch "$DOCKER_CONFIG/credential"
fi
if [[ "$*" = *" up "* && "$FAIL_HEALTH" = 1 ]]; then exit 7; fi
''')
            for path in tools.iterdir():
                path.chmod(0o700)
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode='w') as tar:
                for name in ['compose.yaml', '.env.example', 'deploy/caddy.compose.yaml', 'deploy/bowser.caddy']:
                    tar.add(SERVER / name, arcname=name)
            env = dict(os.environ, PATH=str(tools) + ':' + os.environ['PATH'],
                       TEST_LOG=str(root / 'log'), TEST_CONFIG=str(root / 'config-path'),
                       FAIL_HEALTH='1' if fail else '0')
            result = subprocess.run(['bash', str(SERVER / 'deploy/remote.sh'), str(target), IMAGE, 'fixture'],
                                    input=b'fixture-token\n' + buf.getvalue(), capture_output=True, env=env)
            log = (root / 'log').read_text()
            self.assertNotIn('fixture-token', log)
            self.assertFalse(Path((root / 'config-path').read_text()).exists())
            self.assertNotIn('--build', log)
            self.assertIn('--no-build --wait --wait-timeout 120', log)
            self.assertLess(log.index('pull '), log.index(' up '))
            if existing:
                self.assertEqual((target / '.env').read_text(), 'OPERATOR_VALUE=preserve\n')
                self.assertEqual((target / 'previous-image.env').read_text(), 'old digest\n')
            if fail:
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((target / 'image.env').read_text(), 'old digest\n')
                self.assertEqual((target / 'compose.yaml').read_text(), 'old compose\n')
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((target / 'image.env').read_text(), 'BOWSER_SERVER_IMAGE=' + IMAGE + '\n')
                self.assertTrue((target / 'deploy/bowser.caddy').is_file())
                self.assertTrue((target / 'downloads').is_dir())
                self.assertEqual((target / '.env').stat().st_mode & 0o777, 0o600)

    def test_success_preserves_operator_config(self):
        self.run_deploy()

    def test_failed_health_does_not_mark_release_successful(self):
        self.run_deploy(fail=True)

    def test_first_deploy_bootstraps(self):
        self.run_deploy(existing=False)


class ClientTests(unittest.TestCase):
    def test_encrypted_stdin_protocol_and_quoted_remote_command(self):
        client = runpy.run_path(str(SERVER / 'deploy/deploy.py'))
        env = dict(BOWSER_DEPLOY_HOST='dodorouter.tail5bb99c.ts.net',
                   BOWSER_DEPLOY_USER='ubuntu', BOWSER_DEPLOY_DIR="/home/ubuntu/bowser's files",
                   BOWSER_SERVER_IMAGE=IMAGE, GH_TOKEN='fixture-token', GITHUB_ACTOR='fixture')
        with patch.dict(os.environ, env), patch('subprocess.run') as run:
            client['deploy']()
        args, kwargs = run.call_args
        self.assertEqual(args[0][:3], ['tailscale', 'ssh', 'ubuntu@dodorouter.tail5bb99c.ts.net'])
        self.assertNotIn('fixture-token', args[0][3])
        remote_args = shlex.split(args[0][3])
        self.assertEqual(remote_args[-3], env['BOWSER_DEPLOY_DIR'])
        token, archive = kwargs['input'].split(b'\n', 1)
        self.assertEqual(token, b'fixture-token')
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            self.assertEqual(set(tar.getnames()), {'compose.yaml', '.env.example',
                             'deploy/caddy.compose.yaml', 'deploy/bowser.caddy'})

    def test_mutable_tag_rejected_before_connection(self):
        client = runpy.run_path(str(SERVER / 'deploy/deploy.py'))
        env = dict(BOWSER_DEPLOY_HOST='dodorouter', BOWSER_DEPLOY_USER='ubuntu',
                   BOWSER_DEPLOY_DIR='/home/ubuntu/bowser',
                   BOWSER_SERVER_IMAGE='ghcr.io/owner/repo:latest', GH_TOKEN='fixture')
        with patch.dict(os.environ, env), patch('subprocess.run') as run:
            with self.assertRaises(ValueError):
                client['deploy']()
            run.assert_not_called()
