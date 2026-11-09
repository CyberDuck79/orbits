-- steps: The step model of a track: Euclidean pattern with rotation, manual
-- overrides, accent, per-step probability and micro-timing, mute state.

local S = require 'lp3seq/lib/state'
local tracks = S.tracks
local colors = require 'lp3seq/lib/colors'
local AMBER, DIM, MANUAL = colors.AMBER, colors.DIM, colors.MANUAL

local euclid = include('lp3seq/lib/euclid')

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

return {
  STATE_COLOR = STATE_COLOR,
  pulse_index_map = pulse_index_map,
  set_step_microtiming = set_step_microtiming,
  set_step_probability = set_step_probability,
  step_accent = step_accent,
  step_active = step_active,
  step_microtiming = step_microtiming,
  step_probability = step_probability,
  step_state = step_state,
  toggle_manual_step = toggle_manual_step,
  toggle_step_accent = toggle_step_accent,
  track_muted = track_muted,
}
