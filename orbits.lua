-- orbits: 7-track Euclidean sequencer for the Launchpad Mini MK3, driven by
-- the lp3 mod. Euclidean patterns with sticky manual overrides, accent,
-- per-step probability and micro-timing, per-track clock division, note
-- repeater, accent grooves, a chromatic keyboard with scale constraint,
-- arpeggiator and melodic phrases, random modulation of the rhythm
-- parameters, and a Session page for patterns and song chaining. Each track
-- plays through its own nb voice. The screen sub-page system (E1 cycles the
-- sub-pages of the current grid page; each assigns E2/K2/E3/K3) carries
-- everything that doesn't fit on pads.
--
-- This file only wires things together: the code lives in lib/ (see
-- docs/ARCHITECTURE.md). Requires the "lp3" mod (SYSTEM > MODS > LP3).

-- Modules are loaded with require, which norns caches across script loads:
-- drop ours first so relaunching the script always runs the files on disk.
for name in pairs(package.loaded) do
  if name:find('^orbits/') then package.loaded[name] = nil end
end

local lp3 = require 'lp3/lib/mod'
local nb = include('orbits/lib/nb/lib/nb')

local S = require 'orbits/lib/state'
local consts = require 'orbits/lib/consts'
local patterns = require 'orbits/lib/patterns'
local engine = require 'orbits/lib/engine'
local input = require 'orbits/lib/input'
local leds = require 'orbits/lib/leds'
local display = require 'orbits/lib/display'
local controls = require 'orbits/lib/controls'
local splash = require 'orbits/lib/splash'

-- norns calls these globals
redraw = display.redraw
enc = controls.enc
key = controls.key

function init()
  nb:init()
  params:add_separator("ORBITS")
  for t = 1, consts.NUM_TRACKS do
    nb:add_param("voice_t" .. t, "T" .. t .. " OUTPUT")
  end
  params:add_separator("VOICE CONTROLS")
  nb:add_player_params()

  S.init_tracks()
  patterns.init_slots()
  patterns.install_persistence()

  input.create_timers()
  leds.start_blink()

  S.pad = lp3.new()
  S.pad.key = input.on_key
  S.pad.status = function() S.redraw_screen() end

  -- connect() returns false while no Launchpad is plugged in, but lp3 keeps
  -- waiting and connects it as soon as it appears: keep initialising, the
  -- LED buffer is sent at that point
  S.pad:connect()

  S.pad:set_brightness(100)
  S.pad:all(0)
  S.redraw_grid()

  engine.start_sequencer()
  splash.start() -- draws the first frame
end

function cleanup()
  splash.free()
  input.free_timers()
  leds.stop_blink()
  if S.pad then
    S.pad:all(0)
    S.pad:refresh()
    S.pad:disconnect()
  end
end
