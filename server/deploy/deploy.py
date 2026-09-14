#!/usr/bin/env python3
"""Send deployment config and a short-lived GHCR token over Tailscale SSH."""
import io
import os
from pathlib import Path
import re
import shlex
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]


def deploy():
    host = os.environ['BOWSER_DEPLOY_HOST']
    user = os.environ['BOWSER_DEPLOY_USER']
    directory = os.environ['BOWSER_DEPLOY_DIR']
    image = os.environ['BOWSER_SERVER_IMAGE']
    token = os.environ['GH_TOKEN']
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9.-]*', host):
        raise ValueError('Invalid deployment hostname')
    if not re.fullmatch(r'[a-z_][a-z0-9_-]*', user):
        raise ValueError('Invalid deployment user')
    if not directory.startswith('/') or directory == '/' or '\n' in directory:
        raise ValueError('Deployment directory must be an absolute non-root path')
    if not re.fullmatch(r'ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}', image):
        raise ValueError('An immutable GHCR image digest is required')
    if not token or '\n' in token or '\r' in token:
        raise ValueError('Invalid registry token')
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode='w') as tar:
        for name in ['compose.yaml', '.env.example', 'deploy/caddy.compose.yaml', 'deploy/bowser.caddy']:
            tar.add(ROOT / name, arcname=name, recursive=False)
    command = shlex.join(['bash', '-c', (ROOT / 'deploy/remote.sh').read_text(),
                          'bowser-deploy', directory, image, os.environ['GITHUB_ACTOR']])
    # Token is sent on encrypted stdin, never in the remote command or persisted config.
    subprocess.run(['tailscale', 'ssh', f'{user}@{host}', command],
                   input=token.encode() + b'\n' + archive.getvalue(), check=True, timeout=600)


if __name__ == '__main__':
    deploy()
