-- patterns: Pattern snapshots: capture / apply a track's state, switch
-- (immediate or quantized), duplicate, and save/load them with the pset.

local S = require 'lp3seq/lib/state'
local tracks = S.tracks
local consts = require 'lp3seq/lib/consts'
local BASE_NOTE, DEFAULT_DIVISION = consts.BASE_NOTE, consts.DEFAULT_DIVISION
local DEFAULT_GROOVE_LENGTH_INDEX = consts.DEFAULT_GROOVE_LENGTH_INDEX
local NUM_TRACKS = consts.NUM_TRACKS

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
  if not S.playing then
    do_pattern_switch(t, slot)
  else
    trk.pending_pattern = slot
  end
  S.redraw_grid()
end

-- long-press shortcut: duplicates the currently active pattern into `slot`,
-- then switches to it -- a quick way to branch a variation without using
-- copy/paste for the common "start from what I have" case
local function duplicate_pattern_to(t, slot)
  tracks[t].patterns[slot] = capture_pattern(t) -- always the live state, never a possibly-stale save
  queue_pattern_switch(t, slot)
end

-- slot 1 starts out holding each track's default state, so Session isn't
-- blank on first use and there's always something to fall back to
local function init_slots()
  for t = 1, NUM_TRACKS do
    tracks[t].patterns[1] = capture_pattern(t)
    tracks[t].current_pattern = 1
  end
end

-- Patterns/chains live outside the params system (they're not flat
-- scalars pset can serialize), so PSET SAVE/LOAD gets a sidecar file
-- alongside the .pset, the same technique n.kria uses for its own
-- pattern data. Tempo and voice assignments still go through the normal
-- params/pset mechanism untouched.
local function install_persistence()
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
end

return {
  apply_pattern = apply_pattern,
  capture_pattern = capture_pattern,
  deep_copy = deep_copy,
  do_pattern_switch = do_pattern_switch,
  duplicate_pattern_to = duplicate_pattern_to,
  init_slots = init_slots,
  install_persistence = install_persistence,
  queue_pattern_switch = queue_pattern_switch,
}
