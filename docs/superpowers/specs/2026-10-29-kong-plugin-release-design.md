# Kong Plugin Release Design

## Intent

Make the standalone `nextmoca/kong-nextmoca-runtime-defense` repository
installable and operable as a public, thin Kong Gateway plugin. Customers must
be able to deploy one immutable OCI image, configure their secret through their
normal secret manager, and understand both the supported request boundary and
the runtime behavior when the hosted service is unavailable.

## Goals

- Publish multi-architecture, immutable GHCR images from signed release tags.
- Keep the image limited to the Kong plugin client. No selection, scanning,
  quarantine, or policy implementation is copied into the image.
- Document a tested DB-less Kong Gateway 3.8 deployment, including a Helm
  values example and Kubernetes secret reference.
- Document the receipt headers, delivery modes, timeout and circuit-breaker
  behavior, and useful operational alerts.
- Provide a repeatable, opt-in hosted security smoke test for both
  `quarantine` and `enforce` delivery modes.

## Non-goals

- Bundling or mirroring Next Moca core logic.
- Making a broad compatibility claim for untested Kong versions, Konnect, or
  hybrid/control-plane deployments.
- Storing customer credentials, context, or model requests in the repository
  or test artifacts.
- Replacing an organization's existing secret manager, SIEM, or monitoring
  stack.

## Architecture

The release workflow runs the existing test, lint, and local gateway smoke
suite before it builds a `linux/amd64` and `linux/arm64` OCI manifest. It tags
the image with the release semver and commit SHA, attaches standard OCI source
metadata, and creates a GitHub release. A `release-check` target validates
that the workflow and deployment assets retain the required safety properties.

The hosted security smoke test starts disposable local Kong and echo-upstream
containers. It gives only Kong an API key through an environment variable,
sends deterministic malicious-context fixtures through the hosted Next Moca
endpoint, and asserts either sanitized upstream delivery (`quarantine`) or a
gateway block (`enforce`). It removes all disposable containers and temporary
files when finished.

## Compatibility Contract

The initial supported deployment is the official Kong Gateway 3.8 container in
DB-less declarative mode, on Linux `amd64` and `arm64`. The public API boundary
is text-only candidate context inside OpenAI Chat/Responses, Anthropic
Messages, or Gemini GenerateContent request bodies. Unsupported content is
passed or blocked according to the explicitly configured policy.

## Release Policy

The first standalone release after the hosted-contract compatibility fix is
`v0.1.1`. `main` is the repository's release branch. Publishing occurs only
from a pushed `v*` tag and creates an immutable, digest-addressable image.
