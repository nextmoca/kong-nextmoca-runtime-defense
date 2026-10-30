local Access = require("kong.plugins.nextmoca-runtime-defense.access")

local Handler = {
  VERSION = "0.1.0",
  PRIORITY = 750,
}

function Handler:access(config)
  local runtime_config, config_err = Access.runtime_config(config)
  if not runtime_config then
    return Access.unavailable(kong, config_err)
  end
  return Access.run(kong, runtime_config, Access.new_client(runtime_config))
end

function Handler:header_filter()
  Access.write_receipt_headers(kong)
end

return Handler
