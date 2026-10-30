# Operations

The plugin writes a content-free receipt to the upstream response. It also
emits a Kong notice log per governed request. Neither surface contains the
candidate context or API key.

## Receipt Headers

| Header | Meaning |
|---|---|
| `X-NextMoca-Adapter` | Provider request shape that the plugin resolved. |
| `X-NextMoca-Decision` | `transform`, `pass`, or `block` at the Kong boundary. |
| `X-NextMoca-Reason` | Why that delivery decision was made. |
| `X-NextMoca-Request-Id` | Hosted request correlation ID, when selection was called. |
| `X-NextMoca-Tokens-Saved` | Candidate-context tokens removed before the upstream model call. |
| `X-NextMoca-Engine-Latency-Ms` | Hosted selection latency only, not total provider latency. |

## Delivery Behavior

- `shadow` always forwards the original request after recording the hosted
  observation.
- `active` forwards selected text only; hosted security mode is off.
- `quarantine` can forward a selected or sanitized packet. With
  `on_selection_error: block`, transport, timeout, contract, and open-breaker
  errors return HTTP 503 instead of passing context onward.
- `enforce` adds an HTTP 403 for a hosted `blocked` verdict.

The plugin has a 3-second hosted request timeout by default. It does not
retry. The in-worker circuit breaker opens after three transient failures and
allows a new attempt after the configured 30-second cooldown. These values are
service configuration, not guarantees about total LLM latency.

## Alerts

Alert from Kong logs and your gateway metrics, not customer content:

1. Sustained `X-NextMoca-Decision: block` or HTTP 403: inspect policy and
   request-shape changes before relaxing enforcement.
2. Any increase in `selection_error`, `circuit_open`, HTTP 503, or timeouts:
   investigate the hosted endpoint, network path, secret configuration, and
   configured timeout.
3. A material change in `X-NextMoca-Engine-Latency-Ms`: investigate upstream
   selection latency separately from model latency.
4. Unexpected zero or negative token savings after rollout: review whether
   candidate context is actually present in the provider-bound request.

## Safe Change Procedure

Treat `mode`, `unsupported_shape`, and `on_selection_error` as policy changes.
Validate them in a staging route first, retain the receipt headers during the
canary, and roll back by setting `mode: shadow` rather than removing the
plugin image.
