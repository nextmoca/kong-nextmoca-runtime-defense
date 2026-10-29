local Breaker = {}
Breaker.__index = Breaker

local transient = {
  timeout = true,
  transport = true,
  server = true,
}

local function default_clock()
  if ngx and ngx.now then
    return ngx.now() * 1000
  end
  return os.time() * 1000
end

function Breaker.new(failure_limit, cooldown_ms, clock)
  return setmetatable({
    failure_limit = failure_limit or 5,
    cooldown_ms = cooldown_ms or 30000,
    clock = clock or default_clock,
    failures = 0,
    opened_until = 0,
    probe_in_flight = false,
  }, Breaker)
end

function Breaker:allow()
  local now = self.clock()
  if self.opened_until == 0 then
    return true
  end
  if now < self.opened_until then
    return false
  end
  if self.probe_in_flight then
    return false
  end
  self.probe_in_flight = true
  return true
end

function Breaker:report(error_class)
  self.probe_in_flight = false
  if not error_class then
    self.failures = 0
    self.opened_until = 0
    return
  end

  if not transient[error_class] then
    self.failures = 0
    return
  end

  self.failures = self.failures + 1
  if self.failures >= self.failure_limit then
    self.opened_until = self.clock() + self.cooldown_ms
  end
end

return Breaker
