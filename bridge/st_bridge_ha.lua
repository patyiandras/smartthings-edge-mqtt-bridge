-- st_bridge_ha: SmartThings capability <-> Home Assistant MQTT discovery mapping.
-- Entity kinds follow what HA's own SmartThings integration creates, so the
-- migrated entities can take over the old entity_ids.
local ha = {}

-- Custom capabilities of the sthm-bridge driver: SmartThings Home Monitor arm state
-- (read-only, set by SmartThings rules) and arm/disarm requests from HA (the driver
-- checks the disarm PIN). Alexa / Google do not know them.
ha.STHM_CAP = "advancelegend34283.sthmState"
ha.STHM_REQ = "advancelegend34283.sthmRequest"

-- HA uses the device name for an entity only if "name" is JSON null (omitted = "MQTT Light").
-- Lua tables cannot hold nil, so this sentinel is replaced with null after json.encode.
ha.NULL = "__ST_BRIDGE_NULL__"

function ha.encode(json, payload)
  return (json.encode(payload):gsub('"' .. ha.NULL .. '"', "null"))
end

-- capability -> attributes worth publishing on (re)connect
local STATE_ATTRS = {
  switch = { "switch" },
  switchLevel = { "level" },
  colorTemperature = { "colorTemperature" },
  colorControl = { "hue", "saturation" },
  motionSensor = { "motion" },
  contactSensor = { "contact" },
  presenceSensor = { "presence" },
  occupancySensor = { "occupancy" },
  waterSensor = { "water" },
  temperatureMeasurement = { "temperature" },
  relativeHumidityMeasurement = { "humidity" },
  illuminanceMeasurement = { "illuminance" },
  battery = { "battery" },
  powerMeter = { "power" },
  energyMeter = { "energy" },
  windowShade = { "windowShade" },
  windowShadeLevel = { "shadeLevel" },
  tamperAlert = { "tamper" },
  voltageMeasurement = { "voltage" },
  ultravioletIndex = { "ultravioletIndex" },
  signalStrength = { "lqi", "rssi" },
  [ha.STHM_CAP] = { "sthmState" },
  [ha.STHM_REQ] = { "request" },
}

function ha.state_attributes(cap_id)
  return STATE_ATTRS[cap_id] or {}
end

-- button presses are events, never retained (HA would replay them on restart)
function ha.retain_state(cap_id)
  return cap_id ~= "button"
end

-- extra topics computed from an attribute update (published next to it)
function ha.derived_states(device, comp_id, cap_id, attr, value)
  local out = {}
  if cap_id == "colorControl" and (attr == "hue" or attr == "saturation") then
    local h = attr == "hue" and value or device:get_latest_state(comp_id, cap_id, "hue")
    local s = attr == "saturation" and value or device:get_latest_state(comp_id, cap_id, "saturation")
    if h ~= nil and s ~= nil then
      out["hs"] = string.format("%.1f,%.1f", h * 3.6, s) -- ST hue is 0-100 %, HA wants degrees
    end
  elseif cap_id == "button" and attr == "button" then
    out["event"] = string.format('{"event_type":"%s"}', tostring(value))
  end
  return out
end

function ha.normalize_command(cap_id, cmd, args)
  if cap_id == "switchLevel" or cap_id == "colorTemperature" or cap_id == "windowShadeLevel" then
    args[1] = math.floor(tonumber(args[1]) or 0)
  elseif cap_id == ha.STHM_REQ and type(args[1]) == "table" then
    args = { args[1].value, args[1].code } -- {"value": ..., "code": ...} from the alarm panel
  end
  return cmd, args
end

local function has(comp, cap_id)
  for _, c in pairs(comp.capabilities) do
    if c.id == cap_id then return true end
  end
  return false
end

local function device_info(device, via)
  local info = {
    identifiers = { "stb_" .. device.id },
    name = device.label or device.id,
    via_device = via,
  }
  local ok, mf = pcall(function() return device:get_manufacturer() end)
  if ok and mf then info.manufacturer = mf end
  local ok2, model = pcall(function() return device:get_model() end)
  if ok2 and model then info.model = model end
  if not info.manufacturer and device.zwave_manufacturer_id then -- Z-Wave: numeric ids only
    info.manufacturer = string.format("Z-Wave %04X", device.zwave_manufacturer_id)
    info.model = string.format("%04X-%04X", device.zwave_product_type or 0, device.zwave_product_id or 0)
  end
  return info
end

local BINARY = {
  motionSensor = { "motion", "motion", "active" },
  contactSensor = { "contact", "door", "open" },
  presenceSensor = { "presence", "presence", "present" },
  occupancySensor = { "occupancy", "occupancy", "occupied" },
  waterSensor = { "water", "moisture", "wet" },
  tamperAlert = { "tamper", "tamper", "detected" },
}

-- capability -> list of { attribute, device_class, unit, state_class, entity_category }
local SENSORS = {
  temperatureMeasurement = { { "temperature", "temperature", "°C", "measurement" } },
  relativeHumidityMeasurement = { { "humidity", "humidity", "%", "measurement" } },
  illuminanceMeasurement = { { "illuminance", "illuminance", "lx", "measurement" } },
  battery = { { "battery", "battery", "%", "measurement", "diagnostic" } },
  powerMeter = { { "power", "power", "W", "measurement" } },
  energyMeter = { { "energy", "energy", "kWh", "total_increasing" } },
  voltageMeasurement = { { "voltage", "voltage", "V", "measurement", "diagnostic" } },
  ultravioletIndex = { { "ultravioletIndex", nil, "UV index", "measurement" } },
  signalStrength = {
    { "lqi", nil, nil, "measurement", "diagnostic" },
    { "rssi", "signal_strength", "dBm", "measurement", "diagnostic" },
  },
}

--- Build discovery configs for one device.
--- opts: state_prefix, cmd_prefix, availability_topic, device_availability_topic, via
function ha.discovery(device, opts)
  local out = {}
  local dev = device_info(device, opts.via)

  for comp_id, comp in pairs(device.profile.components) do
    local st = string.format("%s/%s/%s", opts.state_prefix, device.id, comp_id)
    local cm = string.format("%s/%s/%s", opts.cmd_prefix, device.id, comp_id)
    local suffix = comp_id == "main" and "" or (" " .. comp_id)

    local function add(domain, key, payload)
      local uid = string.format("stb_%s_%s_%s", device.id, comp_id, key)
      payload.unique_id = uid
      if opts.device_availability_topic then
        -- unavailable if the driver is down OR this device has gone silent (unplugged)
        payload.availability = { { topic = opts.availability_topic }, { topic = opts.device_availability_topic } }
        payload.availability_mode = "all"
      else
        payload.availability_topic = opts.availability_topic
      end
      payload.device = dev -- full block every time: HA handles discovery concurrently, an
                           -- identifiers-only entity arriving first creates a nameless device
      out[#out + 1] = { topic = string.format("homeassistant/%s/%s/config", domain, uid), payload = payload }
    end

    if has(comp, "switch") then
      local dimmable = has(comp, "switchLevel")
      local ct = has(comp, "colorTemperature")
      local color = has(comp, "colorControl")
      if dimmable or ct or color then
        local p = {
          name = suffix ~= "" and comp_id or ha.NULL,
          command_topic = cm .. "/switch/cmd", state_topic = st .. "/switch/switch",
          payload_on = "on", payload_off = "off",
        }
        if dimmable then
          p.brightness_command_topic = cm .. "/switchLevel/setLevel"
          p.brightness_state_topic = st .. "/switchLevel/level"
          p.brightness_scale = 100
          p.on_command_type = "brightness"
        end
        if ct then
          p.color_temp_kelvin = true
          p.color_temp_command_topic = cm .. "/colorTemperature/setColorTemperature"
          p.color_temp_state_topic = st .. "/colorTemperature/colorTemperature"
          p.min_kelvin = 2200
          p.max_kelvin = 6500
        end
        if color then
          p.hs_command_topic = cm .. "/colorControl/setColor"
          p.hs_command_template = '{"hue": {{ (hue / 3.6) | round(1) }}, "saturation": {{ sat | round(1) }} }'
          p.hs_state_topic = st .. "/colorControl/hs"
        end
        add("light", "light", p)
      else
        add("switch", "switch", {
          name = suffix ~= "" and comp_id or ha.NULL,
          command_topic = cm .. "/switch/cmd", state_topic = st .. "/switch/switch",
          payload_on = "on", payload_off = "off", state_on = "on", state_off = "off",
        })
      end
    end

    for cap_id, b in pairs(BINARY) do
      if has(comp, cap_id) then
        add("binary_sensor", b[1], {
          name = b[1] .. suffix, device_class = b[2],
          state_topic = st .. "/" .. cap_id .. "/" .. b[1],
          value_template = "{{ 'ON' if value == '" .. b[3] .. "' else 'OFF' }}",
        })
      end
    end

    for cap_id, list in pairs(SENSORS) do
      if has(comp, cap_id) then
        for _, s in ipairs(list) do
          add("sensor", s[1], {
            name = s[1] .. suffix, device_class = s[2], unit_of_measurement = s[3],
            state_class = s[4], entity_category = s[5],
            state_topic = st .. "/" .. cap_id .. "/" .. s[1],
          })
        end
      end
    end

    if has(comp, "windowShade") or has(comp, "windowShadeLevel") then
      local p = {
        name = suffix ~= "" and comp_id or ha.NULL, device_class = "shutter",
        command_topic = cm .. "/windowShade/cmd",
        payload_open = "open", payload_close = "close", payload_stop = "pause",
        state_topic = st .. "/windowShade/windowShade",
        value_template = "{{ 'open' if value == 'partially open' else value }}",
        state_open = "open", state_closed = "closed", state_opening = "opening", state_closing = "closing",
      }
      if has(comp, "windowShadeLevel") then
        p.position_topic = st .. "/windowShadeLevel/shadeLevel"
        p.set_position_topic = cm .. "/windowShadeLevel/setShadeLevel"
      end
      add("cover", "cover", p)
    end

    if has(comp, "windowShadePreset") then
      add("button", "preset", {
        name = "preset" .. suffix, command_topic = cm .. "/windowShadePreset/cmd", payload_press = "presetPosition",
      })
    end

    if has(comp, "button") then
      add("event", "button", {
        name = "button" .. suffix, device_class = "button",
        event_types = { "pushed", "held", "double", "pushed_2x", "pushed_3x", "down_hold", "up", "down" },
        state_topic = st .. "/button/event",
      })
    end

    if has(comp, ha.STHM_CAP) then
      add("sensor", "sthm", {
        name = "Home Monitor" .. suffix, device_class = "enum", icon = "mdi:shield-home",
        options = { "armedAway", "armedStay", "disarmed" },
        state_topic = st .. "/" .. ha.STHM_CAP .. "/sthmState",
      })
      if has(comp, ha.STHM_REQ) then
        -- HA shows the real STHM state; a request only changes it once the SmartThings
        -- routine has armed / disarmed. The disarm code is checked on the hub, not in HA.
        add("alarm_control_panel", "alarm", {
          name = "Home Monitor" .. suffix,
          state_topic = st .. "/" .. ha.STHM_CAP .. "/sthmState",
          value_template = "{{ {'armedAway': 'armed_away', 'armedStay': 'armed_home',"
            .. " 'disarmed': 'disarmed'}.get(value, 'unknown') }}",
          command_topic = cm .. "/" .. ha.STHM_REQ .. "/sendRequest",
          command_template = '{"value": "{{ action }}"{% if code %}, "code": "{{ code }}"{% endif %}}',
          payload_arm_away = "armAway", payload_arm_home = "armStay", payload_disarm = "disarm",
          code = "REMOTE_CODE", code_arm_required = false, code_disarm_required = true,
          supported_features = { "arm_home", "arm_away" },
        })
        add("sensor", "sthm_request", {
          name = "HA request" .. suffix, entity_category = "diagnostic", icon = "mdi:shield-key",
          state_topic = st .. "/" .. ha.STHM_REQ .. "/request",
        })
      end
    end

    if has(comp, "refresh") and comp_id == "main" then
      add("button", "refresh", {
        name = "refresh", entity_category = "diagnostic",
        command_topic = cm .. "/refresh/cmd", payload_press = "refresh",
      })
    end
  end
  return out
end

--- Diagnostic entities for the bridge itself (one HA device per bridged driver).
function ha.bridge_discovery(bridge_id, driver_name, diag_topic, status_topic)
  local dev = { identifiers = { bridge_id }, name = "ST Bridge " .. driver_name, manufacturer = "st_bridge" }
  local out = {}
  local function sensor(key, name, extra)
    local p = {
      name = name, unique_id = bridge_id .. "_" .. key, state_topic = diag_topic,
      value_template = "{{ value_json." .. key .. " }}", entity_category = "diagnostic",
      device = dev,
      availability_topic = status_topic,
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    out[#out + 1] = { topic = "homeassistant/sensor/" .. bridge_id .. "_" .. key .. "/config", payload = p }
  end
  sensor("memory_kb", "Memory", { unit_of_measurement = "kB", state_class = "measurement" })
  sensor("uptime_s", "Uptime", { unit_of_measurement = "s", device_class = "duration" })
  sensor("devices", "Devices", {
    json_attributes_topic = diag_topic, json_attributes_template = "{{ {'labels': value_json.labels} | tojson }}",
  })
  sensor("events", "Events", { state_class = "total_increasing" })
  sensor("commands", "Commands", { state_class = "total_increasing" })
  sensor("reconnects", "Reconnects", { state_class = "total_increasing" })
  sensor("last_error", "Last error")
  sensor("last_log", "Last log", {
    json_attributes_topic = diag_topic, json_attributes_template = "{{ {'lines': value_json.logs} | tojson }}",
  })
  out[#out + 1] = { topic = "homeassistant/binary_sensor/" .. bridge_id .. "_online/config", payload = {
    name = "Online", unique_id = bridge_id .. "_online", device_class = "connectivity",
    state_topic = status_topic, payload_on = "online", payload_off = "offline",
    entity_category = "diagnostic", device = dev,
  } }
  return out
end

return ha
