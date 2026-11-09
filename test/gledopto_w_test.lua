-- Offline test of the GLEDOPTO W-channel patch (patches/zigbee-light-multifunction-v6/gledopto_w.lua).
-- node st-edge/test/run.js test/gledopto_w_test.lua
local warns = {}
package.loaded["log"] = { info = function() end, warn = function(m) warns[#warns + 1] = m end }

package.loaded["st.capabilities"] = {
  switch = { ID = "switch", switch = { NAME = "switch",
                                       on = function() return { cap = "switch", value = "on" } end,
                                       off = function() return { cap = "switch", value = "off" } end } },
  switchLevel = { ID = "switchLevel", level = setmetatable({ NAME = "level" },
    { __call = function(_, v) return { cap = "switchLevel", value = v } end }) },
  refresh = { ID = "refresh" },
  colorTemperature = { ID = "colorTemperature",
    colorTemperature = function(v) return { cap = "colorTemperature", value = v } end },
  colorControl = { ID = "colorControl",
    hue = function(v) return { cap = "hue", value = v } end,
    saturation = function(v) return { cap = "saturation", value = v } end },
}
local function msg(kind) return function(_, ...) return { kind = kind, args = { ... },
  to_endpoint = function(self, ep) self.ep = ep; return self end } end end
local function attr(id, name) return { ID = id, read = function(_, d) return msg(name .. ":read")(nil) end,
  configure_reporting = function(_, d, ...) return msg(name .. ":report")(nil, ...) end } end
package.loaded["st.zigbee.zcl.clusters"] = {
  OnOff = { ID = 6, attributes = { OnOff = attr(0, "OnOff") },
            server = { commands = { On = msg("On"), Off = msg("Off") } } },
  Level = { ID = 8, attributes = { CurrentLevel = attr(0, "Level") },
            server = { commands = { MoveToLevelWithOnOff = msg("MoveToLevelWithOnOff") } } },
  ColorControl = { ID = 0x300, server = { commands = { MoveToHueAndSaturation = msg("MoveToHueAndSaturation"),
                                                        MoveToColorTemperature = msg("MoveToColorTemperature") } } },
}
package.loaded["st.zigbee.device_management"] = {
  build_bind_request = function(_, cluster, _, ep) return { kind = "bind", cluster = cluster, ep = ep } end,
}
local M = dofile("patches/zigbee-light-multifunction-v6/gledopto_w.lua")

local calls = {}
local function orig(name) return function() calls[#calls + 1] = name end end
local template = {
  capability_handlers = { switch = { on = orig("on"), off = orig("off") },
                          switchLevel = { setLevel = orig("setLevel") }, refresh = { refresh = orig("refresh") },
                          colorTemperature = { setColorTemperature = orig("setColorTemperature") },
                          colorControl = { setColor = orig("setColor") } },
  zigbee_handlers = { attr = { [6] = { [0] = orig("onoff_attr") }, [8] = { [0] = orig("level_attr") } } },
  lifecycle_handlers = { init = orig("init"), infoChanged = orig("infoChanged"), doConfigure = orig("doConfigure") },
}
M.wrap(template)
local deleted = {}
local driver = { environment_info = { hub_zigbee_eui = "HUB" },
  try_delete_device = function(_, id) deleted[#deleted + 1] = id end }

local function new_device(eps)
  local d = { label = "Cupboard light", id = "p1", network_type = "DEVICE_ZIGBEE", sent = {}, fields = {},
              zigbee_endpoints = {}, children = {}, profile = { components = { main = { id = "main" } } },
              preferences = {}, state = {} }
  for id, cl in pairs(eps) do d.zigbee_endpoints[id] = { id = id, server_clusters = cl } end
  function d:get_manufacturer() return "GLEDOPTO" end
  function d:get_model() return "GL-C-007" end
  function d:get_endpoint(c)
    local ids = {}
    for id in pairs(self.zigbee_endpoints) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      for _, x in ipairs(self.zigbee_endpoints[id].server_clusters) do if x == c then return id end end
    end
  end
  function d:supports_server_cluster(c, ep)
    for _, x in ipairs(self.zigbee_endpoints[ep].server_clusters) do if x == c then return true end end
    return false
  end
  function d:send(m) self.sent[#self.sent + 1] = m end
  function d:refresh() self.sent[#self.sent + 1] = { kind = "full-refresh" } end
  function d:extend_device(name, fn) self[name] = fn end
  function d:get_child_by_parent_assigned_key(k) return self.children[k] end
  function d:get_field(k) return self.fields[k] end
  function d:set_field(k, v) self.fields[k] = v end
  function d:try_update_metadata(m) self.new_profile = m.profile end
  function d:set_endpoint_to_component_fn(fn) self.ep_to_comp = fn end
  function d:emit_component_event(comp, e)
    self.state[comp.id] = self.state[comp.id] or {}
    self.state[comp.id][e.cap] = e.value
  end
  function d:get_latest_state(comp, cap) return (self.state[comp] or {})[cap] end
  function d:emit_event(e) self:emit_component_event(self.profile.components.main, e) end
  d.delayed = {}
  d.scheduled, d.cancelled = {}, {}
  d.thread = {
    call_with_delay = function(_, s, fn) d.delayed[#d.delayed + 1] = { s = s, fn = fn } end,
    call_on_schedule = function(_, s, fn) local t = { s = s, fn = fn }; d.scheduled[#d.scheduled + 1] = t; return t end,
    cancel_timer = function(_, t) d.cancelled[#d.cancelled + 1] = t end,
  }
  return d
end
local function last(t) return t[#t] end
local function rx(ep) return { address_header = { src_endpoint = { value = ep } } } end
local function w(d) return d.state.white or {} end
local lc, caps, attrs = template.lifecycle_handlers, template.capability_handlers, template.zigbee_handlers.attr

-- 2 ID in the hub's list: profile switch + configure, old child deleted
local p = new_device({ [11] = { 6, 8, 0x300 }, [15] = { 6, 8 } })
p.children.W0F = { id = "child-1" }
assert(M.white_endpoint(p) == 15)
lc.init(driver, p)
assert(calls[#calls] == "init", "original init runs")
assert(p.new_profile == "rgbw-w-level-colortemp-2000-6500", "switched to W profile")
assert(deleted[1] == "child-1", "old W child deleted")
local kinds = {}
for _, m in ipairs(p.sent) do kinds[#kinds + 1] = m.kind .. "@" .. tostring(m.ep) end
assert(table.concat(kinds, " "):find("bind@15") and table.concat(kinds, " "):find("OnOff:report@15"))
assert(last(warns):find("W%-vegpont: 15"), "endpoints logged")

-- reports before the profile switch are dropped, never reach the main lamp
local n = #calls
attrs[6][0](driver, p, { value = true }, rx(15))
assert(#calls == n and w(p).switch == nil)

-- after the profile switch: infoChanged reads W, reports go to the white component
assert(p.ep_to_comp(p, 15) == "main", "no white component yet")
p.profile.components.white = { id = "white" }
-- other W-endpoint messages (e.g. Default Response of the W Off command) map to the white component
assert(p.ep_to_comp(p, 15) == "white" and p.ep_to_comp(p, 11) == "main", "endpoint -> component")
p.sent = {}
lc.infoChanged(driver, p)
assert(last(p.sent).kind == "Level:read" and last(p.sent).ep == 15, "W read after profile switch")
attrs[6][0](driver, p, { value = true }, rx(15))
attrs[8][0](driver, p, { value = 127 }, rx(15))
assert(w(p).switch == "on" and w(p).switchLevel == 50 and #calls == n + 1)
attrs[6][0](driver, p, { value = true }, rx(11))
assert(calls[#calls] == "onoff_attr", "RGB report to Mariano handler")
lc.init(driver, p)
assert(last(p.sent).kind == "Level:read", "restart with W profile: only a read")

-- white component commands go to endpoint 15, never to Mariano
n = #calls
caps.switch.off(driver, p, { component = "white" })
assert(last(p.sent).kind == "Off" and last(p.sent).ep == 15 and w(p).switch == "off")
caps.switchLevel.setLevel(driver, p, { component = "white", args = { level = 40 } })
assert(last(p.sent).kind == "MoveToLevelWithOnOff" and last(p.sent).args[1] == 102 and w(p).switch == "on")
caps.refresh.refresh(driver, p, { component = "white" })
assert(last(p.sent).kind == "Level:read" and last(p.sent).ep == 15)
assert(#calls == n, "white commands never reach Mariano handlers")

-- main off: W off and remembered; main on (also via setLevel from HA): W back
caps.switch.off(driver, p, { component = "main" })
assert(calls[#calls] == "off" and last(p.sent).kind == "Off" and last(p.sent).ep == 15 and w(p).switch == "off")
caps.switch.on(driver, p, { component = "main" })
assert(calls[#calls] == "on" and last(p.sent).kind == "On" and last(p.sent).ep == 15 and w(p).switch == "on")
caps.switch.off(driver, p, { component = "main" })
p.sent = {}
caps.switchLevel.setLevel(driver, p, { component = "main", args = { level = 60 } })
assert(calls[#calls] == "setLevel" and p.sent[1].kind == "On" and last(p.sent).kind == "MoveToLevelWithOnOff")
assert(w(p).switchLevel == 60, "W follows main level in auto mode")
-- W was off during main off -> main on does not light it
caps.switch.off(driver, p, { component = "white" })
caps.switch.off(driver, p, { component = "main" })
p.sent = {}
caps.switch.on(driver, p, { component = "main" })
assert(#p.sent == 0 and w(p).switch == "off", "W not restored if it was off")

-- presets: colour temperature -> W on with main level, colour -> W off
p.state.main = { switchLevel = 80 }
caps.colorTemperature.setColorTemperature(driver, p, { component = "main", args = { temperature = 3000 } })
assert(calls[#calls] == "setColorTemperature" and w(p).switch == "on" and w(p).switchLevel == 80)
caps.colorControl.setColor(driver, p, { component = "main", args = { color = { hue = 33.3, saturation = 100 } } })
assert(calls[#calls] == "setColor" and w(p).switch == "off")
assert(p.state.main.hue == 33.3 and p.state.main.saturation == 100, "colour reported immediately")
assert(p.state.main.colorTemperature == 3000, "colour temperature reported immediately")
-- manual mode: presets leave W alone, main off still switches it off
p.preferences.wPresetMode = "manual"
caps.switch.on(driver, p, { component = "white" })
caps.colorControl.setColor(driver, p, { component = "main", args = {} })
assert(w(p).switch == "on", "manual: colour preset keeps W")
caps.switchLevel.setLevel(driver, p, { component = "main", args = { level = 20 } })
assert(w(p).switchLevel ~= 20, "manual: W does not follow main level")
caps.switch.off(driver, p, { component = "main" })
assert(w(p).switch == "off")

-- endpoint missing from the hub's list but answering the probe
local q = new_device({ [11] = { 6, 8, 0x300 }, [242] = { 0x21 } })
lc.init(driver, q)
assert(q.new_profile == nil and last(warns):find("W%-vegpont: nincs"))
local probes = {}
for _, m in ipairs(q.sent) do probes[#probes + 1] = m.kind .. "@" .. m.ep end
assert(table.concat(probes, " ") == "OnOff:read@12 OnOff:read@13 OnOff:read@14 OnOff:read@15", table.concat(probes, " "))
local sent = #q.sent
caps.switch.off(driver, q, { component = "main" })
assert(#q.sent == sent, "1 ID: no extra W command")
n = #calls
attrs[6][0](driver, q, { value = true }, rx(11))
assert(calls[#calls] == "onoff_attr" and q.new_profile == nil, "main endpoint report is not a probe hit")
attrs[6][0](driver, q, { value = true }, rx(15))
assert(q.fields.gledopto_w_ep == 15 and q.new_profile == "rgbw-w-level-colortemp-2000-6500", "probe hit -> W profile")
q.profile.components.white = { id = "white" }
assert(q.ep_to_comp(q, 15) == "white", "probed W endpoint mapped to the white component")
assert(#calls == n + 1, "probe answer not passed to Mariano handler")

-- other manufacturers untouched
local r = new_device({ [1] = { 6 }, [2] = { 6 } })
function r:get_manufacturer() return "IKEA of Sweden" end
local wn = #warns
lc.init(driver, r)
assert(r.new_profile == nil and #warns == wn and M.white_endpoint(r) == nil)
r.sent = {}
caps.switch.off(driver, r, { component = "main" })
assert(#r.sent == 0)
-- colour while off: ExecuteIfOff before Mariano, instant resend after the On; no W restore afterwards
local x = new_device({ [11] = { 6, 8, 0x300 }, [15] = { 6, 8 } })
lc.init(driver, x)
x.profile.components.white = { id = "white" }
x.state.main = { switch = "off" }
x.fields.gledopto_w_restore = true
x.sent = {}
n = #calls
caps.colorControl.setColor(driver, x, { component = "main", args = { color = { hue = 0, saturation = 100 } } })
local first = x.sent[1]
assert(first.kind == "MoveToHueAndSaturation" and first.args[1] == 0 and first.args[2] == 254, "colour sent first")
assert(first.args[3] == 0 and first.args[4] == 1 and first.args[5] == 1, "ExecuteIfOff, no transition")
assert(calls[n + 1] == "setColor", "Mariano handler still runs (level + On)")
assert(#x.delayed == 2 and x.delayed[1].s == 3 and x.delayed[2].s <= 0.5, "on-guard + instant resend")
x.delayed[2].fn()
local again = last(x.sent)
assert(again.kind == "MoveToHueAndSaturation" and again.args[3] == 0 and again.args[4] == 0, "instant resend after On")
assert(x.fields.gledopto_w_restore == nil, "colour turn-on does not bring the W back")
-- colour temperature while off
x.state.main.switch = "off"
x.sent, x.delayed = {}, {}
caps.colorTemperature.setColorTemperature(driver, x, { component = "main", args = { temperature = 2500 } })
assert(x.sent[1].kind == "MoveToColorTemperature" and x.sent[1].args[1] == 400 and x.sent[1].args[3] == 1)
-- lamp already on: no extra messages, no delayed resend
x.state.main.switch = "on"
x.sent, x.delayed = {}, {}
caps.colorControl.setColor(driver, x, { component = "main", args = { color = { hue = 50, saturation = 50 } } })
assert(#x.delayed == 0 and (x.sent[1] == nil or x.sent[1].kind ~= "MoveToHueAndSaturation"))
-- W already off: main off / colour send no extra W message (fewer Zigbee messages)
x.state.main.switch = "on"
x.state.white = { switch = "off" }
x.sent = {}
caps.switch.off(driver, x, { component = "main" })
for _, m in ipairs(x.sent) do assert(m.ep ~= 15, "no W Off when W is already off") end
caps.colorControl.setColor(driver, x, { component = "main", args = { color = { hue = 10, saturation = 90 } } })
for _, m in ipairs(x.sent) do assert(m.ep ~= 15, "no W Off on colour when W is already off") end
-- on-guard: main stays off after an on command -> W state re-sent, command retried once, results logged
local g = new_device({ [11] = { 6, 8, 0x300 }, [15] = { 6, 8 } })
lc.init(driver, g)
g.profile.components.white = { id = "white" }
g.state.main = { switch = "off" }
g.state.white = { switch = "off" }
g.sent, g.delayed = {}, {}
n = #calls
caps.switch.on(driver, g, { component = "main" })
assert(calls[n + 1] == "on" and #g.delayed == 1 and g.delayed[1].s == 3, "check scheduled")
local check = table.remove(g.delayed, 1)
check.fn()
assert(last(g.sent).kind == "Off" and last(g.sent).ep == 15, "W known state (off) re-sent")
assert(last(warns):find("nem kapcsolt be"), "logged")
local retry = table.remove(g.delayed, 1)
assert(retry.s == 0.5)
retry.fn()
assert(calls[#calls] == "on" and #calls == n + 2, "command retried once")
-- the retry itself schedules only the result log, not another guard
local logs = 0
for _, d in ipairs(g.delayed) do logs = logs + 1 end
assert(logs == 1, "no second guard on the retry")
g.state.main.switch = "on"
table.remove(g.delayed, 1).fn()
assert(last(warns):find("bekapcsolt"), "result logged")
-- lamp answered in time: nothing happens
g.state.main.switch = "off"
g.sent, g.delayed = {}, {}
caps.switch.on(driver, g, { component = "main" })
g.state.main.switch = "on"
table.remove(g.delayed, 1).fn()
assert(#g.delayed == 0 and #g.sent == 0, "no retry when the lamp answered")
-- W on: its On is re-sent (state kept); setLevel 0 and white commands never guarded
g.state.main.switch = "off"
g.state.white.switch = "on"
g.sent, g.delayed = {}, {}
caps.switchLevel.setLevel(driver, g, { component = "main", args = { level = 70 } })
local gi
for i, d in ipairs(g.delayed) do if d.s == 3 then gi = i end end
table.remove(g.delayed, gi).fn()
assert(last(g.sent).kind == "On" and last(g.sent).ep == 15, "W on re-sent as On")
g.delayed = {}
caps.switchLevel.setLevel(driver, g, { component = "main", args = { level = 0 } })
caps.switch.on(driver, g, { component = "white" })
for _, d in ipairs(g.delayed) do assert(d.s ~= 3, "no guard for off/white") end
print("OK - gledopto_w tests passed")

-- keepalive: every GLEDOPTO (1 and 2 ID) reads the main endpoint periodically; re-init replaces the timer
local k = new_device({ [11] = { 6, 8, 0x300 } })
lc.init(driver, k)
assert(#k.scheduled == 1 and k.scheduled[1].s == 300, "keepalive scheduled")
k.sent = {}
k.scheduled[1].fn()
assert(#k.sent == 2 and k.sent[1].kind == "OnOff:read" and k.sent[1].ep == 11
  and k.sent[2].kind == "Level:read" and k.sent[2].ep == 11, "keepalive reads main endpoint")
lc.init(driver, k)
assert(#k.scheduled == 2 and k.cancelled[1] == k.scheduled[1], "old keepalive cancelled")
-- device:refresh() (Mariano after on/off, the bridge's probe) reads only the main endpoint's OnOff + Level
k.sent = {}
k:refresh()
assert(#k.sent == 2 and k.sent[1].kind == "OnOff:read" and k.sent[2].kind == "Level:read"
  and k.sent[2].ep == 11, "refresh limited to the main endpoint")
-- other manufacturers: no keepalive
assert(#r.scheduled == 0, "no keepalive for non-GLEDOPTO")
r.sent = {}
r:refresh()
assert(#r.sent == 1 and r.sent[1].kind == "full-refresh", "non-GLEDOPTO refresh untouched")
print("gledopto keepalive OK")

-- wake-up: 2 ID, no answer for NUDGE_S -> the keepalive also re-sends the W state; an answer clears it
local real_time = os.time
local now = 1000000
os.time = function() return now end
local z = new_device({ [11] = { 6, 8, 0x300 }, [15] = { 6, 8 } })
z.profile.components.white = { id = "white" }
lc.init(driver, z)
local ka = last(z.scheduled)
z.sent = {}
now = now + 300
ka.fn()
assert(#z.sent == 2 and z.sent[1].kind == "OnOff:read", "answering device: only the keepalive reads")
z.sent = {}
now = now + 300
local wn2 = #warns
ka.fn()
assert(z.sent[1].kind == "Off" and z.sent[1].ep == 15 and #z.sent == 3, "silent device: W state re-sent + reads")
assert(#warns == wn2 + 1 and last(warns):find("ebresztes"), "wake-up logged once")
now = now + 300
ka.fn()
assert(#warns == wn2 + 1, "no repeated log while silent")
attrs[8][0](driver, z, { value = 200 }, rx(11))
assert(last(warns):find("ujra valaszol"), "recovery logged")
z.sent = {}
now = now + 300
ka.fn()
assert(#z.sent == 2, "after the answer: only reads again")
-- 1 ID (no W endpoint): never a W command
local y = new_device({ [11] = { 6, 8, 0x300 } })
lc.init(driver, y)
y.sent = {}
now = now + 2000
last(y.scheduled).fn()
assert(#y.sent == 2 and y.sent[1].kind == "OnOff:read", "1 ID: reads only")
os.time = real_time
print("gledopto wake-up OK")

