-- Offline test of the sthm-bridge driver's request / PIN logic (stubbed SmartThings libs).
-- node st-edge/test/run.js test/sthm_driver_test.lua
local emitted, delayed, template = {}, {}, nil
local function attr(name) return function(v) return { attr = name, value = v } end end
package.loaded["log"] = { info = function() end, warn = function() end }
package.loaded["st.capabilities"] = {
  ["advancelegend34283.sthmState"] = { ID = "S", sthmState = attr("sthmState"),
    commands = { setSthmState = { NAME = "setSthmState" } } },
  ["advancelegend34283.sthmRequest"] = { ID = "R", request = attr("request"),
    commands = { sendRequest = { NAME = "sendRequest" } } },
}
package.loaded["st.driver"] = function(_, t)
  template = t
  return { run = function() end, get_devices = function() return {} end }
end
dofile("drivers/sthm-bridge/src/init.lua")

local now = 1000
os.time = function() return now end
local dev = { preferences = {}, _f = {},
  thread = { call_with_delay = function(_, _, fn) delayed[#delayed + 1] = fn end } }
function dev:get_field(k) return self._f[k] end
function dev:set_field(k, v) self._f[k] = v end
function dev:emit_event(e) emitted[#emitted + 1] = e.value end

local send = template.capability_handlers.R.sendRequest
local function req(value, code)
  emitted = {}
  send(nil, dev, { args = { value = value, code = code } })
  return emitted[1]
end

assert(req("armAway") == "armAway", "arm away")
assert(req("armStay") == "armStay", "arm stay")
assert(#delayed == 2, "request reset to none not scheduled")
delayed[1](); assert(emitted[#emitted] == "none")
assert(req("disarm", "1234") == "rejected", "disarm without PIN set must be rejected")
assert(req("bogus") == "rejected")
dev.preferences.disarmPin = "1234"
assert(req("disarm") == "rejected", "missing code")
assert(req("disarm", "0000") == "rejected", "wrong code")
assert(req("disarm", "1234") == "disarm", "right code")
-- 3 wrong codes lock disarming, even with the right code
req("disarm", "1"); req("disarm", "2"); req("disarm", "3")
assert(req("disarm", "1234") == "rejected", "lockout")
now = now + 301
assert(req("disarm", "1234") == "disarm", "lockout expires")
print("OK - sthm driver tests passed")
