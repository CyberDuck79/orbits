-- lp3seq: 7-track Euclidean sequencer for the Launchpad Mini MK3, driven by
-- the lp3 mod. Euclidean patterns with sticky manual overrides, per-step
-- accent, chords, per-track nb (engine or MIDI) output, and a generic
-- screen sub-page system (E1 cycles sub-pages of the current grid page;
-- each sub-page independently assigns E2/K2/E3/K3, or leaves them unused).
--
-- Requires the "lp3" mod (SYSTEM > MODS > LP3) to be enabled.

-- Modules are loaded with require, which norns caches across script loads:
-- drop ours first so relaunching the script always runs the files on disk.
for name in pairs(package.loaded) do
  if name:find('^lp3seq/') then package.loaded[name] = nil end
end

local lp3 = require 'lp3/lib/mod'
local nb = include('lp3seq/lib/nb/lib/nb')
local S = require 'lp3seq/lib/state'
local tracks = S.tracks
local consts = require 'lp3seq/lib/consts'
local NUM_TRACKS = consts.NUM_TRACKS
local patterns = require 'lp3seq/lib/patterns'
local apply_pattern, capture_pattern = patterns.apply_pattern, patterns.capture_pattern
local deep_copy = patterns.deep_copy
local engine = require 'lp3seq/lib/engine'
local start_sequencer = engine.start_sequencer
local input = require 'lp3seq/lib/input'
local on_key = input.on_key

-- these three register themselves with the shared state (redraw hooks)
-- and provide the norns callbacks
local leds = require 'lp3seq/lib/leds'
local display = require 'lp3seq/lib/display'
local controls = require 'lp3seq/lib/controls'

redraw = display.redraw
enc = controls.enc
key = controls.key

function init()
  nb:init()
  params:add_separator("LP3SEQ")
  for t = 1, NUM_TRACKS do
    nb:add_param("voice_t" .. t, "T" .. t .. " OUTPUT")
  end
  params:add_separator("VOICE CONTROLS")
  nb:add_player_params()

  S.init_tracks()

  -- slot 1 starts out holding each track's default state, so Session isn't
  -- blank on first use and there's always something to fall back to
  for t = 1, NUM_TRACKS do
    tracks[t].patterns[1] = capture_pattern(t)
    tracks[t].current_pattern = 1
  end

  -- Patterns/chains live outside the params system (they're not flat
  -- scalars pset can serialize), so PSET SAVE/LOAD gets a sidecar file
  -- alongside the .pset, the same technique n.kria uses for its own
  -- pattern data. Tempo and voice assignments still go through the normal
  -- params/pset mechanism untouched.
  params.action_write = function(filename, name, pset_number)
    -- sync each track's live edits into its active slot first, so a save
    -- never loses whatever you were in the middle of doing
    for t = 1, NUM_TRACKS do
      local trk = tracks[t]
      if trk.current_pattern then
        trk.patterns[trk.current_pattern] = capture_pattern(t)
      end
    end
    local data = {}
    for t = 1, NUM_TRACKS do
      local trk = tracks[t]
      data[t] = {
        patterns = deep_copy(trk.patterns),
        current_pattern = trk.current_pattern,
        pattern_quantize = trk.pattern_quantize,
        song_chain = deep_copy(trk.song_chain),
        song_enabled = trk.song_enabled,
      }
    end
    tab.save(data, filename .. ".lp3seqdata")
  end

  params.action_read = function(filename, name, pset_number)
    local patternfile = filename .. ".lp3seqdata"
    if util.file_exists(patternfile) then
      local data = tab.load(patternfile)
      if data then
        for t = 1, NUM_TRACKS do
          local d = data[t]
          local trk = tracks[t]
          if d then
            trk.patterns = d.patterns or {}
            trk.current_pattern = d.current_pattern
            trk.pattern_quantize = d.pattern_quantize or 8
            trk.song_chain = d.song_chain or {}
            trk.song_enabled = d.song_enabled or false
            if trk.current_pattern and trk.patterns[trk.current_pattern] then
              apply_pattern(t, trk.patterns[trk.current_pattern])
            end
          end
        end
      end
    end
    S.redraw_grid()
  end

  S.hold_metro = metro.init(function() end, 0.45, 1)
  S.mute_hold_metro = metro.init(function() end, 0.3, 1)
  S.pulse_metro = metro.init(function()
    S.pulse_phase = not S.pulse_phase
    local needs_redraw = S.selected_step ~= nil or S.copy_mode_active or S.chain_edit_pos ~= nil
      or (S.page == "user" and S.last_slider ~= nil)
    if not needs_redraw then
      for t = 1, NUM_TRACKS do
        if tracks[t].momentary_mute or tracks[t].pending_pattern then
          needs_redraw = true
          break
        end
      end
    end
    if needs_redraw then S.redraw_grid() end
  end, 0.25)
  S.pulse_metro:start()

  S.pad = lp3.new()
  S.pad.key = on_key
  S.pad.status = function() S.redraw_screen() end

  -- connect() returns false while no Launchpad is plugged in, but lp3 keeps
  -- waiting and connects it as soon as it appears: keep initialising, the
  -- LED buffer is sent at that point
  S.pad:connect()

  S.pad:set_brightness(100)
  S.pad:all(0)
  S.redraw_grid()

  start_sequencer()
  S.redraw_screen()
end

function cleanup()
  if S.hold_metro then metro.free(S.hold_metro.id) end
  if S.mute_hold_metro then metro.free(S.mute_hold_metro.id) end
  if S.pulse_metro then metro.free(S.pulse_metro.id) end
  if S.pad then
    S.pad:all(0)
    S.pad:refresh()
    S.pad:disconnect()
  end
end
