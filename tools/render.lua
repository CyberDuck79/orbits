-- Generates the SVG illustrations used by the README (docs/img/*.svg).
--
--   lua tools/render.lua <root> <out-dir>
--
-- <root> is the directory that contains the `lp3seq/` folder. The script runs
-- for real against stubbed norns/lp3 APIs; the Launchpad LED buffer and the
-- screen draw calls it produces are captured and drawn as SVG, so the pictures
-- always match what the code does. Use tools/render.sh to run it on the norns
-- and bring the files back.

local root, outdir = arg[1], arg[2]
assert(root and outdir, "usage: render.lua <root> <out-dir>")

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

-- screen: captures draw calls into a list of SVG elements
local SCALE = 4
local ops, cx, cy, level, path, lw
local function reset_screen() ops, cx, cy, level, path, lw = {}, 0, 0, 15, {}, 1 end
reset_screen()
local function grey(l) local v = math.floor(l / 15 * 255 + 0.5); return string.format("#%02x%02x%02x", v, v, v) end
local function extents(s) return #tostring(s) * 4.6 end
local last_frame
screen = {
  clear = reset_screen,
  level = function(l) level = l end,
  font_size = function() end,
  line_width = function(w) lw = w end,
  move = function(x, y) cx, cy = x, y end,
  text = function(s)
    s = tostring(s)
    ops[#ops + 1] = string.format(
      '<text x="%g" y="%g" fill="%s" xml:space="preserve">%s</text>',
      cx * SCALE, cy * SCALE, grey(level), (s:gsub("&", "&amp;"):gsub("<", "&lt;")))
    cx = cx + extents(s)
  end,
  text_extents = extents,
  rect = function(x, y, w, h) path[#path + 1] = {x, y, w, h} end,
  fill = function()
    for _, r in ipairs(path) do
      ops[#ops + 1] = string.format('<rect x="%g" y="%g" width="%g" height="%g" fill="%s"/>',
        r[1] * SCALE, r[2] * SCALE, r[3] * SCALE, r[4] * SCALE, grey(level))
    end
    path = {}
  end,
  stroke = function()
    for _, r in ipairs(path) do
      ops[#ops + 1] = string.format(
        '<rect x="%g" y="%g" width="%g" height="%g" fill="none" stroke="%s" stroke-width="%g"/>',
        r[1] * SCALE, r[2] * SCALE, r[3] * SCALE, r[4] * SCALE, grey(level), lw * SCALE)
    end
    path = {}
  end,
  update = function() last_frame = table.concat(ops, "\n") end,
}

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
local display = require 'lp3seq/lib/display'

-- ------------------------------------------------------------ SVG utils ----
local function write(name, text)
  local f = assert(io.open(outdir .. "/" .. name, "w"))
  f:write(text)
  f:close()
end

local FONT = 'font-family="-apple-system, Segoe UI, Helvetica, Arial, sans-serif"'
local INK, MUTED, CARD = "#e8e8ec", "#9a9aa6", "#1c1c21"

-- screen image: 128x64 OLED
local function screen_svg(name)
  reset_screen()
  S.redraw_screen()
  local W, H, PAD = 128 * SCALE, 64 * SCALE, 14
  write(name, string.format([[
<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">
<rect width="100%%" height="100%%" rx="14" fill="%s"/>
<g transform="translate(%d,%d)" shape-rendering="crispEdges" font-family="Helvetica, Arial, sans-serif" font-size="%d">
<rect width="%d" height="%d" fill="#000"/>
%s
</g>
</svg>
]], W + 2 * PAD, H + 2 * PAD, W + 2 * PAD, H + 2 * PAD, "#2a2a30", PAD, PAD, 8 * SCALE, W, H, last_frame))
end

local function lerp8(v) return math.floor(255 * (v / 127) ^ 0.75 + 0.5) end
local function hex(c) return string.format("#%02x%02x%02x", lerp8(c[1]), lerp8(c[2]), lerp8(c[3])) end

-- Launchpad image. `labels` = {left = {[y] = text}, right = {[y] = text},
-- top = {[x] = text}, notes = {...}} drawn around the device.
local CELL, GAP = 44, 6
local function pad_svg(name, labels)
  labels = labels or {}
  local LEFT = labels.left and 250 or 20
  local RIGHT = labels.right and 120 or 20
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
        add('<circle cx="%g" cy="%g" r="9" fill="%s" stroke="#34343c"/>', x0 + CELL / 2, y0 + CELL / 2, lit and fill or "#222")
      elseif y == 9 or x == 9 then
        add('<circle cx="%g" cy="%g" r="%g" fill="%s" stroke="%s"/>', x0 + CELL / 2, y0 + CELL / 2, CELL / 2 - 6, fill, lit and "#00000040" or "#2a2a30")
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

-- --------------------------------------------------------- scenario state ----
local function draw_everything()
  S.redraw_grid()
end

local function reset_state()
  S.init_tracks()
  S.page = "drums"
  S.selected_track = 1
  S.playing = false
  S.selected_step = nil
  S.last_slider = nil
  S.active_temp_page = nil
  S.copy_mode_active = false
  S.chain_edit_pos = nil
  S.pulse_phase = true
  S.logo_on = false
  for k in pairs(S.current_subpage) do S.current_subpage[k] = 1 end
end

local T = S.tracks

local function drums_scene()
  reset_state()
  local trk = T[1]
  trk.length, trk.pulses, trk.rotation = 16, 5, 2
  trk.manual[8] = {active = true, accent = false, probability = 100, microtiming = 0}
  trk.pulse_accents[1] = true
  trk.division = consts.DIVISIONS_STRAIGHT[5]
  trk.repeat_time = consts.DIVISIONS_STRAIGHT[6]
  trk.repeats = 3
  trk.groove = 7
  T[3].mute = true
  T[5].mute = true
  S.playing, trk.step = true, 5
  S.logo_on = true
end

-- ------------------------------------------------------------------ pads ----
local pages_top = {[5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"}
local DIV_S = table.concat({"1/1", "1/128"}, " → ")

drums_scene()
S.page = "drums"
draw_everything()
pad_svg("pad-drums.svg", {
  left = {
    [8] = "steps 1–8", [7] = "steps 9–16",
    [6] = "division: 1/1 → 1/128", [5] = "division: 1/4. → 1/64t",
    [4] = "repeat time: 1/1 → 1/128", [3] = "repeat time: 1/4. → 1/64t",
    [2] = "repeats: off, 1× → 7×", [1] = "groove: agogo → pulse",
  },
  right = {[8] = "track 1", [7] = "track 2", [6] = "track 3", [5] = "track 4", [4] = "track 5", [3] = "track 6", [2] = "track 7", [1] = "play / shift"},
  top = {[1] = "pulses +", [2] = "pulses −", [3] = "rotate ←", [4] = "rotate →", [5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
})

-- the same page while editing a step
drums_scene()
S.selected_step = 8
S.pulse_phase = false -- the selected step blinks: show its dim phase
draw_everything()
pad_svg("pad-drums-edit.svg", {
  left = {[8] = "steps 1–8", [7] = "steps 9–16"},
  top = {[5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
  caption = "step 8 selected: its pad blinks and its settings move to the norns screen",
})

-- Keys
reset_state()
S.page = "keys"
local k = T[1]
k.root_pc, k.scale_index = 0, 7
k.notes = {[36] = true, [39] = true, [43] = true}
k.arp_style, k.phrase_type = 3, 4
k.arp_enabled, k.phrase_enabled = true, true
draw_everything()
pad_svg("pad-keys.svg", {
  left = {
    [8] = "sharps", [7] = "notes: C → C",
    [6] = "root: sharps", [5] = "root: C → B",
    [4] = "scale 1–8", [3] = "scale 9–16",
    [2] = "arp style", [1] = "phrase type",
  },
  right = {[8] = "track 1", [7] = "track 2", [6] = "track 3", [5] = "track 4", [4] = "track 5", [3] = "track 6", [2] = "track 7", [1] = "play / shift"},
  top = {[1] = "oct ↑", [2] = "oct ↓", [3] = "−1 st", [4] = "+1 st", [5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
})

-- User
reset_state()
S.page = "user"
local u = T[1]
u.length, u.pulses, u.rotation = 16, 5, 2
u.velocity, u.repeats, u.ramp, u.pace = 100, 3, 20, -10
u.groove_amount, u.groove = 60, 7
local function enable(id, amount, rate, base_val)
  local sl
  for _, s in ipairs(modulation.USER_SLIDERS) do if s.id == id then sl = s end end
  modulation.set_modulation_enabled(1, sl, true)
  local r = u.random_states[id]
  r.amount, r.rate_index = amount, rate
  return r, sl
end
local r1, s1 = enable("velocity", 40, 3)
r1.pos = 3
s1.set(u, 80)
r1.last = 80
local r2, s2 = enable("pulses", 50, 2)
r2.pos = 5
s2.set(u, 7)
r2.last = 7
S.last_slider = 3
draw_everything()
pad_svg("pad-user.svg", {
  left = {
    [8] = "pulses", [7] = "rotation", [6] = "velocity", [5] = "rpt",
    [4] = "rpt ramp", [3] = "rpt pace", [2] = "grv amt", [1] = "grv shape",
  },
  right = {[8] = "track 1", [7] = "track 2", [6] = "track 3", [5] = "track 4", [4] = "track 5", [3] = "track 6", [2] = "track 7", [1] = "play / shift"},
  top = {[5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
})

-- Session
reset_state()
S.page = "session"
local s = T[1]
for _, slot in ipairs({1, 2, 3, 5, 9, 12}) do s.patterns[slot] = {} end
s.current_pattern, s.pending_pattern = 2, 3
s.pattern_quantize = 3
s.song_chain = {[1] = 1, [2] = 2, [3] = 2, [4] = 5}
s.song_enabled, s.song_pos = true, 2
draw_everything()
pad_svg("pad-session.svg", {
  left = {
    [8] = "quantize: 1/1 → 1/128", [7] = "quantize: 1/4. → 1/64t",
    [6] = "patterns 1–8", [5] = "patterns 9–16", [4] = "patterns 17–24", [3] = "patterns 25–32",
    [2] = "song chain 1–8", [1] = "song chain 9–16",
  },
  right = {[8] = "track 1", [7] = "track 2", [6] = "track 3", [5] = "track 4", [4] = "track 5", [3] = "track 6", [2] = "track 7", [1] = "play / shift"},
  top = {[5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
})

-- overview: the controls shared by every page (Drums page shown dimmed content-wise)
drums_scene()
draw_everything()
pad_svg("pad-overview.svg", {
  right = {
    [8] = "track 1 (selected)", [7] = "track 2", [6] = "track 3 (muted)", [5] = "track 4",
    [4] = "track 5 (muted)", [3] = "track 6", [2] = "track 7", [1] = "play / shift",
  },
  top = {[1] = "↑", [2] = "↓", [3] = "←", [4] = "→", [5] = "Session", [6] = "Drums", [7] = "Keys", [8] = "User"},
})

-- ---------------------------------------------------------------- screens ----
local function with(fn, name)
  reset_state()
  fn()
  draw_everything()
  screen_svg(name)
end

with(function()
  local t = T[1]
  t.length, t.pulses = 16, 5
  t.repeats, t.groove = 3, 7
end, "screen-drums.svg")

with(function()
  drums_scene()
  S.selected_step = 8
  T[1].manual[8] = {active = true, accent = true, probability = 75, microtiming = 10}
end, "screen-drums-step.svg")

with(function() S.current_subpage.drums = 2 end, "screen-drums-velocity.svg")
with(function() S.current_subpage.drums = 3 end, "screen-drums-repeat.svg")
with(function() S.current_subpage.drums = 4 end, "screen-drums-groove.svg")

with(function()
  S.page = "keys"
  local t = T[1]
  t.scale_index, t.arp_enabled, t.arp_style = 7, true, 3
  t.phrase_enabled, t.phrase_type, t.phrase_range = true, 4, 40
  t.arp_octaves = 2
end, "screen-keys.svg")

with(function()
  S.page = "user"
  S.last_slider = 3
  modulation.set_modulation_enabled(1, modulation.USER_SLIDERS[3], true)
  local r = T[1].random_states.velocity
  r.amount, r.rate_index = 40, 3
end, "screen-user.svg")

with(function() S.page = "user" end, "screen-user-empty.svg")

with(function()
  S.page = "session"
  T[1].patterns[2] = {}
  T[1].current_pattern = 2
  T[1].song_enabled, T[1].song_pos = true, 2
end, "screen-session.svg")

with(function() S.active_temp_page = "tempo" end, "screen-tempo.svg")

with(function() pad.connected = false end, "screen-disconnected.svg")
pad.connected = true

print("ok")
