-- st_bridge: local MQTT bridge between a SmartThings Edge driver and Home Assistant.
--
-- Attached to an (otherwise unmodified) Edge driver with one line before driver:run():
--     require("st_bridge").attach(driver)
--
-- * Every capability event the driver emits is also published to MQTT
--   (stb/<device_id>/<component>/<capability>/<attribute>, retained).
-- * Commands from HA arrive on stbc/<device_id>/<component>/<capability>/<command>
--   and are injected into the driver's own capability dispatcher, so they behave
--   exactly like commands from the SmartThings app.
-- * HA MQTT discovery configs are generated from the device profile (st_bridge_ha).
-- * Native (hub-side) handlers are disabled, otherwise the hub would emit events
--   without going through Lua and the bridge would never see them.
local log = require "log"
local json = require "st.json"
local cosock = require "cosock"
local Mqtt = require "st_bridge_mqtt"
local ha = require "st_bridge_ha"
local cfg = require "st_bridge_config"

local bridge = {
  devices = {},   -- device_id -> device object
  topics = {},    -- device_id -> list of retained discovery topics
  started = os.time(),
  events = 0,
  commands = 0,
  last_error = "",
  logs = {},      -- last warn/error lines of the whole driver (hub logcat is LAN-only)
  hooks = {},     -- driver-specific patches: fn(device, comp_id, cap_id, attr, value, prev)
  extra = {},     -- own drivers' extra subscriptions: { filter, prefix, fn(topic, payload) }
  last_seen = {}, -- device_id -> os.time() of its last emitted event (availability)
  probed = {},    -- device_id -> os.time() of the last refresh sent to a silent device
  offline = {},   -- device_id -> true while reported unavailable to HA
  skip_discovery = nil, -- own drivers: fn(device) -> true = no HA entities for this device
}

--- Register a callback for every emitted capability event (used by st-edge/patches).
function bridge.on_event(fn)
  bridge.hooks[#bridge.hooks + 1] = fn
end

--- Extra MQTT subscription for an own driver (e.g. "stmirror/+/motion"). The filter may
--- only use "+" / "#" after its last fixed "/" segment; messages are routed by that prefix.
function bridge.subscribe(filter, fn)
  local prefix = filter:match("^([^+#]*)")
  bridge.extra[#bridge.extra + 1] = { filter = filter, prefix = prefix, fn = fn }
end

local STATE = "stb"
local CMD = "stbc"

-- Per-device availability. The hub knows when a Zigbee / Z-Wave device is offline, but
-- the Lua driver is not told, so the bridge tracks it itself: mains-powered devices
-- switches (plugs, relays, lamps) that stay silent get a refresh, and if they still do not
-- answer they are reported unavailable to HA (e.g. an unplugged plug). Battery devices
-- sleep for hours, covers / sensors may not answer a refresh and LAN / virtual devices may
-- legitimately stay silent, so they are always "online"; Edge children follow their parent.
local AVAIL_CHECK_S = 120
local AVAIL_PROBE_S = 600
local AVAIL_OFFLINE_S = 1200

local function set_error(msg)
  bridge.last_error = ((os.date and os.date("!%H:%M:%S ")) or "") .. tostring(msg)
  log.warn("[st_bridge] " .. tostring(msg))
end

local publish_bridge_diag -- forward declaration (push_log publishes immediately)
local last_log_publish = 0

local last_log_msg
local function push_log(level, msg)
  -- log.warn -> log.warn_with: a hub sajat log modulja egymasba hiv, ugyanaz az uzenet ketszer jonne
  if msg == last_log_msg then return end
  -- zajszures: a lib minden profilban nem szereplo capability-esemenyt naplozza (pl. Aeotec Notification)
  if msg:find("but it does not support capability", 1, true) then return end
  last_log_msg = msg
  local line = ((os.date and os.date("!%H:%M:%S ")) or "") .. level .. " " .. msg
  bridge.logs[#bridge.logs + 1] = line:sub(1, 400)
  if #bridge.logs > 10 then table.remove(bridge.logs, 1) end
  if os.time() - last_log_publish >= 2 and publish_bridge_diag then
    last_log_publish = os.time()
    pcall(publish_bridge_diag)
  end
end

-- Mirror the driver's warn/error logs (including errors the dispatcher catches inside
-- capability/zigbee handlers) into the diag topic.
local function hook_logs()
  for _, name in ipairs({ "error", "warn", "error_with", "warn_with" }) do
    local orig = log[name]
    if type(orig) == "function" then
      pcall(function()
        log[name] = function(...)
          local args = table.pack(...)
          local parts = {}
          for i = (name:find("_with") and 2 or 1), args.n do parts[#parts + 1] = tostring(args[i]) end
          pcall(push_log, name:gsub("_with", ""):upper(), table.concat(parts, " "))
          return orig(...)
        end
      end)
    end
  end
end

local function encode_value(v)
  if type(v) == "table" then return json.encode(v) end
  if v == nil then return "" end
  return tostring(v)
end

function bridge.publish_state(device, comp_id, cap_id, attr, value)
  local m = bridge.mqtt
  if not m or not m.connected then return end
  local base = string.format("%s/%s/%s/%s", STATE, device.id, comp_id, cap_id)
  local retain = ha.retain_state(cap_id)
  m:publish(base .. "/" .. attr, encode_value(value), retain)
  for topic, payload in pairs(ha.derived_states(device, comp_id, cap_id, attr, value)) do
    m:publish(base .. "/" .. topic, payload, retain)
  end
end

local function avail_topic(device_id)
  return string.format("%s/%s/availability", STATE, device_id)
end

-- Only Edge children follow their parent: hub-connected Zigbee / Z-Wave devices have the
-- hub itself as parent_device_id.
local function root_id(device)
  if device.network_type == "DEVICE_EDGE_CHILD" and device.parent_device_id then return device.parent_device_id end
  return device.id
end

local function tracked(device)
  if device.network_type ~= "DEVICE_ZIGBEE" and device.network_type ~= "DEVICE_ZWAVE" then return false end
  local switch = false
  for _, comp in pairs(device.profile.components) do
    for _, cap in pairs(comp.capabilities) do
      if cap.id == "battery" then return false end
      if cap.id == "switch" then switch = true end
    end
  end
  -- only switches / plugs / lamps: they always answer an OnOff / SwitchBinary read. Covers and
  -- sensors may not (e.g. Tuya blinds neither report periodically nor answer a refresh).
  return switch
end

local function publish_availability(device)
  local m = bridge.mqtt
  if not m or not m.connected then return end
  m:publish(avail_topic(device.id), bridge.offline[root_id(device)] and "offline" or "online", true)
end

-- availability change of a root device: publish it for the device and its children
local function set_offline(root, offline)
  if (bridge.offline[root] or false) == offline then return end
  bridge.offline[root] = offline or nil
  for _, d in pairs(bridge.devices) do
    if root_id(d) == root then pcall(publish_availability, d) end
  end
  local dev = bridge.devices[root]
  log.warn("[st_bridge] " .. tostring(dev and dev.label or root) .. (offline and " offline" or " back online"))
end

local function seen(device)
  local now = os.time()
  bridge.last_seen[device.id] = now
  local root = root_id(device)
  bridge.last_seen[root] = now
  if bridge.offline[root] then set_offline(root, false) end
end

-- for the diag topic: how many devices are tracked / offline, and the most silent ones
function bridge.avail_summary()
  local now, tracked_n, off, silent = os.time(), 0, {}, {}
  for id, d in pairs(bridge.devices) do
    if tracked(d) then
      tracked_n = tracked_n + 1
      if bridge.offline[id] then off[#off + 1] = tostring(d.label) end
      silent[#silent + 1] = { s = now - (bridge.last_seen[id] or now), l = tostring(d.label) }
    end
  end
  table.sort(silent, function(a, b) return a.s > b.s end)
  local top = {}
  for i = 1, math.min(3, #silent) do top[i] = silent[i].l .. ":" .. silent[i].s end
  table.sort(off)
  return { tracked = tracked_n, offline = off, silent = top, checks = bridge.avail_checks or 0 }
end

function bridge.check_availability()
  bridge.avail_checks = (bridge.avail_checks or 0) + 1
  local now = os.time()
  for id, device in pairs(bridge.devices) do
    if tracked(device) then
      local silent = now - (bridge.last_seen[id] or now)
      if silent >= AVAIL_OFFLINE_S then
        set_offline(id, true)
      elseif silent >= AVAIL_PROBE_S and now - (bridge.probed[id] or 0) >= AVAIL_PROBE_S then
        bridge.probed[id] = now
        device.thread:queue_event(function()
          pcall(bridge.driver.handle_capability_command, bridge.driver, device,
            { component = "main", capability = "refresh", command = "refresh", args = {} }, true)
        end)
      end
    end
  end
end

local function publish_current_state(device)
  for comp_id, comp in pairs(device.profile.components) do
    for _, cap in pairs(comp.capabilities) do
      for _, attr in ipairs(ha.state_attributes(cap.id)) do
        local ok, v = pcall(device.get_latest_state, device, comp_id, cap.id, attr)
        if ok and v ~= nil then bridge.publish_state(device, comp_id, cap.id, attr, v) end
      end
    end
  end
end

local function publish_discovery(device)
  local m = bridge.mqtt
  if not m or not m.connected then return end
  if bridge.skip_discovery and bridge.skip_discovery(device) then return end
  local configs = ha.discovery(device, {
    state_prefix = STATE, cmd_prefix = CMD,
    availability_topic = bridge.status_topic,
    device_availability_topic = avail_topic(device.id),
    via = bridge.bridge_id,
  })
  local topics = {}
  for _, c in ipairs(configs) do
    m:publish(c.topic, ha.encode(json, c.payload), true)
    topics[#topics + 1] = c.topic
  end
  bridge.topics[device.id] = topics
  publish_availability(device)
  publish_current_state(device)
end

local function remove_discovery(device_id)
  local m = bridge.mqtt
  for _, t in ipairs(bridge.topics[device_id] or {}) do
    if m and m.connected then m:publish(t, "", true) end
  end
  bridge.topics[device_id] = nil
end

publish_bridge_diag = function()
  local m = bridge.mqtt
  if not m or not m.connected then return end
  local count, labels = 0, {}
  for id, d in pairs(bridge.devices) do
    count = count + 1
    labels[#labels + 1] = tostring(d.label or id)
  end
  table.sort(labels)
  m:publish(bridge.diag_topic, json.encode({
    labels = labels,
    uptime_s = os.time() - bridge.started,
    memory_kb = math.floor(collectgarbage("count")),
    devices = count,
    events = bridge.events,
    commands = bridge.commands,
    reconnects = m.reconnects,
    last_error = bridge.last_error ~= "" and bridge.last_error or m.last_error,
    last_log = (bridge.logs[#bridge.logs] or ""):sub(1, 250),
    logs = bridge.logs,
    avail = bridge.avail_summary and bridge.avail_summary() or nil,
  }), true)
end

local function publish_bridge_discovery()
  local m = bridge.mqtt
  for _, c in ipairs(ha.bridge_discovery(bridge.bridge_id, bridge.key, bridge.diag_topic, bridge.status_topic)) do
    m:publish(c.topic, ha.encode(json, c.payload), true)
  end
end

local function on_connect(m)
  m:publish(bridge.status_topic, "online", true)
  local topics = { CMD .. "/#", "homeassistant/status" }
  for _, e in ipairs(bridge.extra) do topics[#topics + 1] = e.filter end
  m:subscribe(topics)
  publish_bridge_discovery()
  for _, device in pairs(bridge.devices) do publish_discovery(device) end
  publish_bridge_diag()
end

local function parse_args(cap_id, command, payload)
  if command == "cmd" then return payload, {} end
  local ok, v = pcall(json.decode, payload)
  if not ok or v == nil then return command, { payload } end
  if type(v) == "table" and #v > 0 then return command, v end
  return command, { v }
end

local function on_message(topic, payload)
  if topic == "homeassistant/status" then
    if payload == "online" then
      publish_bridge_discovery()
      for _, device in pairs(bridge.devices) do publish_discovery(device) end
    end
    return
  end
  for _, e in ipairs(bridge.extra) do
    if topic:sub(1, #e.prefix) == e.prefix then
      local ok, err = pcall(e.fn, topic, payload)
      if not ok then set_error("extra " .. topic .. ": " .. tostring(err)) end
      return
    end
  end
  local dev_id, comp_id, cap_id, command = topic:match("^" .. CMD .. "/([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
  if not dev_id then return end
  if cap_id == ha.STHM_CAP then return end -- mirrors STHM, set only by the SmartThings rules
  local device = bridge.devices[dev_id]
  if not device then return end -- belongs to another bridged driver
  local cmd_name, args = parse_args(cap_id, command, payload)
  cmd_name, args = ha.normalize_command(cap_id, cmd_name, args)
  local cap_command = { component = comp_id, capability = cap_id, command = cmd_name, args = args }
  bridge.commands = bridge.commands + 1
  local function dispatch(c)
    device.thread:queue_event(function()
      local ok, err = pcall(bridge.driver.handle_capability_command, bridge.driver, device, c, true)
      if not ok then set_error("command " .. c.capability .. "." .. tostring(c.command) .. ": " .. tostring(err)) end
    end)
  end
  -- Zigbee lamps ignore color commands while off (HA sends the color before "on"):
  -- switch on first and send the color once the lamp is up.
  if (cap_id == "colorControl" or cap_id == "colorTemperature")
      and device:get_latest_state(comp_id, "switch", "switch") == "off" then
    dispatch({ component = comp_id, capability = "switch", command = "on", args = {} })
    device.thread:call_with_delay(1.5, function() dispatch(cap_command) end)
    return
  end
  dispatch(cap_command)
end

-- Broker settings. A private build bakes them into st_bridge_config.lua (build.py with
-- .st-bridge.json); a public build ships an empty config, and the user enters the broker in
-- the SmartThings app under the settings of ANY device of the driver (stbMqttHost, ...).
-- One device is enough per driver: the first device (by id) with a host set wins.
local function broker_from_prefs()
  local ids = {}
  for id in pairs(bridge.devices) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local p = bridge.devices[id].preferences or {}
    local host = p.stbMqttHost
    if type(host) == "string" and host:match("%S") then
      -- leading / trailing whitespace is a copy-paste or phone-keyboard accident, never intended
      local function clean(s)
        if type(s) ~= "string" then return nil end
        s = s:match("^%s*(.-)%s*$")
        return s ~= "" and s or nil
      end
      return {
        host = clean(host),
        port = tonumber(p.stbMqttPort) or 1883,
        username = clean(p.stbMqttUser),
        password = clean(p.stbMqttPass),
      }
    end
  end
end

function bridge.broker()
  if type(cfg.host) == "string" and cfg.host ~= "" then
    return { host = cfg.host, port = cfg.port or 1883, username = cfg.username, password = cfg.password }
  end
  return broker_from_prefs()
end

--- Re-read the broker settings; on a change the MQTT session reconnects with the new ones.
function bridge.apply_broker()
  local m = bridge.mqtt
  if not m then return end
  local b = bridge.broker() or {}
  local o = m.opts
  if o.host == b.host and o.port == (b.port or 1883) and o.username == b.username and o.password == b.password then
    return
  end
  o.host, o.port, o.username, o.password = b.host, b.port or 1883, b.username, b.password
  log.info("[st_bridge] broker set to " .. tostring(b.host) .. ":" .. tostring(o.port))
  m:_drop()
end

local function hook_device(device)
  bridge.devices[device.id] = device
  bridge.last_seen[device.id] = bridge.last_seen[device.id] or os.time() -- grace period after (re)start
  if device:get_field("st_bridge_hooked") then return end
  device:set_field("st_bridge_hooked", true)

  local orig_emit = device.emit_component_event
  device:extend_device("emit_component_event", function(self, component, capability_event)
    local cap_id, attr = capability_event.capability.ID, capability_event.attribute.NAME
    local prev
    if #bridge.hooks > 0 then
      local okp, v = pcall(self.get_latest_state, self, component.id, cap_id, attr)
      if okp then prev = v end
    end
    local event, err = orig_emit(self, component, capability_event)
    if not event then return event, err end -- invalid / unsupported: nothing reached SmartThings either
    local value = capability_event.value and capability_event.value.value
    local ok, perr = pcall(function()
      bridge.events = bridge.events + 1
      seen(self)
      bridge.publish_state(self, component.id, cap_id, attr, value)
    end)
    if not ok then set_error("publish: " .. tostring(perr)) end
    for _, hook in ipairs(bridge.hooks) do
      local hok, herr = pcall(hook, self, component.id, cap_id, attr, value, prev)
      if not hok then set_error("hook: " .. tostring(herr)) end
    end
    return event, err
  end)

  local function no_native() return nil, "native handlers disabled by st_bridge" end
  device:extend_device("register_native_capability_attr_handler", no_native)
  device:extend_device("register_native_capability_cmd_handler", no_native)

  publish_discovery(device)
end

function bridge.attach(driver)
  bridge.driver = driver
  bridge.driver_name = driver.NAME or "driver"
  local key = (cfg.bridge_key or bridge.driver_name):gsub("[^%w_-]", "_")
  bridge.key = key -- egyedi (packageKey); driver.NAME tobb drivernel is azonos lehet
  bridge.bridge_id = "stb_bridge_" .. key
  bridge.status_topic = STATE .. "/_bridge/" .. key .. "/status"
  bridge.diag_topic = STATE .. "/_bridge/" .. key .. "/diag"

  hook_logs()

  local dispatcher = driver.lifecycle_dispatcher
  local orig_dispatch = dispatcher.dispatch
  dispatcher.dispatch = function(self, drv, device, event, ...)
    if event == "init" or event == "added" then
      local ok, err = pcall(hook_device, device)
      if not ok then set_error("hook: " .. tostring(err)) end
    end
    local ret = table.pack(orig_dispatch(self, drv, device, event, ...))
    if event == "infoChanged" then
      pcall(publish_discovery, device) -- label / profile may have changed
    elseif event == "removed" then
      pcall(remove_discovery, device.id)
      bridge.devices[device.id] = nil
      bridge.last_seen[device.id], bridge.probed[device.id], bridge.offline[device.id] = nil, nil, nil
    end
    if event == "init" or event == "added" or event == "infoChanged" or event == "removed" then
      pcall(bridge.apply_broker) -- broker settings may live in device preferences
    end
    return table.unpack(ret, 1, ret.n)
  end

  local b = bridge.broker() or {} -- empty in a public build until a device reports its settings
  bridge.mqtt = Mqtt.new({
    host = b.host, port = b.port or 1883,
    client_id = "st_bridge_" .. key,
    username = b.username, password = b.password,
    keepalive = 60,
    will_topic = bridge.status_topic, will_payload = "offline",
    on_connect = on_connect, on_message = on_message,
  })
  bridge.mqtt:start()
  driver:call_on_schedule(60, function() pcall(publish_bridge_diag) end, "st_bridge diag")
  driver:call_on_schedule(AVAIL_CHECK_S, function()
    local ok, err = pcall(bridge.check_availability)
    if not ok then set_error("availability: " .. tostring(err)) end
  end, "st_bridge availability")
  log.info("[st_bridge] attached to " .. bridge.driver_name .. ", broker " .. tostring(b.host or "(from device settings)"))
end

return bridge
