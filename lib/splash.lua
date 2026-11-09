-- splash: Start-up animation. Seven Euclidean rings (one per track), each with
-- its own length, fade in and start to turn at the same step rate, so they
-- drift apart like orbits; then every playhead snaps back to the first step
-- and the name appears under them.
--
-- Everything is computed from the time t, so splash.draw(t) gives any frame
-- (used for the README screenshots). The script runs for real behind it; any
-- encoder or key stops it (see controls.lua).

local S = require 'orbits/lib/state'
local euclid = include('orbits/lib/euclid')

local splash = {active = false}

local DURATION = 4.8
local FADE_IN = 0.5     -- seconds for a ring to appear
local STAGGER = 0.08    -- delay between two rings
local PLAY_AT = 0.5     -- the playheads start
local STEP_RATE = 9     -- steps per second, the same for every ring
local ALIGN_AT = 2.6    -- every playhead snaps back to step 1
local NAME_AT = 2.4     -- the name starts to appear
local OUT_FOR = 0.4     -- final fade out

-- {length, pulses}: lengths with no common rhythm, so the rings drift
local RINGS = {{5, 2}, {7, 3}, {8, 3}, {9, 4}, {11, 5}, {12, 5}, {13, 5}}
local CY, R = 15, 8
local function ring_x(i) return 10 + (i - 1) * 18 end

local NAME, SCALE, NAME_Y = "orbits", 2, 34
local TAGLINE = "euclidean sequencer"
local GLYPHS = {
  o = {"0110", "1001", "1001", "1001", "0110"},
  r = {"1011", "1100", "1000", "1000", "1000"},
  b = {"1000", "1000", "1110", "1001", "1110"},
  i = {"1", "0", "1", "1", "1"},
  t = {"010", "111", "010", "010", "011"},
  s = {"0111", "1000", "0110", "0001", "1110"},
}

local patterns, name_cells
local start_time, ticker

local function smooth(x)
  x = math.min(math.max(x, 0), 1)
  return x * x * (3 - 2 * x)
end

local function round(x) return math.floor(x + 0.5) end

local function build()
  patterns = {}
  for i, ring in ipairs(RINGS) do patterns[i] = euclid.pattern(ring[1], ring[2]) end
  -- the name's pixels, grouped by letter so letters can appear one by one
  name_cells = {}
  local width = 0
  for i = 1, #NAME do width = width + #GLYPHS[NAME:sub(i, i)][1] + 1 end
  local left = math.floor((128 - (width - 1) * SCALE) / 2)
  local x = 0
  for i = 1, #NAME do
    local glyph = GLYPHS[NAME:sub(i, i)]
    local cells = {}
    for row, line in ipairs(glyph) do
      for col = 1, #line do
        if line:sub(col, col) == "1" then
          cells[#cells + 1] = {left + (x + col - 1) * SCALE, NAME_Y + (row - 1) * SCALE}
        end
      end
    end
    name_cells[i] = cells
    x = x + #glyph[1] + 1
  end
end

-- one frame, at time t (seconds)
function splash.draw(t)
  if not patterns then build() end
  screen.clear()
  screen.font_size(8)
  local out = 1 - smooth((t - (DURATION - OUT_FOR)) / OUT_FOR)
  local function level(l) return math.min(15, round(l * out)) end

  for i, ring in ipairs(RINGS) do
    local len = ring[1]
    local fade = smooth((t - (i - 1) * STAGGER) / FADE_IN)
    local head -- step the playhead is on (0-based), nil before it starts
    if t >= ALIGN_AT then
      head = 0
    elseif t >= PLAY_AT then
      head = math.floor((t - PLAY_AT) * STEP_RATE) % len
    end
    for k = 0, len - 1 do
      local a = -math.pi / 2 + 2 * math.pi * k / len
      local x, y = round(ring_x(i) + R * math.cos(a)), round(CY + R * math.sin(a))
      local pulse = patterns[i][k + 1]
      local l, size = pulse and 10 or 4, pulse and 2 or 1
      if k == head then
        size = 2
        if t >= ALIGN_AT then
          l = 11 + 4 * (1 - smooth((t - ALIGN_AT) / 0.5)) -- the snap-back flash
        else
          l = pulse and 15 or 9
        end
      end
      screen.level(level(l * fade))
      screen.rect(x, y, size, size)
      screen.fill()
    end
  end

  for i, cells in ipairs(name_cells) do
    local a = smooth((t - NAME_AT - (i - 1) * 0.07) / 0.3)
    if a > 0 then
      screen.level(level(15 * a))
      for _, c in ipairs(cells) do
        screen.rect(c[1], c[2], SCALE, SCALE)
        screen.fill()
      end
    end
  end

  local a = smooth((t - NAME_AT - 0.5) / 0.4)
  if a > 0 then
    screen.level(level(5 * a))
    screen.move(round((128 - screen.text_extents(TAGLINE)) / 2), 57)
    screen.text(TAGLINE)
  end
  screen.update()
end

-- called by display.redraw while the animation is up
function splash.redraw()
  local t = util.time() - start_time
  if t >= DURATION then
    splash.stop()
    return
  end
  splash.draw(t)
end

function splash.start()
  build()
  start_time = util.time()
  splash.active = true
  ticker = metro.init(function() S.redraw_screen() end, 1 / 30)
  ticker:start()
  S.redraw_screen()
end

-- ends the animation and puts the normal screen back
function splash.stop()
  if not splash.active then return end
  splash.free()
  S.redraw_screen()
end

-- ends the animation without drawing anything (script cleanup)
function splash.free()
  splash.active = false
  if ticker then
    metro.free(ticker.id)
    ticker = nil
  end
end

return splash
