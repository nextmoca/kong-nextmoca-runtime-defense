local Common = require("kong.plugins.nextmoca-runtime-defense.adapters.common")

local Adapter = {
  name = "openai_chat",
  OMITTED_CONTEXT_MARKER = "[Next Moca omitted nonessential context for this request.]",
}

local candidate_roles = {
  user = true,
  assistant = true,
  tool = true,
}

local source_kinds = {
  user = "conversation",
  assistant = "assistant",
  tool = "tool",
}

local record_kinds = {
  user = "conversation_history",
  assistant = "assistant_message",
  tool = "tool_result",
}

local function unsupported(reason)
  return { supported = false, reason = reason, adapter = Adapter }, nil
end

local function record_for(index, message)
  local role = message.role
  return {
    id = "message-" .. index,
    kind = record_kinds[role],
    source = "openai.messages[" .. index .. "]",
    source_kind = source_kinds[role],
    text = message.content,
    message_index = index,
  }
end

function Adapter.parse(raw)
  local body, decode_err = Common.decode_object(raw)
  if not body then
    return nil, decode_err
  end
  if type(body.messages) ~= "table" then
    return unsupported("messages_not_supported")
  end

  local task_index
  for index, message in ipairs(body.messages) do
    if type(message) ~= "table" or type(message.role) ~= "string" then
      return unsupported("invalid_message_shape")
    end
    if message.role == "function" then
      return unsupported("function_role_not_supported")
    end
    if type(message.content) == "table" then
      return unsupported("content_parts_not_supported")
    end
    if type(message.content) ~= "string" then
      return unsupported("non_string_content_not_supported")
    end
    if message.role == "user" and Common.has_text(message.content) then
      task_index = index
    end
  end

  if not task_index then
    return unsupported("task_not_found")
  end

  local records = {}
  for index = 1, task_index - 1 do
    local message = body.messages[index]
    if candidate_roles[message.role] then
      records[#records + 1] = record_for(index, message)
    end
  end

  return {
    supported = true,
    adapter = Adapter,
    body = body,
    task_prompt = body.messages[task_index].content,
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

  local rewritten = Common.deep_copy(parsed.body)
  for _, record in ipairs(parsed.records) do
    local excerpt = excerpts[record.id]
    if Common.has_text(excerpt) then
      rewritten.messages[record.message_index].content = excerpt
    else
      rewritten.messages[record.message_index].content = Adapter.OMITTED_CONTEXT_MARKER
    end
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
