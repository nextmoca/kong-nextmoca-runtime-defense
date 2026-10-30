local Policy = {}

local function pass(body, reason)
  return { kind = "pass", body = body, reason = reason }
end

local function block(reason, cause)
  return { kind = "block", cause = cause, reason = reason }
end

local function screens(mode)
  return mode == "quarantine" or mode == "enforce"
end

local function delivery_adapter(parsed)
  if type(parsed) ~= "table" or type(parsed.adapter) ~= "table"
    or type(parsed.adapter.rewrite_selected) ~= "function"
    or type(parsed.adapter.rewrite_single_candidate) ~= "function" then
    return nil
  end
  return parsed.adapter
end

local function selected(original, parsed, response)
  if response.fallback_used or type(response.selected) ~= "table" or #response.selected == 0 then
    return pass(original, "selection_not_deliverable")
  end

  local excerpts = {}
  local known = {}
  for _, record in ipairs(parsed.records) do
    known[record.id] = true
  end
  for _, selection in ipairs(response.selected) do
    if known[selection.record_id] and type(selection.excerpt) == "string" and selection.excerpt:match("%S") then
      excerpts[selection.record_id] = selection.excerpt
    end
  end
  if next(excerpts) == nil then
    return pass(original, "selection_has_no_matching_candidate")
  end

  local adapter = delivery_adapter(parsed)
  if not adapter then
    return pass(original, "selection_adapter_not_resolved")
  end
  local rewritten, rewrite_err = adapter.rewrite_selected(parsed, excerpts)
  if not rewritten then
    return pass(original, "selection_rewrite_failed:" .. tostring(rewrite_err))
  end
  return { kind = "transform", body = rewritten, reason = "selected" }
end

local function sanitized_fallback(mode, original, parsed, response)
  if not screens(mode) then
    return pass(original, "sanitized_fallback_observed_not_enabled")
  end
  if type(response.rendered_context) ~= "string" or not response.rendered_context:match("%S") then
    return block("empty_sanitized_fallback", "verdict")
  end

  local adapter = delivery_adapter(parsed)
  if not adapter then
    return block("sanitized_fallback_adapter_not_resolved", "verdict")
  end
  local rewritten, rewrite_err = adapter.rewrite_single_candidate(parsed, response.rendered_context)
  if not rewritten then
    return block(rewrite_err, "verdict")
  end
  return { kind = "transform", body = rewritten, reason = "sanitized_fallback" }
end

function Policy.decide(config, original, parsed, response, selection_err)
  if selection_err then
    if screens(config.mode) and config.on_selection_error == "block" then
      return block("selection_error_blocked", "unavailable")
    end
    return pass(original, "selection_error")
  end
  if config.mode == "shadow" then
    return pass(original, "shadow")
  end

  if response.outcome == "blocked" then
    if config.mode == "enforce" then
      return block("blocked_by_nextmoca", "verdict")
    end
    return pass(original, "blocked_observed_not_enforced")
  end
  if response.outcome == "sanitized_fallback" then
    return sanitized_fallback(config.mode, original, parsed, response)
  end
  if response.outcome == "selected" or response.outcome == "engaged" then
    return selected(original, parsed, response)
  end
  if response.outcome == "fallback" then
    return pass(original, "fallback")
  end
  return pass(original, "unknown_delivery_outcome")
end

return Policy
