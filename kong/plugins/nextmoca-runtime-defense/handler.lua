local Access = require("kong.plugins.nextmoca-runtime-defense.access")

local Handler = {
  VERSION = "0.1.0",
  PRIORITY = 750,
}

local function client_key(config)
  return table.concat({
    tostring(config.endpoint),
    tostring(config.api_key),
    tostring(config.operating_point),
    tostring(config.max_context_tokens),
    tostring(config.capacity_tokens),
    tostring(config.autochunk),
    tostring(config.mode),
    tostring(config.timeout_ms),
    tostring(config.breaker_failures),
    tostring(config.breaker_cooldown_ms),
  }, "\0")
end

function Handler:client_for(config, create_client)
  self._clients = self._clients or {}
  local key = client_key(config)
  local client = self._clients[key]
  if client then
    return client
  end

  client = (create_client or Access.new_client)(config)
  self._clients[key] = client
  return client
end

function Handler:access(config)
  local runtime_config, config_err = Access.runtime_config(config)
  if not runtime_config then
    return Access.unavailable(kong, config_err)
  end
  return Access.run(kong, runtime_config, self:client_for(runtime_config))
end

function Handler:header_filter()
  Access.write_receipt_headers(kong)
end

return Handler
