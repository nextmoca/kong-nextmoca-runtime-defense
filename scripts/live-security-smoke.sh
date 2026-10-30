#!/usr/bin/env bash
set -euo pipefail

: "${NEXTMOCA_API_KEY:?Set NEXTMOCA_API_KEY to a non-production key before running this smoke test.}"

root="$(cd "$(dirname "$0")/.." && pwd)"
plugin_image="${NEXTMOCA_IMAGE:-nextmoca/kong-runtime-defense:live-security-smoke}"
echo_image="nextmoca/kong-runtime-defense-echo:live-security-smoke"
endpoint="${NEXTMOCA_ENDPOINT:-https://api.nextmoca.com}"
operating_point="${NEXTMOCA_OPERATING_POINT:-np-2026-10-r8}"
suffix="$$"
network="nextmoca-live-security-${suffix}"
upstream="nextmoca-live-security-upstream-${suffix}"
tmpdir="$(mktemp -d)"
containers=()

cleanup() {
  local container
  for container in "${containers[@]:-}"; do
    docker rm --force "$container" >/dev/null 2>&1 || true
  done
  docker rm --force "$upstream" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

docker build --quiet --tag "$plugin_image" "$root" >/dev/null
docker build --quiet --file "$root/smoke/Dockerfile" --tag "$echo_image" "$root" >/dev/null
docker network create "$network" >/dev/null
docker run --detach --name "$upstream" --network "$network" --env ROLE=upstream "$echo_image" >/dev/null

write_config() {
  local mode="$1"
  local config="$2"
  cat > "$config" <<CONFIG
_format_version: "3.0"
_transform: true

services:
  - name: local-echo
    url: http://${upstream}:8080
    routes:
      - name: local-echo-route
        paths:
          - /
        strip_path: false
    plugins:
      - name: nextmoca-runtime-defense
        config:
          endpoint: ${endpoint}
          api_key_env: NEXTMOCA_API_KEY
          operating_point: ${operating_point}
          mode: ${mode}
          request_adapter: openai_chat
          unsupported_shape: block
          on_selection_error: block
          max_context_tokens: 512
          capacity_tokens: 32768
          autochunk: true
          timeout_ms: 3000
          breaker_failures: 3
          breaker_cooldown_ms: 30000
CONFIG
}

wait_for_gateway() {
  local container="$1"
  for _ in $(seq 1 30); do
    if docker logs "$container" 2>&1 | grep -q "declarative config loaded"; then
      return 0
    fi
    sleep 1
  done
  docker logs "$container" >&2
  return 1
}

assert_sanitized_delivery() {
  local response_file="$1"
  local mode="$2"
  node - "$response_file" "$mode" <<'NODE'
const fs = require("fs");
const [responsePath, mode] = process.argv.slice(2);
const response = JSON.parse(fs.readFileSync(responsePath, "utf8"));
if (!response.received) {
  throw new Error(`${mode}: local upstream did not receive a rewritten request`);
}
const forwarded = JSON.stringify(response.received);
if (/ignore previous instructions|attacker@example\.com|delete the audit log/i.test(forwarded)) {
  throw new Error(`${mode}: malicious instruction reached the local upstream`);
}
console.log(`${mode}: sanitized delivery verified`);
NODE
}

run_case() {
  local mode="$1"
  local fixture="$2"
  local config="$tmpdir/${mode}.yml"
  local container="nextmoca-live-security-${mode}-${suffix}"
  local headers="$tmpdir/${mode}.headers"
  local response="$tmpdir/${mode}.json"
  local port
  local http_status

  write_config "$mode" "$config"
  docker run --detach --name "$container" --network "$network" --publish 127.0.0.1::8000 \
    --volume "$config:/kong/declarative/kong.yml:ro" \
    --env KONG_DATABASE=off \
    --env KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml \
    --env KONG_PROXY_LISTEN=0.0.0.0:8000 \
    --env KONG_PLUGINS=bundled,nextmoca-runtime-defense \
    --env KONG_NGINX_MAIN_ENV=NEXTMOCA_API_KEY \
    --env NEXTMOCA_API_KEY \
    "$plugin_image" >/dev/null
  containers+=("$container")
  wait_for_gateway "$container"
  port="$(docker port "$container" 8000/tcp | sed -E 's/.*:([0-9]+)$/\1/')"
  http_status="$(curl --silent --show-error --write-out '%{http_code}' --dump-header "$headers" --output "$response" \
    --request POST "http://127.0.0.1:${port}/v1/chat/completions" \
    --header 'Content-Type: application/json' \
    --header "X-Request-Id: live-security-${mode}" \
    --data-binary @"$root/smoke/$fixture")"

  if [ "$http_status" = "200" ]; then
    grep -qi '^X-NextMoca-Decision: transform' "$headers"
    assert_sanitized_delivery "$response" "$mode"
  elif [ "$mode" = "enforce" ] && [ "$http_status" = "403" ]; then
    node - "$response" <<'NODE'
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (response.code !== "context_security_blocked") {
  throw new Error(`enforce: expected context_security_blocked, received ${response.code || "unknown"}`);
}
console.log("enforce: gateway block verified");
NODE
  else
    printf '%s returned unexpected HTTP %s\n' "$mode" "$http_status" >&2
    node - "$response" <<'NODE' >&2
const fs = require("fs");
const response = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
console.error(`gateway error code: ${response.code || "unknown"}`);
NODE
    return 1
  fi
}

run_case "quarantine" "security-quarantine-request.json"
run_case "enforce" "security-enforce-request.json"
printf 'Hosted Next Moca quarantine and enforce gateway smoke tests passed.\n'
