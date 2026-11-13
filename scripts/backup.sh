#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

target=${1:?Usage: scripts/backup.sh /absolute/path/to/new.dump}
[[ "$target" = /* && ! -e "$target" ]]
umask 077
temporary=$(mktemp "${target}.XXXXXX")
trap 'rm -f -- "$temporary"' EXIT
compose exec -T postgres pg_dump -U openbot -d openbot --format=custom > "$temporary"
test -s "$temporary"
compose exec -T postgres pg_restore --list < "$temporary" >/dev/null
ln -- "$temporary" "$target"
