#!/bin/bash
# Invoked over Tailscale SSH by deploy.py. stdin: registry token line, then tar.
set -euo pipefail
umask 077
deploy_dir="$1"
image="$2"
registry_user="$3"
[[ "$deploy_dir" = /* && "$deploy_dir" != / ]]
[[ "$image" =~ ^ghcr\.io/[a-z0-9._/-]+@sha256:[a-f0-9]{64}$ ]]
mkdir -p "$deploy_dir"
cd "$deploy_dir"
exec 9>.deploy.lock
flock -w 300 9
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export DOCKER_CONFIG="$scratch/docker"
mkdir -p "$DOCKER_CONFIG" "$scratch/files"
IFS= read -r registry_token
printf '%s' "$registry_token" | docker login ghcr.io --username "$registry_user" --password-stdin >/dev/null
unset registry_token
tar -xf - -C "$scratch/files"
docker pull "$image"
# Preserve operator configuration across deployments.
if [[ ! -f .env ]]; then
  cp "$scratch/files/.env.example" .env
fi
chmod 600 .env
export BOWSER_SERVER_IMAGE="$image"
export BOWSER_ENV_FILE="$deploy_dir/.env"
compose=(docker compose --project-name bowser --project-directory "$deploy_dir" -f "$scratch/files/compose.yaml")
"${compose[@]}" config --quiet
# Keep the previous deployment configuration for an explicit rollback.
if [[ -f image.env && -f compose.yaml ]]; then
  cp -f image.env previous-image.env
  cp -f compose.yaml previous-compose.yaml
fi
"${compose[@]}" up -d --no-build --wait --wait-timeout 120 bowser
cp -f "$scratch/files/compose.yaml" compose.yaml
mkdir -p deploy
cp -f "$scratch/files/deploy/"* deploy/
printf 'BOWSER_SERVER_IMAGE=%s\n' "$image" > image.env.next
mv -f image.env.next image.env
printf 'Healthy Bowser deployment: %s\n' "$image"
