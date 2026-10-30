local Common = require("kong.plugins.nextmoca-runtime-defense.adapters.common")

local Adapter = {
  name = "gemini_generate_content",
  OMITTED_CONTEXT_MARKER = "[Next Moca omitted nonessential context for this request.]",
}

local function unsupported(reason)
  return { supported = false, reason = reason, adapter = Adapter }, nil
end

local function text_only_part(part)
  if type(part) ~= "table" or type(part.text) ~= "string" then
    return false
  end
  for key in pairs(part) do
    if key ~= "text" then
      return false
    end
  end
  return true
end

local function records_for_content(content_index, content)
  if type(content) ~= "table" or (content.role ~= "user" and content.role ~= "model") then
    return nil, nil, "invalid_content_shape"
  end
  if type(content.parts) ~= "table" then
    return nil, nil, "content_parts_not_supported"
  end

  local records = {}
  local task_fragments = {}
  for part_index, part in ipairs(content.parts) do
    if not text_only_part(part) then
      return nil, nil, "content_part_not_supported"
    end
    records[#records + 1] = {
      id = "content-" .. content_index .. "-part-" .. part_index,
      kind = content.role == "model" and "assistant_message" or "conversation_history",
      source = "gemini.contents[" .. content_index .. "].parts[" .. part_index .. "]",
      source_kind = content.role == "model" and "assistant" or "conversation",
      text = part.text,
      content_index = content_index,
      part_index = part_index,
    }
    if Common.has_text(part.text) then
      task_fragments[#task_fragments + 1] = part.text
    end
  end
  return records, table.concat(task_fragments, "\n"), nil
end

function Adapter.parse(raw)
  local body, decode_err = Common.decode_object(raw)
  if not body then
    return nil, decode_err
  end
  if type(body.contents) ~= "table" then
    return unsupported("contents_not_supported")
  end

  local content_records = {}
  local task_index
  local task_prompt
  for content_index, content in ipairs(body.contents) do
    local records, content_text, content_err = records_for_content(content_index, content)
    if content_err then
      return unsupported(content_err)
    end
    content_records[content_index] = records
    if content.role == "user" and Common.has_text(content_text) then
      task_index = content_index
      task_prompt = content_text
    end
  end
  if not task_index then
    return unsupported("task_not_found")
  end

  local records = {}
  for content_index = 1, task_index - 1 do
    for _, record in ipairs(content_records[content_index]) do
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
    rewritten.contents[record.content_index].parts[record.part_index].text = Common.has_text(excerpt)
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
