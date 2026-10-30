# Kong Plugin Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a reproducible OCI release path and the production documentation and security validation needed to operate the Kong plugin.

**Architecture:** A tag-triggered GitHub Actions workflow publishes a thin multi-architecture OCI image to GHCR. Static release validation protects its required properties. Deployment and operations documentation covers the only tested runtime boundary, while an explicit local script tests hosted quarantine and enforcement behavior without committing credentials.

**Tech Stack:** Kong Gateway 3.8, Lua, Docker Buildx, GitHub Actions, Bash, Kubernetes manifests, Helm values.

**Spec:** `docs/superpowers/specs/2026-10-29-kong-plugin-release-design.md`

## Global Constraints

- Publish only the standalone thin Kong plugin repository.
- Use `v0.1.1` for the first release and GHCR repository `ghcr.io/nextmoca/kong-nextmoca-runtime-defense`.
- Never commit API keys, captured context, or hosted response bodies.
- Support only the explicitly tested Kong Gateway 3.8 DB-less deployment in the compatibility contract.

## Review Focus

- Verify the release job cannot publish from an untagged push.
- Verify OCI labels point to the standalone public repository, not the monorepo.
- Verify Kubernetes values reference a Secret rather than an inline API key.
- Verify quarantine testing cannot accidentally forward the attack marker upstream.
- Verify enforce testing accepts only a gateway block, not a local assertion of intent.

### Task 1: Reproducible OCI Release

**Files:**
- Create: `.github/workflows/release.yml`
- Create: `scripts/verify-release-assets.sh`
- Modify: `Makefile`

- [ ] Write a failing release-asset validation script that expects a tag-only workflow, package write permission, multi-architecture output, OCI source metadata, and a release check target.
- [ ] Run `make release-check` and verify it fails because the release assets do not exist.
- [ ] Add the minimal release workflow and Make target required for the validator.
- [ ] Run `make release-check`, `make test`, `make lint`, and `make smoke`.

### Task 2: Deployment and Operations Contract

**Files:**
- Create: `deploy/helm/values.yaml`
- Create: `deploy/kubernetes/nextmoca-api-key-secret.example.yaml`
- Create: `docs/DEPLOYMENT.md`
- Create: `docs/OPERATIONS.md`
- Create: `docs/COMPATIBILITY.md`
- Modify: `README.md`

- [ ] Extend the release validator to require a secret reference, the image tag, and supported-boundary documentation.
- [ ] Run `make release-check` and verify it fails for the absent deployment assets.
- [ ] Add deployment and operational documents with the release contract from the spec.
- [ ] Run `make release-check` and the existing complete local suite.

### Task 3: Hosted Security Smoke Test

**Files:**
- Create: `scripts/live-security-smoke.sh`
- Modify: `Makefile`
- Modify: `README.md`

- [ ] Add a local policy regression test covering safe sanitized delivery and an enforce block verdict.
- [ ] Run `make test` and verify the new assertions fail before their expected policy inputs exist.
- [ ] Add an opt-in script that starts only disposable local containers, calls the hosted endpoint with `NEXTMOCA_API_KEY`, and validates quarantine and enforce result boundaries.
- [ ] Run the local suite, then run `make live-security-smoke` with a supplied secret.

### Task 4: Main Branch and Release

**Files:**
- No source changes expected.

- [ ] Create and push `main` from the verified release commit.
- [ ] Set `main` as the repository default branch.
- [ ] Push annotated `v0.1.1`, monitor the release workflow, verify its GHCR digest and GitHub release, and ensure the package is public.
