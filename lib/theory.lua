-- theory: Musical logic that only needs a track: note pool and scale snapping,
-- groove and phrase curves, phrase application, arp note order.

local S = require 'orbits/lib/state'
local tracks = S.tracks
local consts = require 'orbits/lib/consts'
local ARP_STYLES, BASE_NOTE, GROOVES = consts.ARP_STYLES, consts.BASE_NOTE, consts.GROOVES
local GROOVE_LENGTHS, PERCUSSION_GROOVES = consts.GROOVE_LENGTHS, consts.PERCUSSION_GROOVES
local PHRASE_RANDOM_WALK, PHRASE_TYPES = consts.PHRASE_RANDOM_WALK, consts.PHRASE_TYPES
local SCALES = consts.SCALES

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

-- -1..1 velocity modulation for a track's selected groove, at the current
-- position in its (shared) phase. Saw/Triangle/Sine/Pulse are the real T1
-- waveforms; the percussion-named ones are an approximation (see above).
local function groove_curve_value(t)
  local trk = tracks[t]
  local shape = GROOVES[trk.groove]
  if shape == "saw" or shape == "triangle" or shape == "sine" or shape == "pulse" then
    local length_steps = GROOVE_LENGTHS[trk.groove_length_index] * 16 -- 16th notes per bar
    local phase = (S.groove_pos % length_steps) / length_steps -- 0..1 across the whole groove cycle
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
    return pat[(S.groove_pos % 16) + 1]
  end
end

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

return {
  apply_phrase = apply_phrase,
  arp_sequence = arp_sequence,
  groove_curve_value = groove_curve_value,
  note_in_scale = note_in_scale,
  round = round,
  shift_octave_view = shift_octave_view,
  snap_notes_to_scale = snap_notes_to_scale,
  toggle_note = toggle_note,
  transpose_notes = transpose_notes,
  view_root = view_root,
}
