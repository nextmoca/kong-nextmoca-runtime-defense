local cjson = require("cjson.safe")
local Breaker = require("kong.plugins.nextmoca-runtime-defense.breaker")

local Client = {}
Client.__index = Client

local select_path = "/v1/context/select"
local max_body_bytes = 6 * 1024 * 1024

local function new_error(class, message)
  return { class = class, message = message }
end

local function is_nonnegative_integer(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function security_mode(mode)
  if mode == "shadow" then
    return "audit"
  end
  if mode == "quarantine" then
    return "quarantine"
  end
  if mode == "enforce" then
    return "enforce"
  end
  return "off"
end

local function status_class(status)
  if status == 401 or status == 403 then
    return "auth"
  end
  if status == 402 then
    return "quota"
  end
  if status == 429 then
    return "rate_limit"
  end
  if status == 413 then
    return "oversize"
  end
  if status >= 500 then
    return "server"
  end
  return "contract"
end

function Client.wire_request(config, parsed, request_id)
  local records = {}
  for _, record in ipairs(parsed.records) do
    records[#records + 1] = {
      id = record.id,
      kind = record.kind,
      source = record.source,
      source_kind = record.source_kind,
      text = record.text,
    }
  end

  return {
    request_id = request_id,
    records = records,
    task = { prompt = parsed.task_prompt },
    budget = {
      max_context_tokens = config.max_context_tokens,
      capacity_cap_tokens = config.capacity_tokens,
      operating_point = config.operating_point,
      autochunk = config.autochunk,
    },
    render = true,
    render_format = "plain",
    return_per_record = true,
    security_mode = security_mode(config.mode),
  }
end

function Client.decode_response(status, headers, raw, expected_request_id)
  if status < 200 or status >= 300 then
    return nil, new_error(status_class(status), "Next Moca returned HTTP " .. tostring(status))
  end
  if type(raw) ~= "string" or #raw > max_body_bytes then
    return nil, new_error("contract", "invalid Next Moca response body")
  end

  local body, decode_err = cjson.decode(raw)
  if not body then
    return nil, new_error("contract", "invalid Next Moca response: " .. tostring(decode_err))
  end
  if type(body.request_id) ~= "string" or body.request_id == "" or body.request_id ~= expected_request_id then
    return nil, new_error("contract", "Next Moca response request_id does not match")
  end
  if type(body.outcome) ~= "string" or body.outcome == "" then
    return nil, new_error("contract", "Next Moca response outcome is required")
  end
  if type(body.fallback_used) ~= "boolean" then
    return nil, new_error("contract", "Next Moca response fallback_used is required")
  end
  if not is_nonnegative_integer(body.tokens_before)
    or not is_nonnegative_integer(body.tokens_after)
    or not is_nonnegative_integer(body.tokens_saved)
    or type(body.engine_latency_ms) ~= "number" then
    return nil, new_error("contract", "Next Moca response token counters are invalid")
  end
  if type(body.rendered_context) ~= "string" then
    return nil, new_error("contract", "Next Moca response rendered_context is required")
  end
  if body.selected ~= nil and type(body.selected) ~= "table" then
    return nil, new_error("contract", "Next Moca response selected must be an array")
  end

  return {
    request_id = body.request_id,
    selection_id = headers and headers["x-needlepath-selection-id"] or nil,
    outcome = body.outcome,
    fallback_used = body.fallback_used,
    rendered_context = body.rendered_context,
    tokens_before = body.tokens_before,
    tokens_after = body.tokens_after,
    tokens_saved = body.tokens_saved,
    engine_latency_ms = body.engine_latency_ms,
    selected = body.selected or {},
  }, nil
end

function Client.new(config)
  return setmetatable({
    config = config,
    breaker = Breaker.new(config.breaker_failures, config.breaker_cooldown_ms),
  }, Client)
end

function Client:select(parsed, request_id)
  if not self.breaker:allow() then
    return nil, new_error("circuit_open", "Next Moca circuit breaker is open")
  end

  local request, request_err = cjson.encode(Client.wire_request(self.config, parsed, request_id))
  if not request or #request > max_body_bytes then
    local err = new_error("request", "could not encode Next Moca request: " .. tostring(request_err))
    self.breaker:report(err.class)
    return nil, err
  end

  local http = require("resty.http")
  local http_client = http.new()
  http_client:set_timeout(self.config.timeout_ms)
  local response, transport_err = http_client:request_uri(
    self.config.endpoint:gsub("/$", "") .. select_path,
    {
      method = "POST",
      body = request,
      headers = {
        ["Authorization"] = "Bearer " .. self.config.api_key,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
      },
      ssl_verify = true,
    }
  )
  if not response then
    local err = new_error("transport", "Next Moca request failed: " .. tostring(transport_err))
    self.breaker:report(err.class)
    return nil, err
  end

  local decoded, decode_err = Client.decode_response(response.status, response.headers, response.body, request_id)
  self.breaker:report(decode_err and decode_err.class or nil)
  return decoded, decode_err
end

return Client
