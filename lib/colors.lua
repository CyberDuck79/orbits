-- colors: Colour palette (RGB triples, 0-127 per channel) and colour helpers.
-- One hue per parameter type, shared by the pad selectors and the User-page
-- faders.

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

return {
  AMBER = AMBER,
  ARP_SELECTED = ARP_SELECTED,
  CHAIN_STEP = CHAIN_STEP,
  CHAIN_STEP_ACTIVE = CHAIN_STEP_ACTIVE,
  DIM = DIM,
  DIVISION_SELECTED = DIVISION_SELECTED,
  GROOVE_SELECTED = GROOVE_SELECTED,
  MANUAL = MANUAL,
  OUT_OF_SCALE = OUT_OF_SCALE,
  PATTERN_ACTIVE = PATTERN_ACTIVE,
  PATTERN_SAVED = PATTERN_SAVED,
  PHRASE_SELECTED = PHRASE_SELECTED,
  RED = RED,
  REPEATS_SELECTED = REPEATS_SELECTED,
  ROOT_COLOR = ROOT_COLOR,
  SCALE_SELECTED = SCALE_SELECTED,
  VELOCITY_COLOR = VELOCITY_COLOR,
  brighten = brighten,
  scale_color = scale_color,
}
