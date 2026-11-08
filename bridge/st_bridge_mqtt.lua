-- Minimal MQTT 3.1.1 client for SmartThings Edge (cosock), QoS 0 only.
-- Single writer coroutine (all outgoing packets go through a channel), so
-- packets from different device threads never interleave on the socket.
local cosock = require "cosock"
local socket = cosock.socket
local log = require "log"

local M = {}
M.__index = M

local function u16(n) return string.char((n >> 8) & 0xFF, n & 0xFF) end
local function str(s) return u16(#s) .. s end

local function varint(n)
  local out = {}
  repeat
    local b = n % 128
    n = n // 128
    if n > 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function packet(first_byte, body)
  return string.char(first_byte) .. varint(#body) .. body
end

--- opts: host, port, client_id, username, password, keepalive,
---       will_topic, will_payload, on_connect(client), on_message(topic, payload)
function M.new(opts)
  local self = setmetatable({}, M)
  self.opts = opts
  self.sock = nil
  self.connected = false
  self.reconnects = 0
  self.last_error = ""
  self.tx, self.rx = cosock.channel.new()
  return self
end

function M:_raw_send(data)
  local sock = self.sock
  if not sock then return nil, "not connected" end
  local ok, err = sock:send(data)
  if not ok then
    self.last_error = "send: " .. tostring(err)
    self:_drop()
  end
  return ok, err
end

function M:_drop()
  self.connected = false
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
end

--- Queue a publish. Silently dropped while disconnected (state is re-published on reconnect).
function M:publish(topic, payload, retain)
  if not self.connected then return false end
  local body = str(topic) .. (payload or "")
  self.tx:send(packet(0x30 | (retain and 1 or 0), body))
  return true
end

function M:subscribe(topics)
  self.packet_id = ((self.packet_id or 0) % 65535) + 1
  local body = u16(self.packet_id)
  for _, t in ipairs(topics) do body = body .. str(t) .. string.char(0) end
  self.tx:send(packet(0x82, body))
end

function M:_read_exact(n)
  local data, err, partial = self.sock:receive(n)
  if not data then return nil, err, partial end
  return data
end

function M:_read_packet()
  local h, err = self:_read_exact(1)
  if not h then return nil, err end
  local mult, len = 1, 0
  repeat
    local b, e = self:_read_exact(1)
    if not b then return nil, e end
    b = b:byte()
    len = len + (b & 0x7F) * mult
    mult = mult * 128
  until (b & 0x80) == 0
  local body = ""
  if len > 0 then
    body, err = self:_read_exact(len)
    if not body then return nil, err end
  end
  return h:byte(), body
end

function M:_session()
  local o = self.opts
  if not o.host or o.host == "" then
    return nil, "no MQTT broker configured (device settings: MQTT broker host)"
  end
  local sock = socket.tcp()
  sock:settimeout(10)
  local ok, err = sock:connect(o.host, o.port)
  if not ok then sock:close(); return nil, "connect: " .. tostring(err) end
  self.sock = sock

  local flags = 0x02 -- clean session
  local payload = str(o.client_id)
  if o.will_topic then
    flags = flags | 0x04 | 0x20 -- will flag + will retain
    payload = payload .. str(o.will_topic) .. str(o.will_payload or "")
  end
  if o.username then flags = flags | 0x80; end
  if o.password then flags = flags | 0x40; end
  if o.username then payload = payload .. str(o.username) end
  if o.password then payload = payload .. str(o.password) end
  local body = str("MQTT") .. string.char(4, flags) .. u16(o.keepalive) .. payload
  ok, err = sock:send(packet(0x10, body))
  if not ok then self:_drop(); return nil, "send connect: " .. tostring(err) end

  local typ, ack = self:_read_packet()
  if typ ~= 0x20 or not ack or #ack < 2 then self:_drop(); return nil, "no CONNACK: " .. tostring(ack) end
  if ack:byte(2) ~= 0 then self:_drop(); return nil, "CONNACK refused rc=" .. ack:byte(2) end

  self.connected = true
  self.session_ok = true
  self.last_error = "" -- a korabbi kiesest a reconnects szamlalo orzi
  sock:settimeout(o.keepalive * 2)
  log.info("[st_bridge] MQTT connected to " .. o.host)
  if o.on_connect then
    local cok, cerr = pcall(o.on_connect, self)
    if not cok then log.error("[st_bridge] on_connect: " .. tostring(cerr)) end
  end

  while self.connected do
    local t, b = self:_read_packet()
    if not t then self:_drop(); return nil, "read: " .. tostring(b) end
    local kind = t >> 4
    if kind == 3 then -- PUBLISH
      local tlen = (b:byte(1) << 8) | b:byte(2)
      local topic = b:sub(3, 2 + tlen)
      local pos = 3 + tlen
      if ((t >> 1) & 0x03) > 0 then pos = pos + 2 end -- packet id for QoS>0
      if o.on_message then
        local mok, merr = pcall(o.on_message, topic, b:sub(pos))
        if not mok then log.error("[st_bridge] on_message: " .. tostring(merr)) end
      end
    end
    -- SUBACK (9), PINGRESP (13): nothing to do
  end
  return nil, "disconnected"
end

--- Start the connection + writer + keepalive coroutines. Reconnects forever with backoff.
function M:start()
  cosock.spawn(function()
    while true do
      local msg = self.rx:receive()
      if msg and self.connected then self:_raw_send(msg) end
    end
  end, "st_bridge mqtt writer")

  cosock.spawn(function()
    while true do
      socket.sleep(self.opts.keepalive // 2)
      if self.connected then self.tx:send(string.char(0xC0, 0x00)) end
    end
  end, "st_bridge mqtt ping")

  cosock.spawn(function()
    local backoff = 5
    while true do
      local _, err = self:_session()
      self.last_error = tostring(err)
      log.warn("[st_bridge] MQTT session ended: " .. tostring(err) .. ", retry in " .. backoff .. "s")
      if self.session_ok then backoff = 5; self.session_ok = false end
      socket.sleep(backoff)
      self.reconnects = self.reconnects + 1
      backoff = math.min(backoff * 2, 60)
    end
  end, "st_bridge mqtt session")
end

return M
