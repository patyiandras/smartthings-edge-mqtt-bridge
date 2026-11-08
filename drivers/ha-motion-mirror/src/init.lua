-- HA Motion Mirror: Home Assistant motion sensors as local SmartThings motion sensors.
--
-- Home Assistant gets some motion sensors directly (e.g. the Konnected panel over
-- ESPHome), but the SmartThings app and STHM should still see them. HA publishes them
-- over MQTT (retained) and this driver keeps one LAN device per sensor in sync:
--     stmirror/<key>/label   device label; the device is created on first sight
--     stmirror/<key>/motion  "active" / "inactive"
-- The devices only have the standard motionSensor capability, so they cannot be
-- switched from anywhere (app, Alexa, Google); only HA changes them.
--
-- The MQTT connection comes from st_bridge (attached by build.py). Its HA discovery is
-- turned off for these devices: HA is the source, a mirrored copy there would be a duplicate.
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local bridge = require "st_bridge"

local motion = capabilities.motionSensor
local PREFIX = "stmirror/"
local DNI_PREFIX = "ha-mirror-"

local pending = {}  -- key -> motion value received before its device exists
local creating = {} -- key -> true while try_create_device is in flight

local function key_of(device)
  local dni = device.device_network_id or ""
  return dni:sub(1, #DNI_PREFIX) == DNI_PREFIX and dni:sub(#DNI_PREFIX + 1) or nil
end

local function find(driver, key)
  for _, d in ipairs(driver:get_devices()) do
    if key_of(d) == key then return d end
  end
end

local function apply(device, value)
  device.thread:queue_event(function()
    device:emit_event(value == "active" and motion.motion.active() or motion.motion.inactive())
  end)
end

local function ensure_device(driver, key, label)
  if find(driver, key) or creating[key] then return end
  creating[key] = true
  log.info("[mirror] creating device " .. key .. " (" .. label .. ")")
  driver:try_create_device({
    type = "LAN",
    device_network_id = DNI_PREFIX .. key,
    label = label,
    profile = "mirror-motion",
    manufacturer = "st_bridge",
    model = "ha-motion-mirror",
    vendor_provided_label = label,
  })
end

local function normalize(payload)
  local p = tostring(payload or ""):lower()
  if p == "active" or p == "on" then return "active" end
  if p == "inactive" or p == "off" then return "inactive" end
end

local driver

local function on_message(topic, payload)
  local key, kind = topic:match("^" .. PREFIX .. "([%w_%-]+)/(%w+)$")
  if not key then return end
  if kind == "label" then
    if payload ~= "" then ensure_device(driver, key, payload) end
  elseif kind == "motion" then
    local value = normalize(payload)
    if not value then return log.warn("[mirror] bad motion payload for " .. key .. ": " .. tostring(payload)) end
    local device = find(driver, key)
    if device then apply(device, value) else pending[key] = value end
  end
end

local function device_ready(_, device)
  local key = key_of(device)
  if not key then return end
  creating[key] = nil
  device:online()
  local value = pending[key]
  pending[key] = nil
  if value then
    apply(device, value)
  elseif device:get_latest_state("main", motion.ID, motion.motion.NAME) == nil then
    apply(device, "inactive")
  end
end

driver = Driver("ha-motion-mirror", {
  -- Devices are created from the retained label topics; "scan nearby" has nothing to add.
  discovery = function() end,
  lifecycle_handlers = {
    added = device_ready,
    init = device_ready,
  },
})

bridge.skip_discovery = function() return true end
bridge.subscribe(PREFIX .. "+/+", on_message)

driver:run()
