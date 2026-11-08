-- st-edge patch: Qubino Flush Shutter "nem indult el" őrszem.
--
-- Hiba (Children's Room Shutter, 2026-11): fel-parancsra a Qubino azonnal 99-et (fent) jelent,
-- de a motor nem indul (0 W) -- a modul belső pozíciója elcsúszott, azt hiszi, már fent van.
-- Kézi megoldás eddig: le-parancs, megvárni, míg a relé kattan (a modul a véghelyzetben 0-ra
-- kalibrál), majd újra fel. Ezt csinálja automatikusan:
--  1) parancs után (open/close/setShadeLevel a main-en, ha a cél > 20 %-kal eltér az ismert
--     szinttől): ha a modul 2 s-on belül azt jelenti, hogy már a célnál van, 1,5 s múlva
--     teljesítményt kérdez; ha <= 1 W (áll a motor), azonnal kalibrál (~2-3 s a parancs után).
--     Tartalék: 5 s-mal teljesítmény-lekérdezés, 8 s-mal ellenőrzés. Ha a "célnál vagyok"
--     jelentés később jön (a modul járatta a relét, véghelyzetben 0 W), a redőny tényleg ott
--     volt -> nem nyúl hozzá;
--  2) kalibrálás: az ellenkező véghelyzetbe küldi (fel helyett le, le helyett fel). Mivel a
--     redőny valójában ott van, a motor nem mozdul, a modul a véghelyzetre kalibrál és jelent;
--     a jelentésre azonnal lép (tartalék: 2 s-onkénti lekérdezés; 35 s után stabil szint 0 W
--     mellett, legkésőbb 60 s);
--  3) 1 s múlva újraküldi az eredeti célt, és még egyszer ellenőrzi. Több kör nincs.
-- Szünet (pause) vagy új parancs megszakítja. Naplózás WARN-ként ("[qubino_guard] ..."), így a
-- HA-ban a sensor.st_bridge_..._last_log-ban látszik.
local SwitchMultilevel = (require "st.zwave.CommandClass.SwitchMultilevel")({version=3})
local Meter = (require "st.zwave.CommandClass.Meter")({version=3})
local log = require "log"

local M = {
  FAST_METER = 1.5, -- s a hamis "már ott vagyok" jelentés után: teljesítmény-lekérdezés; ha <= 1 W,
                     --   azonnal kalibrál (induló motornál az első ~1 s-ban még ~1 W-ot mér)
  METER_DELAY = 5,   -- s a parancs után: tartalék teljesítmény-lekérdezés
  CHECK_DELAY = 8,   -- s a parancs után: tartalék ellenőrzés, ha a gyors út nem döntött
  POLL = 2,          -- s: tartalék lekérdezési ütem a kalibráló menet alatt
  SETTLE_MIN = 1,    -- s: ennyi előtt a véghelyzet-jelentést nem fogadjuk el
  STABLE_MIN = 35,   -- s: ennyi után elég a stabil szint 0 W mellett (teljes menet ~25 s)
  TIMEOUT = 60,      -- s: legkésőbb ekkor újraküldés
  RESEND_DELAY = 1,  -- s: a kalibráló menet vége és az újraküldés között
  QUICK = 2,         -- s: a hibás "már ott vagyok" jelentés ennyin belül jön a parancs után
  MIN_DIFF = 20,     -- %: kisebb mozgásnál nem figyel (rövid menetnél a 0 W nem bizonyít semmit)
}
M.states = {} -- device_id -> állapot (teszthez is)

local function norm(level) return level >= 99 and 100 or level end
local function label(dev) return tostring(dev.label or dev.id) end

local function alive(dev, s) return M.states[dev.id] == s end

-- Másodperc-tört pontosságú idő, ha van (hubon a luasocket), különben os.time().
local okso, socket = pcall(require, "socket")
function M.now()
  if okso and type(socket) == "table" and socket.gettime then return socket.gettime() end
  return os.time()
end

-- Hibás eset: a modul AZONNAL (QUICK-on belül) a célt jelenti, és nem mozog. Ha a jelentés
-- később jön (a modul járatta a relét, és a véghelyzetben 0 W-ot látott), a redőny valójában
-- már a célnál volt (pl. lent volt, de "fent"-nek látszott) -> nincs mit javítani.
local function instant_fake(s)
  return s.first_lv ~= nil and s.first_lv_t <= M.QUICK and math.abs(s.first_lv - norm(s.target)) <= 2
end

local function shade_level(dev)
  local ok, v = pcall(dev.get_latest_state, dev, "main", "windowShadeLevel", "shadeLevel")
  return ok and type(v) == "number" and v or nil
end

local function get_power(dev)
  dev:send(Meter:Get({scale = Meter.scale.electric_meter.WATTS}))
end

local start_recovery

local function watch(dev, s)
  s.moved = false
  s.t0, s.first_lv, s.first_lv_t = M.now(), nil, nil
  dev.thread:call_with_delay(M.METER_DELAY, function()
    if alive(dev, s) and not s.moved then get_power(dev) end
  end, "qubino guard meter")
  dev.thread:call_with_delay(M.CHECK_DELAY, function()
    if not alive(dev, s) then return end
    if s.moved then
      if s.phase == "retry" then
        log.warn(string.format("[qubino_guard] %s: újraküldés után elindult (cél %d)", label(dev), s.target))
      end
      M.states[dev.id] = nil
    elseif not instant_fake(s) then
      log.warn(string.format("[qubino_guard] %s: %s %d: nem mozgott, de nem azonnali hamis jelentés (első szint %s, %s s, %s W) -> rendben, már ott volt",
        label(dev), s.phase == "retry" and "újraküldött cél" or "cél", s.target, tostring(s.first_lv),
        s.first_lv_t and string.format("%.1f", s.first_lv_t) or "-", tostring(s.power)))
      M.states[dev.id] = nil
    elseif s.phase == "watch" then
      start_recovery(dev, s)
    else
      log.warn(string.format("[qubino_guard] %s: újraküldés után sem indult el (cél %d, szint %s, %s W)",
        label(dev), s.target, tostring(s.last_level), tostring(s.power)))
      M.states[dev.id] = nil
    end
  end, "qubino guard check")
end

local function resend(dev, s, why)
  s.phase = "retry"
  log.warn(string.format("[qubino_guard] %s: kalibráló menet vége (%s, %.1f s, szint %s) -> cél %d újraküldése",
    label(dev), why, M.now() - s.rec_t0, tostring(s.last_level), s.target))
  dev.thread:call_with_delay(M.RESEND_DELAY, function()
    if not alive(dev, s) then return end
    watch(dev, s) -- előbb: a válasz-események már az új körbe számítsanak
    dev:send(SwitchMultilevel:Set({value = s.target}))
  end, "qubino guard resend")
end

local function poll(dev, s)
  dev.thread:call_with_delay(M.POLL, function()
    if not alive(dev, s) or s.phase ~= "recover" then return end
    local el = M.now() - s.rec_t0
    local lv = s.last_level
    local at_end = type(lv) == "number" and ((s.opp == 0 and lv <= 1) or (s.opp == 99 and lv >= 99))
    local still = (s.power or 0) <= 1
    if el >= M.SETTLE_MIN and still and at_end then
      return resend(dev, s, "véghelyzet")
    elseif el >= M.STABLE_MIN and still and lv ~= nil and lv == s.poll_level then
      return resend(dev, s, "stabil szint")
    elseif el >= M.TIMEOUT then
      return resend(dev, s, "időtúllépés")
    end
    s.poll_level = lv
    dev:send(SwitchMultilevel:Get({}))
    get_power(dev)
    poll(dev, s)
  end, "qubino guard poll")
end

start_recovery = function(dev, s)
  s.phase = "recover"
  s.rec_t0 = M.now()
  s.opp = norm(s.target) > s.prior and 0 or 99
  s.last_level, s.poll_level = nil, nil
  log.warn(string.format("[qubino_guard] %s: %d -> %d parancsra nem indult el (%s W, jelentett szint %s) -> %s, majd újra",
    label(dev), s.prior, s.target, tostring(s.power), tostring(shade_level(dev)), s.opp == 0 and "le" or "fel"))
  dev:send(SwitchMultilevel:Set({value = s.opp}))
  poll(dev, s)
end

--- Az aldriver window_shade_level_change-éből hívva, a main komponens parancsai előtt.
function M.commanded(dev, level)
  local prior = shade_level(dev)
  if prior == nil or math.abs(norm(level) - prior) <= M.MIN_DIFF then
    M.states[dev.id] = nil
    return
  end
  local s = { target = level, prior = prior, phase = "watch" }
  M.states[dev.id] = s
  watch(dev, s)
end

--- Szünet: a futó őrzés/kalibrálás megszakítása.
function M.cancel(dev)
  M.states[dev.id] = nil
end

--- A híd minden kiadott eseményéről értesít (st_bridge.on_event).
function M.on_event(dev, comp_id, cap_id, attr, value)
  local s = M.states[dev.id]
  if s == nil or comp_id ~= "main" then return end
  if cap_id == "powerMeter" and attr == "power" and type(value) == "number" then
    s.power = value
    if value > 1 and s.phase ~= "recover" then s.moved = true end
    -- Gyors út: hamis azonnali jelentés + a kért (későbbi) mérés szerint áll a motor.
    if value <= 1 and s.phase == "watch" and not s.moved and s.fast_req_t and M.now() >= s.fast_req_t
        and instant_fake(s) then
      s.fast_req_t = nil
      start_recovery(dev, s)
    end
  elseif cap_id == "windowShade" and attr == "windowShade" and (value == "opening" or value == "closing") then
    if s.phase ~= "recover" then s.moved = true end
  elseif cap_id == "windowShadeLevel" and attr == "shadeLevel" and type(value) == "number" then
    s.last_level = value
    if s.phase ~= "recover" and s.first_lv == nil then
      s.first_lv, s.first_lv_t = value, M.now() - s.t0
      if s.phase == "watch" and instant_fake(s) then
        dev.thread:call_with_delay(M.FAST_METER, function()
          if not alive(dev, s) or s.phase ~= "watch" or s.moved then return end
          s.fast_req_t = M.now()
          get_power(dev)
        end, "qubino guard fast meter")
      end
    elseif s.phase == "recover" and (s.power or 0) <= 1 and M.now() - s.rec_t0 >= M.SETTLE_MIN
        and ((s.opp == 0 and value <= 1) or (s.opp == 99 and value >= 99)) then
      resend(dev, s, "véghelyzet")
    end
  end
end

local ok, bridge = pcall(require, "st_bridge")
if ok and type(bridge) == "table" and bridge.on_event then bridge.on_event(M.on_event) end

return M
