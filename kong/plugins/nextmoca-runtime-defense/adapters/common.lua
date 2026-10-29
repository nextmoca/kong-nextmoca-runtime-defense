local cjson = require("cjson.safe")

local Common = {}

function Common.trim(value)
  if type(value) ~= "string" then
    return nil
  end
  return value:match("^%s*(.-)%s*$")
end

function Common.has_text(value)
  local trimmed = Common.trim(value)
  return trimmed ~= nil and trimmed ~= ""
end

function Common.decode_object(raw)
  if type(raw) ~= "string" then
    return nil, "request_body_not_string"
  end

  local body, decode_err = cjson.decode(raw)
  if not body then
    return nil, "invalid_json: " .. tostring(decode_err)
  end
  if type(body) ~= "table" then
    return nil, "request_body_not_object"
  end
  return body, nil
end

function Common.deep_copy(value, seen)
  if type(value) ~= "table" then
    return value
  end

  seen = seen or {}
  if seen[value] then
    return seen[value]
  end

  local copy = {}
  seen[value] = copy
  for key, item in pairs(value) do
    copy[Common.deep_copy(key, seen)] = Common.deep_copy(item, seen)
  end
  return copy
end

function Common.encode(body)
  local encoded, encode_err = cjson.encode(body)
  if not encoded then
    return nil, "encode_failed: " .. tostring(encode_err)
  end
  return encoded, nil
end

return Common
