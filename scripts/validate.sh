#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "$0")/common.sh"

mode=${1:---offline}
if [[ "$mode" != --offline && "$mode" != --registry ]]; then
  echo 'Usage: scripts/validate.sh [--offline|--registry]' >&2
  exit 2
fi

scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
version=$(jq -er '
  .images.server.reference | capture(":(?<version>v[0-9]+[.][0-9]+[.][0-9]+)@").version
' openbot-images.json)
jq -e '
  .images | keys == ["agent-computer", "agent-langgraph", "server", "supervisor"]
' openbot-images.json >/dev/null
for component in server supervisor agent-computer agent-langgraph; do
  jq -e --arg component "$component" --arg version "$version" '
    .images[$component].reference | startswith("ghcr.io/copilotkit/openbot-" + $component + ":" + $version + "@") and
    test("@sha256:[0-9a-f]{64}$")' openbot-images.json >/dev/null
done
runtime_env="$scratch/runtime.env"
cp .env.example "$runtime_env"
cat >> "$runtime_env" <<'ENV'
POSTGRES_PASSWORD=ci-placeholder
KEY_ENCRYPTION_KEY=ci-placeholder
SUPERVISOR_TOKEN=ci-placeholder
COMPUTER_TOKEN=ci-placeholder
WORKER_SHARED_SECRET=ci-placeholder
AGENT_TOOL_TOKEN=ci-placeholder
MANAGED_AGENT_TOKEN=ci-placeholder
BETTER_AUTH_SECRET=ci-placeholder
INITIAL_ADMIN_EMAILS=ci@example.invalid
GOOGLE_OAUTH_CLIENT_ID=ci-placeholder
GOOGLE_OAUTH_CLIENT_SECRET=ci-placeholder
BOT_PROVIDER=openai
OPENAI_API_KEY=ci-placeholder
INTELLIGENCE_API_URL=https://intelligence.example.invalid
INTELLIGENCE_GATEWAY_WS_URL=wss://intelligence.example.invalid
CPK_INTELLIGENCE_API_KEY=ci-placeholder
ENV

compose config --format json > "$scratch/compose.json"
jq -e '
  (.networks.data.internal and .networks.control.internal) and
  (.services.server.ports | length == 1 and .[0].host_ip == "127.0.0.1" and .[0].published == "3010") and
  (.services.postgres.networks | keys == ["data"]) and
  (.services.supervisor.networks | keys == ["control"]) and
  (.services.supervisor.environment.COMPUTER_NETWORK == .networks.computers.name) and
  ([.services | to_entries[] | select(.value.volumes[]?.source == "/var/run/docker.sock") | .key] == ["supervisor"]) and
  (all(.services | to_entries[]; . as $service | .value |
    (.privileged != true and .build == null and .network_mode != "host") and
    (.image | test("@sha256:[0-9a-f]{64}$")) and
    ($service.key == "server" or .ports == null)))
' "$scratch/compose.json" >/dev/null

if [[ "$mode" == --registry ]]; then
  curl --fail --silent --show-error --location --retry 3 --max-time 120 \
    "https://github.com/CopilotKit/OpenBot/releases/download/$version/container-images.json" -o "$scratch/upstream.json"
  jq -e --arg version "$version" --slurpfile upstream "$scratch/upstream.json" '
    $version == $upstream[0].version and
    all(.images | to_entries[]; . as $pin | ($pin.value.reference | sub(":" + $version + "@"; "@")) == $upstream[0].images[$pin.key].reference)
  ' openbot-images.json >/dev/null
  images=$(compose config --images | sort -u)
  computer=$(jq -er '.images["agent-computer"].reference' openbot-images.json)
  while IFS= read -r image; do
    docker buildx imagetools inspect --raw "$image" |
      jq -e 'any(.manifests[]; .platform.os == "linux" and .platform.architecture == "amd64")' >/dev/null
  done <<< "$images"$'\n'"$computer"
fi

echo "Validated OpenBot $version ($mode)"
