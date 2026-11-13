#!/usr/bin/env bash

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_env=${OPENBOT_ENV_FILE:-/etc/openbot/runtime.env}
cd "$repo" || exit 1

compose() {
  local server supervisor computer langgraph
  server=$(jq -er '.images.server.reference' openbot-images.json) || return
  supervisor=$(jq -er '.images.supervisor.reference' openbot-images.json) || return
  computer=$(jq -er '.images["agent-computer"].reference' openbot-images.json) || return
  langgraph=$(jq -er '.images["agent-langgraph"].reference' openbot-images.json) || return
  env -i PATH="$PATH" HOME="$HOME" SERVER_IMAGE="$server" SUPERVISOR_IMAGE="$supervisor" \
    COMPUTER_IMAGE="$computer" LANGGRAPH_IMAGE="$langgraph" \
    docker compose -f "$repo/compose.yaml" --env-file "$repo/images.env" \
    --env-file "$runtime_env" "$@"
}
