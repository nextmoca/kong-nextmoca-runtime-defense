return {
  name = "nextmoca-runtime-defense",
  fields = {
    {
      config = {
        type = "record",
        fields = {
          { endpoint = { type = "string", default = "https://api.nextmoca.com" } },
          { api_key_env = { type = "string", default = "NEXTMOCA_API_KEY" } },
          { operating_point = { type = "string", default = "np-2026-10-r7" } },
          { mode = { type = "string", default = "shadow", one_of = { "shadow", "active", "quarantine", "enforce" } } },
          { request_adapter = { type = "string", default = "auto", one_of = { "auto", "openai_chat", "openai_responses", "anthropic_messages", "gemini_generate_content" } } },
          { unsupported_shape = { type = "string", default = "pass", one_of = { "pass", "block" } } },
          { on_selection_error = { type = "string", default = "pass", one_of = { "pass", "block" } } },
          { max_context_tokens = { type = "integer", default = 8192 } },
          { capacity_tokens = { type = "integer", default = 128000 } },
          { autochunk = { type = "boolean", default = true } },
          { timeout_ms = { type = "integer", default = 3000 } },
          { breaker_failures = { type = "integer", default = 3 } },
          { breaker_cooldown_ms = { type = "integer", default = 30000 } },
        },
      },
    },
  },
}
