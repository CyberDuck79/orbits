-- Headless golden-master harness for orbits.
--
-- Runs the script against stub norns/lp3 APIs on a virtual clock, drives it
-- with a long, deterministic pseudo-random sequence of pad/encoder/key
-- events, and logs everything observable: LED changes, screen draw calls,
-- and the notes sent to the voices (with their beat position). Running the
-- same scenario on two versions of the script and diffing the logs shows
-- whether a refactor changed any behaviour.
--
--   lua tools/harness.lua <root> <events> <out.log>
--
-- <root> is the directory that contains the `orbits/` folder (the one
-- `include('orbits/...')` resolves against).

local root = arg[1]
local n_events = tonumber(arg[2]) or 3000
local out = assert(io.open(arg[3] or "harness.log", "w"))

local function fmt(v)
  if type(v) == "number" then
    if v == math.floor(v) then return string.format("%d", v) end
    return string.format("%.4f", v)
  end
  return tostring(v)
end
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = fmt((select(i, ...))) end
  out:write(table.concat(parts, " "), "\n")
end

-- optional line coverage (COVER=1): which lines of orbits's own files ran.
-- Hooks are per coroutine in Lua 5.1, so clock.run installs it on each one.
local covered = {}
local cover_fn
if os.getenv("COVER") then
  cover_fn = function(_, line)
    local src = debug.getinfo(2, "S").source
    if src:find("orbits", 1, true) and not src:find("harness", 1, true) then
      covered[src .. ":" .. line] = true
    end
  end
end

-- ---------------------------------------------------------------- time ----
local BPM = 120
local now = 0 -- seconds of virtual time
local function beats() return now * BPM / 60 end

local tasks = {} -- {at=, seq=, run=function}
local seq = 0
local function schedule(at, run)
  seq = seq + 1
  table.insert(tasks, {at = at, seq = seq, run = run})
end

local function advance(dt)
  local target = now + dt
  while true do
    local best, bi
    for i, t in ipairs(tasks) do
      if t.at <= target and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then
        best, bi = t, i
      end
    end
    if not best then break end
    table.remove(tasks, bi)
    if best.at > now then now = best.at end
    best.run()
  end
  now = target
end

-- --------------------------------------------------------------- clock ----
local function resume(co)
  local ok, req = coroutine.resume(co)
  if not ok then
    log("CLOCK-ERR", (tostring(req):gsub("^[^:]*:%d+: ", "")))
    return
  end
  if coroutine.status(co) == "dead" then return end
  if req and req.sync then
    local b = beats()
    local nb = (math.floor(b / req.sync + 1e-9) + 1) * req.sync
    schedule(nb * 60 / BPM, function() resume(co) end)
  elseif req and req.sleep then
    schedule(now + req.sleep, function() resume(co) end)
  end
end

clock = {
  run = function(fn)
    local co = coroutine.create(fn)
    if cover_fn then debug.sethook(co, cover_fn, "l") end
    resume(co)
    return co
  end,
  sync = function(b) coroutine.yield({sync = b}) end,
  sleep = function(s) coroutine.yield({sleep = s}) end,
  cancel = function() end,
  get_beats = beats,
  get_tempo = function() return BPM end,
}

-- --------------------------------------------------------------- metro ----
local metro_id = 0
metro = {
  init = function(fn, time, count)
    metro_id = metro_id + 1
    local m = {id = metro_id, event = fn, time = time or 1, count = count or -1, running = false, gen = 0}
    function m:start(t, c)
      self.running = true
      self.gen = self.gen + 1
      local gen = self.gen
      local period = t or self.time
      local left = c or self.count
      local function tick()
        if not self.running or self.gen ~= gen then return end
        self.event(self)
        if left > 0 then left = left - 1 end
        if left == 0 then self.running = false return end
        schedule(now + period, tick)
      end
      schedule(now + period, tick)
    end
    function m:stop() self.running = false end
    return m
  end,
  free = function() end,
}

-- --------------------------------------------------------- misc stubs ----
local saved_tabs
util = {
  time = function() return now end,
  clamp = function(x, lo, hi) return math.min(math.max(x, lo), hi) end,
  file_exists = function(p) return saved_tabs[p] ~= nil end,
}
saved_tabs = {}
tab = {
  save = function(t, path) saved_tabs[path] = t end,
  load = function(path) return saved_tabs[path] end,
}

local function noop_table()
  return setmetatable({}, {__index = function() return function() end end})
end

local players = {}
local function player_for(name)
  if not players[name] then
    players[name] = {
      note_on = function(_, note, vel) log("NOTE_ON", name, beats(), note, vel) end,
      note_off = function(_, note) log("NOTE_OFF", name, beats(), note) end,
    }
  end
  return players[name]
end
params = setmetatable({
  lookup_param = function(_, name)
    return {get_player = function() return player_for(name) end, string = function() return "stub" end}
  end,
  get = function(_, k) if k == "clock_tempo" then return BPM end return 0 end,
}, {__index = function() return function() end end})

screen = setmetatable({
  text_extents = function(s) return #tostring(s) * 5 end,
  update = function() log("SCREEN-UPDATE") end,
}, {__index = function(_, name)
  return function(...)
    local parts = {"S." .. name}
    for i = 1, select("#", ...) do parts[#parts + 1] = fmt((select(i, ...))) end
    out:write(table.concat(parts, " "), "\n")
  end
end})

-- fake Launchpad ---------------------------------------------------------
local fakepad
do
  local buf, last = {}, {}
  fakepad = {connected = true}
  function fakepad:connect() self.connected = true return true end
  function fakepad:disconnect() self.connected = false end
  function fakepad:set_brightness(v) log("BRIGHT", v) end
  function fakepad:led(x, y, c) buf[x .. "," .. y] = "c" .. c end
  function fakepad:led_rgb(x, y, r, g, b) buf[x .. "," .. y] = r .. "." .. g .. "." .. b end
  function fakepad:all(c)
    for x = 1, 9 do for y = 1, 9 do buf[x .. "," .. y] = "c" .. (c or 0) end end
  end
  function fakepad:refresh()
    local keys = {}
    for k, v in pairs(buf) do if last[k] ~= v then keys[#keys + 1] = k end end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. buf[k]; last[k] = buf[k] end
    log("LED", #keys > 0 and table.concat(parts, " ") or "-")
  end
end

package.path = root .. "/?.lua;" .. package.path
package.preload["lp3/lib/mod"] = function() return {new = function() return fakepad end} end

local nb_stub = {init = function() end, add_param = function() end, add_player_params = function() end}
function include(file)
  if file:find("lib/nb/lib/nb", 1, true) then return nb_stub end
  return dofile(root .. "/" .. file .. ".lua")
end

-- ------------------------------------------------------------ scenario ----
math.randomseed(1)
dofile(root .. "/orbits/orbits.lua")

local lcg = tonumber(os.getenv("SEED")) or 12345
local function rnd(n)
  lcg = (lcg * 1103515245 + 12345) % 2147483648
  return (lcg % n) + 1
end

local function try(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then log("ERR", label, (tostring(err):gsub("^[^:]*:%d+: ", ""))) end
end

if cover_fn then debug.sethook(cover_fn, "l") end

try("init", init)
local held = {}
local DT = {0.02, 0.05, 0.1, 0.25, 0.5, 1.0}

local function tap(x, y)
  try("key", fakepad.key, x, y, 1)
  advance(0.05)
  try("key", fakepad.key, x, y, 0)
  advance(0.05)
end

-- Turns on the features random fuzzing would take a long time to reach
-- (repeats, groove, arp, phrase, modulations, patterns, song), through the
-- real pads/encoders/keys like a user would.
local function setup_features()
  log("EV setup")
  tap(6, 9)                                   -- Drums
  tap(4, 2); tap(3, 4); tap(5, 1)             -- repeats, repeat time, groove
  for x = 1, 8 do tap(x, 8) end               -- steps
  try("enc", enc, 1, 3); try("enc", enc, 2, 8); try("enc", enc, 3, 2)
  try("enc", enc, 1, -2)
  tap(7, 9)                                   -- Keys
  tap(2, 2); tap(3, 1); tap(5, 3); tap(3, 5)  -- arp style, phrase type, scale, root
  tap(1, 7); tap(3, 7); tap(5, 7)             -- chord
  try("key", key, 2, 1); try("key", key, 2, 0)
  try("key", key, 3, 1); try("key", key, 3, 0)
  tap(8, 9)                                   -- User
  for y = 8, 1, -1 do
    tap(1, y)
    try("enc", enc, 2, 25); try("enc", enc, 3, rnd(4) - 2)
    try("key", key, 2, 1); try("key", key, 2, 0)
  end
  tap(5, 9)                                   -- Session
  tap(1, 6); tap(2, 6); tap(3, 5); tap(1, 6)
  tap(2, 7); tap(5, 8)
  try("key", key, 2, 1); try("key", key, 2, 0)
  tap(6, 9)                                   -- back to Drums

  -- step edit: select a step, toggle accent / manual, adjust, deselect
  tap(2, 8)
  try("key", key, 3, 1); try("key", key, 3, 0)
  try("key", key, 2, 1); try("key", key, 2, 0)
  try("enc", enc, 2, 10); try("enc", enc, 3, 5)
  tap(2, 8)

  -- mute (shift = hold transport): latched, then momentary; tempo page
  try("key", fakepad.key, 9, 1, 1)
  tap(9, 6)
  try("key", fakepad.key, 9, 4, 1); advance(0.5); try("key", fakepad.key, 9, 4, 0)
  try("enc", enc, 2, 7)
  try("key", fakepad.key, 9, 1, 0)

  -- every arp style and phrase type, with time to play through them
  tap(7, 9)
  for x = 1, 8 do tap(x, 2); advance(1.5) end
  for x = 1, 8 do tap(x, 1); advance(1.5) end
  tap(6, 9)

  -- Session: copy a pattern (long press arms copy mode, next tap pastes)
  tap(5, 9)
  try("key", fakepad.key, 1, 6, 1); advance(0.9); try("key", fakepad.key, 1, 6, 0)
  tap(4, 6)

  -- pset save + load round trip
  try("pset", function()
    params.action_write("x", "n", 1)
    params.action_read("x", "n", 1)
  end)
  tap(6, 9)
end

for e = 1, n_events do
  local r = rnd(100)
  if e == 3 or e % 500 == 0 then
    setup_features()
  elseif e == 5 then
    -- start playback early so the engine runs through most of the scenario
    fakepad.key(9, 1, 1); fakepad.key(9, 1, 0)
  elseif r <= 55 then
    local x, y = rnd(9), rnd(9)
    log("EV pad", x, y)
    try("key", fakepad.key, x, y, 1)
    if rnd(100) <= 80 then
      advance(DT[rnd(#DT)])
      try("key", fakepad.key, x, y, 0)
    else
      held[#held + 1] = {x, y}
    end
  elseif r <= 62 then
    local x, y = rnd(9), rnd(9)
    log("EV hold", x, y)
    try("key", fakepad.key, x, y, 1)
    advance(0.7)
    try("key", fakepad.key, x, y, 0)
  elseif r <= 75 then
    local n, d = rnd(3), (rnd(2) == 1) and 1 or -1
    log("EV enc", n, d)
    try("enc", enc, n, d)
  elseif r <= 88 then
    local n, z = rnd(3), rnd(2) - 1
    log("EV key", n, z)
    try("key", key, n, z)
  elseif #held > 0 then
    local h = table.remove(held)
    log("EV release", h[1], h[2])
    try("key", fakepad.key, h[1], h[2], 0)
  end
  advance(DT[rnd(#DT)])
  try("redraw", redraw)
end

try("cleanup", cleanup)
log("END", beats())
out:close()

if os.getenv("COVER") then
  debug.sethook()
  local cf = io.open(arg[3] .. ".cover", "w")
  for k in pairs(covered) do cf:write(k, "\n") end
  cf:close()
end
