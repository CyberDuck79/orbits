-- state: Shared mutable state. Every module that needs it requires this table
-- and reads/writes its fields directly (S.page, S.playing, ...); `tracks` and
-- `current_subpage` are also exposed as plain locals since they are never
-- reassigned. `redraw_grid` / `redraw_screen` are hooks the leds and display
-- modules fill in when they load, so lower layers can ask for a redraw without
-- requiring them.

local consts = require 'orbits/lib/consts'
local BASE_NOTE, DEFAULT_DIVISION = consts.BASE_NOTE, consts.DEFAULT_DIVISION
local DEFAULT_GROOVE_LENGTH_INDEX = consts.DEFAULT_GROOVE_LENGTH_INDEX
local NUM_TRACKS = consts.NUM_TRACKS

local S = {
  pad = nil,
  tracks = {},
  selected_track = 1,
  page = "drums", -- "drums" | "keys" | "user" | "session"
  current_subpage = {drums = 1, keys = 1, user = 1, session = 1},
  playing = false,
  play_epoch = 0, -- bumped on every start/stop, so in-flight repeat/arp bursts from a previous run can tell they're stale
  shift_held = false,
  shift_used = false,
  -- temporary pages: a held button takes over the screen (and later the pads)
  -- for as long as it's held, like the T1's [CTRL]. Same e2/k2/e3/k3 contract
  -- as the screen sub-pages, so both render through the same code.
  active_temp_page = nil, -- key into temp_pages while its button is held
  temp_page_used = false, -- true once a control on the held page has been touched
  selected_step = nil, -- 1..16, set while editing a step's active/accent state
  last_slider = nil, -- index into USER_SLIDERS, so the screen can name the slider you just moved
  pulse_phase = false,
  logo_on = false, -- flashes on the beat, independent of any track's own division
  groove_pos = 0, -- 16th-notes elapsed since playback started; drives the accent groove phase, shared by all tracks
  hold_metro = nil,
  mute_hold_metro = nil,
  pulse_metro = nil,
  hold_pending = nil, -- step index currently being timed for long-press
  session_hold_pending = nil, -- pattern slot currently being timed for long-press (duplicate/copy-mode gesture)
  delete_armed = nil, -- {track=, slot=}: a long-pressed pattern waiting to be tapped (delete) or cancelled
  clipboard = nil, -- {snap=, track=, slot=}: the copied pattern, shared by every track
  copy_flash = nil, -- {track=, slot=}: the pattern just copied, flashing briefly to confirm it
  flash_metro = nil, -- one-shot timer that ends the flash
  arrow_held = nil, -- 1 (copy) or 2 (paste) while that Session-page arrow is held
  chain_hold_pending = nil, -- chain step currently being timed for long-press (clear gesture)
  chain_edit_pos = nil, -- chain step armed for assignment; next pattern tap fills it
  mute_hold_pending = nil, -- track number currently being timed for shift+scene hold

  -- hooks: filled in by leds.lua / display.lua when they load
  redraw_grid = function() end,
  redraw_screen = function() end,
}

local tracks = S.tracks

function S.init_tracks()
  for t = 1, NUM_TRACKS do
    tracks[t] = {
      length = 8,
      pulses = 4,
      rotation = 0,
      division = DEFAULT_DIVISION, -- this track's own clock rate, in clock.sync() beats
      step = 0, -- this track's own free-running position, advances at its own division
      octave = 0, -- which octave the keyboard is currently viewing (display only)
      notes = {[BASE_NOTE] = true}, -- set of selected MIDI notes (chord), independent of the view
      manual = {}, -- manual[step] = {active=bool, accent=bool}: hand-added steps, on top of the Euclidean pattern
      pulse_accents = {}, -- pulse_accents[pulse_index] = bool: accent for the Nth generated pulse, follows that pulse across length/rotation/density changes
      pulse_probability = {}, -- pulse_probability[pulse_index] = 0-100
      pulse_microtiming = {}, -- pulse_microtiming[pulse_index] = 0-90 (% of the track's division, delay only)
      velocity = 100, -- 0-127, base velocity for non-accented hits
      accent_amount = 27, -- added to velocity for accented hits, clamped to 127
      mute = false, -- latched mute
      momentary_mute = false, -- held mute (shift+scene held past the threshold)

      repeats = 0, -- note repeater: extra triggers per step, 0 = off
      repeat_time = DEFAULT_DIVISION, -- spacing between repeats, in clock.sync() beats
      ramp = 0, -- -63..63: how repeat velocity rises/falls across the series
      pace = 0, -- -63..63: how repeat timing speeds up/slows down across the series

      groove = 1, -- index into GROOVES
      groove_amount = 0, -- 0-127: how strongly the groove's velocity curve is applied
      groove_length_index = DEFAULT_GROOVE_LENGTH_INDEX, -- index into GROOVE_LENGTHS (bars)

      root_pc = 0, -- scale root, pitch class 0-11 (0 = C)
      scale_index = 1, -- index into SCALES/SCALE_NAMES

      arp_enabled = false,
      arp_style = 1, -- index into ARP_STYLES
      arp_octaves = 1, -- 1-4: how many octaves the arp sequence spans
      arp_pos = 0, -- position in the current arp sequence, advances every triggered hit

      phrase_enabled = false,
      phrase_type = 1, -- index into PHRASE_TYPES
      phrase_range = 0, -- 0-127: how far the phrase contour shifts pitch (0 = none, 127 = up to an octave)

      -- random_states[fader id] = {enabled, amount, rate_index, seq, pos,
      -- step_counter, base, last}: each fader keeps its own modulation, so
      -- selecting another fader on the User page doesn't disturb it, and
      -- several can run at once even though only the selected one is shown
      -- on E2/K2/E3/K3 (see modulation.lua).
      random_states = {},

      -- Session-page undo/redo: entries {kind="slot"|"chain", ..., before=, after=}
      history = {undo = {}, redo = {}},

      patterns = {}, -- patterns[1..32] = a captured snapshot (see PATTERN_FIELDS), or nil if unused
      current_pattern = nil, -- slot currently loaded
      pending_pattern = nil, -- slot queued to load at the next quantize boundary
      pattern_quantize = 8, -- index into ALL_DIVISIONS; defaults to the smallest (near-immediate)

      -- song chain: a track-level arrangement (like voice/mute, not part of
      -- any one pattern) that auto-advances through pattern slots
      song_chain = {}, -- song_chain[1..16] = a pattern slot number, or nil
      song_pos = 0,
      song_enabled = false,
    }
  end
end

return S
