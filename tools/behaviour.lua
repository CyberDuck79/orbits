-- Behaviour tests for pattern changes (quantize / song length / chain). Not a
-- standalone file: tools/behaviour.sh appends it to the stubs and virtual clock
-- of tools/harness.lua and runs it on the norns.
math.randomseed(1)
dofile(root .. "/orbits/orbits.lua")
init()
local S = require 'orbits/lib/state'
local patterns = require 'orbits/lib/patterns'
local trk = S.tracks[1]
local function check(name, cond, extra) print((cond and "ok   " or "FAIL ") .. name .. (extra and ("  " .. extra) or "")) end
local function tap_play() fakepad.key(9, 1, 1); advance(0.05); fakepad.key(9, 1, 0) end
local function align() advance(((math.floor(beats()) + 1) - beats()) * 60 / BPM + 0.001) end

-- patterns 2 and 3 are 5 steps long, all active; 2 is loaded
local function setup()
  S.init_tracks(); patterns.init_slots(); trk = S.tracks[1]
  local function five() trk.length, trk.pulses = 5, 5 end
  five()
  patterns.do_pattern_switch(1, 2); five(); trk.notes = {[40] = true}
  patterns.do_pattern_switch(1, 3); five(); trk.notes = {[50] = true}
  patterns.do_pattern_switch(1, 2)
  S.page = "session"
end
-- plays n sixteenths and returns "pattern:step" after each (tick k = the k-th sixteenth)
local function run(n)
  align(); tap_play()
  local out = {}
  for _ = 1, n do advance(0.125); out[#out + 1] = trk.current_pattern .. ":" .. trk.step end
  tap_play()
  return out
end
local function first_change(list, from_pattern)
  for i, v in ipairs(list) do if not v:find("^" .. from_pattern .. ":") then return i, v end end
end

setup(); trk.song_enabled = true; trk.song_length = 9; trk.song_chain = {2, 2, 3}
local r = run(40)
local i, v = first_change(r, 2)
check("song 1 loop: a repeated pattern is not restarted", r[13] == "2:13" and r[14] == "2:14" and r[15] == "2:15")
check("song 1 loop: pattern 3 after 3 loops, from its first step", i == 16 and v == "3:1", "tick " .. tostring(i))

setup(); trk.song_enabled = true; trk.song_length = 10; trk.song_chain = {2, 3}
i = first_change(run(40), 2)
check("song 2 loops: pattern 3 after 2 x 2 loops", i == 21, "tick " .. tostring(i))

setup(); trk.song_enabled = true; trk.song_length = 4; trk.song_chain = {2, 3}
i = first_change(run(60), 2)
check("song 1 bar: pattern 3 at the second bar", i == 32, "tick " .. tostring(i))

setup(); trk.quantize = 4
align(); tap_play()
for _ = 1, 5 do advance(0.125) end
patterns.queue_pattern_switch(1, 3)
check("live tap is queued while playing", trk.pending_pattern == 3 and trk.current_pattern == 2)
local at
for k = 1, 20 do advance(0.125); if trk.current_pattern == 3 and not at then at = k + 5 end end
tap_play()
check("live tap, 1 bar: switches at the bar", at == 16, "tick " .. tostring(at))

setup(); trk.quantize = 9
align(); tap_play()
for _ = 1, 2 do advance(0.125) end
patterns.queue_pattern_switch(1, 3)
at = nil
for k = 1, 12 do advance(0.125); if trk.current_pattern == 3 and not at then at = k + 2 end end
tap_play()
check("live tap, 1 loop: switches when the 5-step loop ends", at == 6, "tick " .. tostring(at))

setup(); trk.song_enabled = true; trk.song_chain = {2}
fakepad.key(5, 5, 1); fakepad.key(5, 5, 0)
check("song mode: tapping a pattern does nothing", trk.pending_pattern == nil and trk.current_pattern == 2)

setup(); trk.step = 3
patterns.do_pattern_switch(1, 2)
check("switching to the loaded pattern keeps the step", trk.step == 3)

setup()
fakepad.key(4, 8, 1); fakepad.key(4, 8, 0)
check("song off: the pad row sets quantize", trk.quantize == 4 and trk.song_length == 4)
trk.song_enabled = true
fakepad.key(2, 7, 1); fakepad.key(2, 7, 0)
check("song on: the same pads set the song length", trk.song_length == 10 and trk.quantize == 4)
out:close()
