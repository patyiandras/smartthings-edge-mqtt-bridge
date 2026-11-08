-- Offline test of patches/zwave-window-treatment/qubino_guard.lua
-- node st-edge/test/run.js test/qubino_guard_test.lua
local warns = {}
package.loaded["log"] = { info = function() end, warn = function(m) warns[#warns + 1] = m end }
local function msg(kind) return function(_, args) return { kind = kind, args = args or {} } end end
package.loaded["st.zwave.CommandClass.SwitchMultilevel"] = function()
  return { Set = msg("Set"), Get = msg("Get"), StopLevelChange = msg("Stop") }
end
package.loaded["st.zwave.CommandClass.Meter"] = function()
  return { Get = msg("MeterGet"), scale = { electric_meter = { WATTS = 2 } } }
end
local hook
package.loaded["st_bridge"] = { on_event = function(fn) hook = fn end }

-- simulated clock + device thread
local now = 1000
os.time = function() return now end
local timers = {}
local function advance(sec)
  local target = now + sec
  while true do
    table.sort(timers, function(a, b) return a.at < b.at end)
    local t = timers[1]
    if not t or t.at > target then break end
    table.remove(timers, 1)
    now = t.at
    t.fn()
  end
  now = target
end

local M = dofile("patches/zwave-window-treatment/qubino_guard.lua")
assert(hook == M.on_event, "on_event registered")

local function new_device(level)
  local d = { id = "sh1", label = "Children's Room Shutter", sent = {}, level = level }
  d.thread = { call_with_delay = function(_, sec, fn) timers[#timers + 1] = { at = now + sec, fn = fn } end }
  function d:send(m) self.sent[#self.sent + 1] = m; if self.on_send then self:on_send(m) end end
  function d:get_latest_state(comp, cap, attr) if cap == "windowShadeLevel" then return self.level end end
  function d:emit(cap, attr, v)
    if cap == "windowShadeLevel" then self.level = v end
    hook(self, "main", cap, attr, v)
  end
  return d
end
local function kinds(d)
  local t = {}
  for _, m in ipairs(d.sent) do t[#t + 1] = m.kind .. (m.args.value and ("(" .. m.args.value .. ")") or "") end
  return table.concat(t, " ")
end

-- 1) Failure: closed (0), open command, module instantly reports 99 with 0 W, no movement.
--    Guard: down (Set 0) -> module reports 0 after a few seconds -> Set 99 again -> moves.
do
  timers, warns = {}, {}
  local d = new_device(0)
  local believed = 99 -- the module's (wrong) internal position
  function d:on_send(m)
    if m.kind == "Set" then
      local v = m.args.value
      if v == 99 and believed == 99 then
        self:emit("windowShade", "windowShade", "open"); self:emit("windowShadeLevel", "shadeLevel", 100)
      elseif v == 0 and believed == 99 then
        -- relay down, shutter already at the bottom: 0 W, after 5 s "click" + report 0
        d.thread:call_with_delay(5, function()
          believed = 0
          self:emit("windowShade", "windowShade", "closed"); self:emit("windowShadeLevel", "shadeLevel", 0)
        end)
      elseif v == 99 and believed == 0 then
        self.moving = true
        self:emit("powerMeter", "power", 130); self:emit("windowShade", "windowShade", "opening")
        d.thread:call_with_delay(23, function()
          believed = 99; self.moving = false
          self:emit("powerMeter", "power", 0)
          self:emit("windowShade", "windowShade", "open"); self:emit("windowShadeLevel", "shadeLevel", 100)
        end)
      end
    elseif m.kind == "MeterGet" then
      self:emit("powerMeter", "power", self.moving and 130 or 0)
    end
  end
  M.commanded(d, 99); d:send({ kind = "Set", args = { value = 99 } })
  advance(1)
  assert(not kinds(d):find("Set%(0%)"), "no recovery before the power check: " .. kinds(d))
  advance(1)
  assert(kinds(d):find("Set%(99%) MeterGet Set%(0%)"), "fast recovery down within 2 s: " .. kinds(d))
  advance(30)
  local k = kinds(d)
  assert(k:find("Set%(0%).*Set%(99%)"), "target resent after calibration: " .. k)
  advance(30)
  assert(M.states[d.id] == nil, "guard finished")
  assert(d.level == 100, "shutter up")
  local w = table.concat(warns, "\n")
  assert(w:find("nem indult el") and w:find("véghelyzet") and w:find("újraküldés után elindult"), w)
  print("ok 1: failure -> calibrate down -> resend up\n" .. w)
end

-- 2) Normal open: power reported -> no recovery.
do
  timers, warns = {}, {}
  local d = new_device(0)
  function d:on_send(m)
    if m.kind == "Set" and m.args.value == 99 then
      self:emit("powerMeter", "power", 130); self:emit("windowShade", "windowShade", "opening")
      d.thread:call_with_delay(23, function()
        self:emit("powerMeter", "power", 0); self:emit("windowShadeLevel", "shadeLevel", 100)
      end)
    end
  end
  M.commanded(d, 99); d:send({ kind = "Set", args = { value = 99 } })
  advance(60)
  assert(kinds(d) == "Set(99)", "only the command: " .. kinds(d))
  assert(#warns == 0 and M.states[d.id] == nil)
  print("ok 2: normal open untouched")
end

-- 3) Already open + open command, and small move: not watched.
do
  timers, warns = {}, {}
  local d = new_device(100)
  M.commanded(d, 99); advance(20)
  assert(M.states[d.id] == nil and #d.sent == 0)
  d.level = 50; M.commanded(d, 60); advance(20)
  assert(M.states[d.id] == nil and #d.sent == 0)
  print("ok 3: no-op cases")
end

-- 4) Failure on close (module believes it is at the bottom: instant "0"): calibrate up (module
--    never reports -> timeout), resend close, still instant "0" -> logged, stops (single round).
do
  timers, warns = {}, {}
  local d = new_device(100)
  function d:on_send(m)
    if m.kind == "Set" and m.args.value == 0 then self:emit("windowShadeLevel", "shadeLevel", 0) end
  end
  M.commanded(d, 0); d:send({ kind = "Set", args = { value = 0 } })
  advance(9)
  assert(kinds(d):find("^Set%(0%) MeterGet MeterGet Set%(99%)"), "calibrate up: " .. kinds(d))
  advance(80)
  local k = kinds(d)
  assert(k:find("Set%(99%).*Set%(0%)"), "resend close after timeout: " .. k)
  advance(30)
  assert(M.states[d.id] == nil)
  local w = table.concat(warns, "\n")
  assert(w:find("időtúllépés") and w:find("újraküldés után sem indult el"), w)
  local n = 0; for _ in k:gmatch("Set%(") do n = n + 1 end
  assert(n == 3, "exactly one recovery round: " .. k)
  print("ok 4: close failure, timeout, single retry")
end

-- 6) Shutter physically already at the target (HA showed "open", but it was down): close ->
--    module runs the relay, 0 W, reports 0 only after 5 s -> no recovery.
do
  timers, warns = {}, {}
  local d = new_device(100)
  function d:on_send(m)
    if m.kind == "Set" and m.args.value == 0 then
      d.thread:call_with_delay(5, function() self:emit("windowShadeLevel", "shadeLevel", 0) end)
    end
  end
  M.commanded(d, 0); d:send({ kind = "Set", args = { value = 0 } })
  advance(60)
  assert(kinds(d) == "Set(0) MeterGet", "no recovery: " .. kinds(d))
  assert(M.states[d.id] == nil and table.concat(warns):find("már ott volt"), table.concat(warns))
  print("ok 6: already there (late report) -> untouched")
end

-- 5) Pause during recovery cancels it.
do
  timers, warns = {}, {}
  local d = new_device(0)
  M.commanded(d, 99); d:emit("windowShadeLevel", "shadeLevel", 100); advance(9)
  assert(M.states[d.id] and M.states[d.id].phase == "recover")
  M.cancel(d); local before = #d.sent; advance(90)
  assert(#d.sent == before, "nothing after cancel")
  print("ok 5: pause cancels")
end
print("ALL OK")
