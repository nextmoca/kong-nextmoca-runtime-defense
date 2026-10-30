# Kong Provider Adapters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a public, thin Kong plugin that invokes the hosted Next Moca Select API for OpenAI Chat, OpenAI Responses, Anthropic Messages, and native Gemini GenerateContent request bodies.

**Architecture:** Provider adapters parse and rewrite only the text coordinates they own. A registry resolves a single adapter, and the shared hosted client and delivery policy operate through that adapter interface. Kong’s handler reads the raw request body in `access`, invokes the hosted service, rewrites the upstream request or returns the configured gateway block response, and adds content-free receipt headers.

**Tech Stack:** Kong Gateway custom plugin API, Lua/OpenResty, `lua-cjson`, `lua-resty-http`, Docker-based Lua tests.

**Spec:** `docs/superpowers/specs/2026-10-29-kong-provider-adapters-design.md`

## Global Constraints

- Lua only; CPU-bound and deterministic.
- The plugin contains no Next Moca selection, scan, quarantine, or policy logic; it calls the hosted service only.
- Preserve non-text provider content and fail safely rather than partially transforming unsupported bodies.
- Apache-2.0 license; public repository contains only the thin plugin, tests, documentation, and release metadata.
- `auto` resolves one unambiguous adapter; unsupported requests pass or block according to configuration.

## Review Focus

- A request containing both `messages` and `contents` must be unsupported rather than arbitrarily routed; Task 1 adds this registry test.
- Tool IDs and schemas must survive every selected rewrite; Tasks 2–5 include provider-specific preservation tests.
- A selected record ID unknown to the resolved adapter must never alter another provider field; Task 6 tests no-match delivery.
- A multi-record sanitized fallback must never restore original raw context in security modes; Task 6 tests this against all adapter families.
- Handler failures before upstream invocation must return the documented 422/403/503 status, never silently pass through; Task 7 adds PDK-double tests.

---

### Task 1: Shared Adapter Contract And Registry

**Files:**
- Create: `kong/plugins/nextmoca-runtime-defense/adapters/common.lua`
- Create: `kong/plugins/nextmoca-runtime-defense/adapters/registry.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: raw JSON strings and `request_adapter` values.
- Produces: `registry.resolve(raw_body, configured_name) -> adapter | nil, reason`.

- [x] **Step 1: Write failing registry tests** for auto detection, explicit adapter mismatch, and ambiguous request bodies.
- [x] **Step 2: Run `make test`** and verify the registry import fails.
- [x] **Step 3: Implement adapter common helpers and the registry** with exact adapter names from the spec.
- [x] **Step 4: Run `make test`** and verify registry tests pass.
- [ ] **Step 5: Commit** `feat: add Kong provider adapter registry`.

### Task 2: OpenAI Chat And Responses Adapters

**Files:**
- Move: `kong/plugins/nextmoca-runtime-defense/openai.lua` to `kong/plugins/nextmoca-runtime-defense/adapters/openai_chat.lua`
- Create: `kong/plugins/nextmoca-runtime-defense/adapters/openai_responses.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: Chat `messages` or Responses `input` bodies.
- Produces: a parsed provider packet implementing the common adapter contract.

- [x] **Step 1: Write failing tests** for Responses string input, text-only input items, function output records, and unsupported mixed input.
- [x] **Step 2: Run `make test`** and verify Responses tests fail.
- [x] **Step 3: Implement adapters** retaining existing Chat behavior and preserving all non-context fields.
- [x] **Step 4: Run `make test`** and verify both OpenAI suites pass.
- [ ] **Step 5: Commit** `feat: support OpenAI request adapters`.

### Task 3: Anthropic Messages Adapter

**Files:**
- Create: `kong/plugins/nextmoca-runtime-defense/adapters/anthropic_messages.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: top-level `system` plus text-safe Anthropic `messages`.
- Produces: parsed candidates and rewrites preserving tools and provider metadata.

- [x] **Step 1: Write failing tests** for plain-string messages, text-safe blocks, tool preservation, and mixed non-text block rejection.
- [x] **Step 2: Run `make test`** and verify the Anthropic suite fails.
- [x] **Step 3: Implement exact text-coordinate extraction and rewrite.**
- [x] **Step 4: Run `make test`** and verify all tests pass.
- [ ] **Step 5: Commit** `feat: support Anthropic Messages adapter`.

### Task 4: Gemini GenerateContent Adapter

**Files:**
- Create: `kong/plugins/nextmoca-runtime-defense/adapters/gemini_generate_content.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: native Gemini `contents` and optional `systemInstruction`.
- Produces: text-only candidate entries and round-trippable selected rewrites.

- [x] **Step 1: Write failing tests** for text-only content, system instruction preservation, tool preservation, and binary/function-part rejection.
- [x] **Step 2: Run `make test`** and verify Gemini tests fail.
- [x] **Step 3: Implement Gemini parse and rewrite behavior.**
- [x] **Step 4: Run `make test`** and verify all tests pass.
- [ ] **Step 5: Commit** `feat: support native Gemini request adapter`.

### Task 5: Generic Hosted Client And Delivery Policy

**Files:**
- Modify: `kong/plugins/nextmoca-runtime-defense/client.lua`
- Modify: `kong/plugins/nextmoca-runtime-defense/policy.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: any parsed adapter packet.
- Produces: hosted Select payloads and provider-safe gateway decisions.

- [ ] **Step 1: Write failing tests** for client payloads from every adapter and policy’s adapter-specific selected rewrite.
- [ ] **Step 2: Run `make test`** and verify generic policy tests fail.
- [ ] **Step 3: Remove OpenAI-specific coupling** by carrying the resolved adapter in parsed packets.
- [ ] **Step 4: Run `make test`** and verify all adapter delivery tests pass.
- [ ] **Step 5: Commit** `refactor: make Kong delivery policy adapter-neutral`.

### Task 6: Kong Plugin Handler And Schema

**Files:**
- Create: `kong/plugins/nextmoca-runtime-defense/handler.lua`
- Create: `kong/plugins/nextmoca-runtime-defense/schema.lua`
- Modify: `spec/run.lua`

**Interfaces:**
- Consumes: Kong route configuration and raw HTTP request body.
- Produces: rewritten upstream body or HTTP 403/422/503 gateway response plus content-free receipt headers.

- [ ] **Step 1: Write failing handler tests** using a Kong PDK double for selected, blocked, unsupported, and service-unavailable outcomes.
- [ ] **Step 2: Run `make test`** and verify the handler import fails.
- [ ] **Step 3: Implement `access` phase handling and schema validation**, including exact `request_adapter`, timeout, breaker, and unsupported-shape options.
- [ ] **Step 4: Run `make test`** and verify the handler tests pass.
- [ ] **Step 5: Commit** `feat: add Kong runtime defense handler`.

### Task 7: Package, OCI, Documentation, And Gateway Smoke Test

**Files:**
- Create: `Dockerfile`
- Create: `docker-compose.smoke.yml`
- Create: `scripts/smoke-gateway.sh`
- Create: `README.md`
- Create: `LICENSE`
- Create: `.github/workflows/test.yml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: plugin source and fake hosted Select endpoint fixture.
- Produces: a minimal OCI image and reproducible tests without Next Moca core code.

- [ ] **Step 1: Write a failing smoke script** that expects an upstream fixture to receive a Gemini-shaped request with unselected text omitted.
- [ ] **Step 2: Run the smoke command** and verify it fails before packaging exists.
- [ ] **Step 3: Add the minimal Kong image, Compose fixture, Apache license, public documentation, and GitHub Actions workflow.**
- [ ] **Step 4: Run `make test`, `make lint`, and the container smoke test** until all pass.
- [ ] **Step 5: Commit** `feat: package Kong runtime defense plugin`.

## Execution Handoff

The user explicitly requested inline implementation. Execute each task in order with no subagents, preserving the test-first steps above.
