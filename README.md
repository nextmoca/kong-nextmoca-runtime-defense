# Next Moca Runtime Defense for AI Agents - Kong Plugin

This is a thin [Kong Gateway](https://konghq.com/) plugin that places Next Moca immediately before an LLM provider. It calls the hosted Next Moca Runtime Defense API to select relevant context and apply its security delivery verdict before Kong forwards the request upstream.

The repository contains no Next Moca selection, scanning, quarantine, or policy engine. Those decisions remain in the hosted service.

## Supported Request Shapes

| `request_adapter` | Native request shape | `auto` resolution |
|---|---|---|
| `openai_chat` | OpenAI-compatible Chat Completions `messages` | When OpenAI-only message signals are present |
| `openai_responses` | OpenAI Responses `input` | When `input` is present |
| `anthropic_messages` | Anthropic Messages `system` and `messages` | When Anthropic-specific signals are present |
| `gemini_generate_content` | Gemini GenerateContent `contents` | When `contents` is present |

`auto` refuses ambiguous bodies. For plain `user`/`assistant` message arrays that could be OpenAI or Anthropic, choose an explicit adapter. The plugin rewrites text-only candidate context; requests containing multimodal, file, image, binary, or control blocks that it cannot round-trip are passed through or blocked according to `unsupported_shape`.

## Install

```sh
docker pull ghcr.io/nextmoca/kong-nextmoca-runtime-defense:0.1.0
```

Use the image as the base image for your Kong Gateway deployment, then enable the plugin:

```yaml
plugins:
  - name: nextmoca-runtime-defense
    config:
      endpoint: https://api.nextmoca.com
      api_key_env: NEXTMOCA_API_KEY
      operating_point: np-2026-10-r7
      mode: quarantine
      request_adapter: auto
      unsupported_shape: block
      on_selection_error: block
      max_context_tokens: 8192
      capacity_tokens: 128000
      autochunk: true
```

Inject `NEXTMOCA_API_KEY` into Kong through your normal secret manager. Do not put it in declarative configuration or source control. Kong runs plugins in Nginx workers, so also set `KONG_NGINX_MAIN_ENV=NEXTMOCA_API_KEY` on the Gateway container. This exports the secret name to the workers without placing its value in declarative configuration.

For example, a container deployment needs both environment variables:

```yaml
environment:
  NEXTMOCA_API_KEY: ${NEXTMOCA_API_KEY}
  KONG_NGINX_MAIN_ENV: NEXTMOCA_API_KEY
```

## Delivery Modes

The plugin defaults to `shadow`, so enabling it does not change provider-bound requests until a delivery mode is chosen deliberately.

| Mode | Hosted behavior | Gateway delivery behavior |
|---|---|---|
| `shadow` | Audit only | Original request is forwarded unchanged |
| `active` | Selection only | Selected request is forwarded; hosted security mode is off |
| `quarantine` | Security-aware selection | Selected or safely sanitized context is forwarded; unavailable/unsafe delivery can be configured to block |
| `enforce` | Security-aware selection | A hosted `blocked` verdict returns HTTP 403 before the provider |

When a selected rewrite is delivered, the plugin returns content-free receipt headers, including `X-NextMoca-Adapter`, `X-NextMoca-Decision`, `X-NextMoca-Request-Id`, and token/latency fields where present.

## Operational Boundary

The plugin governs the final request that Kong sees. It can protect tool output, retrieved context, memory, and conversation history only when the application includes that material in the next LLM request routed through Kong. It does not inspect tool execution, data stores, or provider responses.

## Test

```sh
make test
make lint
make smoke
```

`make smoke` launches a local Kong Gateway, a fake hosted Select endpoint, and an echo upstream. It verifies the full gateway path for OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and native Gemini GenerateContent: selected text reaches the upstream, omitted candidates do not, and the response carries the correct adapter receipt headers. It does not call an external model or the production Next Moca API.

## License

Apache-2.0. See [LICENSE](LICENSE).
