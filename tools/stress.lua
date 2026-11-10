-- Stress test: all seven tracks at once, in every combination (song mode or
-- not, every quantize / length value, different lengths, divisions, repeats,
-- arp, modulation...), checked against independent reference models.
--
-- Not a standalone file: tools/stress.sh appends it to the stubs and virtual
-- clock of tools/harness.lua and runs it on the norns.
--
--   A  timing of pattern changes: song chains and tapped patterns on 7 tracks,
--      every event compared with a reference simulation
--   B  chaos: random pads, encoders, keys, mutes, play/stop, psets... on all
--      pages, with invariants checked after every sixteenth note
--   C  Session editing: copy / paste / delete / chain edits / undo / redo
--      against a model of the history
--   D  replay: stop and play again gives exactly the same notes
--
-- Environment: SEED (default 1), ROUNDS (A, default 12), CHAOS (B, sixteenths,
-- default 3000), OPS (C, default 1500), BPM (default 300, set in harness.lua).

local seed = tonumber(os.getenv("SEED")) or 1
local ROUNDS = tonumber(os.getenv("ROUNDS")) or 12
local CHAOS = tonumber(os.getenv("CHAOS")) or 3000
local OPS = tonumber(os.getenv("OPS")) or 1500

math.randomseed(seed)
dofile(root .. "/orbits/orbits.lua")
init()

local S = require 'orbits/lib/state'
local consts = require 'orbits/lib/consts'
local patterns = require 'orbits/lib/patterns'
local modulation = require 'orbits/lib/modulation'
local NUM_TRACKS = consts.NUM_TRACKS
local ALL_DIV = consts.ALL_DIVISIONS
local SIXTEENTHS, LOOPS = consts.QUANT_SIXTEENTHS, consts.QUANT_LOOPS

-- ---------------------------------------------------------------- helpers ----
local lcg = seed * 7919 + 13
local function rnd(n) lcg = (lcg * 16807) % 2147483647; return (lcg % n) + 1 end
local function chance(p) return rnd(100) <= p end
local function pick(t) return t[rnd(#t)] end

local fails, checks, by_layer = {}, 0, {}
local layer = "?"
local function check(cond, msg)
  checks = checks + 1
  by_layer[layer] = by_layer[layer] or {checks = 0, fails = 0}
  by_layer[layer].checks = by_layer[layer].checks + 1
  if not cond then
    by_layer[layer].fails = by_layer[layer].fails + 1
    fails[#fails + 1] = layer .. ": " .. msg
    if #fails <= 30 then print("FAIL " .. layer .. ": " .. msg) end
  end
end
local function try(label, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then check(false, label .. " raised: " .. tostring(err)) end
  return ok
end

local SIXT = 0.25 * 60 / BPM -- seconds per sixteenth note
local function tap_play() fakepad.key(9, 1, 1); advance(0.02); fakepad.key(9, 1, 0) end
local function align() advance(((math.floor(beats()) + 1) - beats()) * 60 / BPM + 0.001) end
-- every division repeats its grid after 12 beats at most (dotted and triplet
-- ones every 3, straight ones every 4): plays started on a multiple of 12
-- beats see the same grid
local function align12() advance(((math.floor(beats() / 12) + 1) * 12 - beats()) * 60 / BPM + 0.001) end
local function tap(x, y) fakepad.key(x, y, 1); advance(0.01); fakepad.key(x, y, 0) end

-- LED arguments must be whole numbers in range: they become MIDI data bytes
local orig_led, orig_rgb = fakepad.led, fakepad.led_rgb
local function whole(v, lo, hi) return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi end
fakepad.led = function(self, x, y, c)
  if not (whole(x, 1, 9) and whole(y, 1, 9) and whole(c, 0, 127)) then
    check(false, "led(" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(c) .. ")")
  end
  return orig_led(self, x, y, c)
end
fakepad.led_rgb = function(self, x, y, r, g, b)
  if not (whole(x, 1, 9) and whole(y, 1, 9) and whole(r, 0, 127) and whole(g, 0, 127) and whole(b, 0, 127)) then
    check(false, "led_rgb(" .. tostring(x) .. "," .. tostring(y) .. "," .. tostring(r) .. "," .. tostring(g) .. "," .. tostring(b) .. ")")
  end
  return orig_rgb(self, x, y, r, g, b)
end

local function deep_eq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_eq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- gives track t a random live pattern (the loaded one)
local function randomize_live(t, deterministic)
  local trk = S.tracks[t]
  trk.length = rnd(16)
  trk.pulses = rnd(trk.length + 1) - 1
  trk.rotation = rnd(16) - 1
  trk.division = pick(ALL_DIV)
  trk.notes = {}
  for _ = 1, rnd(3) do trk.notes[35 + rnd(30)] = true end
  trk.manual = {}
  for _ = 1, rnd(4) - 1 do
    trk.manual[rnd(16)] = {active = true, accent = chance(40), probability = deterministic and 100 or rnd(100),
                           microtiming = chance(20) and rnd(60) or 0}
  end
  trk.pulse_accents, trk.pulse_probability, trk.pulse_microtiming = {}, {}, {}
  for k = 1, trk.pulses do
    if chance(30) then trk.pulse_accents[k] = true end
    if not deterministic and chance(20) then trk.pulse_probability[k] = rnd(100) end
    if chance(15) then trk.pulse_microtiming[k] = rnd(80) end
  end
  trk.velocity, trk.accent_amount = rnd(128) - 1, rnd(60)
  trk.repeats, trk.repeat_time = pick(consts.REPEATS_VALUES), pick(ALL_DIV)
  trk.ramp, trk.pace = rnd(127) - 64, rnd(127) - 64
  trk.groove, trk.groove_amount, trk.groove_length_index = rnd(8), rnd(128) - 1, rnd(#consts.GROOVE_LENGTHS)
  trk.root_pc, trk.scale_index = rnd(12) - 1, rnd(#consts.SCALES)
  trk.arp_enabled, trk.arp_style, trk.arp_octaves = chance(40), rnd(8), rnd(4)
  if deterministic and trk.arp_style == 5 then trk.arp_style = 3 end -- "random" is random by nature
  trk.phrase_enabled, trk.phrase_type, trk.phrase_range = chance(40), rnd(8), rnd(128) - 1
  trk.random_states = {}
  for _, sl in ipairs(modulation.USER_SLIDERS) do
    if chance(25) then
      modulation.set_modulation_enabled(t, sl, true)
      local r = trk.random_states[sl.id]
      r.amount, r.rate_index = rnd(128) - 1, rnd(6)
    end
  end
end

-- fills nslots random slots of track t with random patterns, loads the first;
-- returns the slot list and each slot's length
local function build_patterns(t, nslots, deterministic)
  local slots, lens, used = {}, {}, {}
  while #slots < nslots do
    local s = rnd(32)
    if not used[s] then used[s] = true; slots[#slots + 1] = s end
  end
  for _, s in ipairs(slots) do
    patterns.do_pattern_switch(t, s)
    randomize_live(t, deterministic)
    lens[s] = S.tracks[t].length
  end
  patterns.do_pattern_switch(t, slots[1])
  return slots, lens
end

-- a random song chain over the given slots, with gaps
local function random_chain(slots)
  local chain, n = {}, rnd(6) + 1
  for _ = 1, n do chain[rnd(16)] = pick(slots) end
  local any = false
  for _ = 1, 16 do if chain[_] then any = true end end
  if not any then chain[rnd(16)] = slots[1] end
  return chain
end

local function next_filled(chain, pos)
  for _ = 1, 16 do
    pos = pos % 16 + 1
    if chain[pos] then return pos end
  end
end

-- first field of a table that is NaN or infinite (a number n is NaN when n ~= n)
local function bad_number(tbl, path)
  for k, v in pairs(tbl) do
    local here = path .. "." .. tostring(k)
    if type(v) == "number" and (v ~= v or v == math.huge or v == -math.huge) then return here .. " = " .. tostring(v) end
    if type(v) == "table" and k ~= "history" then
      local found = bad_number(v, here)
      if found then return found end
    end
  end
end

-- ============================================================ A: timing ====
layer = "A"
print("== A  timing of pattern changes (" .. ROUNDS .. " rounds, 7 tracks each)")

local function run_round(round)
  S.init_tracks(); patterns.init_slots()
  local events, conf = {}, {}
  for t = 1, NUM_TRACKS do events[t] = {} end
  S.on_change = function(info) info.beats = beats(); local e = events[info.t]; e[#e + 1] = info end

  for t = 1, NUM_TRACKS do
    local slots, lens = build_patterns(t, rnd(3) + 2, false)
    local trk = S.tracks[t]
    local c = {slots = slots, lens = lens, start = slots[1], divs = {}}
    for _, s in ipairs(slots) do
      -- a pattern's division is part of the pattern: load it once to read it
      patterns.do_pattern_switch(t, s)
      c.divs[s] = S.tracks[t].division
    end
    patterns.do_pattern_switch(t, slots[1])
    if chance(55) then
      c.kind = "song"
      c.chain = random_chain(slots)
      c.value = rnd(16)
      trk.song_enabled, trk.song_length, trk.song_chain = true, c.value, c.chain
    else
      c.kind = "live"
      c.value = rnd(16)
      trk.quantize = c.value
      c.waiting = nil
    end
    conf[t] = c
  end

  local R = 60 + rnd(240) -- sixteenths to play
  -- a track's clock only notices a new division after its current wait is over
  -- (at most 4 beats): let them all catch up while stopped
  advance(5 * 60 / BPM)
  align()
  tap_play()
  local beats0 = beats() -- play starts when the button is released
  local taps = {}
  for t = 1, NUM_TRACKS do taps[t] = {} end

  for _ = 1, R do
    -- live tracks: at most one tap in flight, so the expected change is unambiguous
    for t = 1, NUM_TRACKS do
      local c, trk = conf[t], S.tracks[t]
      if c.kind == "live" then
        if c.waiting and #events[t] >= c.waiting.n_events + 1 then c.waiting = nil end
        if not c.waiting and chance(7) then
          local slot = pick(c.slots)
          local w = {slot = slot, g = S.groove_pos, step = trk.step, n_events = #events[t], len = trk.length}
          c.waiting = w
          taps[t][#taps[t] + 1] = w
          patterns.queue_pattern_switch(t, slot)
        end
      end
    end
    advance(SIXT)
  end
  local g_end = S.groove_pos
  local final = {}
  for t = 1, NUM_TRACKS do final[t] = {step = S.tracks[t].step} end
  tap_play() -- stop: playing ends when the button is released
  local beats_end = beats()
  S.on_change = nil

  for t = 1, NUM_TRACKS do
    local c, ev = conf[t], events[t]
    local P = c.value <= 8 and SIXTEENTHS[c.value] or nil
    local N = c.value > 8 and LOOPS[c.value - 8] or nil
    local tag = string.format("round %d track %d (%s, value %d)", round, t, c.kind, c.value)

    if c.kind == "song" and P then
      -- boundaries at every multiple of P sixteenths, chain advancing each time
      local pos, cur, k = 0, c.start, 0
      local exp_lo, exp_hi = math.floor((g_end - 1) / P), math.floor((g_end + 1) / P) -- a sixteenth may pass while the stop is pressed
      check(#ev >= exp_lo and #ev <= exp_hi, tag .. ": " .. #ev .. " changes, expected " .. exp_lo .. ".." .. exp_hi)
      for i, e in ipairs(ev) do
        pos = next_filled(c.chain, pos)
        local slot = c.chain[pos]
        check(e.groove_pos == i * P, tag .. ": change " .. i .. " at groove " .. e.groove_pos .. ", expected " .. i * P)
        check(e.song_pos_after == pos and e.pattern_after == slot,
              tag .. ": change " .. i .. " went to position " .. tostring(e.song_pos_after) .. "/pattern " .. tostring(e.pattern_after) .. ", expected " .. pos .. "/" .. slot)
        if slot == cur then check(e.step_after == e.step, tag .. ": same pattern restarted") else check(e.step_after == 0, tag .. ": new pattern did not restart") end
        cur = slot
      end
    elseif c.kind == "song" then
      -- every N loops of the pattern currently playing, counted in the track's
      -- own ticks; tick times follow the division of the pattern playing, and
      -- the first tick after a change of division lands on that division's grid
      local sim, step, cur, pos = {}, 0, c.start, 0
      local function next_tick(b, d) return (math.floor(b / d + 1e-9) + 1) * d end
      local b = next_tick(beats0, c.divs[cur])
      while b <= beats_end + 1e-6 and #sim < 400 do
        local L = c.lens[cur]
        if step > 0 and step % L == 0 and math.floor(step / L) % N == 0 then
          pos = next_filled(c.chain, pos)
          local slot = c.chain[pos]
          sim[#sim + 1] = {beats = b, pos = pos, slot = slot, step = step}
          if slot ~= cur then cur = slot; step = 0 end
        end
        step = step + 1
        b = next_tick(b, c.divs[cur])
      end
      check(#ev == #sim, tag .. ": " .. #ev .. " changes, expected " .. #sim)
      for i = 1, math.min(#ev, #sim) do
        local e, s = ev[i], sim[i]
        check(e.song_pos_after == s.pos and e.pattern_after == s.slot and e.step == s.step,
              tag .. ": change " .. i .. " pos/pattern/step " .. tostring(e.song_pos_after) .. "/" .. tostring(e.pattern_after) .. "/" .. tostring(e.step) ..
              ", expected " .. s.pos .. "/" .. s.slot .. "/" .. s.step)
        check(math.abs(e.beats - s.beats) < 1e-3, tag .. ": change " .. i .. " at beat " .. e.beats .. ", expected " .. s.beats)
      end
    else
      -- live: each tap is answered at the first boundary after it
      local nt = #taps[t]
      for i = 1, #ev do
        local w, e = taps[t][i], ev[i]
        if w then
          local ok_slot = (e.pattern_after == w.slot)
          check(ok_slot, tag .. ": tap " .. i .. " asked " .. w.slot .. " got " .. tostring(e.pattern_after))
          if P then
            local expect = (math.floor(w.g / P) + 1) * P
            check(e.groove_pos == expect, tag .. ": tap " .. i .. " (groove " .. w.g .. ") changed at " .. e.groove_pos .. ", expected " .. expect)
          else
            local L, expect = w.len, w.step
            while not (expect > 0 and expect % L == 0 and math.floor(expect / L) % N == 0) do expect = expect + 1 end
            check(e.step == expect, tag .. ": tap " .. i .. " (step " .. w.step .. ") changed at step " .. e.step .. ", expected " .. expect)
          end
        end
      end
      check(#ev <= nt, tag .. ": more changes (" .. #ev .. ") than taps (" .. nt .. ")")
      -- a tap whose boundary is well before the end must have been answered
      if #ev < nt then
        local w = taps[t][#ev + 1]
        if P then
          local expect = (math.floor(w.g / P) + 1) * P
          check(expect > g_end - 2, tag .. ": tap " .. (#ev + 1) .. " never answered (due at groove " .. expect .. ", ended at " .. g_end .. ")")
        else
          local L, expect = w.len, w.step
          while not (expect > 0 and expect % L == 0 and math.floor(expect / L) % N == 0) do expect = expect + 1 end
          check(expect > final[t].step - 2, tag .. ": tap " .. (#ev + 1) .. " never answered (due at step " .. expect .. ", ended at " .. final[t].step .. ")")
        end
      end
    end
  end
  advance(SIXT * 4)
end

for round = 1, ROUNDS do try("A round " .. round, run_round, round) end

-- ============================================================== B: chaos ====
layer = "B"
print("== B  chaos (" .. CHAOS .. " sixteenths, all pages)")

local TIDY = {
  length = {1, 16}, pulses = {0, 16}, velocity = {0, 127}, accent_amount = {0, 127}, ramp = {-63, 63}, pace = {-63, 63},
  groove = {1, 8}, groove_amount = {0, 127}, root_pc = {0, 11}, scale_index = {1, 16}, arp_style = {1, 8},
  arp_octaves = {1, 4}, phrase_type = {1, 8}, phrase_range = {0, 127}, quantize = {1, 16}, song_length = {1, 16},
  song_pos = {0, 16}, step = {0, math.huge},
}
local REPEATS = {}
for _, v in ipairs(consts.REPEATS_VALUES) do REPEATS[v] = true end
local DIVSET = {}
for _, v in ipairs(ALL_DIV) do DIVSET[v] = true end

local function check_state()
  for t = 1, NUM_TRACKS do
    local trk = S.tracks[t]
    local bad = bad_number(trk, "track " .. t)
    check(bad == nil, "NaN or infinity: " .. tostring(bad))
    for f, r in pairs(TIDY) do
      local v = trk[f]
      check(type(v) == "number" and v >= r[1] and v <= r[2], "track " .. t .. " " .. f .. " = " .. tostring(v))
    end
    check(trk.pulses <= trk.length, "track " .. t .. " pulses " .. trk.pulses .. " > length " .. trk.length)
    check(trk.rotation == math.floor(trk.rotation), "track " .. t .. " rotation not whole")
    check(REPEATS[trk.repeats] == true, "track " .. t .. " repeats " .. tostring(trk.repeats))
    check(DIVSET[trk.division] == true and DIVSET[trk.repeat_time] == true, "track " .. t .. " division / repeat_time off the list")
    check(trk.groove_length_index >= 1 and trk.groove_length_index <= #consts.GROOVE_LENGTHS, "track " .. t .. " groove length index")
    check(trk.current_pattern == nil or (trk.current_pattern >= 1 and trk.current_pattern <= 32), "track " .. t .. " current_pattern")
    check(trk.pending_pattern == nil or (trk.pending_pattern >= 1 and trk.pending_pattern <= 32), "track " .. t .. " pending_pattern")
    for note in pairs(trk.notes) do check(whole(note, 0, 127), "track " .. t .. " note " .. tostring(note)) end
    for slot, snap in pairs(trk.patterns) do
      check(whole(slot, 1, 32) and type(snap) == "table", "track " .. t .. " slot key " .. tostring(slot))
    end
    for pos, slot in pairs(trk.song_chain) do check(whole(pos, 1, 16) and whole(slot, 1, 32), "track " .. t .. " chain " .. tostring(pos) .. "=" .. tostring(slot)) end
    for id, r in pairs(trk.random_states) do
      check(#r.seq == 16 and r.pos >= 1 and r.pos <= 16 and r.rate_index >= 1 and r.rate_index <= 6 and r.amount >= 0 and r.amount <= 127,
            "track " .. t .. " modulation " .. id .. " pos " .. tostring(r.pos) .. " rate " .. tostring(r.rate_index))
    end
    check(#trk.history.undo <= 16 and #trk.history.redo <= 16 + 0, "track " .. t .. " history size")
  end
  check(S.groove_pos >= 0, "groove_pos")
end

-- every pattern change must happen on a legal boundary, to the right pattern
local chaos_changes = 0
local function legal_change(e)
  chaos_changes = chaos_changes + 1
  local tag = "chaos change on track " .. e.t .. " (song " .. tostring(e.song) .. ", value " .. e.value .. ")"
  if e.value <= 8 then
    check(e.groove_pos % SIXTEENTHS[e.value] == 0, tag .. " at groove " .. e.groove_pos .. " is not a boundary of " .. SIXTEENTHS[e.value])
  else
    local L, N = e.length, LOOPS[e.value - 8]
    check(e.step > 0 and e.step % L == 0 and math.floor(e.step / L) % N == 0,
          tag .. " at step " .. e.step .. " (length " .. L .. ") is not a boundary of " .. N .. " loops")
  end
  if e.song then
    local trk = S.tracks[e.t]
    local expect_pos = next_filled(trk.song_chain, e.song_pos)
    if expect_pos then
      check(e.song_pos_after == expect_pos, tag .. ": song position " .. e.song_pos .. " -> " .. tostring(e.song_pos_after) .. ", expected " .. expect_pos)
      check(e.pattern_after == trk.song_chain[e.song_pos_after] or trk.song_chain[e.song_pos_after] == nil, tag .. ": wrong pattern after")
    end
  else
    check(e.pending ~= nil, tag .. " without a pending pattern")
    check(e.pattern_after == e.pending, tag .. ": changed to " .. tostring(e.pattern_after) .. " instead of " .. tostring(e.pending))
  end
  if e.pattern_after == e.pattern then
    check(e.step_after == e.step, tag .. ": same pattern was restarted")
  else
    check(e.step_after == 0, tag .. ": new pattern did not start from the first step")
  end
end

-- a random state: every track with patterns, some in song mode, random settings
S.init_tracks(); patterns.init_slots()
for t = 1, NUM_TRACKS do
  local slots = build_patterns(t, rnd(4) + 1, false)
  local trk = S.tracks[t]
  trk.quantize, trk.song_length = rnd(16), rnd(16)
  trk.song_chain = random_chain(slots)
  trk.song_enabled = chance(50)
end
S.on_change = legal_change

local function random_event()
  local r = rnd(100)
  if r <= 38 then
    local x, y = rnd(9), rnd(9)
    fakepad.key(x, y, 1)
    advance(SIXT * (chance(8) and 6 or 0.2))
    fakepad.key(x, y, 0)
  elseif r <= 52 then
    try("enc", enc, rnd(3), (chance(50) and 1 or -1) * rnd(4))
  elseif r <= 62 then
    local n = rnd(2) + 1
    try("key", key, n, 1); try("key", key, n, 0)
  elseif r <= 70 then
    tap(4 + rnd(4), 9)                          -- a page
  elseif r <= 77 then
    tap(9, 2 + rnd(7) - 1)                      -- a track
  elseif r <= 80 then
    tap_play()
  elseif r <= 84 then
    fakepad.key(9, 1, 1); tap(9, 2 + rnd(7) - 1); advance(SIXT * (chance(50) and 4 or 0.1)); fakepad.key(9, 1, 0) -- mute
  elseif r <= 90 then
    S.page = "session"
    local a = rnd(2)
    fakepad.key(a, 9, 1); tap(rnd(8), 2 + rnd(5)); fakepad.key(a, 9, 0)     -- copy / paste, a pattern or a chain pad
  elseif r <= 94 then
    tap(rnd(2) + 2, 9)                          -- undo / redo
  elseif r <= 96 then
    try("pset", function() params.action_write("x", "n", 1); params.action_read("x", "n", 1) end)
  else
    S.page = pick({"drums", "keys", "user", "session"}); S.redraw_grid()
  end
end

align(); tap_play()
for i = 1, CHAOS do
  for _ = 1, rnd(3) - 1 do random_event() end
  advance(SIXT)
  try("redraw", redraw)
  check_state()
end
if S.playing then tap_play() end
S.on_change = nil
print("   " .. chaos_changes .. " pattern changes seen, " .. checks .. " checks so far")

-- ============================================================= C: history ====
layer = "C"
print("== C  copy / paste / delete / chain / undo / redo (" .. OPS .. " operations)")

S.init_tracks(); patterns.init_slots()
local blank = patterns.fresh_pattern_snapshot()
local function canon(t)
  local trk = S.tracks[t]
  local out = {chain = {}, slots = {}}
  for pos, slot in pairs(trk.song_chain) do out.chain[pos] = slot end
  for slot = 1, 32 do
    local c
    if slot == trk.current_pattern then c = patterns.capture_pattern(t)
    elseif trk.patterns[slot] then c = patterns.deep_copy(trk.patterns[slot]) end
    if c then
      for _, r in pairs(c.random_states or {}) do r.pos, r.step_counter, r.base, r.last = nil, nil, nil, nil end
      -- a loaded pattern always counts as filled, even blank: a blank one is the same as an empty slot
      if not deep_eq(c, blank) then out.slots[slot] = c end
    end
  end
  return out
end
local function describe_diff(a, b)
  local out = {}
  for pos = 1, 16 do
    if a.chain[pos] ~= b.chain[pos] then out[#out + 1] = "chain[" .. pos .. "] " .. tostring(a.chain[pos]) .. " vs " .. tostring(b.chain[pos]) end
  end
  for slot = 1, 32 do
    local x, y = a.slots[slot], b.slots[slot]
    if (x == nil) ~= (y == nil) then
      out[#out + 1] = "slot " .. slot .. (x and " filled" or " empty") .. " vs " .. (y and "filled" or "empty")
    elseif x and not deep_eq(x, y) then
      local fields = {}
      for k, v in pairs(x) do if not deep_eq(v, y[k]) then fields[#fields + 1] = k end end
      for k in pairs(y) do if x[k] == nil then fields[#fields + 1] = k end end
      out[#out + 1] = "slot " .. slot .. " fields " .. table.concat(fields, ",")
    end
  end
  return table.concat(out, "; ")
end
local model = {}
for t = 1, NUM_TRACKS do
  model[t] = {past = {}, future = {}, cur = nil}
  -- some content to start from
  build_patterns(t, rnd(3) + 1, true)
  model[t].cur = canon(t)
end
local function push_past(m, state)
  m.past[#m.past + 1] = state
  if #m.past > 16 then table.remove(m.past, 1) end
  m.future = {}
end
for n = 1, OPS do
  local t, slot = rnd(NUM_TRACKS), rnd(32)
  local trk, m = S.tracks[t], model[t]
  local r = rnd(100)
  if r <= 14 then
    patterns.copy_pattern(t, slot)
  elseif r <= 36 then
    if S.clipboard then
      local before = canon(t)
      patterns.paste_pattern(t, slot)
      push_past(m, before); m.cur = canon(t)
    else
      patterns.paste_pattern(t, slot)
      check(deep_eq(canon(t), m.cur), "paste without clipboard changed something")
    end
  elseif r <= 52 then
    local filled = (slot == trk.current_pattern) or trk.patterns[slot] ~= nil
    local before = canon(t)
    patterns.delete_pattern(t, slot)
    if filled then push_past(m, before) end
    m.cur = canon(t)
  elseif r <= 66 then
    local pos, val = rnd(16), chance(25) and nil or rnd(32)
    local before = canon(t)
    local differs = trk.song_chain[pos] ~= val
    patterns.set_chain(t, pos, val)
    if differs then push_past(m, before) end
    m.cur = canon(t)
  elseif r <= 78 then
    -- not an edit: switching to a filled slot must not change any contents
    local filled = {}
    for sl = 1, 32 do if sl == trk.current_pattern or trk.patterns[sl] then filled[#filled + 1] = sl end end
    slot = pick(filled)
    patterns.do_pattern_switch(t, slot)
    local got = canon(t)
    check(deep_eq(got, m.cur), "op " .. n .. ": switching pattern changed the contents of track " .. t .. ": " .. describe_diff(got, m.cur))
  elseif r <= 90 then
    local expect = table.remove(m.past)
    patterns.undo(t)
    if expect then
      m.future[#m.future + 1] = m.cur; m.cur = expect
    end
    local got = canon(t)
    check(deep_eq(got, m.cur), "op " .. n .. ": undo on track " .. t .. " did not restore the model state: " .. describe_diff(got, m.cur))
  else
    local expect = table.remove(m.future)
    patterns.redo(t)
    if expect then
      m.past[#m.past + 1] = m.cur; m.cur = expect
    end
    local got = canon(t)
    check(deep_eq(got, m.cur), "op " .. n .. ": redo on track " .. t .. " did not restore the model state: " .. describe_diff(got, m.cur))
  end
  check(#trk.history.undo == #m.past and #trk.history.redo == #m.future,
        "op " .. n .. ": history depth " .. #trk.history.undo .. "/" .. #trk.history.redo .. " vs model " .. #m.past .. "/" .. #m.future)
end

-- ============================================================ D: replay ====
layer = "D"
print("== D  stop / play replays the same notes")
local function replay_round(round)
  S.init_tracks(); patterns.init_slots()
  for t = 1, NUM_TRACKS do
    randomize_live(t, true)
    local trk = S.tracks[t]
    for k = 1, 16 do trk.pulse_probability[k] = nil end
    -- repeat spacing with a pace is snapped to a grid of its own, which depends on where the run starts
    trk.pace = 0
    trk.random_states.pace = nil
  end
  advance(5 * 60 / BPM) -- let every track's clock pick up its division (see round A)
  local prev
  for run = 1, 3 do
    align12()
    -- the state a play starts from must be the same every time: say which fields changed
    local now_state = {}
    for t = 1, NUM_TRACKS do
      local c = patterns.deep_copy(S.tracks[t])
      c.history, c.patterns = nil, nil
      now_state[t] = c
    end
    if prev then
      for t = 1, NUM_TRACKS do
        for k, v in pairs(now_state[t]) do
          -- a modulated parameter keeps its last value after a stop: the first tick applies the sequence again
          if k ~= "random_states" and not now_state[t].random_states[k] and not deep_eq(v, prev[t][k]) then
            local detail = ""
            if type(v) == "table" and k == "random_states" then
              for id, r in pairs(v) do
                for f, x in pairs(r) do
                  if f ~= "seq" and prev[t][k][id] and not deep_eq(x, prev[t][k][id][f]) then detail = detail .. " " .. id .. "." .. f .. "=" .. tostring(x) .. "(was " .. tostring(prev[t][k][id][f]) .. ")" end
                end
              end
            elseif type(v) ~= "table" then
              detail = " " .. tostring(v) .. " (was " .. tostring(prev[t][k]) .. ")"
            end
            log("DRIFT", round, run, t, k .. detail)
          end
        end
      end
    end
    prev = now_state
    log("RUN", round, run, beats())
    tap_play()
    for _ = 1, 96 do
      advance(SIXT)
      for t = 1, NUM_TRACKS do
        local bad = bad_number(S.tracks[t], "track " .. t)
        if bad then check(false, "replay round " .. round .. ": NaN or infinity: " .. bad); break end
      end
    end
    tap_play()
    advance(SIXT * 40) -- let the last notes end and the repeats drop
  end
end
for round = 1, 3 do try("D round " .. round, replay_round, round) end

-- ======================================================= F: micro-timing ====
layer = "F"
print("== F  micro-timing: a step with timing m% is delayed by exactly m% of its division")
local micro_cases = {5, 15, 30, 45, 60, 80, 90}
for _, m in ipairs(micro_cases) do
  S.init_tracks(); patterns.init_slots()
  local trk = S.tracks[1]
  trk.length, trk.pulses, trk.division = 8, 8, 1 / 4
  trk.notes = {[40] = true}
  trk.repeats, trk.arp_enabled, trk.phrase_enabled, trk.groove_amount = 0, false, false, 0
  for k = 1, 8 do trk.pulse_microtiming[k] = m end
  for t = 2, NUM_TRACKS do S.tracks[t].mute = true end
  advance(5 * 60 / BPM)
  align12()
  log("MICRO", m, trk.division)
  tap_play()
  advance(SIXT * 48)
  tap_play()
  advance(SIXT * 8)
end

-- ============================================================ final checks ====
layer = "E"
print("== E  notes: ranges, balanced on/off, replays")
advance(SIXT * 400)
local t0
local drift = {}
local micro, micro_cases_seen
out:flush()
local on, off, bad = {}, {}, 0
local runs, cur_run = {}, nil
local last_on_beat, stop_marks = 0, {}
for line in io.lines(arg[3]) do
  local p = {}
  for w in line:gmatch("%S+") do p[#p + 1] = w end
  if p[1] == "RUN" then
    cur_run = p[2] .. ":" .. p[3]
    runs[cur_run] = {}
    runs[#runs + 1] = cur_run
    t0 = tonumber(p[4]) -- every run starts at the same phase of the beat
  elseif p[1] == "NOTE_ON" then
    local name, b, note, vel = p[2], tonumber(p[3]), tonumber(p[4]), tonumber(p[5])
    local key = name .. ":" .. note
    on[key] = (on[key] or 0) + 1
    check(whole(note, 0, 127), "note_on " .. key)
    check(vel and vel >= 0 and vel <= 1, "velocity " .. tostring(vel))
    if micro then
      -- the note must sit m% of a division after the grid line its tick was on
      local frac = (b % micro.d) / micro.d
      check(math.abs(frac - micro.m / 100) < 0.004 or math.abs(frac - micro.m / 100) > 0.996,
            string.format("micro-timing %d%%: note at %.4f of a division, expected %.2f", micro.m, frac, micro.m / 100))
    end
    if cur_run then
      local rel = math.floor((b - t0) * 1000 + 0.5) / 1000 -- t0: the run's start, same phase every time
      runs[cur_run][#runs[cur_run] + 1] = name .. "@" .. rel .. ":" .. note .. ":" .. vel
    end
  elseif p[1] == "NOTE_OFF" then
    local key = p[2] .. ":" .. p[4]
    off[key] = (off[key] or 0) + 1
  elseif p[1] == "MICRO" then
    micro = {m = tonumber(p[2]), d = tonumber(p[3])}
    micro_cases_seen = (micro_cases_seen or 0) + 1
    cur_run = nil
  elseif p[1] == "DRIFT" then
    drift[#drift + 1] = line
  elseif p[1] == "CLOCK-ERR" then
    check(false, "clock error: " .. line)
  elseif p[1] == "ERR" then
    check(false, "error: " .. line)
  end
end
for key, n in pairs(on) do check(off[key] == n, "note " .. key .. ": " .. n .. " on, " .. tostring(off[key]) .. " off (stuck or extra)") end
for key, n in pairs(off) do check(on[key] ~= nil, "note_off without note_on: " .. key) end
for i = 1, math.min(#drift, 12) do print("   state at play start changed: " .. drift[i]) end
-- the three plays of each replay round must be the same
for round = 1, 3 do
  local a, b, c = runs[round .. ":1"], runs[round .. ":2"], runs[round .. ":3"]
  if a and b and c then
    check(#a > 0, "replay round " .. round .. ": no notes at all")
    table.sort(a); table.sort(b); table.sort(c)
    local why = ""
    local function only_in(x, y)
      local count, out = {}, {}
      for _, v in ipairs(y) do count[v] = (count[v] or 0) + 1 end
      for _, v in ipairs(x) do
        if (count[v] or 0) > 0 then count[v] = count[v] - 1 else out[#out + 1] = v end
      end
      return out
    end
    local only_a, only_b = only_in(a, b), only_in(b, a)
    if #only_a + #only_b > 0 then
      why = " | only in first: " .. table.concat(only_a, " ", 1, math.min(4, #only_a)) .. " | only in second: " .. table.concat(only_b, " ", 1, math.min(4, #only_b))
    end
    check(deep_eq(a, b), "replay round " .. round .. ": second play differs from the first (" .. #a .. " vs " .. #b .. " notes)" .. why)
    check(deep_eq(b, c), "replay round " .. round .. ": third play differs from the second")
  end
end

-- ================================================================ summary ====
print("")
local names = {}
for k in pairs(by_layer) do names[#names + 1] = k end
table.sort(names)
for _, k in ipairs(names) do
  print(string.format("   %s: %d checks, %d failed", k, by_layer[k].checks, by_layer[k].fails))
end
print(string.format("%s  seed %d: %d checks, %d failed", #fails == 0 and "PASS" or "FAIL", seed, checks, #fails))
out:close()
os.exit(#fails == 0 and 0 or 1)
