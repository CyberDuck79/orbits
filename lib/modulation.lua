-- modulation: The User-page faders and the random modulation behind them:
-- fader definitions (range, accessors, colour), per-track modulation state,
-- and the per-step tick that applies it.

local S = require 'orbits/lib/state'
local tracks = S.tracks
local colors = require 'orbits/lib/colors'
local AMBER, GROOVE_SELECTED = colors.AMBER, colors.GROOVE_SELECTED
local REPEATS_SELECTED, VELOCITY_COLOR = colors.REPEATS_SELECTED, colors.VELOCITY_COLOR
local consts = require 'orbits/lib/consts'
local GROOVES, REPEATS_VALUES = consts.GROOVES, consts.REPEATS_VALUES
local repeats_index, repeats_label = consts.repeats_index, consts.repeats_label
local theory = require 'orbits/lib/theory'
local round = theory.round

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
  if not S.last_slider then return nil end
  return modulation_state(S.selected_track, USER_SLIDERS[S.last_slider], create)
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

return {
  RATE_STEPS = RATE_STEPS,
  USER_SLIDERS = USER_SLIDERS,
  focused_state = focused_state,
  fresh_random_seq = fresh_random_seq,
  lin_to_pad = lin_to_pad,
  random_tick = random_tick,
  set_modulation_enabled = set_modulation_enabled,
}
