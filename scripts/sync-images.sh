#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
version=${1:?Usage: scripts/sync-images.sh vX.Y.Z}
[[ "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
curl --fail --silent --show-error --location --retry 3 --max-time 120 \
  "https://github.com/CopilotKit/OpenBot/releases/download/$version/container-images.json" -o "$scratch/upstream.json"
jq -e --arg version "$version" '
  select(.version == $version) |
  {images: (.images | with_entries(select(.key | IN("agent-computer", "agent-langgraph", "server", "supervisor"))) |
  map_values({reference: (.reference | sub("@"; ":" + $version + "@"))}))} |
  select(.images | length == 4)
' "$scratch/upstream.json" > "$scratch/pins.json"
cp "$scratch/pins.json" openbot-images.json
