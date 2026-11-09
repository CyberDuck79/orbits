-- lp3seq: 7-track Euclidean sequencer for the Launchpad Mini MK3, driven by
-- the lp3 mod. Euclidean patterns with sticky manual overrides, per-step
-- accent, chords, per-track nb (engine or MIDI) output, and a generic
-- screen sub-page system (E1 cycles sub-pages of the current grid page;
-- each sub-page independently assigns E2/K2/E3/K3, or leaves them unused).
--
-- Requires the "lp3" mod (SYSTEM > MODS > LP3) to be enabled.

local lp3 = require 'lp3/lib/mod'
local euclid = include('lp3seq/lib/euclid')
local nb = include('lp3seq/lib/nb/lib/nb')

local NUM_TRACKS = 7
local BASE_NOTE = 36 -- C2
local NATURAL_OFFSETS = {0, 2, 4, 5, 7, 9, 11, 12} -- C D E F G A B C, x=1..8 on y=7
local SHARP_OFFSETS = {nil, 1, 3, nil, 6, 8, 10, nil} -- _ C# D# _ F# G# A# _, x=1..8 on y=8 (shifted right, between naturals)

local AMBER = {127, 60, 0} -- generated (Euclidean) pulse
local DIM = {24, 24, 24} -- dim white: inactive, reactivatable by a generated pulse landing here
local MANUAL = {0, 90, 127} -- cyan: manually-added step (not part of the Euclidean pattern)
local RED = {127, 0, 0}

-- one hue per parameter "type", shared between its pad-selector row(s) and
-- (via scale_color, see draw_user_page) its User-page slider -- spread
-- around the color wheel so params that ever appear on-grid together stay
-- visually distinct, and consistent across pages for the same param
local DIVISION_SELECTED = {0, 127, 127} -- cyan: the selected division/repeat-time for a track
local REPEATS_SELECTED = {127, 0, 0} -- red: the selected repeat count (also rpt ramp/pace on User)
local GROOVE_SELECTED = {102, 0, 127} -- violet: the selected accent groove (also grv amt/len on User)

-- per-track clock division, in clock.sync() beats (1 beat = 1 quarter note).
-- row y=6 (straight, always visible under the pattern): whole note down to
-- 128th. row y=5 (dotted/triplet): dotted quarter..32nd, then triplet
-- eighth..64th. Both rows are geometric (halving left to right) so the
-- speed direction stays learnable even without on-pad labels.
local DIVISIONS_STRAIGHT = {4, 2, 1, 1 / 2, 1 / 4, 1 / 8, 1 / 16, 1 / 32}
local DIVISIONS_STRAIGHT_LABELS = {"1/1", "1/2", "1/4", "1/8", "1/16", "1/32", "1/64", "1/128"}
local DIVISIONS_OTHER = {3 / 2, 3 / 4, 3 / 8, 3 / 16, 1 / 3, 1 / 6, 1 / 12, 1 / 24}
local DIVISIONS_OTHER_LABELS = {"1/4.", "1/8.", "1/16.", "1/32.", "1/8t", "1/16t", "1/32t", "1/64t"}
local DEFAULT_DIVISION = DIVISIONS_STRAIGHT[5] -- 1/16, matches the previous fixed global rate

local function div_label(d)
  for i, v in ipairs(DIVISIONS_STRAIGHT) do
    if v == d then return DIVISIONS_STRAIGHT_LABELS[i] end
  end
  for i, v in ipairs(DIVISIONS_OTHER) do
    if v == d then return DIVISIONS_OTHER_LABELS[i] end
  end
  return "?"
end

-- Note Repeater: extra triggers layered on top of each active step, still
-- following the track's own notes/velocity. Repeats = how many (0 = off,
-- capped at 8 rather than the T1's 48 -- that's more than this needs).
-- Ramp/Pace reshape velocity/timing across the repeat series and live on
-- the "repeat shape" screen sub-page instead of the grid.
local REPEATS_VALUES = {0, 1, 2, 3, 4, 5, 6, 7}

local function repeats_label(n)
  return n == 0 and "off" or tostring(n) .. "x"
end

-- Accent: an 8-shape velocity groove (from the T1's current 8-groove set),
-- applied at a track-wide amount over a repeating length in bars.
local GROOVES = {"agogo", "timbales", "congas", "bongo", "saw", "triangle", "sine", "pulse"}
local GROOVE_LENGTHS = {1, 2, 4, 8, 16, 32, 64}
local DEFAULT_GROOVE_LENGTH_INDEX = 3 -- 4 bars, matches the T1's default

local ROOT_COLOR = {127, 64, 0} -- orange: the selected root pitch class
local SCALE_SELECTED = {0, 60, 127} -- blue: the selected scale
local OUT_OF_SCALE = {5, 5, 15} -- near-black blue: unavailable, can't be selected while a scale is active
local ARP_SELECTED = {0, 127, 51} -- spring green: the selected arp style (also arp oct on User)
local PHRASE_SELECTED = {102, 127, 0} -- yellow-green: the selected phrase type (also phr rng on User)
local VELOCITY_COLOR = AMBER -- same amber as an active step: velocity is the base step hit
local ACCENT_COLOR = AMBER -- same amber as an active step: accent is a boost on top of it
local PATTERN_SAVED = {0, 60, 0} -- dim green: a pattern slot with data
local PATTERN_ACTIVE = {0, 127, 0} -- bright green: the currently loaded slot
local CHAIN_STEP = {70, 70, 0} -- dim yellow: a filled song-chain step
local CHAIN_STEP_ACTIVE = {127, 127, 0} -- bright yellow: the chain step currently playing

local PC_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

-- 16 real scales (semitones from root). Chromatic first (= default, no
-- constraint), then diatonic modes, then a few common extras, then two
-- Japanese pentatonics.
local SCALE_NAMES = {
  "chrom", "major", "dorian", "phryg", "lydian", "mixo", "minor",
  "locr", "harm m", "mel m", "majpnt", "minpnt", "blues",
  "whole", "insen", "hirajo",
}
local SCALES = {
  {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}, -- chromatic
  {0, 2, 4, 5, 7, 9, 11}, -- major
  {0, 2, 3, 5, 7, 9, 10}, -- dorian
  {0, 1, 3, 5, 7, 8, 10}, -- phrygian
  {0, 2, 4, 6, 7, 9, 11}, -- lydian
  {0, 2, 4, 5, 7, 9, 10}, -- mixolydian
  {0, 2, 3, 5, 7, 8, 10}, -- minor (aeolian)
  {0, 1, 3, 5, 6, 8, 10}, -- locrian
  {0, 2, 3, 5, 7, 8, 11}, -- harmonic minor
  {0, 2, 3, 5, 7, 9, 11}, -- melodic minor
  {0, 2, 4, 7, 9}, -- major pentatonic
  {0, 3, 5, 7, 10}, -- minor pentatonic
  {0, 3, 5, 6, 7, 10}, -- blues
  {0, 2, 4, 6, 8, 10}, -- whole tone
  {0, 1, 5, 7, 10}, -- in sen
  {0, 2, 3, 7, 8}, -- hirajoshi
}

-- Arp (Style): which of the selected notes plays on each pulse, and in what
-- order. Not enumerated in the T1 docs (unlike Groove) -- invented, same as
-- the percussion grooves.
local ARP_STYLES = {"up", "down", "up-down", "down-up", "random", "as played", "converge", "diverge"}

-- Phrase: melodic contour shape for Range & Phrase, invented (not enumerated
-- in the T1 docs, like Style). Shifts the played pitch over the pattern's
-- own cycle, scaled by Range, then snaps back into the current scale.
local PHRASE_TYPES = {"static", "rise", "fall", "arch", "valley", "zigzag", "random walk", "cascade"}

-- blend a colour toward white by `amt` (0-1), keeping its hue recognisable
local function brighten(c, amt)
  return {
    math.floor(c[1] + (127 - c[1]) * amt),
    math.floor(c[2] + (127 - c[2]) * amt),
    math.floor(c[3] + (127 - c[3]) * amt),
  }
end

local function scale_color(c, factor)
  return {math.floor(c[1] * factor), math.floor(c[2] * factor), math.floor(c[3] * factor)}
end

local pad
local tracks = {}
local selected_track = 1
local page = "drums" -- "drums" | "keys" | "user" | "session"
local current_subpage = {drums = 1, keys = 1, user = 1, session = 1}
local STEP_SUBPAGE = 1 -- index of the "step" sub-page within subpages.drums
local playing = false
local play_epoch = 0 -- bumped on every start/stop, so in-flight repeat/arp bursts from a previous run can tell they're stale
local shift_held = false
local shift_used = false
-- temporary pages: a held button takes over the screen (and later the pads)
-- for as long as it's held, like the T1's [CTRL]. Same e2/k2/e3/k3 contract
-- as the screen sub-pages, so both render through the same code.
local active_temp_page = nil -- key into temp_pages while its button is held
local temp_page_used = false -- true once a control on the held page has been touched
local selected_step = nil -- 1..16, set while editing a step's active/accent state
local last_slider = nil -- index into USER_SLIDERS, so the screen can name the slider you just moved
local pulse_phase = false
local logo_on = false -- flashes on the beat, independent of any track's own division
local groove_pos = 0 -- 16th-notes elapsed since playback started; drives the accent groove phase, shared by all tracks
local hold_metro, mute_hold_metro, pulse_metro
local hold_pending = nil -- step index currently being timed for long-press
local session_hold_pending = nil -- pattern slot currently being timed for long-press (duplicate/copy-mode gesture)
local copy_mode_active = false -- armed by long-pressing the active pattern; next pattern tap pastes
local copy_mode_source = nil -- {track=, slot=} captured when copy mode was armed
local chain_hold_pending = nil -- chain step currently being timed for long-press (clear gesture)
local chain_edit_pos = nil -- chain step armed for assignment; next pattern tap fills it
local mute_hold_pending = nil -- track number currently being timed for shift+scene hold

local function init_tracks()
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

      -- random_states[target_id] = {enabled, amount, rate_index, seq, pos,
      -- step_counter, base}: each target keeps its own settings, so
      -- switching the K1 focus between parameters doesn't disturb them, and
      -- more than one can run at once even though only the focused one is
      -- shown on E2/K2/E3/K3.
      random_states = {},

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

-- root note of the currently viewed keyboard octave for a track (display + note entry)
local function view_root(t)
  return BASE_NOTE + 12 * tracks[t].octave
end

local function note_in_scale(t, note)
  local trk = tracks[t]
  local pc = (note - trk.root_pc) % 12
  for _, s in ipairs(SCALES[trk.scale_index]) do
    if s == pc then return true end
  end
  return false
end

-- toggling off is always allowed (so you can always clear a note); toggling
-- on is blocked for out-of-scale notes, same as the T1 disabling those keys
local function toggle_note(t, note)
  local trk = tracks[t]
  if trk.notes[note] then
    trk.notes[note] = nil
  elseif note_in_scale(t, note) then
    trk.notes[note] = true
  end
end

-- moves a note to the nearest in-scale note (ties favour the lower note)
local function nearest_in_scale_note(t, note)
  if note_in_scale(t, note) then return note end
  for d = 1, 12 do
    if note_in_scale(t, note - d) then return note - d end
    if note_in_scale(t, note + d) then return note + d end
  end
  return note
end

-- called whenever root or scale changes: keeps already-selected notes
-- musically valid instead of silently leaving them out-of-scale
local function snap_notes_to_scale(t)
  local trk = tracks[t]
  local new_notes = {}
  for note, _ in pairs(trk.notes) do
    new_notes[nearest_in_scale_note(t, note)] = true
  end
  trk.notes = new_notes
end

-- change which octave is displayed/edited; does not touch any selected note's pitch
local function shift_octave_view(t, delta)
  local trk = tracks[t]
  trk.octave = util.clamp(trk.octave + delta, -3, 6)
end

-- actually transpose the selected notes (chord shape moves); the keyboard
-- view stays put, so the moved highlights are visible
local function transpose_notes(t, delta)
  local trk = tracks[t]
  local new_notes = {}
  for note, _ in pairs(trk.notes) do
    new_notes[util.clamp(note + delta, 0, 127)] = true
  end
  trk.notes = new_notes
end

local function track_pattern(t)
  local trk = tracks[t]
  local p = euclid.pattern(trk.length, trk.pulses)
  return euclid.rotate(p, trk.rotation)
end

-- maps grid positions to their place in the current Euclidean pattern:
-- positions[k] = the grid step of the k-th generated pulse (in order), and
-- index_at[i] = k for that same position. This is what lets a pulse's own
-- parameters (like accent) follow it across length/pulses/rotation changes,
-- instead of being pinned to a grid position.
local function pulse_index_map(t)
  local trk = tracks[t]
  local pattern = track_pattern(t)
  local positions = {}
  local index_at = {}
  for i = 1, trk.length do
    if pattern[i] then
      table.insert(positions, i)
      index_at[i] = #positions
    end
  end
  return positions, index_at
end

-- one of "on_generated" | "on_manual" | "off". There is no way to suppress a
-- generated pulse -- you can only add manual steps on top; a position is
-- either an active pulse/manual step, or the inactive default (reactivatable
-- the moment a generated pulse lands on it again).
local function step_state(t, i, index_at)
  index_at = index_at or select(2, pulse_index_map(t))
  if index_at[i] then return "on_generated" end
  local m = tracks[t].manual[i]
  if m and m.active then return "on_manual" end
  return "off"
end

local STATE_COLOR = {off = DIM, on_generated = AMBER, on_manual = MANUAL}
local STATE_ACTIVE = {off = false, on_generated = true, on_manual = true}

local function step_active(t, i)
  return STATE_ACTIVE[step_state(t, i)]
end

local function ensure_manual(t, i)
  local trk = tracks[t]
  trk.manual[i] = trk.manual[i] or {active = false, accent = false, probability = 100, microtiming = 0}
  return trk.manual[i]
end

-- accent for whatever currently occupies this position: the generated
-- pulse's own accent if one lands here, else the manual step's accent
local function step_accent(t, i, index_at)
  local trk = tracks[t]
  index_at = index_at or select(2, pulse_index_map(t))
  local k = index_at[i]
  if k then return trk.pulse_accents[k] or false end
  local m = trk.manual[i]
  return m and m.accent or false
end

-- toggle whatever accent currently applies at this position (pulse or manual)
local function toggle_step_accent(t, i)
  local trk = tracks[t]
  local _, index_at = pulse_index_map(t)
  local k = index_at[i]
  if k then
    trk.pulse_accents[k] = not (trk.pulse_accents[k] or false)
  else
    ensure_manual(t, i).accent = not ensure_manual(t, i).accent
  end
end

-- toggle whether this position is a manual step. Always available, even if a
-- generated pulse currently also occupies it (the manual flag simply stays
-- dormant until the generated pulse moves elsewhere).
local function toggle_manual_step(t, i)
  local m = ensure_manual(t, i)
  m.active = not m.active
end

-- 0-100%: chance the step actually triggers when its turn comes up
local function step_probability(t, i, index_at)
  local trk = tracks[t]
  index_at = index_at or select(2, pulse_index_map(t))
  local k = index_at[i]
  if k then return trk.pulse_probability[k] or 100 end
  local m = trk.manual[i]
  return (m and m.probability) or 100
end

local function set_step_probability(t, i, value)
  local trk = tracks[t]
  local _, index_at = pulse_index_map(t)
  local k = index_at[i]
  if k then
    trk.pulse_probability[k] = value
  else
    ensure_manual(t, i).probability = value
  end
end

-- 0-90%: delay applied to the trigger, as a fraction of the track's own
-- division. Delay-only (can't schedule earlier than the grid instant without
-- look-ahead), so this drags the step late rather than pushing it early.
local function step_microtiming(t, i, index_at)
  local trk = tracks[t]
  index_at = index_at or select(2, pulse_index_map(t))
  local k = index_at[i]
  if k then return trk.pulse_microtiming[k] or 0 end
  local m = trk.manual[i]
  return (m and m.microtiming) or 0
end

local function set_step_microtiming(t, i, value)
  local trk = tracks[t]
  local _, index_at = pulse_index_map(t)
  local k = index_at[i]
  if k then
    trk.pulse_microtiming[k] = value
  else
    ensure_manual(t, i).microtiming = value
  end
end

local function track_muted(t)
  local trk = tracks[t]
  return trk.mute or trk.momentary_mute
end

-- Fixed 16-step bipolar patterns standing in for the T1's percussion-derived
-- grooves (Agogo/Timbales/Congas/Bongo), since their exact curve data isn't
-- published -- tiled across the groove length like the real thing.
local PERCUSSION_GROOVES = {
  agogo = {1, -1, 0.5, -0.5, 1, -1, 0.3, -0.3, 0.8, -0.8, 0.2, -0.2, 1, -1, 0.4, -0.4},
  timbales = {1, 0.2, -1, 0.4, 0.6, -0.6, 1, -0.2, -1, 0.8, 0.1, -0.4, 1, -1, 0.5, -0.5},
  congas = {1, -0.3, 0.6, -1, 0.2, 1, -0.6, 0.3, -1, 0.5, 1, -0.2, 0.4, -1, 0.7, -0.4},
  bongo = {1, 0.5, -1, 0.2, -0.5, 1, 0.3, -1, 0.6, -0.3, 1, -0.6, 0.2, 1, -0.8, 0.4},
}

-- -1..1 velocity modulation for a track's selected groove, at the current
-- position in its (shared) phase. Saw/Triangle/Sine/Pulse are the real T1
-- waveforms; the percussion-named ones are an approximation (see above).
local function groove_curve_value(t)
  local trk = tracks[t]
  local shape = GROOVES[trk.groove]
  if shape == "saw" or shape == "triangle" or shape == "sine" or shape == "pulse" then
    local length_steps = GROOVE_LENGTHS[trk.groove_length_index] * 16 -- 16th notes per bar
    local phase = (groove_pos % length_steps) / length_steps -- 0..1 across the whole groove cycle
    if shape == "saw" then
      return phase * 2 - 1
    elseif shape == "triangle" then
      return (phase < 0.5) and (phase * 4 - 1) or (3 - phase * 4)
    elseif shape == "sine" then
      return math.sin(phase * 2 * math.pi)
    else -- pulse
      return (phase < 0.5) and 1 or -1
    end
  else
    local pat = PERCUSSION_GROOVES[shape]
    return pat[(groove_pos % 16) + 1]
  end
end

-- fixed 16-step bipolar sequence for the "random walk" phrase -- stable
-- rather than reshuffled, so the same step always gets the same offset
local PHRASE_RANDOM_WALK = {0.3, -0.6, 0.8, -0.2, 0.5, -0.9, 0.1, 0.6, -0.4, 0.9, -0.7, 0.2, -0.3, 0.7, -0.5, 0.4}

-- -1..1 pitch-contour modulation for a track's selected phrase, at its
-- current position within its own pattern (not shared across tracks, unlike
-- Groove -- a melodic phrase belongs to that track's own loop).
local function phrase_curve_value(t, pos)
  local trk = tracks[t]
  local phrase = PHRASE_TYPES[trk.phrase_type]
  local phase = trk.length > 0 and ((pos - 1) / trk.length) or 0 -- 0..1 across the pattern

  if phrase == "static" then
    return 0
  elseif phrase == "rise" then
    return phase * 2 - 1
  elseif phrase == "fall" then
    return 1 - phase * 2
  elseif phrase == "arch" then
    return (phase < 0.5) and (phase * 4 - 1) or (3 - phase * 4)
  elseif phrase == "valley" then
    return (phase < 0.5) and (1 - phase * 4) or (phase * 4 - 3)
  elseif phrase == "zigzag" then
    return (pos % 2 == 0) and 1 or -1
  elseif phrase == "random walk" then
    return PHRASE_RANDOM_WALK[((pos - 1) % 16) + 1]
  else -- cascade: descending staircase, repeating every 4 steps
    return 1 - 2 * (((pos - 1) % 4) / 3)
  end
end

local function round(x)
  return x >= 0 and math.floor(x + 0.5) or -math.floor(-x + 0.5)
end

-- shifts a note by the phrase's pitch contour (scaled by Range, up to one
-- octave), then snaps the result back into the current scale
local function apply_phrase(t, pos, note)
  local trk = tracks[t]
  if not trk.phrase_enabled then return note end
  local amt = phrase_curve_value(t, pos) * (trk.phrase_range / 127) * 12
  local shifted = util.clamp(note + round(amt), 0, 127)
  return nearest_in_scale_note(t, shifted)
end

-- ==== grid drawing ====

local function draw_drums_page()
  local trk = tracks[selected_track]
  local playhead = (playing and trk.length > 0) and ((trk.step % trk.length) + 1) or nil
  local _, index_at = pulse_index_map(selected_track)
  for i = 1, 16 do
    local x = ((i - 1) % 8) + 1
    local y = (i <= 8) and 8 or 7 -- step 1 starts on the top row, continues on the bottom row
    if i > trk.length then
      pad:led(x, y, 0)
    else
      local state = step_state(selected_track, i, index_at)
      local base = STATE_COLOR[state]
      if state ~= "off" and step_accent(selected_track, i, index_at) then
        base = brighten(base, 0.5)
      end
      if i == selected_step then
        local c = scale_color(base, pulse_phase and 1.0 or 0.35)
        pad:led_rgb(x, y, c[1], c[2], c[3])
      elseif i == playhead then
        local c = brighten(base, 0.6)
        pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end

  -- division rows: always visible, directly under the pattern
  for x = 1, 8 do
    local sel = trk.division == DIVISIONS_STRAIGHT[x]
    local c = sel and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 6, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local sel = trk.division == DIVISIONS_OTHER[x]
    local c = sel and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 5, c[1], c[2], c[3])
  end

  -- repeat time rows: same idea as division, one octave down
  for x = 1, 8 do
    local sel = trk.repeat_time == DIVISIONS_STRAIGHT[x]
    local c = sel and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 4, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local sel = trk.repeat_time == DIVISIONS_OTHER[x]
    local c = sel and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 3, c[1], c[2], c[3])
  end

  -- repeat count row: off, 2, 3, 4, 5, 6, 7, 8
  for x = 1, 8 do
    local sel = trk.repeats == REPEATS_VALUES[x]
    local c = sel and REPEATS_SELECTED or DIM
    pad:led_rgb(x, 2, c[1], c[2], c[3])
  end

  -- groove row: 8 accent curves
  for x = 1, 8 do
    local sel = trk.groove == x
    local c = sel and GROOVE_SELECTED or DIM
    pad:led_rgb(x, 1, c[1], c[2], c[3])
  end
end

local function draw_keys_page()
  local trk = tracks[selected_track]
  local root = view_root(selected_track)

  -- note-pool keyboard: amber = selected, dim = available, near-black = out of the current scale
  for x = 1, 8 do
    local note = root + NATURAL_OFFSETS[x]
    if trk.notes[note] then
      pad:led_rgb(x, 7, AMBER[1], AMBER[2], AMBER[3])
    elseif note_in_scale(selected_track, note) then
      pad:led_rgb(x, 7, DIM[1], DIM[2], DIM[3])
    else
      pad:led_rgb(x, 7, OUT_OF_SCALE[1], OUT_OF_SCALE[2], OUT_OF_SCALE[3])
    end
  end
  for x = 1, 8 do
    local offset = SHARP_OFFSETS[x]
    if offset == nil then
      pad:led(x, 8, 0)
    else
      local note = root + offset
      if trk.notes[note] then
        pad:led_rgb(x, 8, AMBER[1], AMBER[2], AMBER[3])
      elseif note_in_scale(selected_track, note) then
        pad:led_rgb(x, 8, DIM[1], DIM[2], DIM[3])
      else
        pad:led_rgb(x, 8, OUT_OF_SCALE[1], OUT_OF_SCALE[2], OUT_OF_SCALE[3])
      end
    end
  end

  -- root keyboard: same layout, single-select, no octave/scale concept of its own
  -- (naturals on the bottom of the pair, sharps on top -- same convention as the note keyboard)
  for x = 1, 8 do
    local pc = NATURAL_OFFSETS[x] % 12
    local c = (pc == trk.root_pc) and ROOT_COLOR or DIM
    pad:led_rgb(x, 5, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local offset = SHARP_OFFSETS[x]
    if offset == nil then
      pad:led(x, 6, 0)
    else
      local pc = offset % 12
      local c = (pc == trk.root_pc) and ROOT_COLOR or DIM
      pad:led_rgb(x, 6, c[1], c[2], c[3])
    end
  end

  -- scale rows: 16 scales across 2 rows of 8
  for x = 1, 8 do
    local c = (trk.scale_index == x) and SCALE_SELECTED or DIM
    pad:led_rgb(x, 4, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local idx = x + 8
    local c = (trk.scale_index == idx) and SCALE_SELECTED or DIM
    pad:led_rgb(x, 3, c[1], c[2], c[3])
  end

  -- arp style row
  for x = 1, 8 do
    local c = (trk.arp_style == x) and ARP_SELECTED or DIM
    pad:led_rgb(x, 2, c[1], c[2], c[3])
  end

  -- phrase type row
  for x = 1, 8 do
    local c = (trk.phrase_type == x) and PHRASE_SELECTED or DIM
    pad:led_rgb(x, 1, c[1], c[2], c[3])
  end
end

-- ==== user page: modulation faders ====
--
-- The User page is 8 faders, one per row, one per parameter that can be
-- randomly modulated. Touching a pad only *selects* that row (which pad
-- within the row doesn't matter); E2/K2/E3/K3 then configure its modulation.
-- The values themselves are set where they live (Drums/Keys sub-pages,
-- arrows) -- the faders only display them, live.
--
-- A modulation (in trk.random_states[slider.id]) keeps its own 16-step
-- pseudo-random sequence, like the T1's per-parameter sequences:
-- amount = depth, rate = how many of the track's own steps pass between
-- sequence advances (a short musical list rather than a raw 0-127, which
-- reads poorly against everything else here). `base` is the value the
-- modulation swings around; `last` is what it wrote last time, so a change
-- made by hand elsewhere shows up as a mismatch and becomes the new base.
local RATE_STEPS = {1, 2, 4, 8, 16, 32}

-- both division-valued params (Drums' division and repeat-time) pick from
-- the same combined 16-value set
local ALL_DIVISIONS = {}
for _, v in ipairs(DIVISIONS_STRAIGHT) do table.insert(ALL_DIVISIONS, v) end
for _, v in ipairs(DIVISIONS_OTHER) do table.insert(ALL_DIVISIONS, v) end

local function division_index(d)
  for i, v in ipairs(ALL_DIVISIONS) do
    if v == d then return i end
  end
  return 1
end

local function repeats_index(n)
  for i, v in ipairs(REPEATS_VALUES) do
    if v == n then return i end
  end
  return 1
end

local function lin_to_pad(v, lo, hi)
  if hi <= lo then return 1 end
  return util.clamp(math.floor((v - lo) / (hi - lo) * 7 + 0.5) + 1, 1, 8)
end

-- index 1 = top row (y=8) down to index 8 = bottom row (y=1).
-- bounds(trk) = real value range (can depend on the track, e.g. pulses
-- never exceed its length); get/set work in that range; value(trk) is the
-- text for the screen. `wrap` = cyclic (rotation), so modulation wraps
-- around instead of sticking at the ends.
local USER_SLIDERS = {
  {id = "pulses", label = "pulses", color = AMBER,
    bounds = function(trk) return 0, trk.length end,
    get = function(trk) return trk.pulses end,
    set = function(trk, v) trk.pulses = util.clamp(v, 0, trk.length) end,
    value = function(trk) return tostring(trk.pulses) end},
  {id = "rotation", label = "rotation", color = AMBER, wrap = true,
    bounds = function(trk) return 0, math.max(trk.length - 1, 0) end,
    get = function(trk) return trk.length > 0 and trk.rotation % trk.length or 0 end,
    set = function(trk, v) trk.rotation = v end,
    value = function(trk) return tostring(trk.length > 0 and trk.rotation % trk.length or 0) end},
  {id = "velocity", label = "velocity", color = VELOCITY_COLOR,
    bounds = function() return 0, 127 end,
    get = function(trk) return trk.velocity end,
    set = function(trk, v) trk.velocity = util.clamp(v, 0, 127) end,
    value = function(trk) return tostring(trk.velocity) end},
  {id = "repeats", label = "rpt", color = REPEATS_SELECTED,
    bounds = function() return 1, #REPEATS_VALUES end,
    get = function(trk) return repeats_index(trk.repeats) end,
    set = function(trk, v) trk.repeats = REPEATS_VALUES[util.clamp(v, 1, #REPEATS_VALUES)] end,
    value = function(trk) return repeats_label(trk.repeats) end},
  {id = "ramp", label = "rpt ramp", color = REPEATS_SELECTED,
    bounds = function() return -63, 63 end,
    get = function(trk) return trk.ramp end,
    set = function(trk, v) trk.ramp = util.clamp(v, -63, 63) end,
    value = function(trk) return tostring(trk.ramp) end},
  {id = "pace", label = "rpt pace", color = REPEATS_SELECTED,
    bounds = function() return -63, 63 end,
    get = function(trk) return trk.pace end,
    set = function(trk, v) trk.pace = util.clamp(v, -63, 63) end,
    value = function(trk) return tostring(trk.pace) end},
  {id = "groove_amount", label = "grv amt", color = GROOVE_SELECTED,
    bounds = function() return 0, 127 end,
    get = function(trk) return trk.groove_amount end,
    set = function(trk, v) trk.groove_amount = util.clamp(v, 0, 127) end,
    value = function(trk) return tostring(trk.groove_amount) end},
  {id = "groove", label = "grv shape", color = GROOVE_SELECTED,
    bounds = function() return 1, #GROOVES end,
    get = function(trk) return trk.groove end,
    set = function(trk, v) trk.groove = util.clamp(v, 1, #GROOVES) end,
    value = function(trk) return GROOVES[trk.groove] end},
}
local SLIDER_BY_ID = {}
for _, sl in ipairs(USER_SLIDERS) do SLIDER_BY_ID[sl.id] = sl end

local function fresh_random_seq()
  local seq = {}
  for i = 1, 16 do
    seq[i] = math.random() * 2 - 1
  end
  return seq
end

-- the modulation state of a fader for a track; created on first use
local function modulation_state(t, sl, create)
  local trk = tracks[t]
  local r = trk.random_states[sl.id]
  if not r and create then
    r = {enabled = false, amount = 0, rate_index = 1, seq = fresh_random_seq(),
         pos = 1, step_counter = 0, base = sl.get(trk)}
    trk.random_states[sl.id] = r
  end
  return r
end

-- the state of the fader E2/K2/E3/K3 currently edit (nil until one was touched)
local function focused_state(create)
  if not last_slider then return nil end
  return modulation_state(selected_track, USER_SLIDERS[last_slider], create)
end

local function set_modulation_enabled(t, sl, on)
  local trk = tracks[t]
  local r = modulation_state(t, sl, true)
  if on and not r.enabled then
    r.base = sl.get(trk)
    r.last = nil
    r.step_counter = 0
  elseif not on and r.enabled and r.base ~= nil then
    sl.set(trk, r.base) -- back to the value you dialed in
  end
  r.enabled = on
end

-- advances (at `rate`) and applies every one of the track's enabled
-- modulations -- not just the one focused on screen. Called once per
-- sequencer tick. Ids that no longer exist (older saves) are skipped.
local function random_tick(t)
  local trk = tracks[t]
  for id, r in pairs(trk.random_states) do
    local sl = SLIDER_BY_ID[id]
    if sl and r.enabled then
      local cur = sl.get(trk)
      if r.base == nil or (r.last ~= nil and cur ~= r.last) then
        r.base = cur -- changed by hand since our last write: follow it
      end
      r.step_counter = r.step_counter + 1
      if r.step_counter >= RATE_STEPS[r.rate_index] then
        r.step_counter = 0
        r.pos = (r.pos % 16) + 1
      end

      local lo, hi = sl.bounds(trk)
      local offset = r.seq[r.pos] * (r.amount / 127) * (hi - lo) / 2
      local v = round(r.base + offset)
      if sl.wrap then
        v = lo + (v - lo) % (hi - lo + 1)
      else
        v = util.clamp(v, lo, hi)
      end
      sl.set(trk, v)
      r.last = sl.get(trk)
    end
  end
end

-- fill up to the dialed-in value (`base`), bright head on the live value
-- (it moves while a modulation runs), dim halo over the reachable range
-- above the base. The selected fader's head blinks.
local function draw_user_page()
  local trk = tracks[selected_track]
  for i, sl in ipairs(USER_SLIDERS) do
    local y = 9 - i
    local lo, hi = sl.bounds(trk)
    local live_pad = lin_to_pad(sl.get(trk), lo, hi)
    local r = trk.random_states[sl.id]
    local modulating = r ~= nil and r.enabled and r.base ~= nil
    local base_pad = modulating and lin_to_pad(r.base, lo, hi) or live_pad
    local span = (modulating and r.amount > 0 and hi > lo) and (r.amount / 127) * (hi - lo) / 2 or nil
    local body = scale_color(sl.color, 0.4)
    local head = brighten(sl.color, 0.3)
    local halo = scale_color(sl.color, 0.25)
    for x = 1, 8 do
      local c
      if x == live_pad then
        c = (i == last_slider and not pulse_phase) and body or head
      elseif x <= base_pad then
        c = body
      else
        c = DIM
        if span then
          -- the value this pad stands for, against the modulation's reach
          local vx = lo + (x - 1) / 7 * (hi - lo)
          local d = math.abs(vx - r.base)
          if sl.wrap then d = math.min(d, (hi - lo + 1) - d) end
          if d <= span + (hi - lo) / 14 then c = halo end
        end
      end
      pad:led_rgb(x, y, c[1], c[2], c[3])
    end
  end
end

-- ==== session: patterns ====
--
-- A pattern is a snapshot of everything that shapes a track's rhythm/melody
-- -- not its identity (voice) or live performance state (mute).

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[k] = deep_copy(val) end
  return out
end

local PATTERN_FIELDS = {
  "length", "pulses", "rotation", "division",
  "notes", "manual",
  "pulse_accents", "pulse_probability", "pulse_microtiming",
  "velocity", "accent_amount",
  "repeats", "repeat_time", "ramp", "pace",
  "groove", "groove_amount", "groove_length_index",
  "root_pc", "scale_index",
  "arp_enabled", "arp_style", "arp_octaves",
  "phrase_enabled", "phrase_type", "phrase_range",
  "random_states",
}

local function capture_pattern(t)
  local trk = tracks[t]
  local snap = {}
  for _, f in ipairs(PATTERN_FIELDS) do
    snap[f] = deep_copy(trk[f])
  end
  return snap
end

local function apply_pattern(t, snap)
  local trk = tracks[t]
  for _, f in ipairs(PATTERN_FIELDS) do
    trk[f] = deep_copy(snap[f])
  end
  trk.step = 0
  trk.arp_pos = 0
end

-- a blank pattern, same defaults a freshly-initialized track gets
local function fresh_pattern_snapshot()
  return {
    length = 8, pulses = 4, rotation = 0, division = DEFAULT_DIVISION,
    notes = {[BASE_NOTE] = true}, manual = {},
    pulse_accents = {}, pulse_probability = {}, pulse_microtiming = {},
    velocity = 100, accent_amount = 27,
    repeats = 0, repeat_time = DEFAULT_DIVISION, ramp = 0, pace = 0,
    groove = 1, groove_amount = 0, groove_length_index = DEFAULT_GROOVE_LENGTH_INDEX,
    root_pc = 0, scale_index = 1,
    arp_enabled = false, arp_style = 1, arp_octaves = 1,
    phrase_enabled = false, phrase_type = 1, phrase_range = 0,
    random_states = {},
  }
end

local function draw_session_page()
  local trk = tracks[selected_track]

  -- quantize rows: same two lists and layout as the Drums division rows
  for x = 1, 8 do
    local c = (trk.pattern_quantize == x) and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 8, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local c = (trk.pattern_quantize == x + 8) and DIVISION_SELECTED or DIM
    pad:led_rgb(x, 7, c[1], c[2], c[3])
  end

  -- pattern rows: y=6 (top) -> slots 1-8, down to y=3 -> slots 25-32
  for y = 6, 3, -1 do
    local row_base = (6 - y) * 8
    for x = 1, 8 do
      local slot = row_base + x
      local base
      if slot == trk.current_pattern then
        base = PATTERN_ACTIVE
      elseif trk.patterns[slot] then
        base = PATTERN_SAVED
      else
        base = DIM
      end
      if slot == trk.pending_pattern then
        local c = scale_color(PATTERN_ACTIVE, pulse_phase and 1.0 or 0.35)
        pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end

  -- song chain rows: y=2 -> steps 1-8, y=1 -> steps 9-16
  for y = 2, 1, -1 do
    for x = 1, 8 do
      local pos = (y == 2) and x or (x + 8)
      local base
      if trk.song_enabled and pos == trk.song_pos then
        base = CHAIN_STEP_ACTIVE
      elseif trk.song_chain[pos] then
        base = CHAIN_STEP
      else
        base = DIM
      end
      if pos == chain_edit_pos then
        local c = scale_color({127, 127, 127}, pulse_phase and 1.0 or 0.35)
        pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end
end

local function draw_scenes()
  for t = 1, NUM_TRACKS do
    local y = 9 - t -- track 1 -> y=8 (top) .. track 7 -> y=2 (bottom, above transport)
    local trk = tracks[t]
    local selected = (t == selected_track)
    if trk.momentary_mute then
      local c = scale_color(RED, pulse_phase and 1.0 or 0.35)
      pad:led_rgb(9, y, c[1], c[2], c[3])
    elseif trk.mute then
      if selected then pad:led_rgb(9, y, 127, 0, 0) else pad:led_rgb(9, y, 20, 0, 0) end
    else
      if selected then pad:led_rgb(9, y, AMBER[1], AMBER[2], AMBER[3]) else pad:led_rgb(9, y, DIM[1], DIM[2], DIM[3]) end
    end
  end
end

local function draw_transport()
  if playing then
    pad:led_rgb(9, 1, 0, 127, 0)
  else
    pad:led_rgb(9, 1, 20, 0, 0)
  end
end

local function draw_top_row()
  local arrows_active = page == "drums" or page == "keys"
  for x = 1, 4 do
    if arrows_active then
      pad:led_rgb(x, 9, 20, 20, 20)
    else
      pad:led_rgb(x, 9, 0, 0, 0)
    end
  end
  if page == "session" then pad:led_rgb(5, 9, AMBER[1], AMBER[2], AMBER[3]) else pad:led_rgb(5, 9, 10, 10, 10) end
  if page == "drums" then pad:led_rgb(6, 9, AMBER[1], AMBER[2], AMBER[3]) else pad:led_rgb(6, 9, 10, 10, 10) end
  if page == "keys" then pad:led_rgb(7, 9, AMBER[1], AMBER[2], AMBER[3]) else pad:led_rgb(7, 9, 10, 10, 10) end
  if page == "user" then pad:led_rgb(8, 9, AMBER[1], AMBER[2], AMBER[3]) else pad:led_rgb(8, 9, 10, 10, 10) end
  if logo_on then
    pad:led_rgb(9, 9, 127, 127, 127) -- logo flashes on the beat (quarter notes)
  else
    pad:led(9, 9, 0)
  end
end

local function redraw_grid()
  if page == "drums" then
    draw_drums_page()
  elseif page == "keys" then
    draw_keys_page()
  elseif page == "user" then
    draw_user_page()
  else
    draw_session_page()
  end
  draw_scenes()
  draw_transport()
  draw_top_row()

  if copy_mode_active and page == "session" and copy_mode_source.track == selected_track then
    -- pulse the copy source pad so it's clear what the next tap will paste
    local slot = copy_mode_source.slot
    local sy = 6 - math.floor((slot - 1) / 8)
    local sx = ((slot - 1) % 8) + 1
    local c = scale_color({127, 127, 127}, pulse_phase and 1.0 or 0.35)
    pad:led_rgb(sx, sy, c[1], c[2], c[3])
  end

  pad:refresh()
  redraw() -- keep the OLED screen in sync too
end

-- ==== sub-pages (screen) ====
--
-- Each grid page (drums/keys/user) has a list of sub-pages. E1 cycles
-- through them; the grid never changes because of this, only the screen.
-- Each sub-page independently assigns e2/k2/e3/k3, or leaves them nil.

local subpages = {
  drums = {
    {name = "step",
      -- with no step selected, every slot below is unavailable, so this
      -- doubles as the blank default view (no separate "pattern" sub-page needed)
      e2 = {
        available = function() return selected_step ~= nil end,
        label = function() return "prob" end,
        value = function() return step_probability(selected_track, selected_step) .. "%" end,
        delta = function(d)
          local v = util.clamp(step_probability(selected_track, selected_step) + d, 0, 100)
          set_step_probability(selected_track, selected_step, v)
        end,
      },
      k2 = {
        -- unavailable when a generated pulse already occupies this step:
        -- the pulse's own parameters take priority, so there's nothing
        -- manual to toggle from here
        available = function()
          if selected_step == nil then return false end
          local _, index_at = pulse_index_map(selected_track)
          return index_at[selected_step] == nil
        end,
        label = function() return "manual" end,
        state = function()
          if selected_step == nil then return false end
          local m = tracks[selected_track].manual[selected_step]
          return m and m.active or false
        end,
        action = function()
          if selected_step == nil then return end
          toggle_manual_step(selected_track, selected_step)
        end,
      },
      e3 = {
        available = function() return selected_step ~= nil end,
        label = function() return "timing" end,
        value = function() return "+" .. step_microtiming(selected_track, selected_step) .. "%" end,
        delta = function(d)
          local v = util.clamp(step_microtiming(selected_track, selected_step) + d, 0, 90)
          set_step_microtiming(selected_track, selected_step, v)
        end,
      },
      k3 = {
        available = function() return selected_step ~= nil end,
        label = function() return "accent" end,
        state = function() return step_accent(selected_track, selected_step) end,
        action = function() toggle_step_accent(selected_track, selected_step) end,
      },
    },
    {name = "velocity",
      e2 = {
        label = function() return "velocity" end,
        value = function() return tostring(tracks[selected_track].velocity) end,
        delta = function(d) local trk = tracks[selected_track]; trk.velocity = util.clamp(trk.velocity + d, 0, 127) end,
      },
      e3 = {
        label = function() return "accent+" end,
        value = function() return tostring(tracks[selected_track].accent_amount) end,
        delta = function(d) local trk = tracks[selected_track]; trk.accent_amount = util.clamp(trk.accent_amount + d, 0, 127) end,
      },
    },
    {name = "repeat",
      e2 = {
        label = function() return "ramp" end,
        value = function() return tostring(tracks[selected_track].ramp) end,
        delta = function(d) local trk = tracks[selected_track]; trk.ramp = util.clamp(trk.ramp + d, -63, 63) end,
      },
      e3 = {
        label = function() return "pace" end,
        value = function() return tostring(tracks[selected_track].pace) end,
        delta = function(d) local trk = tracks[selected_track]; trk.pace = util.clamp(trk.pace + d, -63, 63) end,
      },
    },
    {name = "groove",
      e2 = {
        label = function() return "amount" end,
        value = function() return tostring(tracks[selected_track].groove_amount) end,
        delta = function(d) local trk = tracks[selected_track]; trk.groove_amount = util.clamp(trk.groove_amount + d, 0, 127) end,
      },
      e3 = {
        label = function() return "length" end,
        value = function()
          local trk = tracks[selected_track]
          return tostring(GROOVE_LENGTHS[trk.groove_length_index])
        end,
        delta = function(d)
          local trk = tracks[selected_track]
          trk.groove_length_index = util.clamp(trk.groove_length_index + d, 1, #GROOVE_LENGTHS)
        end,
      },
    },
  },
  keys = {
    {name = "keys",
      e2 = {
        label = function() return "arp oct" end,
        value = function() return tostring(tracks[selected_track].arp_octaves) end,
        delta = function(d) local trk = tracks[selected_track]; trk.arp_octaves = util.clamp(trk.arp_octaves + d, 1, 4) end,
      },
      k2 = {
        label = function() return "arp" end,
        state = function() return tracks[selected_track].arp_enabled end,
        action = function() local trk = tracks[selected_track]; trk.arp_enabled = not trk.arp_enabled end,
      },
      e3 = {
        label = function() return "phr rng" end,
        value = function() return tostring(tracks[selected_track].phrase_range) end,
        delta = function(d) local trk = tracks[selected_track]; trk.phrase_range = util.clamp(trk.phrase_range + d, 0, 127) end,
      },
      k3 = {
        label = function() return "phrase" end,
        state = function() return tracks[selected_track].phrase_enabled end,
        action = function() local trk = tracks[selected_track]; trk.phrase_enabled = not trk.phrase_enabled end,
      },
    },
  },
  user = {
    {name = "mod",
      -- configures the modulation of whichever fader was last touched
      e2 = {
        available = function() return last_slider ~= nil end,
        label = function() return "amount" end,
        value = function()
          local r = focused_state(false)
          return tostring(r and r.amount or 0)
        end,
        delta = function(d)
          local r = focused_state(true)
          r.amount = util.clamp(r.amount + d, 0, 127)
        end,
      },
      k2 = {
        available = function() return last_slider ~= nil end,
        label = function() return "on" end,
        state = function()
          local r = focused_state(false)
          return r ~= nil and r.enabled
        end,
        action = function()
          local r = focused_state(true)
          set_modulation_enabled(selected_track, USER_SLIDERS[last_slider], not r.enabled)
        end,
      },
      e3 = {
        available = function() return last_slider ~= nil end,
        label = function() return "every" end,
        value = function()
          local r = focused_state(false)
          return tostring(RATE_STEPS[r and r.rate_index or 1])
        end,
        delta = function(d)
          local r = focused_state(true)
          r.rate_index = util.clamp(r.rate_index + d, 1, #RATE_STEPS)
        end,
      },
      k3 = {
        available = function() return last_slider ~= nil end,
        label = function() return "reroll" end,
        state = function() return false end,
        action = function()
          local r = focused_state(true)
          r.seq = fresh_random_seq()
        end,
      },
    },
  },
  session = {
    {name = "session",
      k2 = {
        label = function() return "song" end,
        state = function() return tracks[selected_track].song_enabled end,
        action = function()
          local trk = tracks[selected_track]
          trk.song_enabled = not trk.song_enabled
        end,
      },
    },
  },
}

-- Held-button pages. Same slot contract as `subpages`; while one is open it
-- replaces the current sub-page on screen.
local temp_pages = {
  tempo = {name = "tempo",
    e2 = {
      label = function() return "tempo" end,
      value = function() return string.format("%.0f", params:get("clock_tempo")) end,
      delta = function(d) params:delta("clock_tempo", d) end,
    },
  },
}

local function open_temp_page(name)
  active_temp_page = name
  temp_page_used = false
end

-- returns whether any of the page's controls were touched while it was open,
-- so the caller can tell a bare tap from a hold-and-adjust
local function close_temp_page()
  local used = temp_page_used
  active_temp_page = nil
  temp_page_used = false
  return used
end

local function switch_page(new_page)
  page = new_page
  copy_mode_active = false
  redraw_grid()
end

-- ==== interactions ====

local function select_track(t)
  selected_track = t
  redraw_grid()
end

local function toggle_play()
  playing = not playing
  play_epoch = play_epoch + 1
  if not playing then
    for t = 1, NUM_TRACKS do
      tracks[t].step = 0
      tracks[t].song_pos = 0
    end
    groove_pos = 0
  end
  redraw_grid()
end

-- switches to `slot`, auto-saving whatever pattern is currently active back
-- into its own slot first -- there's no separate "save" action, the active
-- pattern always reflects whatever you last did to the track. Creates a
-- blank pattern if the slot was empty.
local function do_pattern_switch(t, slot)
  local trk = tracks[t]
  if trk.current_pattern then
    trk.patterns[trk.current_pattern] = capture_pattern(t)
  end
  if not trk.patterns[slot] then
    trk.patterns[slot] = fresh_pattern_snapshot()
  end
  apply_pattern(t, trk.patterns[slot])
  trk.current_pattern = slot
  trk.pending_pattern = nil
end

-- switches immediately if stopped (there's no meaningful "next boundary");
-- otherwise queues it for the quantize check in the groove clock
local function queue_pattern_switch(t, slot)
  local trk = tracks[t]
  if not playing then
    do_pattern_switch(t, slot)
  else
    trk.pending_pattern = slot
  end
  redraw_grid()
end

-- long-press shortcut: duplicates the currently active pattern into `slot`,
-- then switches to it -- a quick way to branch a variation without using
-- copy/paste for the common "start from what I have" case
local function duplicate_pattern_to(t, slot)
  tracks[t].patterns[slot] = capture_pattern(t) -- always the live state, never a possibly-stale save
  queue_pattern_switch(t, slot)
end

local function enter_step_edit(i)
  selected_step = i
  current_subpage.drums = STEP_SUBPAGE
  pulse_phase = true
  redraw_grid()
end

local function exit_step_edit()
  selected_step = nil
  current_subpage.drums = 1
  redraw_grid()
end

local function step_index(x, y)
  return (y == 8) and x or (x + 8)
end

local function handle_drums_key(x, y, z)
  if y == 5 or y == 6 then
    if z == 1 then
      local list = (y == 6) and DIVISIONS_STRAIGHT or DIVISIONS_OTHER
      tracks[selected_track].division = list[x]
      redraw_grid()
    end
    return
  end

  if y == 3 or y == 4 then
    if z == 1 then
      local list = (y == 4) and DIVISIONS_STRAIGHT or DIVISIONS_OTHER
      tracks[selected_track].repeat_time = list[x]
      redraw_grid()
    end
    return
  end

  if y == 2 then
    if z == 1 then
      tracks[selected_track].repeats = REPEATS_VALUES[x]
      redraw_grid()
    end
    return
  end

  if y == 1 then
    if z == 1 then
      tracks[selected_track].groove = x
      redraw_grid()
    end
    return
  end

  if y ~= 7 and y ~= 8 then return end
  local i = step_index(x, y)

  if z == 1 then
    hold_pending = i
    hold_metro.event = function()
      if hold_pending == i then
        -- a long press always (re-)enters edit mode on this pad, even if
        -- another pad was already selected -- jumps straight to it
        enter_step_edit(i)
        hold_pending = nil
      end
    end
    hold_metro:start()
  else -- release
    if hold_pending == i then
      -- short tap: didn't reach the long-press threshold
      hold_metro:stop()
      hold_pending = nil
      if selected_step ~= nil then
        exit_step_edit()
      else
        tracks[selected_track].length = i
        tracks[selected_track].pulses = util.clamp(tracks[selected_track].pulses, 0, i)
        redraw_grid()
      end
    end
  end
end

local function handle_keys_key(x, y, z)
  if z ~= 1 then return end
  local trk = tracks[selected_track]

  if y == 7 or y == 8 then
    local view = view_root(selected_track)
    if y == 7 then
      toggle_note(selected_track, view + NATURAL_OFFSETS[x])
    else
      local offset = SHARP_OFFSETS[x]
      if offset ~= nil then toggle_note(selected_track, view + offset) end
    end
    redraw_grid()
    return
  end

  if y == 6 or y == 5 then
    local pc
    if y == 5 then
      pc = NATURAL_OFFSETS[x] % 12
    else
      local offset = SHARP_OFFSETS[x]
      if offset == nil then return end
      pc = offset % 12
    end
    trk.root_pc = pc
    snap_notes_to_scale(selected_track)
    redraw_grid()
    return
  end

  if y == 4 or y == 3 then
    local idx = (y == 4) and x or (x + 8)
    trk.scale_index = idx
    snap_notes_to_scale(selected_track)
    redraw_grid()
    return
  end

  if y == 2 then
    trk.arp_style = x
    redraw_grid()
    return
  end

  if y == 1 then
    trk.phrase_type = x
    redraw_grid()
    return
  end
end

local function handle_user_key(x, y, z)
  if z ~= 1 then return end
  local i = 9 - y
  if USER_SLIDERS[i] == nil then return end
  -- selection only: which pad within the row doesn't matter, just which row
  last_slider = i
  redraw_grid()
end

local function handle_session_key(x, y, z)
  -- copy mode is armed: any pattern tap now pastes the source here and
  -- exits, regardless of which track is currently selected (so switching
  -- tracks via the scene buttons first lets you copy across tracks)
  if copy_mode_active and y >= 3 and y <= 6 and z == 1 then
    local slot = (6 - y) * 8 + x
    local trk = tracks[selected_track]
    local source = tracks[copy_mode_source.track].patterns[copy_mode_source.slot]
    trk.patterns[slot] = deep_copy(source)
    if slot == trk.current_pattern then
      apply_pattern(selected_track, trk.patterns[slot])
    end
    copy_mode_active = false
    copy_mode_source = nil
    redraw_grid()
    return
  end

  -- a chain step is armed: any pattern tap fills it and exits
  if chain_edit_pos and y >= 3 and y <= 6 and z == 1 then
    local slot = (6 - y) * 8 + x
    tracks[selected_track].song_chain[chain_edit_pos] = slot
    chain_edit_pos = nil
    redraw_grid()
    return
  end

  if y == 8 or y == 7 then -- quantize: same layout as Drums' division rows
    if z == 1 then
      tracks[selected_track].pattern_quantize = (y == 8) and x or (x + 8)
      redraw_grid()
    end
    return
  end

  if y >= 3 and y <= 6 then
    -- pattern slots: tap to switch (creating a blank pattern if empty).
    -- long-press the *active* pattern's own pad to arm copy mode (a
    -- self-duplicate would be a no-op anyway, so that gesture is free);
    -- long-press any other pad duplicates the active pattern into it.
    local slot = (6 - y) * 8 + x
    if z == 1 then
      session_hold_pending = slot
      hold_metro.event = function()
        if session_hold_pending == slot then
          if slot == tracks[selected_track].current_pattern then
            -- sync the live edits into storage first -- otherwise the copy
            -- would grab whatever was last saved, not what's playing now
            tracks[selected_track].patterns[slot] = capture_pattern(selected_track)
            copy_mode_active = true
            copy_mode_source = {track = selected_track, slot = slot}
          else
            duplicate_pattern_to(selected_track, slot)
          end
          session_hold_pending = nil
          redraw_grid()
        end
      end
      hold_metro:start()
    else -- release
      if session_hold_pending == slot then
        -- short tap: didn't reach the long-press threshold
        hold_metro:stop()
        session_hold_pending = nil
        queue_pattern_switch(selected_track, slot)
      end
    end
    return
  end

  if y == 1 or y == 2 then
    -- chain steps: tap to arm for assignment (next pattern tap fills it),
    -- long-press to clear
    local pos = (y == 2) and x or (x + 8)
    if z == 1 then
      chain_hold_pending = pos
      hold_metro.event = function()
        if chain_hold_pending == pos then
          tracks[selected_track].song_chain[pos] = nil
          chain_hold_pending = nil
          redraw_grid()
        end
      end
      hold_metro:start()
    else -- release
      if chain_hold_pending == pos then
        hold_metro:stop()
        chain_hold_pending = nil
        chain_edit_pos = pos
        redraw_grid()
      end
    end
    return
  end
end

local function handle_arrow(x, z)
  if z ~= 1 then return end
  local trk = tracks[selected_track]
  if page == "drums" then
    if x == 1 then -- up: +1 pulse
      trk.pulses = util.clamp(trk.pulses + 1, 0, trk.length)
    elseif x == 2 then -- down: -1 pulse
      trk.pulses = util.clamp(trk.pulses - 1, 0, trk.length)
    elseif x == 3 then -- left: rotate earlier
      trk.rotation = trk.rotation - 1
    elseif x == 4 then -- right: rotate later
      trk.rotation = trk.rotation + 1
    end
  elseif page == "keys" then
    if x == 1 then -- up: view octave up (does not move selected notes)
      shift_octave_view(selected_track, 1)
    elseif x == 2 then -- down: view octave down (does not move selected notes)
      shift_octave_view(selected_track, -1)
    elseif x == 3 then -- left: transpose selected notes down a semitone
      transpose_notes(selected_track, -1)
    elseif x == 4 then -- right: transpose selected notes up a semitone
      transpose_notes(selected_track, 1)
    end
  end
  redraw_grid()
end

local function on_key(x, y, z)
  if x == 9 and y == 1 then
    -- Stop Solo Mute: bare tap = play/pause; held = shift for mute AND opens
    -- the tempo page, so a hold-and-adjust doesn't also toggle transport
    if z == 1 then
      shift_held = true
      shift_used = false
      open_temp_page("tempo")
      redraw()
    else
      local adjusted = close_temp_page()
      if not shift_used and not adjusted then toggle_play() end
      shift_held = false
      redraw()
    end
  elseif x == 9 and y >= 2 and y <= 8 then
    local t = 9 - y -- y=8 (top) -> track 1 .. y=2 (bottom) -> track 7
    if z == 1 then
      if shift_held then
        shift_used = true
        mute_hold_pending = t
        mute_hold_metro.event = function()
          if mute_hold_pending == t then
            tracks[t].momentary_mute = true
            mute_hold_pending = nil
            redraw_grid()
          end
        end
        mute_hold_metro:start()
      else
        select_track(t)
      end
    else -- release
      if mute_hold_pending == t then
        mute_hold_metro:stop()
        mute_hold_pending = nil
        tracks[t].mute = not tracks[t].mute
        redraw_grid()
      elseif tracks[t].momentary_mute then
        tracks[t].momentary_mute = false
        redraw_grid()
      end
    end
  elseif x == 9 and y == 9 then
    -- logo: unused
  elseif y == 9 and x >= 1 and x <= 4 then
    handle_arrow(x, z)
  elseif y == 9 and x == 6 then
    if z == 1 then switch_page("drums") end
  elseif y == 9 and x == 7 then
    if z == 1 then switch_page("keys") end
  elseif y == 9 and x == 8 then
    if z == 1 then switch_page("user") end
  elseif y == 9 and x == 5 then
    if z == 1 then switch_page("session") end
  elseif y == 9 then
    -- unused
  else
    if page == "drums" then
      handle_drums_key(x, y, z)
    elseif page == "keys" then
      handle_keys_key(x, y, z)
    elseif page == "user" then
      handle_user_key(x, y, z)
    elseif page == "session" then
      handle_session_key(x, y, z)
    end
  end
end

-- ==== sequencer ====

-- Note Repeater: `repeats` extra triggers after the initial hit, spaced by
-- `repeat_time`. `ramp` (-63..63) shapes velocity rising/falling across the
-- series; `pace` (-63..63) shapes the spacing speeding up/slowing down.
local function trigger_repeats(t, notes_to_play, base_vel)
  local trk = tracks[t]
  if trk.repeats <= 0 then return end
  local player = params:lookup_param("voice_t" .. t):get_player()
  local epoch = play_epoch
  clock.run(function()
    for i = 1, trk.repeats do
      local progress = (i - 1) / math.max(trk.repeats - 1, 1)
      local pace_factor = math.max(1 - (trk.pace / 63) * progress * 0.5, 0.1)
      clock.sync(trk.repeat_time * pace_factor)
      if epoch ~= play_epoch then return end -- stopped (or restarted) meanwhile: drop the rest of the series
      local vel = util.clamp(base_vel + trk.ramp * (i / trk.repeats), 0, 127)
      for _, note in ipairs(notes_to_play) do
        player:note_on(note, vel / 127)
      end
      clock.run(function()
        clock.sync(trk.repeat_time / 2)
        for _, note in ipairs(notes_to_play) do
          player:note_off(note)
        end
      end)
    end
  end)
end

-- builds the note order for the arp, per the selected style, extended
-- across `arp_octaves` octaves. Not enumerated in the T1 docs -- invented.
local function arp_sequence(t)
  local trk = tracks[t]
  local notes = {}
  for note, _ in pairs(trk.notes) do table.insert(notes, note) end
  table.sort(notes)
  if #notes == 0 then return {} end

  local style = ARP_STYLES[trk.arp_style]
  local seq = {}
  if style == "up" or style == "as played" then
    seq = notes
  elseif style == "down" then
    for i = #notes, 1, -1 do table.insert(seq, notes[i]) end
  elseif style == "up-down" then
    for i = 1, #notes do table.insert(seq, notes[i]) end
    for i = #notes - 1, 2, -1 do table.insert(seq, notes[i]) end
  elseif style == "down-up" then
    for i = #notes, 1, -1 do table.insert(seq, notes[i]) end
    for i = 2, #notes - 1 do table.insert(seq, notes[i]) end
  elseif style == "random" then
    seq = {notes[math.random(#notes)]}
  elseif style == "converge" then
    local lo, hi = 1, #notes
    while lo <= hi do
      table.insert(seq, notes[lo])
      lo = lo + 1
      if lo <= hi then
        table.insert(seq, notes[hi])
        hi = hi - 1
      end
    end
  elseif style == "diverge" then
    local mid = math.ceil(#notes / 2)
    local lo, hi = mid, mid + 1
    while lo >= 1 or hi <= #notes do
      if lo >= 1 then
        table.insert(seq, notes[lo])
        lo = lo - 1
      end
      if hi <= #notes then
        table.insert(seq, notes[hi])
        hi = hi + 1
      end
    end
  end

  local full = {}
  for oct = 0, trk.arp_octaves - 1 do
    for _, n in ipairs(seq) do
      table.insert(full, util.clamp(n + oct * 12, 0, 127))
    end
  end
  return full
end

-- Arp reuses the Note Repeater's own controls instead of a separate rate:
-- Repeats sets how many notes the run contains (1 + repeats total), Time
-- sets its speed, Ramp/Pace shape it -- exactly like a plain repeat, except
-- each note in the burst steps through the arp sequence instead of
-- replaying the same chord. arp_pos persists across pulses so the line
-- keeps moving forward rather than restarting every hit.
local function trigger_arp_burst(t, pos, base_vel)
  local trk = tracks[t]
  local player = params:lookup_param("voice_t" .. t):get_player()
  local seq = arp_sequence(t)
  if #seq == 0 then return end
  local burst_count = 1 + trk.repeats
  local epoch = play_epoch
  clock.run(function()
    for i = 1, burst_count do
      if i > 1 then
        local progress = (i - 2) / math.max(burst_count - 2, 1)
        local pace_factor = math.max(1 - (trk.pace / 63) * progress * 0.5, 0.1)
        clock.sync(trk.repeat_time * pace_factor)
        if epoch ~= play_epoch then return end -- stopped (or restarted) meanwhile: drop the rest of the burst
      end
      trk.arp_pos = trk.arp_pos % #seq
      local note = apply_phrase(t, pos, seq[trk.arp_pos + 1])
      trk.arp_pos = trk.arp_pos + 1
      local vel = util.clamp(base_vel + trk.ramp * (i / burst_count), 0, 127)
      player:note_on(note, vel / 127)
      clock.run(function()
        clock.sync(trk.repeat_time / 2)
        player:note_off(note)
      end)
    end
  end)
end

local function trigger_track(t, pos)
  local trk = tracks[t]
  local player = params:lookup_param("voice_t" .. t):get_player()
  local vel = step_accent(t, pos) and util.clamp(trk.velocity + trk.accent_amount, 0, 127) or trk.velocity
  -- accent groove: bipolar velocity modulation over time, layered on top
  vel = util.clamp(vel + groove_curve_value(t) * trk.groove_amount, 0, 127)

  if trk.arp_enabled then
    trigger_arp_burst(t, pos, vel)
    return
  end

  local notes_to_play = {}
  for note, _ in pairs(trk.notes) do
    table.insert(notes_to_play, apply_phrase(t, pos, note))
  end
  for _, note in ipairs(notes_to_play) do
    player:note_on(note, vel / 127)
  end
  if #notes_to_play == 0 then return end
  clock.run(function()
    clock.sync(1 / 8)
    for _, note in ipairs(notes_to_play) do
      player:note_off(note)
    end
  end)

  trigger_repeats(t, notes_to_play, vel)
end

-- one coroutine per track, each free-running at that track's own division --
-- this is what makes per-track polymeter/polyrhythm possible.
local function start_track_sequencer(t)
  clock.run(function()
    while true do
      clock.sync(tracks[t].division)
      if playing then
        local trk = tracks[t]
        random_tick(t)
        if not track_muted(t) and trk.length > 0 then
          local pos = (trk.step % trk.length) + 1
          if step_active(t, pos) and math.random(100) <= step_probability(t, pos) then
            local micro = step_microtiming(t, pos)
            if micro > 0 then
              clock.run(function()
                clock.sync(trk.division * (micro / 100))
                trigger_track(t, pos)
              end)
            else
              trigger_track(t, pos)
            end
          end
          trk.step = trk.step + 1
        end
        if t == selected_track then
          redraw_grid() -- reflects the step that was just triggered, before advancing
        end
      end
    end
  end)
end

-- flashes the logo on every quarter note, independent of any track's division
local function start_logo_beat()
  clock.run(function()
    while true do
      clock.sync(1)
      if playing then
        logo_on = true
        redraw_grid()
        clock.sleep(0.08)
        logo_on = false
        redraw_grid()
      end
    end
  end)
end

-- advances the shared accent-groove phase at a fixed 16th-note rate,
-- independent of any track's own division
local function start_groove_clock()
  clock.run(function()
    while true do
      clock.sync(1 / 4)
      if playing then
        groove_pos = groove_pos + 1

        -- quantized pattern switches (and song-chain advances): checked
        -- here (a shared, always-on 16th note clock) so "next bar" means
        -- the same musical moment for every track, regardless of each
        -- track's own division. Song mode takes priority over a manually
        -- queued switch -- it drives what plays as long as it's on.
        for t = 1, NUM_TRACKS do
          local trk = tracks[t]
          if trk.song_enabled or trk.pending_pattern then
            local steps16 = math.max(1, round(ALL_DIVISIONS[trk.pattern_quantize] * 4))
            if groove_pos % steps16 == 0 then
              if trk.song_enabled then
                local start = trk.song_pos
                for _ = 1, 16 do
                  trk.song_pos = (trk.song_pos % 16) + 1
                  if trk.song_chain[trk.song_pos] then
                    do_pattern_switch(t, trk.song_chain[trk.song_pos])
                    break
                  end
                  if trk.song_pos == start then break end -- chain is empty
                end
              else
                do_pattern_switch(t, trk.pending_pattern)
              end
              if t == selected_track then redraw_grid() end
            end
          end
        end
      end
    end
  end)
end

local function start_sequencer()
  for t = 1, NUM_TRACKS do
    start_track_sequencer(t)
  end
  start_logo_beat()
  start_groove_clock()
end

-- ==== norns hardware UI (screen + encoders/keys) ====

-- a held temporary page takes over the controls; otherwise the current
-- page's selected sub-page owns them
local function current_subpage_def()
  if active_temp_page then return temp_pages[active_temp_page] end
  return subpages[page][current_subpage[page]]
end

-- a slot (e2/k2/e3/k3) counts as assigned only if present and, when it
-- declares an `available` guard, currently available
local function slot_ready(slot)
  return slot ~= nil and (slot.available == nil or slot.available())
end

function enc(n, d)
  if n == 1 then
    if active_temp_page then return end -- a temp page is a single view; nothing to cycle
    local list = subpages[page]
    current_subpage[page] = ((current_subpage[page] - 1 + d) % #list) + 1
    redraw()
  elseif n == 2 then
    local sp = current_subpage_def()
    if slot_ready(sp.e2) then
      sp.e2.delta(d)
      if active_temp_page then temp_page_used = true end
      redraw_grid()
    end
    redraw()
  elseif n == 3 then
    local sp = current_subpage_def()
    if slot_ready(sp.e3) then
      sp.e3.delta(d)
      if active_temp_page then temp_page_used = true end
      redraw_grid()
    end
    redraw()
  end
end

function key(n, z)
  if n == 1 then return end -- K1 is unused

  if z ~= 1 then return end
  local sp = current_subpage_def()
  if n == 2 and slot_ready(sp.k2) then
    sp.k2.action()
    if active_temp_page then temp_page_used = true end
    redraw_grid()
  elseif n == 3 and slot_ready(sp.k3) then
    sp.k3.action()
    if active_temp_page then temp_page_used = true end
    redraw_grid()
  end
end

-- small filled "dot" built only from rects (no arcs/circles: those leave a
-- stray line from the prior current-point on this screen lib) -- a 4x4
-- square with its 4 corner pixels shaved off.
function draw_round_dot(x, y)
  screen.rect(x + 1, y, 2, 1)
  screen.fill()
  screen.rect(x, y + 1, 4, 2)
  screen.fill()
  screen.rect(x + 1, y + 3, 2, 1)
  screen.fill()
end

-- 4x4 icon evoking the grid's default Euclidean staircase shape: 3/2/1 lit
-- pixels per row, last row empty -- used where a page has only one pad-param.
function draw_grid_icon(x, y)
  local widths = {3, 2, 1, 0}
  for i = 0, 3 do
    local w = widths[i + 1]
    if w > 0 then
      screen.level(15)
      screen.rect(x, y + i, w, 1)
      screen.fill()
    end
    if w < 4 then
      screen.level(3)
      screen.rect(x + w, y + i, 4 - w, 1)
      screen.fill()
    end
  end
end

-- indicator (":"/".") bright, label dim, value bright -- left aligned
function param_left(x, y, indicator, label, value)
  screen.move(x, y)
  screen.level(15)
  screen.text(indicator .. " ")
  screen.level(5)
  screen.text(label .. " ")
  screen.level(15)
  screen.text(value)
end

-- stacked-row icon: `total` rows tall. Lit rows show this param's position
-- in the top-to-bottom-then-left-to-right reading order of the page's
-- params; a 2-row-span param lights two consecutive rows instead of one.
function draw_param_icon(x, y, index, span, total)
  span = span or 1
  total = total or 4
  for i = 0, total - 1 do
    local lit = i >= (index - 1) and i < (index - 1 + span)
    screen.level(lit and 15 or 3)
    screen.rect(x, y + i, 4, 1)
    screen.fill()
  end
end

function param_idx(x, y, index, label, value, span, total)
  total = total or 4
  draw_param_icon(x, y - total, index, span, total)
  screen.move(x + 6, y)
  screen.level(5)
  screen.text(label .. " ")
  screen.level(15)
  screen.text(value)
end

function redraw()
  screen.clear()
  screen.level(15)
  screen.font_size(8)

  local sp = current_subpage_def()

  -- Playing/stopped, track number, and page name being *selected* are NOT
  -- repeated here -- the grid already shows all three (logo flash, scene
  -- highlight, top-row button). The main page name itself is shown though,
  -- since nothing on the grid spells it out.
  screen.move(0, 8)
  screen.level(15)
  screen.text(page:sub(1, 1):upper() .. page:sub(2))

  -- Launchpad unplugged: the grid is dark, so the screen is the only place
  -- to say so. 5x5 "X" in the gap between page name and sub-page name.
  if pad and not pad.connected then
    for i = 0, 4 do
      screen.rect(58 + i, 3 + i, 1, 1)
      screen.fill()
      if i ~= 2 then
        screen.rect(62 - i, 3 + i, 1, 1)
        screen.fill()
      end
    end
  end

  if active_temp_page then
    local w = screen.text_extents(sp.name)
    screen.move(128 - w, 8)
    screen.text(sp.name)
  else
    local list = subpages[page]
    if #list > 1 then
      local idx = current_subpage[page]
      local dots_w = #list * 5
      local w_name = screen.text_extents(sp.name)
      screen.move(128 - dots_w - w_name - 3, 8)
      screen.text(sp.name)

      -- one dot per sub-page, top-right, current one bright
      local dot_x = 128 - dots_w
      for i = 1, #list do
        screen.level(i == idx and 15 or 4)
        screen.rect(dot_x + (i - 1) * 5, 4, 3, 3)
        screen.fill()
      end
      screen.level(15)
    end
  end

  -- two columns, matching the physical layout (E2 sits above K2, E3 above K3)
  if slot_ready(sp.e2) then
    screen.level(15)
    draw_round_dot(0, 15)
    screen.move(7, 19)
    screen.level(5)
    screen.text(sp.e2.label())
    screen.level(15)
    screen.text(" " .. sp.e2.value())
  else
    screen.level(5)
    draw_round_dot(0, 15)
    screen.move(7, 19)
    screen.text("--")
  end
  if slot_ready(sp.k2) then
    screen.level(15)
    screen.line_width(1)
    if sp.k2.state() then
      screen.rect(0, 24, 4, 4)
      screen.fill()
    else
      screen.rect(0.5, 24.5, 3, 3)
      screen.stroke()
    end
    screen.move(7, 28)
    screen.text(sp.k2.label())
  else
    screen.level(5)
    screen.line_width(1)
    screen.rect(0.5, 24.5, 3, 3)
    screen.stroke()
    screen.move(7, 28)
    screen.text("--")
  end

  if slot_ready(sp.e3) then
    screen.level(15)
    draw_round_dot(64, 15)
    screen.move(71, 19)
    screen.level(5)
    screen.text(sp.e3.label())
    screen.level(15)
    screen.text(" " .. sp.e3.value())
  else
    screen.level(5)
    draw_round_dot(64, 15)
    screen.move(71, 19)
    screen.text("--")
  end
  if slot_ready(sp.k3) then
    screen.level(15)
    screen.line_width(1)
    if sp.k3.state() then
      screen.rect(64, 24, 4, 4)
      screen.fill()
    else
      screen.rect(64.5, 24.5, 3, 3)
      screen.stroke()
    end
    screen.move(71, 28)
    screen.text(sp.k3.label())
  else
    screen.level(5)
    screen.line_width(1)
    screen.rect(64.5, 24.5, 3, 3)
    screen.stroke()
    screen.move(71, 28)
    screen.text("--")
  end
  screen.level(15)

  if page == "drums" then
    local trk = tracks[selected_track]
    param_idx(0, 48, 1, "div", div_label(trk.division), 2)
    param_idx(64, 48, 3, "rpt", repeats_label(trk.repeats))
    param_idx(0, 60, 2, "time", div_label(trk.repeat_time), 2)
    param_idx(64, 60, 4, "grv", GROOVES[trk.groove])
  elseif page == "keys" then
    local trk = tracks[selected_track]
    param_idx(0, 48, 1, "root", PC_NAMES[trk.root_pc + 1], 2)
    param_idx(0, 60, 2, "scale", SCALE_NAMES[trk.scale_index], 2)
    param_idx(64, 48, 3, "arp", trk.arp_enabled and ARP_STYLES[trk.arp_style] or "--")
    param_idx(64, 60, 4, "phr", trk.phrase_enabled and PHRASE_TYPES[trk.phrase_type] or "--")
  elseif page == "user" then
    -- the rows carry no labels, so name whichever fader was touched last,
    -- with its live value (it moves while a modulation runs)
    draw_grid_icon(0, 44)
    screen.move(6, 48)
    screen.level(5)
    if last_slider then
      screen.text(USER_SLIDERS[last_slider].label .. " ")
      screen.level(15)
      screen.text(USER_SLIDERS[last_slider].value(tracks[selected_track]))
    else
      screen.text("touch a row")
    end
  elseif page == "session" then
    local trk = tracks[selected_track]
    local pat_value = trk.pending_pattern and ("-> " .. trk.pending_pattern)
      or (trk.current_pattern and tostring(trk.current_pattern) or "--")
    local song_value = trk.song_enabled and tostring(math.max(trk.song_pos, 1)) or "--"
    param_idx(0, 48, 1, "quant", div_label(ALL_DIVISIONS[trk.pattern_quantize]), 2)
    param_idx(0, 60, 2, "pat", pat_value, 2)
    param_idx(64, 48, 3, "song", song_value, 2)
  end
  screen.level(15)

  screen.update()
end

function init()
  nb:init()
  params:add_separator("LP3SEQ")
  for t = 1, NUM_TRACKS do
    nb:add_param("voice_t" .. t, "T" .. t .. " OUTPUT")
  end
  params:add_separator("VOICE CONTROLS")
  nb:add_player_params()

  init_tracks()

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
    redraw_grid()
  end

  hold_metro = metro.init(function() end, 0.45, 1)
  mute_hold_metro = metro.init(function() end, 0.3, 1)
  pulse_metro = metro.init(function()
    pulse_phase = not pulse_phase
    local needs_redraw = selected_step ~= nil or copy_mode_active or chain_edit_pos ~= nil
      or (page == "user" and last_slider ~= nil)
    if not needs_redraw then
      for t = 1, NUM_TRACKS do
        if tracks[t].momentary_mute or tracks[t].pending_pattern then
          needs_redraw = true
          break
        end
      end
    end
    if needs_redraw then redraw_grid() end
  end, 0.25)
  pulse_metro:start()

  pad = lp3.new()
  pad.key = on_key
  pad.status = function() redraw() end

  -- connect() returns false while no Launchpad is plugged in, but lp3 keeps
  -- waiting and connects it as soon as it appears: keep initialising, the
  -- LED buffer is sent at that point
  pad:connect()

  pad:set_brightness(100)
  pad:all(0)
  redraw_grid()

  start_sequencer()
  redraw()
end

function cleanup()
  if hold_metro then metro.free(hold_metro.id) end
  if mute_hold_metro then metro.free(mute_hold_metro.id) end
  if pulse_metro then metro.free(pulse_metro.id) end
  if pad then
    pad:all(0)
    pad:refresh()
    pad:disconnect()
  end
end
