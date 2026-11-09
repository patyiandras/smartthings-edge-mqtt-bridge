-- Public build: the broker comes from device preferences (stbMqttHost, ...).
-- Runs on any Lua 5.3 (we use fengari: node st-edge/test/run.js).
package.path = "./bridge/?.lua;./vendor/lua_libs/lua_libs-api_v21/?.lua;" .. package.path

collectgarbage = function() return 123.4 end -- fengari has no GC stats
local sent = {}           -- raw MQTT packets written to the "socket" channel
local spawned = {}
package.preload["log"] = function()
  local l = {}
  for _, k in ipairs({ "info", "warn", "error", "debug", "trace", "error_with", "warn_with", "info_with" }) do l[k] = function() end end
  return l
end
package.preload["st.json"] = function() return require "dkjson" end
package.preload["cosock"] = function()
  return {
    spawn = function(fn, name) spawned[#spawned + 1] = name end,
    socket = { sleep = function() end, tcp = function() error("no tcp in test") end },
    channel = { new = function()
      return { send = function(_, msg) sent[#sent + 1] = msg end }, { receive = function() end }
    end },
  }
end
package.preload["st_bridge_config"] = function()
  return { bridge_key = "zigbee-switch" } -- public build: no baked broker
end

-- fake device ----------------------------------------------------------------
local Device = {}
function Device:get_field(k) return self._fields[k] end
function Device:set_field(k, v) self._fields[k] = v end
function Device:extend_device(name, fn) self._over[name] = fn end
function Device:get_manufacturer() return "IKEA of Sweden" end
function Device:get_model() return "TRADFRI bulb E27 WS opal 980lm" end
function Device:get_latest_state(comp, cap, attr) return ((self._state[comp] or {})[cap] or {})[attr] end
function Device:emit_component_event(component, ev)
  self._emitted[#self._emitted + 1] = ev
  return { ok = true }
end
function Device:register_native_capability_attr_handler() return "REGISTERED" end

local function new_device(id, label, caps)
  local capt = {}
  for _, c in ipairs(caps) do capt[#capt + 1] = { id = c } end
  local d = {
    id = id, label = label, _fields = {}, _over = {}, _emitted = {},
    _state = { main = { switch = { switch = "off" }, switchLevel = { level = 40 } } },
    profile = { components = { main = { id = "main", capabilities = capt } } },
    thread = { queue_event = function(_, fn) fn() end, call_with_delay = function(_, _, fn) fn() end },
  }
  return setmetatable(d, { __index = function(t, k) return rawget(t, "_over")[k] or Device[k] end })
end

-- fake driver ----------------------------------------------------------------
local handled = {}
local lifecycle = {}
function lifecycle:dispatch(driver, device, event) self.last = event; return "dispatched" end
local driver = {
  NAME = "zigbee_switch",
  lifecycle_dispatcher = setmetatable({}, { __index = lifecycle }),
  call_on_schedule = function() end,
  handle_capability_command = function(drv, device, cmd, quiet) handled[#handled + 1] = cmd end,
}

local bridge = require "st_bridge"
bridge.attach(driver)
assert(bridge.mqtt.opts.host == nil, "public build must start without a broker")

-- a device without settings: still no broker
local lamp = new_device("dev-2", "Lamp", { "switch" })
lamp.preferences = {}
driver.lifecycle_dispatcher:dispatch(driver, lamp, "init")
assert(bridge.mqtt.opts.host == nil, "broker invented from nothing")

-- a second device with the broker set -> it is used, and the session is dropped to reconnect
local dropped = 0
local orig_drop = bridge.mqtt._drop
bridge.mqtt._drop = function(self) dropped = dropped + 1; return orig_drop(self) end
local plug = new_device("dev-9", "Plug", { "switch" })
plug.preferences = { stbMqttHost = " 10.0.0.5 ", stbMqttPort = 1884, stbMqttUser = "st", stbMqttPass = "pw" }
driver.lifecycle_dispatcher:dispatch(driver, plug, "init")
local o = bridge.mqtt.opts
assert(o.host == "10.0.0.5" and o.port == 1884 and o.username == "st" and o.password == "pw", "broker not taken from prefs")
assert(dropped == 1, "no reconnect after broker change")

-- unchanged settings (infoChanged for a label rename) -> no reconnect
driver.lifecycle_dispatcher:dispatch(driver, plug, "infoChanged")
assert(dropped == 1, "reconnected without a change")

-- the lowest device id wins when several are set; empty user/password -> anonymous
lamp.preferences = { stbMqttHost = "10.0.0.7", stbMqttUser = "", stbMqttPass = "" }
driver.lifecycle_dispatcher:dispatch(driver, lamp, "infoChanged")
assert(o.host == "10.0.0.7" and o.port == 1883 and o.username == nil and o.password == nil, "wrong precedence / defaults")
assert(dropped == 2)

-- removing that device falls back to the other one
driver.lifecycle_dispatcher:dispatch(driver, lamp, "removed")
assert(o.host == "10.0.0.5", "no fallback after removal")
-- whitespace around the values (copy-paste, phone keyboard) is ignored
plug.preferences = { stbMqttHost = "10.0.0.5", stbMqttUser = " st ", stbMqttPass = "pw  " }
driver.lifecycle_dispatcher:dispatch(driver, plug, "infoChanged")
assert(o.username == "st" and o.password == "pw", "credentials not trimmed")
print("OK - public broker tests passed")
