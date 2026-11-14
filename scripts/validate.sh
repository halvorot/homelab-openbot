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
OPENAI_BASE_URL=https://gateway.example.invalid/v1
INTELLIGENCE_API_URL=https://intelligence.example.invalid
INTELLIGENCE_GATEWAY_WS_URL=wss://intelligence.example.invalid
CPK_INTELLIGENCE_API_KEY=ci-placeholder
COMPOSIO_API_KEY=ci-placeholder
ENV

compose config --format json > "$scratch/compose.json"
jq -e '
  (.networks.data.internal and .networks.control.internal) and
  (.services.server.environment.COMPOSIO_API_KEY == "ci-placeholder") and
  (all(.services | to_entries[] | select(.key != "server"); .value.environment.COMPOSIO_API_KEY == null)) and
  (.services.server.environment.OPENAI_BASE_URL == "https://gateway.example.invalid/v1") and
  (.services["agent-langgraph"].environment.OPENAI_BASE_URL == .services.server.environment.OPENAI_BASE_URL) and
  (.services.server.ports | length == 1 and .[0].host_ip == "127.0.0.1" and .[0].published == "3010") and
  (.services.postgres.networks | keys == ["data"]) and
  (.services.supervisor.networks | keys == ["control"]) and
  (.services.supervisor.environment.COMPUTER_NETWORK == .networks.computers.name) and
  ([.services | to_entries[] | select(.value.volumes[]?.source == "/var/run/docker.sock") | .key] == ["supervisor"]) and
  (all(.services | to_entries[]; . as $service | .value |
    (.privileged != true and .build == null and .network_mode != "host") and
    ($service.key == "server" or .ports == null)))
' "$scratch/compose.json" >/dev/null

version=$(jq -er '
  .services.server.image | capture("^ghcr[.]io/copilotkit/openbot-server:(?<version>v[0-9]+[.][0-9]+[.][0-9]+)$").version
' "$scratch/compose.json")
images=$(jq -er --arg version "$version" '
  .services as $services |
  {
    "agent-computer": $services.supervisor.environment.COMPUTER_IMAGE,
    "agent-langgraph": $services["agent-langgraph"].image,
    server: $services.server.image,
    supervisor: $services.supervisor.image
  } as $images |
  select($services.worker.image == $images.server and $services.migrate.image == $images.server) |
  select(all($images | to_entries[]; .value == ("ghcr.io/copilotkit/openbot-" + .key + ":" + $version))) |
  $images | to_entries[] | [.key, .value] | @tsv
' "$scratch/compose.json")
postgres=$(jq -er '
  .services.postgres.image | select(test("^pgvector/pgvector:[0-9]+[.][0-9]+[.][0-9]+-pg17-bookworm$"))
' "$scratch/compose.json")

if [[ "$mode" == --registry ]]; then
  curl --fail --silent --show-error --location --retry 3 --max-time 120 \
    "https://github.com/CopilotKit/OpenBot/releases/download/$version/container-images.json" -o "$scratch/upstream.json"
  jq -e --arg version "$version" '.version == $version' "$scratch/upstream.json" >/dev/null

  while IFS=$'\t' read -r component image; do
    manifest=$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$image")
    jq -e 'any(.manifests[]; .platform.os == "linux" and .platform.architecture == "amd64")' <<< "$manifest" >/dev/null
    if [[ "$component" != postgres ]]; then
      digest=$(jq -er '.digest' <<< "$manifest")
      reference="${image%:*}@$digest"
      if ! jq -e --arg component "$component" --arg reference "$reference" \
        '.images[$component].reference == $reference' "$scratch/upstream.json" >/dev/null; then
        echo "$image does not match the upstream $version release manifest." >&2
        exit 1
      fi
    fi
  done <<< "$images"$'\npostgres\t'"$postgres"
fi

echo "Validated OpenBot $version ($mode)"
