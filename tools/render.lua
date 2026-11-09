-- Generates the Launchpad illustrations of the README (docs/img/pad-*.svg).
--
--   lua tools/render.lua <root> <scenes.lua> <out-dir>
--
-- <root> is the directory that contains the `lp3seq/` folder. The script runs
-- for real against stubbed norns/lp3 APIs; the LED buffer it produces for each
-- scene (see scenes.lua) is drawn as SVG, so the pictures always match what
-- the code does. The screen pictures are real norns screenshots instead (see
-- screenshots.sh). tools/render.sh runs this on the norns and fetches the files.

local root, scenes_file, outdir = arg[1], arg[2], arg[3]
assert(root and scenes_file and outdir, "usage: render.lua <root> <scenes.lua> <out-dir>")

-- ---------------------------------------------------------------- stubs ----
local BPM = 120
clock = {
  run = function() end, sync = function() end, sleep = function() end,
  cancel = function() end, get_beats = function() return 0 end,
  get_tempo = function() return BPM end,
}
metro = {
  init = function(fn) return {id = 1, event = fn, start = function() end, stop = function() end} end,
  free = function() end,
}
util = {
  clamp = function(x, lo, hi) return math.min(math.max(x, lo), hi) end,
  file_exists = function() return false end,
}
tab = {save = function() end, load = function() end}
params = setmetatable({
  lookup_param = function()
    return {get_player = function() return {note_on = function() end, note_off = function() end} end}
  end,
  get = function(_, k) if k == "clock_tempo" then return BPM end return 0 end,
}, {__index = function() return function() end end})
screen = setmetatable({text_extents = function(s) return #tostring(s) * 5 end},
  {__index = function() return function() end end})

-- fake Launchpad: keeps the whole LED buffer
local buf = {}
local pad = {connected = true}
function pad:connect() return true end
function pad:disconnect() end
function pad:set_brightness() end
function pad:led(x, y, c) buf[x .. "," .. y] = c == 0 and {0, 0, 0} or {c, c, c} end
function pad:led_rgb(x, y, r, g, b) buf[x .. "," .. y] = {r, g, b} end
function pad:all() buf = {} end
function pad:refresh() end

package.path = root .. "/?.lua;" .. package.path
package.preload["lp3/lib/mod"] = function() return {new = function() return pad end} end
local nb_stub = {init = function() end, add_param = function() end, add_player_params = function() end}
function include(file)
  if file:find("lib/nb/lib/nb", 1, true) then return nb_stub end
  return dofile(root .. "/" .. file .. ".lua")
end
dofile(root .. "/lp3seq/lp3seq.lua")
init()

local S = require 'lp3seq/lib/state'
local consts = require 'lp3seq/lib/consts'
local modulation = require 'lp3seq/lib/modulation'
local scenes = dofile(scenes_file)(S, consts, modulation)

-- ------------------------------------------------------------ SVG utils ----
local function write(name, text)
  local f = assert(io.open(outdir .. "/" .. name, "w"))
  f:write(text)
  f:close()
end

local FONT = 'font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif"'
local INK, MUTED, CARD = "#e8e8ec", "#9a9aa6", "#1c1c21"

local function lerp8(v) return math.floor(255 * (v / 127) ^ 0.75 + 0.5) end
local function hex(c) return string.format("#%02x%02x%02x", lerp8(c[1]), lerp8(c[2]), lerp8(c[3])) end

-- Launchpad Mini MK3 picture. `labels` = {left = {[y] = text}, right = {[y] = text},
-- top = {[x] = text}, caption = text} written around the device.
local CELL, GAP = 44, 6
local function pad_svg(name, labels)
  labels = labels or {}
  local LEFT = labels.left and 250 or 20
  local RIGHT = labels.right and 150 or 20
  local TOP = labels.top and 50 or 20
  local BOTTOM = 20
  local pitch = CELL + GAP
  local gw = pitch * 9
  local W, H = LEFT + gw + RIGHT, TOP + gw + BOTTOM + (labels.caption and 28 or 0)
  local out = {}
  local function add(s, ...) out[#out + 1] = string.format(s, ...) end
  add('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" %s>', W, H, W, H, FONT)
  add('<rect width="100%%" height="100%%" rx="14" fill="%s"/>', CARD)
  add('<rect x="%d" y="%d" width="%d" height="%d" rx="14" fill="#0d0d10" stroke="#34343c"/>',
    LEFT - 8, TOP - 8, gw + 10, gw + 10)
  local function px(x) return LEFT + (x - 1) * pitch end
  local function py(y) return TOP + (9 - y) * pitch end
  for y = 1, 9 do
    for x = 1, 9 do
      local c = buf[x .. "," .. y] or {0, 0, 0}
      local lit = (c[1] + c[2] + c[3]) > 0
      local fill = lit and hex(c) or "#17171b"
      local x0, y0 = px(x), py(y)
      if x == 9 and y == 9 then
        -- the logo: a small LED, not a button
        add('<rect x="%g" y="%g" width="16" height="16" rx="4" fill="%s" stroke="#34343c"/>', x0 + CELL / 2 - 8, y0 + CELL / 2 - 8, lit and fill or "#222")
      else
        add('<rect x="%g" y="%g" width="%d" height="%d" rx="7" fill="%s" stroke="%s"/>', x0, y0, CELL, CELL, fill, lit and "#00000040" or "#2a2a30")
      end
    end
  end
  -- arrow glyphs on the first four top buttons
  local function tri(x, pts)
    local x0, y0 = px(x) + CELL / 2, py(9) + CELL / 2
    local c = buf[x .. ",9"] or {0, 0, 0}
    local on = (c[1] + c[2] + c[3]) > 0
    local p = {}
    for i = 1, #pts, 2 do p[#p + 1] = string.format("%g,%g", x0 + pts[i], y0 + pts[i + 1]) end
    add('<polygon points="%s" fill="%s"/>', table.concat(p, " "), on and "#0d0d10" or "#55555e")
  end
  tri(1, {0, -7, 7, 5, -7, 5})
  tri(2, {0, 7, 7, -5, -7, -5})
  tri(3, {-7, 0, 5, -7, 5, 7})
  tri(4, {7, 0, -5, -7, -5, 7})

  local function label(x, y, s, anchor, color, size)
    add('<text x="%g" y="%g" fill="%s" font-size="%d" text-anchor="%s">%s</text>', x, y, color or INK, size or 13,
      anchor or "start", (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;")))
  end
  if labels.left then
    for y, s in pairs(labels.left) do label(LEFT - 18, py(y) + CELL / 2 + 4, s, "end") end
  end
  if labels.right then
    for y, s in pairs(labels.right) do label(px(9) + CELL + 14, py(y) + CELL / 2 + 4, s, "start", MUTED) end
  end
  if labels.top then
    for x, s in pairs(labels.top) do label(px(x) + CELL / 2, TOP - 18, s, "middle", MUTED, 11) end
  end
  if labels.caption then label(W / 2, H - 10, labels.caption, "middle", MUTED, 12) end
  add("</svg>")
  write(name, table.concat(out, "\n"))
end

local function scene(name, svg, labels)
  scenes[name]()
  S.redraw_grid()
  pad_svg(svg, labels)
end

local TRACKS = {[8] = "track 1", [7] = "track 2", [6] = "track 3", [5] = "track 4", [4] = "track 5", [3] = "track 6", [2] = "track 7", [1] = "play / mute"}
local PAGES = {[5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"}
local function with_pages(t) for k, v in pairs(PAGES) do t[k] = v end return t end

-- Drums
scene("drums", "pad-drums.svg", {
  left = {
    [8] = "steps 1–8", [7] = "steps 9–16",
    [6] = "division: 1/1 → 1/128", [5] = "division: 1/4. → 1/64t",
    [4] = "repeat time: 1/1 → 1/128", [3] = "repeat time: 1/4. → 1/64t",
    [2] = "repeats: off, 1× → 7×", [1] = "groove: agogo → pulse",
  },
  right = TRACKS,
  top = with_pages({[1] = "pulses +", [2] = "pulses −", [3] = "rotate ←", [4] = "rotate →"}),
  caption = "amber = pulse · blue = manual step · grey = inactive",
})

scene("drums_edit", "pad-drums-edit.svg", {
  left = {[8] = "steps 1–8", [7] = "steps 9–16"},
  top = PAGES,
  caption = "step 8 selected: its pad blinks and its settings move to the norns screen",
})

scene("keys", "pad-keys.svg", {
  left = {
    [8] = "sharps", [7] = "notes: C → C",
    [6] = "root: sharps", [5] = "root: C → B",
    [4] = "scale 1–8", [3] = "scale 9–16",
    [2] = "arp style", [1] = "phrase type",
  },
  right = TRACKS,
  top = with_pages({[1] = "oct ↑", [2] = "oct ↓", [3] = "−1 st", [4] = "+1 st"}),
})

scene("user", "pad-user.svg", {
  left = {
    [8] = "pulses", [7] = "rotation", [6] = "velocity", [5] = "rpt",
    [4] = "rpt ramp", [3] = "rpt pace", [2] = "grv amt", [1] = "grv shape",
  },
  right = TRACKS,
  top = PAGES,
})

scene("session", "pad-session.svg", {
  left = {
    [8] = "quantize: 1/1 → 1/128", [7] = "quantize: 1/4. → 1/64t",
    [6] = "patterns 1–8", [5] = "patterns 9–16", [4] = "patterns 17–24", [3] = "patterns 25–32",
    [2] = "song chain 1–8", [1] = "song chain 9–16",
  },
  right = TRACKS,
  top = PAGES,
})

scene("drums", "pad-overview.svg", {
  right = {
    [8] = "track 1 (selected)", [7] = "track 2", [6] = "track 3 (muted)", [5] = "track 4",
    [4] = "track 5 (muted)", [3] = "track 6", [2] = "track 7", [1] = "play / mute",
  },
  top = with_pages({[1] = "↑", [2] = "↓", [3] = "←", [4] = "→"}),
})

print("ok")
