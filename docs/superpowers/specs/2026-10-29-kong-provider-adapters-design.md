# Kong Provider Adapters Design

## Intent

Ship the public `nextmoca-runtime-defense` Kong plugin as a thin, provider-shape-aware gateway adapter. It must govern the final LLM request without embedding Next Moca selection, security, scanning, or policy logic. The only decision service remains the hosted Next Moca Select API.

## Goal

The plugin accepts the common text-based LLM request formats used by agent applications and maps their eligible earlier context to the existing hosted Select contract:

1. OpenAI-compatible Chat Completions (`messages`).
2. OpenAI Responses (`input`).
3. Anthropic Messages (`system`, `messages`).
4. Native Gemini GenerateContent (`systemInstruction`, `contents`).

OpenAI-compatible requests routed by Kong to another provider, including Gemini, remain governed by the OpenAI adapter because the body at the plugin boundary is OpenAI-shaped.

## Non-Goals

- No embedded selection, lexical scoring, chunking, scan/quarantine rules, or model calls.
- No transformation of images, audio, documents, binary parts, tool schemas, tool-call arguments, or provider response bodies.
- No attempt to rewrite an unsupported, ambiguous, malformed, or non-text body.
- No claim that a provider-native request is governed until its adapter has passed an end-to-end provider test.

## Common Adapter Contract

Every adapter exposes these deterministic operations:

```lua
adapter.matches(raw_body) -> boolean
adapter.parse(raw_body) -> parsed | unsupported_reason | error
adapter.candidate_count(parsed) -> integer
adapter.rewrite_selected(parsed, excerpts_by_record_id) -> raw_body | error
adapter.rewrite_single_candidate(parsed, rendered_context) -> raw_body | error
```

`parsed` contains the unmodified decoded request body, the user task prompt, and an ordered list of eligible records. Each record has `id`, `kind`, `source`, `source_kind`, `text`, and enough provider-local coordinates to replace only its text field later. The common client sends only those records, the prompt, budget, operating point, and security mode to the hosted API.

The common policy works exclusively through the adapter supplied by `parsed`. It preserves the original raw body for shadow, fallback, unknown outcomes, selection errors, and unsupported-shape pass-through. It blocks only under the existing `enforce` or `quarantine` policy contract.

## Adapter Rules

### OpenAI Chat Completions

- Preserve `system`, `developer`, final user task, tool definitions, tool-call identifiers, and other metadata verbatim.
- Earlier `user`, `assistant`, and `tool` messages with string content are eligible records.
- Content arrays, legacy `function` messages, missing final user task, and non-string candidate content remain unsupported rather than partially rewritten.

### OpenAI Responses

- Accept a top-level string `input`, or an `input` array containing text-only message items and `function_call_output` items with string output.
- The final nonempty `user` input item is the task. Earlier text messages and function-call outputs are eligible records.
- Preserve tools, instructions, model, response settings, function-call identifiers, and non-context items unchanged.
- Reject content blocks that include non-text input, multi-part values the adapter cannot round-trip, or no unambiguous final user task.

### Anthropic Messages

- Preserve top-level `system`, `tools`, model, and request settings unchanged.
- The final nonempty `user` message is the task. Earlier messages with string content are eligible records.
- For content-block arrays, treat individual `text` and `tool_result.content` string blocks as records only when their surrounding message contains no blocks requiring structural rewriting. Otherwise stand down as unsupported.
- Never alter `tool_use`, thinking, image, document, or citation blocks.

### Gemini GenerateContent

- Preserve `systemInstruction`, `tools`, `generationConfig`, `safetySettings`, model path, and all non-text parts unchanged.
- The last `contents` entry with a nonempty text part and role `user` is the task.
- Earlier content entries are eligible only if all their parts are textual. Rewriting replaces text parts in that entry and preserves its role and order.
- Requests with file, inline data, function call/response, executable code, or other non-text parts in a candidate entry are unsupported for V1. They are passed through or blocked according to the unsupported-shape policy; they are never partially transformed.

## Routing

`request_adapter` has these values:

- `auto` (default): choose exactly one adapter by unambiguous body shape.
- `openai_chat`, `openai_responses`, `anthropic_messages`, `gemini_generate_content`: require that exact shape; a mismatch is unsupported.

Auto precedence is shape-specific, not URL-specific: OpenAI Responses only when `input` exists; OpenAI Chat only when `messages` exists; Anthropic when `messages` plus Anthropic-specific top-level body is present; Gemini when `contents` exists. Ambiguous bodies are unsupported.

## Security And Delivery Rules

- Selection and security execution remain in the hosted API. `shadow` always calls it with security off/audit behavior as currently defined; `active`, `quarantine`, and `enforce` retain their current mapping.
- `selected` rewrites only known record coordinates. Unknown record IDs do not produce a rewrite.
- `sanitized_fallback` can be delivered only when the adapter has exactly one eligible record. Otherwise security modes block rather than restore raw context.
- Hosted `blocked` blocks only in `enforce`. Selection errors, timeouts, invalid responses, and circuit-open use the existing `on_selection_error` policy.

## Observable Outcomes

The handler adds content-free response headers for adapter name, decision kind, decision reason, selection request ID, token counts, and hosted latency. It logs the same metadata, never task or candidate text. This makes provider-specific test evidence inspectable without leaking governed context.

## Validation

1. Unit tests cover parse, unsupported decisions, request construction, selected rewrite, and sanitized fallback for each adapter.
2. Handler tests use a Kong PDK double for pass, transform, HTTP 403 block, HTTP 422 unsupported block, and HTTP 503 unavailable.
3. Container smoke test runs each payload through an actual Kong Gateway instance and a fake hosted Select endpoint, verifying the upstream sees only selected content.
4. Real-provider acceptance is separate: configure each provider through Kong and validate at least one governed call per supported native adapter. A provider is not advertised as end-to-end verified before this passes.

## Constraints

- Lua only; no native extensions or model dependencies.
- CPU-only, deterministic transformations.
- The public repository contains only the plugin, test fixtures, build/release metadata, and documentation.
- Apache-2.0 licensed.
