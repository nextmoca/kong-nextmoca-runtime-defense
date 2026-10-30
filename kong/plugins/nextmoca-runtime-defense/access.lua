local Client = require("kong.plugins.nextmoca-runtime-defense.client")
local Policy = require("kong.plugins.nextmoca-runtime-defense.policy")
local Registry = require("kong.plugins.nextmoca-runtime-defense.adapters.registry")

local Access = {}

local function screens(mode)
  return mode == "quarantine" or mode == "enforce"
end

local function request_id(pdk)
  local supplied = pdk.request.get_header("x-request-id")
  if type(supplied) == "string" and supplied ~= "" then
    return supplied
  end
  return pdk.request.get_id()
end

local function exit(pdk, status, code, reason)
  return pdk.response.exit(status, {
    code = code,
    reason = reason,
  })
end

local function record_receipt(pdk, adapter_name, decision, reason, response)
  local receipt = {
    adapter = adapter_name,
    decision = decision,
    reason = reason,
  }
  if type(response) == "table" then
    receipt.request_id = response.request_id
    receipt.selection_id = response.selection_id
    receipt.tokens_before = response.tokens_before
    receipt.tokens_after = response.tokens_after
    receipt.tokens_saved = response.tokens_saved
    receipt.engine_latency_ms = response.engine_latency_ms
  end
  pdk.ctx.plugin.receipt = receipt
  pdk.log.notice("nextmoca adapter=", adapter_name or "none", " decision=", decision, " reason=", reason)
end

local function unsupported(pdk, config, reason)
  if screens(config.mode) and config.unsupported_shape == "block" then
    record_receipt(pdk, nil, "block", reason, nil)
    return exit(pdk, 422, "context_security_unsupported_request", reason)
  end
  record_receipt(pdk, nil, "pass", reason, nil)
  return nil
end

local function delivery(pdk, config, decision, response, adapter_name)
  record_receipt(pdk, adapter_name, decision.kind, decision.reason, response)
  if decision.kind == "transform" then
    pdk.service.request.set_raw_body(decision.body)
    return nil
  end
  if decision.kind ~= "block" then
    return nil
  end
  if decision.cause == "unavailable" then
    return exit(pdk, 503, "context_security_unavailable", decision.reason)
  end
  return exit(pdk, 403, "context_security_blocked", decision.reason)
end

function Access.runtime_config(config, getenv)
  getenv = getenv or os.getenv
  local api_key = config.api_key or getenv(config.api_key_env or "NEXTMOCA_API_KEY")
  if type(api_key) ~= "string" or api_key == "" then
    return nil, "nextmoca_api_key_unavailable"
  end
  if type(config.operating_point) ~= "string" or config.operating_point == "" then
    return nil, "operating_point_missing"
  end
  return {
    endpoint = config.endpoint,
    api_key = api_key,
    operating_point = config.operating_point,
    max_context_tokens = config.max_context_tokens,
    capacity_tokens = config.capacity_tokens,
    autochunk = config.autochunk,
    mode = config.mode,
    on_selection_error = config.on_selection_error,
    unsupported_shape = config.unsupported_shape,
    request_adapter = config.request_adapter,
    timeout_ms = config.timeout_ms,
    breaker_failures = config.breaker_failures,
    breaker_cooldown_ms = config.breaker_cooldown_ms,
  }, nil
end

function Access.run(pdk, config, select_client)
  local raw_body, body_err = pdk.request.get_raw_body()
  if not raw_body then
    local decision = Policy.decide(config, "", {}, nil, { class = "transport", message = body_err })
    return delivery(pdk, config, decision, nil, nil)
  end

  local adapter, adapter_err = Registry.resolve(raw_body, config.request_adapter or "auto")
  if not adapter then
    return unsupported(pdk, config, adapter_err)
  end
  local parsed, parse_err = adapter.parse(raw_body)
  if not parsed then
    return unsupported(pdk, config, parse_err)
  end
  if not parsed.supported then
    return unsupported(pdk, config, parsed.reason)
  end
  if adapter.candidate_count(parsed) == 0 then
    record_receipt(pdk, adapter.name, "pass", "no_candidate_context", nil)
    return nil
  end

  local response, selection_err = select_client:select(parsed, request_id(pdk))
  local decision = Policy.decide(config, raw_body, parsed, response, selection_err)
  return delivery(pdk, config, decision, response, adapter.name)
end

function Access.unavailable(pdk, reason)
  record_receipt(pdk, nil, "block", reason, nil)
  return exit(pdk, 503, "context_security_unavailable", reason)
end

function Access.write_receipt_headers(pdk)
  local receipt = pdk.ctx.plugin.receipt
  if type(receipt) ~= "table" then
    return
  end
  if receipt.adapter then
    pdk.response.set_header("X-NextMoca-Adapter", receipt.adapter)
  end
  pdk.response.set_header("X-NextMoca-Decision", receipt.decision)
  pdk.response.set_header("X-NextMoca-Reason", receipt.reason)
  if receipt.request_id then
    pdk.response.set_header("X-NextMoca-Request-Id", receipt.request_id)
  end
  if receipt.tokens_saved ~= nil then
    pdk.response.set_header("X-NextMoca-Tokens-Saved", tostring(receipt.tokens_saved))
  end
  if receipt.engine_latency_ms ~= nil then
    pdk.response.set_header("X-NextMoca-Engine-Latency-Ms", tostring(receipt.engine_latency_ms))
  end
end

function Access.new_client(config)
  return Client.new(config)
end

return Access
