#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$root/.github/workflows/release.yml"

require_file() {
  test -f "$1" || {
    printf 'missing required release asset: %s\n' "$1" >&2
    exit 1
  }
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "$pattern" "$file" || {
    printf 'missing required release setting %q in %s\n' "$pattern" "$file" >&2
    exit 1
  }
}

require_file "$workflow"
require_pattern "tags:" "$workflow"
require_pattern "- 'v*'" "$workflow"
require_pattern "contents: write" "$workflow"
require_pattern "packages: write" "$workflow"
require_pattern "linux/amd64,linux/arm64" "$workflow"
require_pattern 'ghcr.io/${{ github.repository_owner }}/kong-nextmoca-runtime-defense' "$workflow"
require_pattern 'org.opencontainers.image.source=https://github.com/${{ github.repository }}' "$workflow"
require_pattern "steps.image.outputs.digest" "$workflow"
require_pattern "org.opencontainers.image.source=\"https://github.com/nextmoca/kong-nextmoca-runtime-defense\"" "$root/Dockerfile"

copy_sources="$(sed -n -E 's/^COPY[[:space:]]+([^[:space:]]+).*/\1/p' "$root/Dockerfile")"
if [ "$copy_sources" != "kong/plugins/nextmoca-runtime-defense" ]; then
  printf 'the release image must copy only the thin Kong plugin directory\n' >&2
  exit 1
fi

helm_values="$root/deploy/helm/values.yaml"
secret_example="$root/deploy/kubernetes/nextmoca-api-key-secret.example.yaml"
compatibility="$root/docs/COMPATIBILITY.md"
operations="$root/docs/OPERATIONS.md"

require_file "$helm_values"
require_file "$secret_example"
require_file "$compatibility"
require_file "$operations"
require_pattern "repository: ghcr.io/nextmoca/kong-nextmoca-runtime-defense" "$helm_values"
require_pattern "tag: \"0.1.1\"" "$helm_values"
require_pattern "nginx_main_env: NEXTMOCA_API_KEY" "$helm_values"
require_pattern "secretKeyRef:" "$helm_values"
require_pattern "Kong Gateway 3.8" "$compatibility"
require_pattern "text-only" "$compatibility"
require_pattern "X-NextMoca-Decision" "$operations"
require_pattern "np-2026-10-r8" "$root/kong/plugins/nextmoca-runtime-defense/schema.lua"
require_pattern "np-2026-10-r8" "$root/README.md"

printf 'release asset check passed\n'
