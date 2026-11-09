-- st-edge patch: GLEDOPTO RGBW vezerlok (GL-C-007 "2 ID") W csatornaja ugyanazon az eszkozon.
--
-- A 2 ID-s firmware ket Zigbee-vegpontot ad: RGB (altalaban 11) es W (altalaban 15). A Mariano-driver
-- csak az elsot kezeli, ezert a W soha nem kapcsol ki. Ez a modul:
--   * az eszkozt a W_PROFILE profilra allitja: a "white" komponens (kapcsolo + fenyero) a W-vegpont,
--     igy az ST appban ugyanazon az eszkozlapon allithato;
--   * a W-vegpont OnOff/Level jelenteseit a "white" komponensre iranyitja (kulonben a fo lampat irnak felul);
--     a W-vegpont minden mas uzenete is (pl. a W On/Off parancs Default Response-a, amit az ST alap-
--     kezeloje switch-esemenynek vesz) a "white" komponensre megy (endpoint_to_component);
--   * a "white" komponens parancsait a W-vegpontra kuldi;
--   * a fo lampa kikapcsolasa a W-t is lekapcsolja, a bekapcsolasa visszakapcsolja, ha ego volt;
--   * presetek ("wPresetMode" = "auto", alapertek): szinhomerseklet-parancs -> W be a fo fenyerovel,
--     szin-parancs -> W ki; a fo fenyero valtozasat a bekapcsolt W koveti.
-- Szin/szinhomerseklet parancsnal a kert erteket azonnal visszajelzi (GLEDOPTO, 1 es 2 ID): a Mariano-driver
-- csak az atmenet + 2 s utani visszaolvasaskor jelez, addig az ST app "gondolkodik".
-- Kikapcsolt lampanal a szin/szinhomerseklet parancs a lampaban figyelmen kivul marad (ZCL: ExecuteIfOff=0),
-- igy a lampa a regi szinen (pl. feheren) gyullad fel, es csak utana valt at. Ezert elotte ExecuteIfOff
-- opcioval, a bekapcsolas utan pedig meg egyszer, atmenet nelkul is elkuldjuk a kert szint.
-- Bekapcsolas-orseg (2 ID): a vezerlo nehany esetben a fo (RGB) vegpont parancsait nem hajtja vegre, amig a
-- W-vegpont nem kap egy parancsot (2026-11-03: tapelvetel nem segitett, egy W be/ki igen). Ha a fo lampa
-- ON_CHECK_S alatt nem jelez "on"-t, a W ismert allapotat ujrakuldjuk, majd egyszer a parancsot is (WARN-naplo).
-- Ha a hub vegpontlistajaban nincs W (pl. a vezerlot a parositas utan allitottak 2 ID-re), indulaskor a
-- PROBE_ENDPOINTS vegpontokrol is lekeri az OnOff-ot; ha valamelyik valaszol, azt W-vegpontnak veszi
-- (perzisztens mezo). Egy ID-s firmware-nel nem valaszol senki, akkor nem valtozik semmi.
-- Eletjel (1 es 2 ID): a vezerlo magatol nem jelent, es a hid 10 perces refresh-probajara sem mindig
-- valaszol, ezert a hid 20 perc csend utan "offline"-nak vette (2026-11-04: Kitchen LED 22 percenkent,
-- LED strip hasonloan, ~1 percre). KEEPALIVE_S-enkent kiolvassuk a fo vegpont allapotat es fenyerejet;
-- a valasz esemenyt general, igy a hid 20 perces ablakaban tobb esely is van.
-- Kevesebb Zigbee-forgalom (2026-11-07: a vezerlo sűrű kapcsolgatas utan 1 orara elnemult): a device:refresh()
-- (Mariano: be/ki utan 3 s-mal, ha az allapot nem jott meg; a hid refresh-probaja) GLEDOPTO-nal csak a fo
-- vegpont OnOff + CurrentLevel erteket olvassa, nem minden konfiguralt attributumot mindket vegponton (~8 olvasas).
-- Ebresztes (2 ID): ha a vezerlo NUDGE_S ota semmire nem valaszolt (ket eletjel-olvasas elmaradt), az eletjel
-- mellett a W ismert allapotat is elkuldjuk: a fo vegpont neha addig nem valaszol, amig a W nem kap parancsot
-- (2026-11-03 es 11-07: a W-parancs utan azonnal magahoz tert; 11-08: ~1 orara elnemult). WARN-naplo az elso
-- ebreszteskor es a magahoz tereskor.
-- A W-vegpont a sajat refresh-ebol (read_white) olvashato. A szin/szinhomerseklet allapotat a parancsok azonnal
-- visszajelzik, a Mariano-handler kesleltetett visszaolvasasai pedig maradnak.
local capabilities = require "st.capabilities"
local clusters = require "st.zigbee.zcl.clusters"
local device_management = require "st.zigbee.device_management"
local log = require "log"

local OnOff, Level, ColorControl = clusters.OnOff, clusters.Level, clusters.ColorControl
local W_PROFILE = "rgbw-w-level-colortemp-2000-6500"
local W_COMP = "white"
local W_EP_FIELD = "gledopto_w_ep"
local W_RESTORE_FIELD = "gledopto_w_restore"
local PROBE_ENDPOINTS = { 12, 13, 14, 15 }
local RESEND_DELAY_S = 0.4 -- a bekapcsolas utani szin-ujrakuldes kesleltetese
local ON_CHECK_S = 3 -- ennyi ido utan nezzuk, bekapcsolt-e a fo lampa (2 ID)
local DEBUG = false -- ideiglenes nyomkovetes (WARN -> HA last_log)
local KEEPALIVE_S = 300 -- eletjel-olvasas a fo vegpontrol (a hid 20 perc csend utan jelez offline-t)
local KEEPALIVE_FIELD = "gledopto_keepalive"
local NUDGE_S = 540 -- ennyi valasz nelkuli ido utan W-parancs is megy az eletjel mellett
local RX_FIELD = "gledopto_last_rx"
local NUDGED_FIELD = "gledopto_nudged"

local M = {}

local function is_gledopto(device)
  return device.network_type ~= "DEVICE_EDGE_CHILD" and device:get_manufacturer() == "GLEDOPTO"
end

-- a fo vegponton kivuli elso OnOff-vegpont (GLEDOPTO) vagy a felderitett, kulonben nil
function M.white_endpoint(device)
  if not is_gledopto(device) then return nil end
  local probed = device:get_field(W_EP_FIELD)
  if probed then return probed end
  local main = device:get_endpoint(OnOff.ID)
  local ids = {}
  for _, e in pairs(device.zigbee_endpoints or {}) do ids[#ids + 1] = e.id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    if id ~= main and device:supports_server_cluster(OnOff.ID, id) then return id end
  end
  return nil
end

local function white_comp(device)
  return device.profile.components[W_COMP]
end

local function emit_white(device, event)
  local comp = white_comp(device)
  if comp then device:emit_component_event(comp, event) end
end

local function white_is_on(device)
  return device:get_latest_state(W_COMP, capabilities.switch.ID, capabilities.switch.switch.NAME) == "on"
end

local function auto_mode(device)
  return (device.preferences.wPresetMode or "auto") == "auto"
end

local function configure_white(driver, device, ep)
  local hub_eui = driver.environment_info and driver.environment_info.hub_zigbee_eui
  if hub_eui then
    device:send(device_management.build_bind_request(device, OnOff.ID, hub_eui, ep))
    device:send(device_management.build_bind_request(device, Level.ID, hub_eui, ep))
  end
  device:send(OnOff.attributes.OnOff:configure_reporting(device, 0, 300):to_endpoint(ep))
  device:send(Level.attributes.CurrentLevel:configure_reporting(device, 1, 3600, 1):to_endpoint(ep))
end

local function read_white(device, ep)
  device:send(OnOff.attributes.OnOff:read(device):to_endpoint(ep))
  device:send(Level.attributes.CurrentLevel:read(device):to_endpoint(ep))
end

local function white_on(device, ep)
  device:send(OnOff.server.commands.On(device):to_endpoint(ep))
  emit_white(device, capabilities.switch.switch.on())
end

local function white_off(device, ep)
  device:send(OnOff.server.commands.Off(device):to_endpoint(ep))
  emit_white(device, capabilities.switch.switch.off())
end

local function white_level(device, ep, level)
  level = math.max(0, math.min(100, math.floor(level or 0)))
  if level == 0 then return white_off(device, ep) end
  device:send(Level.server.commands.MoveToLevelWithOnOff(device, math.floor(level / 100 * 254 + 0.5), 5)
    :to_endpoint(ep))
  emit_white(device, capabilities.switchLevel.level(level))
  emit_white(device, capabilities.switch.switch.on())
end

-- eletjel: a fo vegpont OnOff + CurrentLevel olvasasa (a Level-valasz mindig esemenyt general)
local function read_main(device)
  local main = device:get_endpoint(OnOff.ID)
  device:send(OnOff.attributes.OnOff:read(device):to_endpoint(main))
  device:send(Level.attributes.CurrentLevel:read(device):to_endpoint(main))
end

-- eletjel; ha regota nincs valasz, a W ismert allapotanak ujrakuldese is (ebresztes)
local function keepalive(device)
  local ep = M.white_endpoint(device)
  if ep and white_comp(device) and os.time() - (device:get_field(RX_FIELD) or os.time()) >= NUDGE_S then
    local w = white_is_on(device)
    if not device:get_field(NUDGED_FIELD) then
      log.warn(string.format("[gledopto_w] %s: %d s ota nem valaszol, ebresztes W-paranccsal (%s)",
        tostring(device.label), os.time() - device:get_field(RX_FIELD), w and "on" or "off"))
      device:set_field(NUDGED_FIELD, true)
    end
    if w then
      device:send(OnOff.server.commands.On(device):to_endpoint(ep))
    else
      device:send(OnOff.server.commands.Off(device):to_endpoint(ep))
    end
  end
  read_main(device)
end

local function start_keepalive(device)
  local old = device:get_field(KEEPALIVE_FIELD)
  if old then device.thread:cancel_timer(old) end
  device:set_field(RX_FIELD, os.time())
  device:set_field(KEEPALIVE_FIELD, device.thread:call_on_schedule(KEEPALIVE_S, function()
    keepalive(device)
  end, "gledopto keepalive"))
end

-- valasz jott a vezerlotol (OnOff/Level jelentes barmelyik vegpontrol)
local function received(device)
  if not is_gledopto(device) then return end
  device:set_field(RX_FIELD, os.time())
  if device:get_field(NUDGED_FIELD) then
    device:set_field(NUDGED_FIELD, nil)
    log.warn(string.format("[gledopto_w] %s: ebresztes utan ujra valaszol", tostring(device.label)))
  end
end

-- fo eszkoz init utan: vegpontok naplozasa, profilvaltas, a korabbi W-gyerek torlese
local function setup(driver, device)
  if not is_gledopto(device) then return end
  start_keepalive(device)
  device:extend_device("refresh", function(dev) read_main(dev) end)
  local list = {}
  for _, e in pairs(device.zigbee_endpoints or {}) do
    local cl = {}
    for _, c in ipairs(e.server_clusters or {}) do cl[#cl + 1] = string.format("%04X", c) end
    list[#list + 1] = string.format("%d[%s]", e.id, table.concat(cl, ","))
  end
  table.sort(list)
  local ep = M.white_endpoint(device)
  log.warn(string.format("[gledopto_w] %s (%s): vegpontok %s -> W-vegpont: %s",
    tostring(device.label), tostring(device:get_model()), table.concat(list, " "), tostring(ep or "nincs")))
  if not ep then
    for _, p in ipairs(PROBE_ENDPOINTS) do
      device:send(OnOff.attributes.OnOff:read(device):to_endpoint(p))
    end
    return
  end
  -- a W-vegpontrol jovo esemenyek (pl. Default Response) ne a fo lampara keruljenek
  device:set_endpoint_to_component_fn(function(dev, src)
    if src == ep and dev.profile.components[W_COMP] then return W_COMP end
    return "main"
  end)
  -- az elozo valtozat kulon "<nev> W" gyerek-eszkoze helyett mostantol komponens
  local old_child = device:get_child_by_parent_assigned_key(string.format("W%02X", ep))
  if old_child then driver:try_delete_device(old_child.id) end
  if white_comp(device) then
    read_white(device, ep)
  else
    configure_white(driver, device, ep)
    device:try_update_metadata({ profile = W_PROFILE })
  end
end

-- W-vegpont jelentese: a "white" komponensre megy, a Mariano-handler nem latja
local function wrap_attr(orig, make_event)
  return function(driver, device, value, zb_rx)
    received(device)
    local src = zb_rx.address_header.src_endpoint.value
    local ep = M.white_endpoint(device)
    -- valasz egy, a hub listajaban nem szereplo vegpontrol: ez a W
    if not ep and is_gledopto(device) and src ~= device:get_endpoint(OnOff.ID) then
      log.warn(string.format("[gledopto_w] %s: valasz a(z) %d. vegpontrol -> W-vegpont", tostring(device.label), src))
      device:set_field(W_EP_FIELD, src, { persist = true })
      setup(driver, device)
      ep = src
    end
    if ep and src == ep then
      emit_white(device, make_event(value))
      return
    end
    return orig(driver, device, value, zb_rx)
  end
end

local function level_event(value)
  return capabilities.switchLevel.level(math.floor(value.value / 254.0 * 100 + 0.5))
end

local function onoff_event(value)
  return value.value and capabilities.switch.switch.on() or capabilities.switch.switch.off()
end

-- a "white" komponens parancsai
local white_cmds = {
  on = function(device, ep) white_on(device, ep) end,
  off = function(device, ep) white_off(device, ep) end,
  setLevel = function(device, ep, command) white_level(device, ep, command.args.level) end,
  refresh = function(device, ep) read_white(device, ep) end,
}

-- a fo lampa parancsai utan a W-re vonatkozo kiegeszites
local function restore_white(device, ep)
  if device:get_field(W_RESTORE_FIELD) then
    device:set_field(W_RESTORE_FIELD, nil, { persist = true })
    white_on(device, ep)
  end
end

-- kikapcsolas: a W is ki, es bekapcsolaskor visszajon, ha egett
-- a fo lampa melletti W-lekapcsolas csak akkor megy ki, ha a W nem ismerten kikapcsolt: a vezerlo a surun
-- erkezo uzenetektol (gyors kapcsolgatas) elnemulhat, ezert nem kuldunk feleslegeset
local function white_off_if_needed(device, ep)
  local s = device:get_latest_state(W_COMP, capabilities.switch.ID, capabilities.switch.switch.NAME)
  if s ~= "off" then white_off(device, ep) end
end

local function main_off(device, ep)
  if white_is_on(device) then device:set_field(W_RESTORE_FIELD, true, { persist = true }) end
  white_off_if_needed(device, ep)
end

local main_after = {
  on = restore_white,
  off = main_off,
  -- a HA a bekapcsolast fenyeroparanccsal kuldi
  setLevel = function(device, ep, command)
    local level = command.args.level or 0
    if level <= 0 then return main_off(device, ep) end
    restore_white(device, ep)
    if auto_mode(device) and white_is_on(device) then white_level(device, ep, level) end
  end,
  setColorTemperature = function(device, ep)
    if not auto_mode(device) then return end
    local level = device:get_latest_state("main", capabilities.switchLevel.ID, capabilities.switchLevel.level.NAME)
    white_level(device, ep, level or 100)
  end,
  setColor = function(device, ep)
    if auto_mode(device) then white_off_if_needed(device, ep) end
  end,
}

-- azonnali visszajelzes a fo lampan (a kesobbi visszaolvasas csak megerositi)
local optimistic = {
  setColor = function(device, command)
    local c = command.args.color or {}
    if c.hue ~= nil then device:emit_event(capabilities.colorControl.hue(c.hue)) end
    if c.saturation ~= nil then device:emit_event(capabilities.colorControl.saturation(c.saturation)) end
  end,
  setColorTemperature = function(device, command)
    local k = command.args.temperature
    if k ~= nil then device:emit_event(capabilities.colorTemperature.colorTemperature(math.floor(k + 0.5))) end
  end,
}

-- a kert szin ColorControl-uzenete (atmenet nelkul); exec_if_off: Options mask/override = ExecuteIfOff
local color_msg = {
  setColor = function(device, command, exec_if_off)
    local c = command.args.color or {}
    if c.hue == nil or c.saturation == nil then return nil end
    local o = exec_if_off and 1 or 0
    return ColorControl.server.commands.MoveToHueAndSaturation(device, math.floor(c.hue * 0xFE / 100 + 0.5),
      math.floor(c.saturation * 0xFE / 100 + 0.5), 0, o, o)
  end,
  setColorTemperature = function(device, command, exec_if_off)
    local k = command.args.temperature
    if not k or k <= 0 then return nil end
    local o = exec_if_off and 1 or 0
    return ColorControl.server.commands.MoveToColorTemperature(device, math.floor(1000000 / k + 0.5), 0, o, o)
  end,
}

local function main_is_off(device)
  return device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME) ~= "on"
end

local TURN_ON = { on = true, setLevel = true, setColor = true, setColorTemperature = true }

local function wrap_cmd(orig, name)
  local self_fn
  self_fn = function(driver, device, command)
    local ep = M.white_endpoint(device)
    if ep and command.component == W_COMP then
      local fn = white_cmds[name]
      if fn then fn(device, ep, command) end
      return
    end
    -- kikapcsolt lampa: a szin mar a bekapcsolas elott ervenyes legyen
    local instant = color_msg[name] and is_gledopto(device) and main_is_off(device)
    if instant then
      local ok, err = pcall(function()
        local msg = color_msg[name](device, command, true)
        if msg then device:send(msg) end
      end)
      if not ok then log.warn("[gledopto_w] ExecuteIfOff szin: " .. tostring(err)) end
      device:set_field(W_RESTORE_FIELD, nil, { persist = true })
    end
    local guard = TURN_ON[name] and ep and white_comp(device) and main_is_off(device) and not command.gledopto_retry
      and not (name == "setLevel" and (command.args.level or 0) <= 0)
    local res = orig and orig(driver, device, command)
    if guard then
      device.thread:call_with_delay(ON_CHECK_S, function()
        if not main_is_off(device) then return end
        local w = device:get_latest_state(W_COMP, capabilities.switch.ID, capabilities.switch.switch.NAME)
        log.warn(string.format("[gledopto_w] %s: %s utan nem kapcsolt be, W-parancs (%s) + ujrakuldes",
          tostring(device.label), name, w == "on" and "on" or "off"))
        if w == "on" then
          device:send(OnOff.server.commands.On(device):to_endpoint(ep))
        else
          device:send(OnOff.server.commands.Off(device):to_endpoint(ep))
        end
        device.thread:call_with_delay(0.5, function()
          self_fn(driver, device, setmetatable({ gledopto_retry = true }, { __index = command }))
          device.thread:call_with_delay(ON_CHECK_S, function()
            log.warn(string.format("[gledopto_w] %s: ujrakuldes utan %s", tostring(device.label),
              main_is_off(device) and "tovabbra sem valaszol" or "bekapcsolt"))
          end, "gledopto on retry check")
        end, "gledopto on retry")
      end, "gledopto on check")
    end
    if instant then
      device.thread:call_with_delay(RESEND_DELAY_S, function()
        local msg = color_msg[name](device, command, false)
        if msg then device:send(msg) end
      end, "gledopto instant color")
    end
    if optimistic[name] and is_gledopto(device) then optimistic[name](device, command) end
    if ep and white_comp(device) and main_after[name] then main_after[name](device, ep, command) end
    return res
  end
  return self_fn
end

local function wrap_lifecycle(orig, name)
  return function(driver, device, ...)
    local res = orig and orig(driver, device, ...)
    if name == "init" then
      setup(driver, device)
    elseif name == "infoChanged" then
      -- profilvaltas utan a "white" komponens kezdoallapota
      local ep = M.white_endpoint(device)
      if ep and white_comp(device) and not device:get_latest_state(W_COMP, capabilities.switch.ID,
          capabilities.switch.switch.NAME) then
        read_white(device, ep)
      end
    elseif name == "doConfigure" then
      local ep = M.white_endpoint(device)
      if ep then configure_white(driver, device, ep) end
    end
    return res
  end
end

local function dbg_attr(orig, name)
  return function(driver, device, value, zb_rx)
    if DEBUG and is_gledopto(device) then
      log.warn(string.format("[gledopto_w dbg] %s ep%d %s=%s", tostring(device.label),
        zb_rx.address_header.src_endpoint.value, name, tostring(value.value)))
    end
    return orig(driver, device, value, zb_rx)
  end
end

local function dbg_cmd(orig, name)
  return function(driver, device, command)
    if DEBUG and is_gledopto(device) then
      local a = command.args or {}
      local c = a.color or {}
      log.warn(string.format("[gledopto_w dbg] %s cmd %s/%s lvl=%s hue=%s sat=%s", tostring(device.label),
        tostring(command.component), name, tostring(a.level), tostring(c.hue), tostring(c.saturation)))
    end
    return orig(driver, device, command)
  end
end

function M.wrap(template)
  template.capability_handlers = template.capability_handlers or {}
  local caps = template.capability_handlers
  local function wrap(cap, cmd)
    caps[cap] = caps[cap] or {}
    caps[cap][cmd] = wrap_cmd(caps[cap][cmd], cmd)
  end
  wrap(capabilities.switch.ID, "on")
  wrap(capabilities.switch.ID, "off")
  wrap(capabilities.switchLevel.ID, "setLevel")
  wrap(capabilities.refresh.ID, "refresh")
  wrap(capabilities.colorTemperature.ID, "setColorTemperature")
  wrap(capabilities.colorControl.ID, "setColor")

  local attr = template.zigbee_handlers.attr
  attr[OnOff.ID] = attr[OnOff.ID] or {}
  attr[Level.ID] = attr[Level.ID] or {}
  attr[OnOff.ID][OnOff.attributes.OnOff.ID] = wrap_attr(attr[OnOff.ID][OnOff.attributes.OnOff.ID], onoff_event)
  attr[Level.ID][Level.attributes.CurrentLevel.ID] =
    wrap_attr(attr[Level.ID][Level.attributes.CurrentLevel.ID], level_event)

  if DEBUG then
    local CC = clusters.ColorControl
    attr[CC.ID] = attr[CC.ID] or {}
    for _, a in ipairs({ { OnOff.ID, OnOff.attributes.OnOff.ID, "OnOff" },
                         { CC.ID, CC.attributes.CurrentHue.ID, "Hue" },
                         { CC.ID, CC.attributes.CurrentSaturation.ID, "Sat" } }) do
      if attr[a[1]][a[2]] then attr[a[1]][a[2]] = dbg_attr(attr[a[1]][a[2]], a[3]) end
    end
    for _, c in ipairs({ { capabilities.switch.ID, "on" }, { capabilities.switch.ID, "off" },
                         { capabilities.colorControl.ID, "setColor" } }) do
      caps[c[1]][c[2]] = dbg_cmd(caps[c[1]][c[2]], c[2])
    end
  end

  local lc = template.lifecycle_handlers
  for _, name in ipairs({ "init", "infoChanged", "doConfigure" }) do
    lc[name] = wrap_lifecycle(lc[name], name)
  end
  return template
end

return M
