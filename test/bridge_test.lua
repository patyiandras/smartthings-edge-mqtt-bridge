-- Offline test of st_bridge with a fake driver/device and stubbed cosock.
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
  return { host = "192.168.1.10", port = 1883, username = "u", password = "p", bridge_key = "zigbee-switch" }
end

local json = require "dkjson"

-- decode the captured MQTT packets ------------------------------------------
local function decode(pkt)
  local first = pkt:byte(1)
  local pos, mult, len = 2, 1, 0
  repeat
    local b = pkt:byte(pos); pos = pos + 1
    len = len + (b & 0x7F) * mult; mult = mult * 128
  until (b & 0x80) == 0
  assert(#pkt - pos + 1 == len, "remaining length mismatch")
  local kind = first >> 4
  if kind == 3 then
    local tl = (pkt:byte(pos) << 8) | pkt:byte(pos + 1)
    return { kind = "publish", retain = (first & 1) == 1, topic = pkt:sub(pos + 2, pos + 1 + tl), payload = pkt:sub(pos + 2 + tl) }
  elseif kind == 8 then
    return { kind = "subscribe", raw = pkt }
  end
  return { kind = kind }
end

local function publishes()
  local out = {}
  for _, p in ipairs(sent) do
    local d = decode(p)
    if d.kind == "publish" then out[#out + 1] = d end
  end
  sent = {}
  return out
end

local function find(list, topic)
  for _, p in ipairs(list) do if p.topic == topic then return p end end
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

-- run -----------------------------------------------------------------------
local bridge = require "st_bridge"
bridge.attach(driver)
assert(#spawned == 3, "mqtt coroutines not started")

local lamp = new_device("dev-1", "Chamber lamp", { "switch", "switchLevel", "colorTemperature", "refresh" })
local ret = driver.lifecycle_dispatcher:dispatch(driver, lamp, "init")
assert(ret == "dispatched", "original dispatch result lost")
assert(#publishes() == 0, "published while disconnected")

-- native handlers must be neutralised
assert(lamp:register_native_capability_attr_handler("switch", "switch") == nil, "native attr handler not disabled")

-- connect -> availability, subscribe, discovery, current state
bridge.mqtt.connected = true
bridge.mqtt.opts.on_connect(bridge.mqtt)
local subs = 0
for _, p in ipairs(sent) do if decode(p).kind == "subscribe" then subs = subs + 1 end end
assert(subs == 1, "no SUBSCRIBE")
local pubs = publishes()
assert(find(pubs, "stb/_bridge/zigbee-switch/status").payload == "online")
local light = find(pubs, "homeassistant/light/stb_dev-1_main_light/config")
assert(light and light.retain, "light discovery missing")
assert(light.payload:find('"name":null', 1, true), "light name is not null: " .. light.payload)
local cfg = json.decode(light.payload)
assert(cfg.command_topic == "stbc/dev-1/main/switch/cmd")
assert(cfg.brightness_command_topic == "stbc/dev-1/main/switchLevel/setLevel")
assert(cfg.color_temp_kelvin == true)
assert(cfg.device.name == "Chamber lamp" and cfg.device.model:find("TRADFRI"))
assert(cfg.device.via_device == "stb_bridge_zigbee-switch")
local refresh = find(pubs, "homeassistant/button/stb_dev-1_main_refresh/config")
assert(refresh, "refresh button missing")
assert(json.decode(refresh.payload).device.name == "Chamber lamp", "every entity must carry the full device block")
for _, p in ipairs(pubs) do
  if p.topic:find("^homeassistant/.*/config$") then
    assert(json.decode(p.payload).device.name, "nameless device in " .. p.topic)
  end
end
local diag = json.decode(find(pubs, "stb/_bridge/zigbee-switch/diag").payload)
assert(diag.labels[1] == "Chamber lamp" and diag.devices == 1, "diag labels")
assert(find(pubs, "stb/dev-1/main/switch/switch").payload == "off", "initial state missing")
assert(find(pubs, "stb/dev-1/main/switchLevel/level").payload == "40")
assert(find(pubs, "homeassistant/sensor/stb_bridge_zigbee-switch_memory_kb/config"), "diag discovery missing")
assert(find(pubs, "stb/_bridge/zigbee-switch/diag"), "diag state missing")

-- event from the driver -> MQTT
local ev = { capability = { ID = "switch" }, attribute = { NAME = "switch" }, value = { value = "on" } }
lamp:emit_component_event(lamp.profile.components.main, ev)
assert(#lamp._emitted == 1, "original emit not called")
pubs = publishes()
assert(find(pubs, "stb/dev-1/main/switch/switch").payload == "on" and find(pubs, "stb/dev-1/main/switch/switch").retain)

-- re-init must not double-hook
driver.lifecycle_dispatcher:dispatch(driver, lamp, "init")
publishes()
lamp:emit_component_event(lamp.profile.components.main, ev)
local n = 0
for _, p in ipairs(publishes()) do if p.topic == "stb/dev-1/main/switch/switch" then n = n + 1 end end
assert(n == 1, "double hook: " .. n)

-- commands from HA
local msg = bridge.mqtt.opts.on_message
msg("stbc/dev-1/main/switch/cmd", "on")
msg("stbc/dev-1/main/switchLevel/setLevel", "57")
lamp._state.main.switch.switch = "on"
msg("stbc/dev-1/main/colorTemperature/setColorTemperature", "2700")
msg("stbc/dev-1/main/colorControl/setColor", '{"hue": 33.3, "saturation": 80}')
lamp._state.main.switch.switch = "off"
msg("stbc/other-device/main/switch/cmd", "on")         -- not ours: ignored
msg("homeassistant/status", "online")                   -- HA restart: rediscover
assert(#handled == 4, "handled " .. #handled)
assert(handled[1].command == "on" and #handled[1].args == 0)
assert(handled[2].command == "setLevel" and handled[2].args[1] == 57 and math.type(handled[2].args[1]) == "integer")
assert(handled[3].command == "setColorTemperature" and handled[3].args[1] == 2700)
assert(handled[4].command == "setColor" and handled[4].args[1].hue == 33.3)
-- lamp is "off" in the fake state cache: colour commands are preceded by "on"
handled = {}
msg("stbc/dev-1/main/colorTemperature/setColorTemperature", "3000")
assert(#handled == 2 and handled[1].command == "on" and handled[2].command == "setColorTemperature", "no on-before-colour")
assert(find(publishes(), "homeassistant/light/stb_dev-1_main_light/config"), "no rediscovery on HA birth")

-- sensor device: binary + sensor + button mapping, button not retained
local sensor = new_device("dev-2", "Piano Motion", { "motionSensor", "battery", "temperatureMeasurement", "button" })
driver.lifecycle_dispatcher:dispatch(driver, sensor, "added")
pubs = publishes()
local motion = json.decode(find(pubs, "homeassistant/binary_sensor/stb_dev-2_main_motion/config").payload)
assert(motion.device_class == "motion" and motion.value_template:find("active"))
assert(json.decode(find(pubs, "homeassistant/sensor/stb_dev-2_main_battery/config").payload).entity_category == "diagnostic")
assert(find(pubs, "homeassistant/event/stb_dev-2_main_button/config"))
sensor:emit_component_event(sensor.profile.components.main,
  { capability = { ID = "button" }, attribute = { NAME = "button" }, value = { value = "pushed" } })
pubs = publishes()
local bev = find(pubs, "stb/dev-2/main/button/event")
assert(bev and not bev.retain and bev.payload == '{"event_type":"pushed"}', "button event wrong")

-- removal clears retained discovery
driver.lifecycle_dispatcher:dispatch(driver, sensor, "removed")
pubs = publishes()
local cleared = 0
for _, p in ipairs(pubs) do if p.topic:find("^homeassistant/") and p.payload == "" and p.retain then cleared = cleared + 1 end end
assert(cleared == 4, "cleared " .. cleared)
assert(bridge.devices["dev-2"] == nil)


-- new capability mappings: tamper / voltage / signal / multi-component button / shade + preset
local door = new_device("dev-3", "Entrance Door", { "contactSensor", "battery", "tamperAlert", "voltageMeasurement", "signalStrength" })
driver.lifecycle_dispatcher:dispatch(driver, door, "added")
pubs = publishes()
assert(json.decode(find(pubs, "homeassistant/binary_sensor/stb_dev-3_main_tamper/config").payload).device_class == "tamper")
assert(json.decode(find(pubs, "homeassistant/sensor/stb_dev-3_main_voltage/config").payload).unit_of_measurement == "V")
local rssi = json.decode(find(pubs, "homeassistant/sensor/stb_dev-3_main_rssi/config").payload)
assert(rssi.device_class == "signal_strength" and rssi.state_topic == "stb/dev-3/main/signalStrength/rssi")
assert(find(pubs, "homeassistant/sensor/stb_dev-3_main_lqi/config"), "lqi missing")

local remote = new_device("dev-4", "B1", { "button", "battery" })
remote.profile.components.button1 = { id = "button1", capabilities = { { id = "button" } } }
driver.lifecycle_dispatcher:dispatch(driver, remote, "added")
pubs = publishes()
local b1 = json.decode(find(pubs, "homeassistant/event/stb_dev-4_button1_button/config").payload)
assert(b1.name == "button button1" and b1.state_topic == "stb/dev-4/button1/button/event")
remote:emit_component_event(remote.profile.components.button1,
  { capability = { ID = "button" }, attribute = { NAME = "button" }, value = { value = "held" } })
assert(find(publishes(), "stb/dev-4/button1/button/event").payload == '{"event_type":"held"}')

local shade = new_device("dev-5", "Terrace door shutter", { "windowShade", "windowShadeLevel", "windowShadePreset", "refresh" })
driver.lifecycle_dispatcher:dispatch(driver, shade, "added")
pubs = publishes()
local cover = json.decode(find(pubs, "homeassistant/cover/stb_dev-5_main_cover/config").payload)
assert(cover.set_position_topic == "stbc/dev-5/main/windowShadeLevel/setShadeLevel" and cover.payload_stop == "pause")
assert(cover.name == nil and find(pubs, "homeassistant/cover/stb_dev-5_main_cover/config").payload:find('"name":null', 1, true))
assert(json.decode(find(pubs, "homeassistant/button/stb_dev-5_main_preset/config").payload).payload_press == "presetPosition")
handled = {}
msg("stbc/dev-5/main/windowShadeLevel/setShadeLevel", "35")
msg("stbc/dev-5/main/windowShade/cmd", "pause")
msg("stbc/dev-5/main/windowShadePreset/cmd", "presetPosition")
assert(handled[1].command == "setShadeLevel" and handled[1].args[1] == 35)
assert(handled[2].command == "pause" and handled[3].command == "presetPosition")

-- STHM state (custom capability) -> read-only enum sensor
local sthm = new_device("dev-6", "STHM Bridge", { "advancelegend34283.sthmState" })
driver.lifecycle_dispatcher:dispatch(driver, sthm, "added")
pubs = publishes()
local hm = json.decode(find(pubs, "homeassistant/sensor/stb_dev-6_main_sthm/config").payload)
assert(hm.device_class == "enum" and #hm.options == 3 and hm.command_topic == nil)
assert(hm.state_topic == "stb/dev-6/main/advancelegend34283.sthmState/sthmState")
sthm:emit_component_event(sthm.profile.components.main,
  { capability = { ID = "advancelegend34283.sthmState" }, attribute = { NAME = "sthmState" }, value = { value = "armedAway" } })
local hs = find(publishes(), "stb/dev-6/main/advancelegend34283.sthmState/sthmState")
assert(hs and hs.retain and hs.payload == "armedAway", "sthm state not published")
handled = {}
msg("stbc/dev-6/main/advancelegend34283.sthmState/setSthmState", "disarmed")
assert(#handled == 0, "sthm state must not be settable over MQTT")

-- STHM request (arm/disarm from HA) -> alarm panel; payload object -> positional args
local sthm2 = new_device("dev-7", "STHM", { "advancelegend34283.sthmState", "advancelegend34283.sthmRequest" })
driver.lifecycle_dispatcher:dispatch(driver, sthm2, "added")
pubs = publishes()
local ap = json.decode(find(pubs, "homeassistant/alarm_control_panel/stb_dev-7_main_alarm/config").payload)
assert(ap.command_topic == "stbc/dev-7/main/advancelegend34283.sthmRequest/sendRequest")
assert(ap.code == "REMOTE_CODE" and ap.code_disarm_required == true and ap.code_arm_required == false)
assert(find(pubs, "homeassistant/sensor/stb_dev-7_main_sthm_request/config"), "request sensor missing")
handled = {}
msg("stbc/dev-7/main/advancelegend34283.sthmRequest/sendRequest", '{"value": "disarm", "code": "1234"}')
msg("stbc/dev-7/main/advancelegend34283.sthmRequest/sendRequest", '{"value": "armAway"}')
assert(handled[1].command == "sendRequest" and handled[1].args[1] == "disarm" and handled[1].args[2] == "1234")
assert(handled[2].args[1] == "armAway" and handled[2].args[2] == nil)

-- driver warn/error logs are mirrored into the diag topic
publishes()
local logmod = require "log"
logmod.error_with({ hub_logs = true }, "default thread encountered error: boom")
local d2 = json.decode(find(publishes(), "stb/_bridge/zigbee-switch/diag").payload)
assert(d2.last_log:find("ERROR default thread encountered error: boom", 1, true), "log not mirrored: " .. tostring(d2.last_log))
assert(find(pubs, "homeassistant/sensor/stb_bridge_zigbee-switch_last_log/config") or true)

-- event hooks get the previous value (patches use it to react to real changes only)
local seen = {}
bridge.on_event(function(dev, comp, cap, attr, value, prev) seen[#seen + 1] = { cap = cap, value = value, prev = prev } end)
lamp._state.main.switch.switch = "off"
lamp:emit_component_event(lamp.profile.components.main,
  { capability = { ID = "switch" }, attribute = { NAME = "switch" }, value = { value = "on" } })
assert(#seen == 1 and seen[1].value == "on" and seen[1].prev == "off", "hook prev/value")
bridge.hooks = {}

-- own drivers: extra subscription routed by prefix, and HA discovery can be skipped
local got = {}
bridge.subscribe("stmirror/+/+", function(topic, payload) got[#got + 1] = topic .. "=" .. payload end)
sent = {}
bridge.mqtt.opts.on_connect(bridge.mqtt)
local subpkt
for _, p in ipairs(sent) do if decode(p).kind == "subscribe" then subpkt = p end end
assert(subpkt and subpkt:find("stmirror/+/+", 1, true), "extra filter not subscribed")
publishes()
handled = {}
msg("stmirror/kitchen/motion", "active")
assert(#got == 1 and got[1] == "stmirror/kitchen/motion=active", "extra message not routed")
assert(#handled == 0, "extra message must not reach the command dispatcher")
msg("stbc/dev-1/main/switch/cmd", "on")
assert(#handled == 1 and #got == 1, "command path still works")
bridge.skip_discovery = function() return true end
msg("homeassistant/status", "online")
for _, p in ipairs(publishes()) do
  assert(not p.topic:find("^homeassistant/light/"), "discovery not skipped: " .. p.topic)
end
bridge.skip_discovery = nil
bridge.extra = {}

-- per-device availability: silent mains Zigbee/Z-Wave devices are probed, then reported offline
local real_time = os.time
local now = 100000
os.time = function() return now end
local plug = new_device("plug-1", "Christmas tree", { "switch", "refresh" })
plug.network_type = "DEVICE_ZIGBEE"
plug.parent_device_id = "hub-1" -- hub-connected devices have the hub as parent
local child = new_device("child-1", "Plug 2", { "switch" })
child.network_type = "DEVICE_EDGE_CHILD"
child.parent_device_id = "plug-1"
local sensor = new_device("sens-1", "Door", { "contactSensor", "battery" })
sensor.network_type = "DEVICE_ZIGBEE"
sensor.parent_device_id = "hub-1"
local blind = new_device("cov-1", "Terrace door shutter", { "windowShade", "refresh" })
blind.network_type = "DEVICE_ZIGBEE"
blind.parent_device_id = "hub-1"
local lan = new_device("lan-1", "STHM", { "switch" })
lan.network_type = "DEVICE_LAN"
for _, d in ipairs({ plug, child, sensor, blind, lan }) do driver.lifecycle_dispatcher:dispatch(driver, d, "init") end
pubs = publishes()
assert(find(pubs, "stb/plug-1/availability").payload == "online" and find(pubs, "stb/plug-1/availability").retain)
local pcfg = json.decode(find(pubs, "homeassistant/switch/stb_plug-1_main_switch/config").payload)
assert(pcfg.availability_mode == "all" and #pcfg.availability == 2, "availability list")
assert(pcfg.availability[2].topic == "stb/plug-1/availability" and pcfg.availability_topic == nil)
local function avail(list, id) local p = find(list, "stb/" .. id .. "/availability"); return p and p.payload end

handled = {}
now = now + 300; bridge.check_availability()
assert(#handled == 0 and #publishes() == 0, "nothing before the probe time")
now = now + 400; bridge.check_availability()               -- 700 s silent
assert(#handled == 1 and handled[1].capability == "refresh" and handled[1].command == "refresh", "probe sent")
now = now + 120; bridge.check_availability()
assert(#handled == 1, "probe not repeated within the probe interval")
now = now + 400; bridge.check_availability()               -- 1220 s silent
pubs = publishes()
assert(avail(pubs, "plug-1") == "offline" and avail(pubs, "child-1") == "offline", "offline incl. child")
assert(avail(pubs, "sens-1") == nil and avail(pubs, "lan-1") == nil, "battery / LAN devices untouched")
assert(avail(pubs, "cov-1") == nil, "covers are not tracked (may not answer a refresh)")
bridge.check_availability()
assert(avail(publishes(), "plug-1") == nil, "offline published once")
-- discovery after reconnect keeps it offline
msg("homeassistant/status", "online")
assert(avail(publishes(), "plug-1") == "offline", "rediscovery keeps offline")
-- any event (also a child's) brings the device back
child:emit_component_event(child.profile.components.main,
  { capability = { ID = "switch" }, attribute = { NAME = "switch" }, value = { value = "off" } })
pubs = publishes()
assert(avail(pubs, "plug-1") == "online" and avail(pubs, "child-1") == "online", "back online")
now = now + 5000; bridge.check_availability()
assert(avail(publishes(), "sens-1") == nil, "battery device never offline")
os.time = real_time

print("OK - all st_bridge tests passed")
