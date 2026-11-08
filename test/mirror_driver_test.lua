-- Offline test of the ha-motion-mirror driver (stubbed SmartThings libs and st_bridge).
-- node st-edge/test/run.js test/mirror_driver_test.lua
local devices, created, template = {}, {}, nil
local sub = {}
package.loaded["log"] = { info = function() end, warn = function() end }
package.loaded["st.capabilities"] = {
  motionSensor = { ID = "motionSensor", motion = {
    NAME = "motion",
    active = function() return { value = "active" } end,
    inactive = function() return { value = "inactive" } end,
  } },
}
package.loaded["st_bridge"] = { subscribe = function(filter, fn) sub.filter, sub.fn = filter, fn end }
package.loaded["st.driver"] = function(_, t)
  template = t
  return {
    run = function() end,
    get_devices = function() return devices end,
    try_create_device = function(_, info) created[#created + 1] = info end,
  }
end
dofile("drivers/ha-motion-mirror/src/init.lua")
local bridge = package.loaded["st_bridge"]

assert(sub.filter == "stmirror/+/+", "subscription filter")
assert(bridge.skip_discovery and bridge.skip_discovery({}) == true, "no HA discovery for mirrored devices")

local function new_device(dni)
  local d = { device_network_id = dni, events = {}, state = nil,
    thread = { queue_event = function(_, fn) fn() end } }
  function d:online() self.is_online = true end
  function d:emit_event(e) self.events[#self.events + 1] = e.value; self.state = e.value end
  function d:get_latest_state() return self.state end
  return d
end

-- motion before the device exists is kept, label creates the device once
sub.fn("stmirror/kitchen/motion", "active")
sub.fn("stmirror/kitchen/label", "Kitchen motion HA")
sub.fn("stmirror/kitchen/label", "Kitchen motion HA")
assert(#created == 1, "device created once while in flight")
assert(created[1].device_network_id == "ha-mirror-kitchen" and created[1].profile == "mirror-motion")
assert(created[1].label == "Kitchen motion HA")

local k = new_device("ha-mirror-kitchen")
devices[#devices + 1] = k
template.lifecycle_handlers.added(nil, k)
assert(k.is_online and k.state == "active", "pending motion applied on added")
template.lifecycle_handlers.init(nil, k)
assert(#k.events == 1, "pending value applied only once")

sub.fn("stmirror/kitchen/motion", "inactive")
assert(k.state == "inactive")
sub.fn("stmirror/kitchen/motion", "on")
assert(k.state == "active", "on/off accepted too")
sub.fn("stmirror/kitchen/motion", "garbage")
assert(k.state == "active", "bad payload ignored")
sub.fn("stmirror/kitchen/label", "Kitchen motion HA")
assert(#created == 1, "existing device not recreated")

-- a fresh device without any known state starts inactive
local l = new_device("ha-mirror-living_room")
devices[#devices + 1] = l
template.lifecycle_handlers.init(nil, l)
assert(l.state == "inactive")

-- unrelated topics / devices are ignored
sub.fn("stmirror/kitchen/motion/x", "active")
sub.fn("stmirror/nobody/motion", "active")
local other = new_device("sthm-state-1")
template.lifecycle_handlers.init(nil, other)
assert(#other.events == 0 and not other.is_online, "foreign device untouched")
print("OK - mirror driver tests passed")
