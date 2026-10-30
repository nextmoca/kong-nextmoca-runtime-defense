local Common = require("kong.plugins.nextmoca-runtime-defense.adapters.common")

local Adapter = {
  name = "openai_responses",
  OMITTED_CONTEXT_MARKER = "[Next Moca omitted nonessential context for this request.]",
}

local function unsupported(reason)
  return { supported = false, reason = reason, adapter = Adapter }, nil
end

local function message_record(index, item)
  return {
    id = "input-" .. index,
    kind = item.role == "assistant" and "llm_response" or "user_input",
    source = "openai.input[" .. index .. "]",
    source_kind = item.role == "assistant" and "unknown" or "user",
    text = item.content,
    input_index = index,
    field = "content",
  }
end

local function function_output_record(index, item)
  return {
    id = "input-" .. index,
    kind = "tool_result",
    source = "openai.input[" .. index .. "]",
    source_kind = "tool",
    text = item.output,
    input_index = index,
    field = "output",
  }
end

local function inspect_item(item)
  if type(item) ~= "table" then
    return nil, "invalid_input_item"
  end
  if item.type == "function_call_output" then
    if type(item.output) ~= "string" then
      return "unsupported", "function_output_not_string"
    end
    return "function_output", nil
  end
  if item.type == "function_call" or item.type == "reasoning" then
    return "preserve", nil
  end
  if item.type ~= nil and item.type ~= "message" then
    return "unsupported", "unsupported_input_item_type"
  end
  if type(item.role) ~= "string" then
    return "unsupported", "message_role_not_string"
  end
  if type(item.content) == "table" then
    return "unsupported", "content_blocks_not_supported"
  end
  if type(item.content) ~= "string" then
    return "unsupported", "message_content_not_string"
  end
  return "message", nil
end

function Adapter.parse(raw)
  local body, decode_err = Common.decode_object(raw)
  if not body then
    return nil, decode_err
  end
  if body.input == nil then
    return unsupported("input_not_supported")
  end
  if type(body.input) == "string" then
    if not Common.has_text(body.input) then
      return unsupported("task_not_found")
    end
    return {
      supported = true,
      adapter = Adapter,
      body = body,
      task_prompt = body.input,
      task_index = nil,
      records = {},
    }, nil
  end
  if type(body.input) ~= "table" then
    return unsupported("input_not_supported")
  end

  local item_types = {}
  local task_index
  for index, item in ipairs(body.input) do
    local item_type, item_err = inspect_item(item)
    if item_type == nil then
      return nil, item_err
    end
    if item_type == "unsupported" then
      return unsupported(item_err)
    end
    item_types[index] = item_type
    if item_type == "message" and item.role == "user" and Common.has_text(item.content) then
      task_index = index
    end
  end
  if not task_index then
    return unsupported("task_not_found")
  end

  local records = {}
  for index = 1, task_index - 1 do
    local item = body.input[index]
    if item_types[index] == "message" and (item.role == "user" or item.role == "assistant") then
      records[#records + 1] = message_record(index, item)
    elseif item_types[index] == "function_output" then
      records[#records + 1] = function_output_record(index, item)
    end
  end

  return {
    supported = true,
    adapter = Adapter,
    body = body,
    task_prompt = body.input[task_index].content,
    task_index = task_index,
    records = records,
  }, nil
end

function Adapter.candidate_count(parsed)
  return #parsed.records
end

function Adapter.rewrite_selected(parsed, excerpts)
  if not parsed.supported then
    return nil, "unsupported_request"
  end
  if type(excerpts) ~= "table" then
    return nil, "invalid_excerpts"
  end
  if type(parsed.body.input) == "string" then
    return nil, "no_candidate_records"
  end

  local rewritten = Common.deep_copy(parsed.body)
  for _, record in ipairs(parsed.records) do
    local excerpt = excerpts[record.id]
    rewritten.input[record.input_index][record.field] = Common.has_text(excerpt)
      and excerpt
      or Adapter.OMITTED_CONTEXT_MARKER
  end
  return Common.encode(rewritten)
end

function Adapter.rewrite_single_candidate(parsed, rendered_context)
  if not parsed.supported then
    return nil, "unsupported_request"
  end
  if #parsed.records ~= 1 then
    return nil, "sanitized_fallback_requires_record_mapping"
  end
  if not Common.has_text(rendered_context) then
    return nil, "empty_sanitized_fallback"
  end
  return Adapter.rewrite_selected(parsed, {
    [parsed.records[1].id] = rendered_context,
  })
end

return Adapter
