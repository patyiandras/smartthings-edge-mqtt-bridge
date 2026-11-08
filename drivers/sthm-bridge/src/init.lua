-- STHM: one virtual LAN device mirroring the SmartThings Home Monitor arm state.
--
-- Edge drivers cannot read STHM themselves, so SmartThings rules (Rules API,
-- condition: location attribute "Security") call setSthmState on this device;
-- st_bridge (attached by build.py) publishes the resulting event to MQTT.
-- The capabilities are custom on purpose: Alexa / Google cannot see or switch them.
--
-- Arm / disarm from HA: HA sends sendRequest(value, code) over MQTT; the driver
-- checks it and sets the "request" attribute for a few seconds. SmartThings app
-- routines ("if STHM request is ...") do the actual arming, because neither Edge
-- drivers nor the Rules API can change the STHM mode.
-- Disarm needs the PIN stored in the device settings (SmartThings app), so it lives
-- only on the hub: HA does not know it, and a bare MQTT publish cannot disarm.
-- 3 wrong PINs lock disarming for 5 minutes.
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"

local sthm = capabilities["advancelegend34283.sthmState"]
local req = capabilities["advancelegend34283.sthmRequest"]
local DNI = "sthm-state-1"
local REQUEST_HOLD_S = 5   -- routines trigger on the change to the requested value
local MAX_FAILS = 3
local LOCKOUT_S = 300

-- A driver with no devices is not started by the hub, so the device is normally created
-- with the virtual devices API (executionTarget LOCAL, this driver). This is the fallback
-- for an app-side "scan nearby"; one device is enough, whatever created it.
local function create_device(driver)
  if #driver:get_devices() > 0 then return end
  log.info("[sthm] creating device")
  driver:try_create_device({
    type = "LAN",
    device_network_id = DNI,
    label = "STHM",
    profile = "sthm-state",
    manufacturer = "st_bridge",
    model = "sthm-state",
    vendor_provided_label = "STHM",
  })
end

local function set_state(_, device, command)
  device:emit_event(sthm.sthmState(command.args.value))
end

local function emit_request(device, value)
  device:emit_event(req.request(value))
  device.thread:call_with_delay(REQUEST_HOLD_S, function()
    device:emit_event(req.request("none"))
  end)
end

local function reject(device, reason)
  log.warn("[sthm] request rejected: " .. reason)
  emit_request(device, "rejected")
end

local function send_request(_, device, command)
  local args = command.args or {}
  local value = args.value or args[1]
  local code = args.code or args[2]
  if value == "disarm" then
    local pin = device.preferences and device.preferences.disarmPin
    if pin == nil or pin == "" then
      return reject(device, "no disarm PIN set in the device settings")
    end
    local now = os.time()
    if (device:get_field("locked_until") or 0) > now then
      return reject(device, "disarm locked after wrong PINs")
    end
    if tostring(code or "") ~= tostring(pin) then
      local fails = (device:get_field("pin_fails") or 0) + 1
      device:set_field("pin_fails", fails)
      if fails >= MAX_FAILS then
        device:set_field("pin_fails", 0)
        device:set_field("locked_until", now + LOCKOUT_S)
        return reject(device, "wrong PIN, disarm locked for " .. LOCKOUT_S .. " s")
      end
      return reject(device, "wrong PIN (" .. fails .. "/" .. MAX_FAILS .. ")")
    end
    device:set_field("pin_fails", 0)
  elseif value ~= "armAway" and value ~= "armStay" then
    return reject(device, "unknown request " .. tostring(value))
  end
  log.info("[sthm] request " .. value)
  emit_request(device, value)
end

local driver = Driver("sthm", {
  discovery = function(drv) create_device(drv) end,
  lifecycle_handlers = {
    init = function(_, device)
      device:online()
      device:emit_event(req.request("none"))
    end,
  },
  capability_handlers = {
    [sthm.ID] = { [sthm.commands.setSthmState.NAME] = set_state },
    [req.ID] = { [req.commands.sendRequest.NAME] = send_request },
  },
})

driver:run()
