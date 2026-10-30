local Common = require("kong.plugins.nextmoca-runtime-defense.adapters.common")

local Adapter = {
  name = "anthropic_messages",
  OMITTED_CONTEXT_MARKER = "[Next Moca omitted nonessential context for this request.]",
}

local function unsupported(reason)
  return { supported = false, reason = reason, adapter = Adapter }, nil
end

local function message_source_kind(role)
  return role == "assistant" and "unknown" or "user"
end

local function message_record(message_index, message)
  return {
    id = "message-" .. message_index,
    kind = message.role == "assistant" and "llm_response" or "user_input",
    source = "anthropic.messages[" .. message_index .. "]",
    source_kind = message_source_kind(message.role),
    text = message.content,
    message_index = message_index,
    field = "content",
  }
end

local function block_record(message_index, block_index, block, role)
  local is_tool = block.type == "tool_result"
  return {
    id = "message-" .. message_index .. "-block-" .. block_index,
    kind = is_tool and "tool_result" or (role == "assistant" and "llm_response" or "user_input"),
    source = "anthropic.messages[" .. message_index .. "].content[" .. block_index .. "]",
    source_kind = is_tool and "tool" or message_source_kind(role),
    text = is_tool and block.content or block.text,
    message_index = message_index,
    block_index = block_index,
    field = is_tool and "content" or "text",
  }
end

local function analyze_blocks(blocks, message_index, role)
  local records = {}
  local task_fragments = {}
  for block_index, block in ipairs(blocks) do
    if type(block) ~= "table" then
      return nil, nil, "invalid_content_block"
    end
    if block.type == "text" and type(block.text) == "string" then
      records[#records + 1] = block_record(message_index, block_index, block, role)
      if Common.has_text(block.text) then
        task_fragments[#task_fragments + 1] = block.text
      end
    elseif block.type == "tool_result" and type(block.content) == "string" then
      records[#records + 1] = block_record(message_index, block_index, block, role)
    else
      return nil, nil, "content_block_not_supported"
    end
  end
  return records, table.concat(task_fragments, "\n"), nil
end

function Adapter.parse(raw)
  local body, decode_err = Common.decode_object(raw)
  if not body then
    return nil, decode_err
  end
  if type(body.messages) ~= "table" then
    return unsupported("messages_not_supported")
  end

  local message_info = {}
  local task_index
  local task_prompt
  for message_index, message in ipairs(body.messages) do
    if type(message) ~= "table" or (message.role ~= "user" and message.role ~= "assistant") then
      return unsupported("invalid_message_shape")
    end

    local records
    local message_text
    if type(message.content) == "string" then
      records = { message_record(message_index, message) }
      message_text = message.content
    elseif type(message.content) == "table" then
      local block_err
      records, message_text, block_err = analyze_blocks(message.content, message_index, message.role)
      if block_err then
        return unsupported(block_err)
      end
    else
      return unsupported("message_content_not_supported")
    end

    message_info[message_index] = records
    if message.role == "user" and Common.has_text(message_text) then
      task_index = message_index
      task_prompt = message_text
    end
  end
  if not task_index then
    return unsupported("task_not_found")
  end

  local records = {}
  for message_index = 1, task_index - 1 do
    for _, record in ipairs(message_info[message_index]) do
      records[#records + 1] = record
    end
  end

  return {
    supported = true,
    adapter = Adapter,
    body = body,
    task_prompt = task_prompt,
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
    local replacement = Common.has_text(excerpt) and excerpt or Adapter.OMITTED_CONTEXT_MARKER
    local message = rewritten.messages[record.message_index]
    if record.block_index then
      message.content[record.block_index][record.field] = replacement
    else
      message[record.field] = replacement
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
