local Common = require("kong.plugins.nextmoca-runtime-defense.adapters.common")

local Registry = {}

local known_adapters = {
  openai_chat = "kong.plugins.nextmoca-runtime-defense.adapters.openai_chat",
  openai_responses = "kong.plugins.nextmoca-runtime-defense.adapters.openai_responses",
  anthropic_messages = "kong.plugins.nextmoca-runtime-defense.adapters.anthropic_messages",
  gemini_generate_content = "kong.plugins.nextmoca-runtime-defense.adapters.gemini_generate_content",
}

local function has_openai_signals(messages)
  for _, message in ipairs(messages) do
    if type(message) == "table" then
      if message.role == "system" or message.role == "developer" or message.role == "tool" or message.role == "function" then
        return true
      end
      if message.tool_calls ~= nil or message.tool_call_id ~= nil or message.function_call ~= nil then
        return true
      end
    end
  end
  return false
end

local function has_anthropic_signals(body)
  if body.system ~= nil then
    return true
  end
  for _, message in ipairs(body.messages or {}) do
    if type(message) == "table" and type(message.content) == "table" then
      return true
    end
  end
  return false
end

local function requested_shape_matches(body, name)
  if name == "openai_responses" then
    return body.input ~= nil
  end
  if name == "gemini_generate_content" then
    return body.contents ~= nil
  end
  if name == "openai_chat" or name == "anthropic_messages" then
    return body.messages ~= nil
  end
  return false
end

function Registry.detect(raw, configured_name)
  local body, decode_err = Common.decode_object(raw)
  if not body then
    return nil, decode_err
  end

  configured_name = configured_name or "auto"
  if configured_name ~= "auto" then
    if not known_adapters[configured_name] then
      return nil, "unknown_adapter"
    end
    if not requested_shape_matches(body, configured_name) then
      return nil, "adapter_shape_mismatch"
    end
    return configured_name, nil
  end

  local shape_count = 0
  if body.input ~= nil then
    shape_count = shape_count + 1
  end
  if body.contents ~= nil then
    shape_count = shape_count + 1
  end
  if body.messages ~= nil then
    shape_count = shape_count + 1
  end
  if shape_count == 0 then
    return nil, "unsupported_request_shape"
  end
  if shape_count > 1 then
    return nil, "ambiguous_request_shape"
  end
  if body.input ~= nil then
    return "openai_responses", nil
  end
  if body.contents ~= nil then
    return "gemini_generate_content", nil
  end
  if type(body.messages) ~= "table" then
    return nil, "messages_not_array"
  end

  local openai = has_openai_signals(body.messages)
  local anthropic = has_anthropic_signals(body)
  if openai and not anthropic then
    return "openai_chat", nil
  end
  if anthropic and not openai then
    return "anthropic_messages", nil
  end
  if openai and anthropic then
    return nil, "ambiguous_messages_shape"
  end
  return nil, "ambiguous_messages_shape"
end

function Registry.resolve(raw, configured_name)
  local name, detect_err = Registry.detect(raw, configured_name)
  if not name then
    return nil, detect_err
  end

  local ok, adapter = pcall(require, known_adapters[name])
  if not ok then
    return nil, "adapter_unavailable"
  end
  adapter.name = name
  return adapter, nil
end

return Registry
