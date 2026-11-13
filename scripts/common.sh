#!/usr/bin/env bash

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_env=${OPENBOT_ENV_FILE:-/etc/openbot/runtime.env}
cd "$repo" || exit 1

compose() {
  env -i PATH="$PATH" HOME="$HOME" \
    docker compose -f "$repo/compose.yaml" --env-file "$runtime_env" "$@"
}
