# Compatibility

## Release-Tested Contract

| Dimension | Supported | Notes |
|---|---|---|
| Gateway runtime | Kong Gateway 3.8 | Tested in the official container image. |
| Configuration mode | DB-less declarative configuration | The supplied Helm values use `database: off`. |
| CPU architectures | Linux `amd64` and `arm64` | The release workflow publishes a multi-architecture OCI manifest. |
| OpenAI | Chat Completions and Responses text-only requests | `request_adapter: auto` resolves unambiguous bodies. |
| Anthropic | Messages text-only requests | Use `request_adapter: anthropic_messages` for ambiguous simple message arrays. |
| Gemini | Native GenerateContent text-only requests | Native provider shape, not an OpenAI compatibility shim. |
| Delivery modes | `shadow`, `active`, `quarantine`, `enforce` | Start with `shadow`; validate security modes with the live smoke test. |

## Request Boundary

The plugin transforms text-only candidate context that is already present in a
provider-bound request. It does not independently fetch RAG documents, inspect
tool execution, govern provider responses, or reach into an agent's memory
store. The application must route the next LLM request through Kong after it
has assembled tool output, retrieval results, memory, or conversation history.

Requests with files, images, binary content, multimodal parts, or unsupported
control blocks are never partially transformed. They are passed through or
blocked by the configured `unsupported_shape` policy.

## Not Yet A Compatibility Claim

The initial release does not claim validation for Kong versions other than
3.8, Konnect-managed deployments, hybrid control-plane/data-plane topology,
traditional database-backed configuration, streaming provider bodies, or
non-Linux runtime environments. Those can be added only with a corresponding
integration test and release-matrix entry.
