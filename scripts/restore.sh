#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

dump=${1:?Usage: scripts/restore.sh /path/to/postgres.dump}
test -s "$dump"
umask 077
exec 9>/run/lock/openbot-deploy.lock
flock -w 300 9

if [[ -n "$(compose ps -a -q postgres)" ]] || docker volume inspect openbot_postgres >/dev/null 2>&1; then
  echo 'Restore requires a fresh OpenBot project with no PostgreSQL container or volume.' >&2
  exit 1
fi

compose up -d --no-build --wait --wait-timeout 120 postgres
compose exec -T postgres pg_restore -U openbot -d openbot \
  --exit-on-error --single-transaction --no-owner --no-privileges < "$dump"
echo 'PostgreSQL restored. Restore computer volumes and verify the release before deploying.'
