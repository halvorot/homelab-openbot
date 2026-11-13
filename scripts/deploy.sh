#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

# The forced SSH command holds the lock across checkout and deployment.
umask 077
backup_dir=${OPENBOT_BACKUP_DIR:-/var/backups/openbot}
test -s "$runtime_env"
compose config --quiet
scripts/validate.sh --registry
systemctl is-active --quiet openbot-firewall

compose pull
computer=$(jq -er '.images["agent-computer"].reference' openbot-images.json)
docker pull "$computer"
compose up -d --no-build --no-recreate --wait --wait-timeout 120 postgres

# Stop both clients before changing the database. Leave them stopped if migration fails.
compose stop worker server
install -d -m 0700 "$backup_dir"
backup=$(mktemp -d "$backup_dir/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short HEAD).XXXXXX")
scripts/backup.sh "$backup/postgres.dump"
compose up -d --no-build --wait --wait-timeout 120 postgres

compose up --no-build --no-deps --force-recreate --exit-code-from migrate migrate
compose up -d --no-build --no-deps --wait --wait-timeout 120 supervisor agent-langgraph
compose up -d --no-build --no-deps --wait --wait-timeout 120 server
compose up -d --no-build --no-deps worker
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for ((attempt = 0; attempt < 18; attempt++)); do
  logs=$(compose logs --no-color --since "$since" worker)
  if [[ "$logs" == *'"type":"routine-sweep"'* ]]; then
    echo 'OpenBot healthy and worker sweep succeeded.'
    exit 0
  fi
  sleep 5
done
echo 'OpenBot worker did not complete a fresh routine sweep.' >&2
exit 1
