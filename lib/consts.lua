-- consts: Static data: track count, note layouts, clock divisions, grooves,
-- scales, arp styles, phrase types, and their display labels.

local NUM_TRACKS = 7

local BASE_NOTE = 36 -- C2

local NATURAL_OFFSETS = {0, 2, 4, 5, 7, 9, 11, 12} -- C D E F G A B C, x=1..8 on y=7

local SHARP_OFFSETS = {nil, 1, 3, nil, 6, 8, 10, nil} -- _ C# D# _ F# G# A# _, x=1..8 on y=8 (shifted right, between naturals)

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
-- Ramp/Pace reshape velocity/timing across the repeat series; they live on
-- the "repeat" screen sub-page (and as faders on the User page).
local REPEATS_VALUES = {0, 1, 2, 3, 4, 5, 6, 7}

local function repeats_label(n)
  return n == 0 and "off" or tostring(n) .. "x"
end

-- Accent: an 8-shape velocity groove (from the T1's current 8-groove set),
-- applied at a track-wide amount over a repeating length in bars.
local GROOVES = {"agogo", "timbales", "congas", "bongo", "saw", "triangle", "sine", "pulse"}

local GROOVE_LENGTHS = {1, 2, 4, 8, 16, 32, 64}

local DEFAULT_GROOVE_LENGTH_INDEX = 3 -- 4 bars, matches the T1's default

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

-- Fixed 16-step bipolar patterns standing in for the T1's percussion-derived
-- grooves (Agogo/Timbales/Congas/Bongo), since their exact curve data isn't
-- published -- tiled across the groove length like the real thing.
local PERCUSSION_GROOVES = {
  agogo = {1, -1, 0.5, -0.5, 1, -1, 0.3, -0.3, 0.8, -0.8, 0.2, -0.2, 1, -1, 0.4, -0.4},
  timbales = {1, 0.2, -1, 0.4, 0.6, -0.6, 1, -0.2, -1, 0.8, 0.1, -0.4, 1, -1, 0.5, -0.5},
  congas = {1, -0.3, 0.6, -1, 0.2, 1, -0.6, 0.3, -1, 0.5, 1, -0.2, 0.4, -1, 0.7, -0.4},
  bongo = {1, 0.5, -1, 0.2, -0.5, 1, 0.3, -1, 0.6, -0.3, 1, -0.6, 0.2, 1, -0.8, 0.4},
}

-- fixed 16-step bipolar sequence for the "random walk" phrase -- stable
-- rather than reshuffled, so the same step always gets the same offset
local PHRASE_RANDOM_WALK = {0.3, -0.6, 0.8, -0.2, 0.5, -0.9, 0.1, 0.6, -0.4, 0.9, -0.7, 0.2, -0.3, 0.7, -0.5, 0.4}

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

-- Session page: how far apart pattern changes are. One setting per track and
-- mode (live "quantize", song "length"), 16 values on two pad rows: the first
-- row in bars of the shared clock (the numbers are 16th notes, labelled like
-- the note values of the division rows), the second in loops of the track's
-- own pattern.
local QUANT_SIXTEENTHS = {1, 4, 8, 16, 32, 64, 128, 256}
local QUANT_LABELS = {"1/16", "1/4", "1/2", "1/1", "2/1", "4/1", "8/1", "16/1"}
local QUANT_LOOPS = {1, 2, 3, 4, 6, 8, 12, 16}

-- label of a value 1..16
local function quant_label(i)
  if i <= 8 then return QUANT_LABELS[i] end
  return QUANT_LOOPS[i - 8] .. "x"
end

local function repeats_index(n)
  for i, v in ipairs(REPEATS_VALUES) do
    if v == n then return i end
  end
  return 1
end

return {
  ALL_DIVISIONS = ALL_DIVISIONS,
  ARP_STYLES = ARP_STYLES,
  BASE_NOTE = BASE_NOTE,
  DEFAULT_DIVISION = DEFAULT_DIVISION,
  DEFAULT_GROOVE_LENGTH_INDEX = DEFAULT_GROOVE_LENGTH_INDEX,
  DIVISIONS_OTHER = DIVISIONS_OTHER,
  DIVISIONS_STRAIGHT = DIVISIONS_STRAIGHT,
  GROOVES = GROOVES,
  GROOVE_LENGTHS = GROOVE_LENGTHS,
  NATURAL_OFFSETS = NATURAL_OFFSETS,
  NUM_TRACKS = NUM_TRACKS,
  PC_NAMES = PC_NAMES,
  QUANT_LOOPS = QUANT_LOOPS,
  QUANT_SIXTEENTHS = QUANT_SIXTEENTHS,
  PERCUSSION_GROOVES = PERCUSSION_GROOVES,
  PHRASE_RANDOM_WALK = PHRASE_RANDOM_WALK,
  PHRASE_TYPES = PHRASE_TYPES,
  REPEATS_VALUES = REPEATS_VALUES,
  SCALES = SCALES,
  SCALE_NAMES = SCALE_NAMES,
  SHARP_OFFSETS = SHARP_OFFSETS,
  div_label = div_label,
  quant_label = quant_label,
  repeats_index = repeats_index,
  repeats_label = repeats_label,
}
