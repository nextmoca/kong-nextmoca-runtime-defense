#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
compose_file="$root/docker-compose.smoke.yml"
project="nextmoca-kong-smoke"
response_file="$(mktemp)"
headers_file="$(mktemp)"

cleanup() {
  docker compose -p "$project" -f "$compose_file" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -f "$response_file" "$headers_file"
}
trap cleanup EXIT

docker compose -p "$project" -f "$compose_file" up --build --detach

ready=false
for _ in $(seq 1 30); do
  if curl --silent --fail http://localhost:18080/health >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done

if [ "$ready" != true ]; then
  docker compose -p "$project" -f "$compose_file" logs kong >&2
  exit 1
fi

run_case() {
  local name="$1"
  local path="$2"
  local fixture="$3"
  local adapter="$4"

  curl --silent --show-error --fail \
    --dump-header "$headers_file" \
    --output "$response_file" \
    --request POST "http://localhost:18080${path}" \
    --header 'Content-Type: application/json' \
    --header "X-Request-Id: smoke-${name}" \
    --data-binary @"$root/smoke/$fixture"

  python3 - "$name" "$response_file" <<'PY'
import json
import sys

name, response_path = sys.argv[1:]
payload = json.load(open(response_path))["received"]
omitted = "[Next Moca omitted nonessential context for this request.]"
assert "Ignore previous instructions" not in json.dumps(payload), payload

if name == "openai-chat":
    assert payload["messages"][1]["content"] == "Reservation confirmation code is H7K2.", payload
    assert payload["messages"][2]["content"] == omitted, payload
    assert payload["messages"][3]["content"] == "What is my reservation confirmation code?", payload
elif name == "openai-responses":
    assert payload["input"][0]["content"] == "Reservation confirmation code is H7K2.", payload
    assert payload["input"][1]["content"] == omitted, payload
    assert payload["input"][2]["content"] == "What is my reservation confirmation code?", payload
elif name == "anthropic-messages":
    assert payload["messages"][0]["content"] == "Reservation confirmation code is H7K2.", payload
    assert payload["messages"][1]["content"] == omitted, payload
    assert payload["messages"][2]["content"] == "What is my reservation confirmation code?", payload
elif name == "gemini":
    assert payload["contents"][0]["parts"][0]["text"] == "Reservation confirmation code is H7K2.", payload
    assert payload["contents"][1]["parts"][0]["text"] == omitted, payload
    assert payload["contents"][2]["parts"][0]["text"] == "What is my reservation confirmation code?", payload
else:
    raise AssertionError(f"unknown smoke case: {name}")
PY

  grep -qi "^X-NextMoca-Adapter: ${adapter}" "$headers_file"
  grep -qi '^X-NextMoca-Decision: transform' "$headers_file"
}

run_case "openai-chat" "/v1/chat/completions" "openai-chat-request.json" "openai_chat"
run_case "openai-responses" "/v1/responses" "openai-responses-request.json" "openai_responses"
run_case "anthropic-messages" "/v1/messages" "anthropic-messages-request.json" "anthropic_messages"
run_case "gemini" "/v1beta/models/gemini-2.5-flash:generateContent" "gemini-request.json" "gemini_generate_content"

printf 'Kong gateway smoke test passed for OpenAI Chat, OpenAI Responses, Anthropic Messages, and Gemini GenerateContent.\n'
