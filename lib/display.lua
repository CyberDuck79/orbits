-- display: The OLED screen: icons and parameter widgets, and `redraw`.

local S = require 'orbits/lib/state'
local current_subpage, tracks = S.current_subpage, S.tracks
local consts = require 'orbits/lib/consts'
local ARP_STYLES, GROOVES = consts.ARP_STYLES, consts.GROOVES
local PC_NAMES, PHRASE_TYPES, SCALE_NAMES = consts.PC_NAMES, consts.PHRASE_TYPES, consts.SCALE_NAMES
local div_label, repeats_label = consts.div_label, consts.repeats_label
local quant_label = consts.quant_label
local modulation = require 'orbits/lib/modulation'
local USER_SLIDERS = modulation.USER_SLIDERS
local pages = require 'orbits/lib/pages'
local current_subpage_def, slot_ready = pages.current_subpage_def, pages.slot_ready
local step_locked = pages.step_locked
local subpages = pages.subpages
local splash = require 'orbits/lib/splash'

-- small filled "dot" built only from rects (no arcs/circles: those leave a
-- stray line from the prior current-point on this screen lib) -- a 4x4
-- square with its 4 corner pixels shaved off.
local function draw_round_dot(x, y)
  screen.rect(x + 1, y, 2, 1)
  screen.fill()
  screen.rect(x, y + 1, 4, 2)
  screen.fill()
  screen.rect(x + 1, y + 3, 2, 1)
  screen.fill()
end

-- 4x4 icon evoking the grid's default Euclidean staircase shape: 3/2/1 lit
-- pixels per row, last row empty -- used where a page has only one pad-param.
local function draw_grid_icon(x, y)
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
local function param_left(x, y, indicator, label, value)
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
local function draw_param_icon(x, y, index, span, total)
  span = span or 1
  total = total or 4
  for i = 0, total - 1 do
    local lit = i >= (index - 1) and i < (index - 1 + span)
    screen.level(lit and 15 or 3)
    screen.rect(x, y + i, 4, 1)
    screen.fill()
  end
end

local function param_idx(x, y, index, label, value, span, total)
  total = total or 4
  draw_param_icon(x, y - total, index, span, total)
  screen.move(x + 6, y)
  screen.level(5)
  screen.text(label .. " ")
  screen.level(15)
  screen.text(value)
end

-- the song chain as two rows of 8 pattern numbers, in the same order as its
-- pads (positions 1-8 on top). The playing position is bright, an armed one
-- blinks with its pad, empty positions are a dim dash.
local function draw_chain()
  local trk = tracks[S.selected_track]
  for pos = 1, 16 do
    local x = ((pos - 1) % 8) * 16 + 2
    local y = pos <= 8 and 19 or 28
    local slot = trk.song_chain[pos]
    local level
    if pos == S.chain_edit_pos then
      level = S.pulse_phase and 15 or 4
    elseif trk.song_enabled and pos == trk.song_pos then
      level = 15
    else
      level = slot and 8 or 3
    end
    screen.level(level)
    screen.move(x, y)
    screen.text(slot and tostring(slot) or "-")
  end
end

local function redraw()
  -- the clocks and the pad call this constantly; while a system menu is open
  -- the screen belongs to it, and drawing here would make the two flicker
  if norns and norns.menu and norns.menu.status() then return end
  if splash.active then return splash.redraw() end
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
  screen.text(S.page:sub(1, 1):upper() .. S.page:sub(2))

  -- Launchpad unplugged: the grid is dark, so the screen is the only place
  -- to say so. 5x5 "X" in the gap between page name and sub-page name.
  if S.pad and not S.pad.connected then
    for i = 0, 4 do
      screen.rect(58 + i, 3 + i, 1, 1)
      screen.fill()
      if i ~= 2 then
        screen.rect(62 - i, 3 + i, 1, 1)
        screen.fill()
      end
    end
  end

  if S.active_temp_page then
    local w = screen.text_extents(sp.name)
    screen.move(128 - w, 8)
    screen.text(sp.name)
  else
    -- sub-page markers, top right, one 5px cell each. On the Drums page the
    -- first cell stands for the special "step" sub-page, which E1 can't reach:
    -- a single pixel while no step is selected, and a white square blinking
    -- with the selected step's pad on the grid when it is up, to say why the
    -- page is locked. The other cells are squares, the current one bright.
    local list = subpages[S.page]
    local has_step = S.page == "drums"
    local n = #list + (has_step and 1 or 0)
    if n > 1 then
      local locked = step_locked()
      local w_name = screen.text_extents(sp.name)
      screen.move(128 - n * 5 - w_name - 3, 8)
      screen.text(sp.name)

      local x0 = 128 - n * 5
      local first = 1
      if has_step then
        if locked then
          screen.level(S.pulse_phase and 15 or 5)
          screen.rect(x0, 4, 3, 3)
        else
          screen.level(5)
          screen.rect(x0 + 1, 5, 1, 1)
        end
        screen.fill()
        first = 2
      end
      for i = 1, #list do
        screen.level((not locked and i == current_subpage[S.page]) and 15 or 4)
        screen.rect(x0 + (first + i - 2) * 5, 4, 3, 3)
        screen.fill()
      end
      screen.level(15)
    end
  end

  -- two columns, matching the physical layout (E2 sits above K2, E3 above K3)
  if sp.chain then
    draw_chain() -- this sub-page has no slots
  else
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
  end
  screen.level(15)

  if S.page == "drums" then
    local trk = tracks[S.selected_track]
    param_idx(0, 48, 1, "div", div_label(trk.division), 2)
    param_idx(64, 48, 3, "rpt", repeats_label(trk.repeats))
    param_idx(0, 60, 2, "time", div_label(trk.repeat_time), 2)
    param_idx(64, 60, 4, "grv", GROOVES[trk.groove])
  elseif S.page == "keys" then
    local trk = tracks[S.selected_track]
    param_idx(0, 48, 1, "root", PC_NAMES[trk.root_pc + 1], 2)
    param_idx(0, 60, 2, "scale", SCALE_NAMES[trk.scale_index], 2)
    param_idx(64, 48, 3, "arp", trk.arp_enabled and ARP_STYLES[trk.arp_style] or "--")
    param_idx(64, 60, 4, "phr", trk.phrase_enabled and PHRASE_TYPES[trk.phrase_type] or "--")
  elseif S.page == "user" then
    -- the rows carry no labels, so name whichever fader was touched last,
    -- with its live value (it moves while a modulation runs)
    draw_grid_icon(0, 44)
    screen.move(6, 48)
    screen.level(5)
    if S.last_slider then
      screen.text(USER_SLIDERS[S.last_slider].label .. " ")
      screen.level(15)
      screen.text(USER_SLIDERS[S.last_slider].value(tracks[S.selected_track]))
    else
      screen.text("touch a row")
    end
  elseif S.page == "session" then
    local trk = tracks[S.selected_track]
    local pat_value = trk.pending_pattern and ("-> " .. trk.pending_pattern)
      or (trk.current_pattern and tostring(trk.current_pattern) or "--")
    local song_value = trk.song_enabled and tostring(math.max(trk.song_pos, 1)) or "--"
    if S.chain_edit_pos then
      -- a chain position is armed: say which pattern it holds
      song_value = S.chain_edit_pos .. " -> " .. (trk.song_chain[S.chain_edit_pos] or "--")
    end
    local song = trk.song_enabled
    param_idx(0, 48, 1, song and "length" or "quant", quant_label(song and trk.song_length or trk.quantize), 2)
    param_idx(0, 60, 2, "pat", pat_value, 2)
    param_idx(64, 48, 3, "song", song_value, 2)
  end
  screen.level(15)

  screen.update()
end

S.redraw_screen = redraw

return {
  redraw = redraw,
}
