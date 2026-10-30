package.path = "./?.lua;./?/init.lua;" .. package.path

local cjson = require("cjson.safe")
local openai = require("kong.plugins.nextmoca-runtime-defense.adapters.openai_chat")
local responses = require("kong.plugins.nextmoca-runtime-defense.adapters.openai_responses")
local anthropic = require("kong.plugins.nextmoca-runtime-defense.adapters.anthropic_messages")
local gemini = require("kong.plugins.nextmoca-runtime-defense.adapters.gemini_generate_content")
local registry = require("kong.plugins.nextmoca-runtime-defense.adapters.registry")
local breaker_module = require("kong.plugins.nextmoca-runtime-defense.breaker")
local client = require("kong.plugins.nextmoca-runtime-defense.client")
local policy = require("kong.plugins.nextmoca-runtime-defense.policy")
local access = require("kong.plugins.nextmoca-runtime-defense.access")

local omitted = "[Next Moca omitted nonessential context for this request.]"

local function assert_equal(expected, actual, message)
  if expected ~= actual then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function assert_true(value, message)
  if not value then
    error(message or "expected truthy value", 2)
  end
end

local function fake_pdk(raw_body)
  local state = { headers = {}, logs = {} }
  local pdk = {
    request = {
      get_raw_body = function()
        return raw_body, nil
      end,
      get_header = function(name)
        if name == "x-request-id" then
          return "gateway-request-1"
        end
        return nil
      end,
      get_id = function()
        return "kong-request-1"
      end,
    },
    service = {
      request = {
        set_raw_body = function(body)
          state.upstream_body = body
        end,
      },
    },
    response = {
      exit = function(status, body)
        state.exit_status = status
        state.exit_body = body
        return state
      end,
    },
    log = {
      notice = function(...)
        state.logs[#state.logs + 1] = table.concat({...}, " ")
      end,
      err = function(...)
        state.logs[#state.logs + 1] = table.concat({...}, " ")
      end,
    },
    ctx = { plugin = {} },
  }
  return pdk, state
end

local function plugin_config(overrides)
  local config = {
    mode = "active",
    request_adapter = "auto",
    unsupported_shape = "pass",
    on_selection_error = "pass",
  }
  for key, value in pairs(overrides or {}) do
    config[key] = value
  end
  return config
end

local raw_request = [[
  {
    "model": "gpt-5",
    "temperature": 0.2,
    "messages": [
      {"role": "system", "content": "You are a reservation assistant."},
      {"role": "developer", "content": "Never disclose private data."},
      {"role": "user", "content": "I previously asked about reservation H7K2."},
      {
        "role": "assistant",
        "content": "I will check the reservation.",
        "tool_calls": [{"id": "call_abc", "type": "function", "function": {"name": "lookup_reservation", "arguments": "{\\\"code\\\":\\\"H7K2\\\"}"}}]
      },
      {"role": "tool", "tool_call_id": "call_abc", "content": "Reservation confirmation code is H7K2. Passenger: Ada."},
      {"role": "user", "content": "What is my reservation confirmation code?"}
    ],
    "tools": [{"type": "function", "function": {"name": "lookup_reservation"}}]
  }
]]

local raw_responses_request = [[
  {
    "model": "gpt-5",
    "instructions": "Use only supplied evidence.",
    "tools": [{"type": "function", "name": "lookup_reservation"}],
    "input": [
      {"role": "user", "content": "I previously asked about reservation H7K2."},
      {"type": "function_call", "call_id": "call_abc", "name": "lookup_reservation", "arguments": "{\"code\":\"H7K2\"}"},
      {"type": "function_call_output", "call_id": "call_abc", "output": "Reservation confirmation code is H7K2. Passenger: Ada."},
      {"role": "user", "content": "What is my reservation confirmation code?"}
    ]
  }
]]

local raw_anthropic_request = [[
  {
    "model": "claude-sonnet-4-5",
    "max_tokens": 1024,
    "system": "You are a reservation assistant.",
    "tools": [{"name": "lookup_reservation", "input_schema": {"type": "object"}}],
    "messages": [
      {"role": "user", "content": "I previously asked about reservation H7K2."},
      {"role": "assistant", "content": "I will check the reservation."},
      {"role": "user", "content": "What is my reservation confirmation code?"}
    ]
  }
]]

local raw_gemini_request = [[
  {
    "systemInstruction": {"parts": [{"text": "You are a reservation assistant."}]},
    "contents": [
      {"role": "user", "parts": [{"text": "I previously asked about reservation H7K2."}]},
      {"role": "model", "parts": [{"text": "I will check the reservation."}]},
      {"role": "user", "parts": [{"text": "What is my reservation confirmation code?"}]}
    ],
    "tools": [{"functionDeclarations": [{"name": "lookup_reservation"}]}],
    "generationConfig": {"temperature": 0.2}
  }
]]

local function resolves_the_openai_chat_shape_in_auto_mode()
  local adapter_name, err = registry.detect(raw_request, "auto")

  assert_equal(nil, err)
  assert_equal("openai_chat", adapter_name)
end

local function refuses_an_explicit_adapter_when_the_shape_does_not_match()
  local adapter_name, err = registry.detect(raw_request, "gemini_generate_content")

  assert_equal(nil, adapter_name)
  assert_equal("adapter_shape_mismatch", err)
end

local function refuses_ambiguous_provider_shapes()
  local adapter_name, err = registry.detect([[{
    "messages": [{"role": "user", "content": "What happened?"}],
    "contents": [{"role": "user", "parts": [{"text": "What happened?"}]}]
  }]], "auto")

  assert_equal(nil, adapter_name)
  assert_equal("ambiguous_request_shape", err)
end

local function extracts_only_eligible_earlier_messages()
  local parsed, err = openai.parse(raw_request)

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("What is my reservation confirmation code?", parsed.task_prompt)
  assert_equal("message-3", parsed.records[1].id)
  assert_equal("message-4", parsed.records[2].id)
  assert_equal("message-5", parsed.records[3].id)
  assert_equal("conversation", parsed.records[1].source_kind)
  assert_equal("assistant", parsed.records[2].source_kind)
  assert_equal("tool", parsed.records[3].source_kind)
end

local function rewrites_excerpts_without_changing_control_or_tool_metadata()
  local parsed = assert(openai.parse(raw_request))
  local rewritten_raw, err = openai.rewrite_selected(parsed, {
    ["message-3"] = "Reservation H7K2.",
    ["message-5"] = "Reservation confirmation code is H7K2.",
  })

  assert_equal(nil, err)
  local rewritten = assert(cjson.decode(rewritten_raw))
  assert_equal("You are a reservation assistant.", rewritten.messages[1].content)
  assert_equal("Never disclose private data.", rewritten.messages[2].content)
  assert_equal("Reservation H7K2.", rewritten.messages[3].content)
  assert_equal(omitted, rewritten.messages[4].content)
  assert_equal("call_abc", rewritten.messages[4].tool_calls[1].id)
  assert_equal("lookup_reservation", rewritten.messages[4].tool_calls[1]["function"].name)
  assert_equal("Reservation confirmation code is H7K2.", rewritten.messages[5].content)
  assert_equal("call_abc", rewritten.messages[5].tool_call_id)
  assert_equal("What is my reservation confirmation code?", rewritten.messages[6].content)
  assert_equal("lookup_reservation", rewritten.tools[1]["function"].name)
  assert_equal("gpt-5", rewritten.model)
end

local function refuses_multimodal_content_without_partial_transformation()
  local parsed, err = openai.parse([[{
    "messages": [
      {"role": "user", "content": [{"type": "text", "text": "Earlier context"}]},
      {"role": "user", "content": "What happened?"}
    ]
  }]])

  assert_equal(nil, err)
  assert_equal(false, parsed.supported)
  assert_equal("content_parts_not_supported", parsed.reason)
end

local function accepts_a_responses_string_input_as_the_task()
  local parsed, err = responses.parse([[{
    "model": "gpt-5",
    "input": "What is my reservation confirmation code?"
  }]])

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("What is my reservation confirmation code?", parsed.task_prompt)
  assert_equal(0, #parsed.records)
end

local function extracts_responses_messages_and_function_output_as_candidates()
  local parsed, err = responses.parse(raw_responses_request)

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("What is my reservation confirmation code?", parsed.task_prompt)
  assert_equal("input-1", parsed.records[1].id)
  assert_equal("conversation", parsed.records[1].source_kind)
  assert_equal("input-3", parsed.records[2].id)
  assert_equal("tool", parsed.records[2].source_kind)
end

local function preserves_responses_tool_metadata_when_rewriting_selected_candidates()
  local parsed = assert(responses.parse(raw_responses_request))
  local rewritten_raw, err = responses.rewrite_selected(parsed, {
    ["input-3"] = "Reservation confirmation code is H7K2.",
  })

  assert_equal(nil, err)
  local rewritten = assert(cjson.decode(rewritten_raw))
  assert_equal(omitted, rewritten.input[1].content)
  assert_equal("call_abc", rewritten.input[2].call_id)
  assert_equal("lookup_reservation", rewritten.input[2].name)
  assert_equal("Reservation confirmation code is H7K2.", rewritten.input[3].output)
  assert_equal("What is my reservation confirmation code?", rewritten.input[4].content)
  assert_equal("Use only supplied evidence.", rewritten.instructions)
  assert_equal("lookup_reservation", rewritten.tools[1].name)
end

local function refuses_responses_non_text_content_without_partial_transformation()
  local parsed, err = responses.parse([[{
    "input": [
      {"role": "user", "content": [{"type": "input_text", "text": "Earlier context"}]},
      {"role": "user", "content": "What happened?"}
    ]
  }]])

  assert_equal(nil, err)
  assert_equal(false, parsed.supported)
  assert_equal("content_blocks_not_supported", parsed.reason)
end

local function extracts_anthropic_plain_string_messages_and_preserves_controls()
  local parsed, err = anthropic.parse(raw_anthropic_request)

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("What is my reservation confirmation code?", parsed.task_prompt)
  assert_equal("message-1", parsed.records[1].id)
  assert_equal("conversation", parsed.records[1].source_kind)
  assert_equal("message-2", parsed.records[2].id)
  assert_equal("assistant", parsed.records[2].source_kind)
end

local function rewrites_anthropic_text_blocks_without_changing_system_or_tools()
  local parsed = assert(anthropic.parse([[{
    "model": "claude-sonnet-4-5",
    "max_tokens": 1024,
    "system": "You are a reservation assistant.",
    "tools": [{"name": "lookup_reservation", "input_schema": {"type": "object"}}],
    "messages": [
      {"role": "user", "content": [{"type": "text", "text": "Reservation H7K2 is in the archive."}]},
      {"role": "user", "content": "What is my reservation confirmation code?"}
    ]
  }]]))
  local rewritten_raw, err = anthropic.rewrite_selected(parsed, {
    ["message-1-block-1"] = "Reservation H7K2 is in the archive.",
  })

  assert_equal(nil, err)
  local rewritten = assert(cjson.decode(rewritten_raw))
  assert_equal("Reservation H7K2 is in the archive.", rewritten.messages[1].content[1].text)
  assert_equal("You are a reservation assistant.", rewritten.system)
  assert_equal("lookup_reservation", rewritten.tools[1].name)
end

local function treats_anthropic_tool_result_text_as_eligible_evidence()
  local parsed, err = anthropic.parse([[{
    "model": "claude-sonnet-4-5",
    "max_tokens": 1024,
    "messages": [
      {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "toolu_1", "content": "Reservation confirmation code is H7K2."}]},
      {"role": "user", "content": "What is my reservation confirmation code?"}
    ]
  }]])

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("message-1-block-1", parsed.records[1].id)
  assert_equal("tool", parsed.records[1].source_kind)
end

local function refuses_anthropic_mixed_non_text_content_without_partial_transformation()
  local parsed, err = anthropic.parse([[{
    "model": "claude-sonnet-4-5",
    "max_tokens": 1024,
    "messages": [
      {"role": "assistant", "content": [{"type": "text", "text": "Looking this up."}, {"type": "tool_use", "id": "toolu_1", "name": "lookup_reservation", "input": {}}]},
      {"role": "user", "content": "What happened?"}
    ]
  }]])

  assert_equal(nil, err)
  assert_equal(false, parsed.supported)
  assert_equal("content_block_not_supported", parsed.reason)
end

local function extracts_native_gemini_text_content_and_preserves_controls()
  local parsed, err = gemini.parse(raw_gemini_request)

  assert_equal(nil, err)
  assert_true(parsed.supported)
  assert_equal("What is my reservation confirmation code?", parsed.task_prompt)
  assert_equal("content-1-part-1", parsed.records[1].id)
  assert_equal("conversation", parsed.records[1].source_kind)
  assert_equal("content-2-part-1", parsed.records[2].id)
  assert_equal("assistant", parsed.records[2].source_kind)
end

local function rewrites_native_gemini_selected_text_without_changing_system_or_tools()
  local parsed = assert(gemini.parse(raw_gemini_request))
  local rewritten_raw, err = gemini.rewrite_selected(parsed, {
    ["content-1-part-1"] = "Reservation H7K2 is in the archive.",
  })

  assert_equal(nil, err)
  local rewritten = assert(cjson.decode(rewritten_raw))
  assert_equal("Reservation H7K2 is in the archive.", rewritten.contents[1].parts[1].text)
  assert_equal(omitted, rewritten.contents[2].parts[1].text)
  assert_equal("What is my reservation confirmation code?", rewritten.contents[3].parts[1].text)
  assert_equal("You are a reservation assistant.", rewritten.systemInstruction.parts[1].text)
  assert_equal("lookup_reservation", rewritten.tools[1].functionDeclarations[1].name)
end

local function refuses_native_gemini_binary_parts_without_partial_transformation()
  local parsed, err = gemini.parse([[{
    "contents": [
      {"role": "user", "parts": [{"inlineData": {"mimeType": "image/png", "data": "..."}}]},
      {"role": "user", "parts": [{"text": "What happened?"}]}
    ]
  }]])

  assert_equal(nil, err)
  assert_equal(false, parsed.supported)
  assert_equal("content_part_not_supported", parsed.reason)
end

local function refuses_native_gemini_function_parts_without_partial_transformation()
  local parsed, err = gemini.parse([[{
    "contents": [
      {"role": "model", "parts": [{"functionCall": {"name": "lookup_reservation", "args": {}}}]},
      {"role": "user", "parts": [{"text": "What happened?"}]}
    ]
  }]])

  assert_equal(nil, err)
  assert_equal(false, parsed.supported)
  assert_equal("content_part_not_supported", parsed.reason)
end

local function wires_only_the_hosted_selection_contract()
  local parsed = assert(openai.parse(raw_request))
  local request = client.wire_request({
    endpoint = "https://api.nextmoca.com",
    operating_point = "np-2026-10-r7",
    max_context_tokens = 8192,
    capacity_tokens = 128000,
    autochunk = true,
    mode = "quarantine",
  }, parsed, "request-123")

  assert_equal("request-123", request.request_id)
  assert_equal("What is my reservation confirmation code?", request.task.prompt)
  assert_equal(8192, request.budget.max_context_tokens)
  assert_equal(128000, request.budget.capacity_cap_tokens)
  assert_equal("np-2026-10-r7", request.budget.operating_point)
  assert_equal(true, request.budget.autochunk)
  assert_equal("quarantine", request.security_mode)
  assert_equal("message-5", request.records[3].id)
  assert_equal("tool", request.records[3].source_kind)
end

local function wires_an_adapter_neutral_hosted_contract_for_gemini()
  local parsed = assert(gemini.parse(raw_gemini_request))
  local request = client.wire_request({
    endpoint = "https://api.nextmoca.com",
    operating_point = "np-2026-10-r7",
    max_context_tokens = 8192,
    capacity_tokens = 128000,
    autochunk = true,
    mode = "quarantine",
  }, parsed, "request-gemini")

  assert_equal("request-gemini", request.request_id)
  assert_equal("What is my reservation confirmation code?", request.task.prompt)
  assert_equal("content-1-part-1", request.records[1].id)
  assert_equal("conversation", request.records[1].source_kind)
  assert_equal("content-2-part-1", request.records[2].id)
  assert_equal("assistant", request.records[2].source_kind)
end

local function rejects_mismatched_hosted_response_ids()
  local response, err = client.decode_response(200, {}, [[{
    "request_id": "another-request",
    "outcome": "selected",
    "fallback_used": false,
    "tokens_before": 120,
    "tokens_after": 40,
    "tokens_saved": 80,
    "engine_latency_ms": 12.4,
    "rendered_context": "Reservation confirmation code is H7K2.",
    "selected": [{"record_id": "message-5", "excerpt": "Reservation confirmation code is H7K2."}]
  }]], "request-123")

  assert_equal(nil, response)
  assert_equal("contract", err.class)
end

local function opens_the_breaker_only_after_configured_transient_failures()
  local now = 1000
  local breaker = breaker_module.new(2, 50, function()
    return now
  end)

  assert_equal(true, breaker:allow())
  breaker:report("timeout")
  assert_equal(true, breaker:allow())
  breaker:report("server")
  assert_equal(false, breaker:allow())
  now = 1050
  assert_equal(true, breaker:allow())
  breaker:report(nil)
  assert_equal(true, breaker:allow())
end

local function blocks_enforced_hosted_security_verdicts_before_upstream()
  local parsed = assert(openai.parse(raw_request))
  local decision = policy.decide({ mode = "enforce", on_selection_error = "pass" }, raw_request, parsed, {
    outcome = "blocked",
    fallback_used = false,
  })

  assert_equal("block", decision.kind)
  assert_equal("verdict", decision.cause)
  assert_equal("blocked_by_nextmoca", decision.reason)
end

local function never_restores_raw_context_after_unsafe_sanitized_fallback()
  local parsed = assert(openai.parse(raw_request))
  local decision = policy.decide({ mode = "quarantine", on_selection_error = "pass" }, raw_request, parsed, {
    outcome = "sanitized_fallback",
    fallback_used = true,
    rendered_context = "Reservation confirmation code is H7K2.",
  })

  assert_equal("block", decision.kind)
  assert_equal("sanitized_fallback_requires_record_mapping", decision.reason)
  assert_equal(nil, decision.body)
end

local function applies_selected_excerpts_without_crossing_message_boundaries()
  local parsed = assert(openai.parse(raw_request))
  local decision = policy.decide({ mode = "active", on_selection_error = "pass" }, raw_request, parsed, {
    outcome = "selected",
    fallback_used = false,
    selected = {{ record_id = "message-5", excerpt = "Reservation confirmation code is H7K2." }},
  })

  assert_equal("transform", decision.kind)
  local rewritten = assert(cjson.decode(decision.body))
  assert_equal(omitted, rewritten.messages[3].content)
  assert_equal(omitted, rewritten.messages[4].content)
  assert_equal("Reservation confirmation code is H7K2.", rewritten.messages[5].content)
  assert_equal("What is my reservation confirmation code?", rewritten.messages[6].content)
end

local function applies_selected_excerpts_with_the_resolved_gemini_adapter()
  local parsed = assert(gemini.parse(raw_gemini_request))
  local decision = policy.decide({ mode = "active", on_selection_error = "pass" }, raw_gemini_request, parsed, {
    outcome = "selected",
    fallback_used = false,
    selected = {{ record_id = "content-1-part-1", excerpt = "Reservation H7K2 is in the archive." }},
  })

  assert_equal("transform", decision.kind)
  local rewritten = assert(cjson.decode(decision.body))
  assert_equal("Reservation H7K2 is in the archive.", rewritten.contents[1].parts[1].text)
  assert_equal(omitted, rewritten.contents[2].parts[1].text)
  assert_equal("What is my reservation confirmation code?", rewritten.contents[3].parts[1].text)
end

local function handler_rewrites_the_real_upstream_body_using_the_resolved_adapter()
  local pdk, state = fake_pdk(raw_gemini_request)
  local fake_client = {
    select = function(_, _, request_id)
      assert_equal("gateway-request-1", request_id)
      return {
        outcome = "selected",
        fallback_used = false,
        request_id = request_id,
        tokens_before = 100,
        tokens_after = 40,
        tokens_saved = 60,
        engine_latency_ms = 7.5,
        selected = {{ record_id = "content-1-part-1", excerpt = "Reservation H7K2 is in the archive." }},
      }, nil
    end,
  }

  access.run(pdk, plugin_config(), fake_client)

  local upstream = assert(cjson.decode(state.upstream_body))
  assert_equal("Reservation H7K2 is in the archive.", upstream.contents[1].parts[1].text)
  assert_equal(omitted, upstream.contents[2].parts[1].text)
  assert_equal("gemini_generate_content", pdk.ctx.plugin.receipt.adapter)
  assert_equal("transform", pdk.ctx.plugin.receipt.decision)
end

local function handler_blocks_hosted_security_verdicts_before_the_upstream()
  local pdk, state = fake_pdk(raw_request)
  local fake_client = {
    select = function()
      return { outcome = "blocked", fallback_used = false }, nil
    end,
  }

  access.run(pdk, plugin_config({ mode = "enforce" }), fake_client)

  assert_equal(403, state.exit_status)
  assert_equal("context_security_blocked", state.exit_body.code)
  assert_equal(nil, state.upstream_body)
end

local function handler_blocks_unsupported_shapes_when_security_policy_requires_it()
  local pdk, state = fake_pdk([[{
    "contents": [
      {"role": "user", "parts": [{"inlineData": {"mimeType": "image/png", "data": "..."}}]},
      {"role": "user", "parts": [{"text": "What happened?"}]}
    ]
  }]])

  access.run(pdk, plugin_config({ mode = "quarantine", unsupported_shape = "block" }), {
    select = function()
      error("unsupported request must not call hosted selection")
    end,
  })

  assert_equal(422, state.exit_status)
  assert_equal("context_security_unsupported_request", state.exit_body.code)
end

local function handler_fails_closed_when_the_hosted_service_is_unavailable()
  local pdk, state = fake_pdk(raw_request)
  access.run(pdk, plugin_config({ mode = "quarantine", on_selection_error = "block" }), {
    select = function()
      return nil, { class = "transport", message = "timeout" }
    end,
  })

  assert_equal(503, state.exit_status)
  assert_equal("context_security_unavailable", state.exit_body.code)
  assert_equal(nil, state.upstream_body)
end

local tests = {
  resolves_the_openai_chat_shape_in_auto_mode,
  refuses_an_explicit_adapter_when_the_shape_does_not_match,
  refuses_ambiguous_provider_shapes,
  extracts_only_eligible_earlier_messages,
  rewrites_excerpts_without_changing_control_or_tool_metadata,
  refuses_multimodal_content_without_partial_transformation,
  accepts_a_responses_string_input_as_the_task,
  extracts_responses_messages_and_function_output_as_candidates,
  preserves_responses_tool_metadata_when_rewriting_selected_candidates,
  refuses_responses_non_text_content_without_partial_transformation,
  extracts_anthropic_plain_string_messages_and_preserves_controls,
  rewrites_anthropic_text_blocks_without_changing_system_or_tools,
  treats_anthropic_tool_result_text_as_eligible_evidence,
  refuses_anthropic_mixed_non_text_content_without_partial_transformation,
  extracts_native_gemini_text_content_and_preserves_controls,
  rewrites_native_gemini_selected_text_without_changing_system_or_tools,
  refuses_native_gemini_binary_parts_without_partial_transformation,
  refuses_native_gemini_function_parts_without_partial_transformation,
  wires_only_the_hosted_selection_contract,
  wires_an_adapter_neutral_hosted_contract_for_gemini,
  rejects_mismatched_hosted_response_ids,
  opens_the_breaker_only_after_configured_transient_failures,
  blocks_enforced_hosted_security_verdicts_before_upstream,
  never_restores_raw_context_after_unsafe_sanitized_fallback,
  applies_selected_excerpts_without_crossing_message_boundaries,
  applies_selected_excerpts_with_the_resolved_gemini_adapter,
  handler_rewrites_the_real_upstream_body_using_the_resolved_adapter,
  handler_blocks_hosted_security_verdicts_before_the_upstream,
  handler_blocks_unsupported_shapes_when_security_policy_requires_it,
  handler_fails_closed_when_the_hosted_service_is_unavailable,
}

for _, test in ipairs(tests) do
  test()
end

io.stdout:write("provider adapter suite: " .. #tests .. " tests passed\n")
