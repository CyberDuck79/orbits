-- leds: Everything drawn on the Launchpad: one draw function per page, the
-- shared columns (scenes, transport, top row) and `redraw_grid`, which also
-- refreshes the screen.

local S = require 'orbits/lib/state'
local tracks = S.tracks
local colors = require 'orbits/lib/colors'
local AMBER, ARP_SELECTED, CHAIN_STEP = colors.AMBER, colors.ARP_SELECTED, colors.CHAIN_STEP
local CHAIN_STEP_ACTIVE, DIM = colors.CHAIN_STEP_ACTIVE, colors.DIM
local DIVISION_SELECTED, GROOVE_SELECTED = colors.DIVISION_SELECTED, colors.GROOVE_SELECTED
local OUT_OF_SCALE, PATTERN_ACTIVE = colors.OUT_OF_SCALE, colors.PATTERN_ACTIVE
local PATTERN_SAVED, PHRASE_SELECTED, RED = colors.PATTERN_SAVED, colors.PHRASE_SELECTED, colors.RED
local REPEATS_SELECTED, ROOT_COLOR = colors.REPEATS_SELECTED, colors.ROOT_COLOR
local SCALE_SELECTED, brighten = colors.SCALE_SELECTED, colors.brighten
local scale_color = colors.scale_color
local consts = require 'orbits/lib/consts'
local DIVISIONS_OTHER, DIVISIONS_STRAIGHT = consts.DIVISIONS_OTHER, consts.DIVISIONS_STRAIGHT
local NATURAL_OFFSETS, NUM_TRACKS = consts.NATURAL_OFFSETS, consts.NUM_TRACKS
local REPEATS_VALUES, SHARP_OFFSETS = consts.REPEATS_VALUES, consts.SHARP_OFFSETS
local theory = require 'orbits/lib/theory'
local note_in_scale, view_root = theory.note_in_scale, theory.view_root
local steps = require 'orbits/lib/steps'
local STATE_COLOR, pulse_index_map = steps.STATE_COLOR, steps.pulse_index_map
local step_accent, step_state = steps.step_accent, steps.step_state
local modulation = require 'orbits/lib/modulation'
local USER_SLIDERS, lin_to_pad = modulation.USER_SLIDERS, modulation.lin_to_pad

local function draw_drums_page()
  local trk = tracks[S.selected_track]
  local playhead = (S.playing and trk.length > 0) and ((trk.step % trk.length) + 1) or nil
  local _, index_at = pulse_index_map(S.selected_track)
  for i = 1, 16 do
    local x = ((i - 1) % 8) + 1
    local y = (i <= 8) and 8 or 7 -- step 1 starts on the top row, continues on the bottom row
    if i > trk.length then
      S.pad:led(x, y, 0)
    else
      local state = step_state(S.selected_track, i, index_at)
      local base = STATE_COLOR[state]
      if state ~= "off" and step_accent(S.selected_track, i, index_at) then
        base = brighten(base, 0.5)
      end
      if i == S.selected_step then
        local c = scale_color(base, S.pulse_phase and 1.0 or 0.35)
        S.pad:led_rgb(x, y, c[1], c[2], c[3])
      elseif i == playhead then
        local c = brighten(base, 0.6)
        S.pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        S.pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end

  -- division rows: always visible, directly under the pattern
  for x = 1, 8 do
    local sel = trk.division == DIVISIONS_STRAIGHT[x]
    local c = sel and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 6, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local sel = trk.division == DIVISIONS_OTHER[x]
    local c = sel and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 5, c[1], c[2], c[3])
  end

  -- repeat time rows: same idea as division, one octave down
  for x = 1, 8 do
    local sel = trk.repeat_time == DIVISIONS_STRAIGHT[x]
    local c = sel and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 4, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local sel = trk.repeat_time == DIVISIONS_OTHER[x]
    local c = sel and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 3, c[1], c[2], c[3])
  end

  -- repeat count row: off, 2, 3, 4, 5, 6, 7, 8
  for x = 1, 8 do
    local sel = trk.repeats == REPEATS_VALUES[x]
    local c = sel and REPEATS_SELECTED or DIM
    S.pad:led_rgb(x, 2, c[1], c[2], c[3])
  end

  -- groove row: 8 accent curves
  for x = 1, 8 do
    local sel = trk.groove == x
    local c = sel and GROOVE_SELECTED or DIM
    S.pad:led_rgb(x, 1, c[1], c[2], c[3])
  end
end

local function draw_keys_page()
  local trk = tracks[S.selected_track]
  local root = view_root(S.selected_track)

  -- note-pool keyboard: amber = selected, dim = available, near-black = out of the current scale
  for x = 1, 8 do
    local note = root + NATURAL_OFFSETS[x]
    if trk.notes[note] then
      S.pad:led_rgb(x, 7, AMBER[1], AMBER[2], AMBER[3])
    elseif note_in_scale(S.selected_track, note) then
      S.pad:led_rgb(x, 7, DIM[1], DIM[2], DIM[3])
    else
      S.pad:led_rgb(x, 7, OUT_OF_SCALE[1], OUT_OF_SCALE[2], OUT_OF_SCALE[3])
    end
  end
  for x = 1, 8 do
    local offset = SHARP_OFFSETS[x]
    if offset == nil then
      S.pad:led(x, 8, 0)
    else
      local note = root + offset
      if trk.notes[note] then
        S.pad:led_rgb(x, 8, AMBER[1], AMBER[2], AMBER[3])
      elseif note_in_scale(S.selected_track, note) then
        S.pad:led_rgb(x, 8, DIM[1], DIM[2], DIM[3])
      else
        S.pad:led_rgb(x, 8, OUT_OF_SCALE[1], OUT_OF_SCALE[2], OUT_OF_SCALE[3])
      end
    end
  end

  -- root keyboard: same layout, single-select, no octave/scale concept of its own
  -- (naturals on the bottom of the pair, sharps on top -- same convention as the note keyboard)
  for x = 1, 8 do
    local pc = NATURAL_OFFSETS[x] % 12
    local c = (pc == trk.root_pc) and ROOT_COLOR or DIM
    S.pad:led_rgb(x, 5, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local offset = SHARP_OFFSETS[x]
    if offset == nil then
      S.pad:led(x, 6, 0)
    else
      local pc = offset % 12
      local c = (pc == trk.root_pc) and ROOT_COLOR or DIM
      S.pad:led_rgb(x, 6, c[1], c[2], c[3])
    end
  end

  -- scale rows: 16 scales across 2 rows of 8
  for x = 1, 8 do
    local c = (trk.scale_index == x) and SCALE_SELECTED or DIM
    S.pad:led_rgb(x, 4, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local idx = x + 8
    local c = (trk.scale_index == idx) and SCALE_SELECTED or DIM
    S.pad:led_rgb(x, 3, c[1], c[2], c[3])
  end

  -- arp style row
  for x = 1, 8 do
    local c = (trk.arp_style == x) and ARP_SELECTED or DIM
    S.pad:led_rgb(x, 2, c[1], c[2], c[3])
  end

  -- phrase type row
  for x = 1, 8 do
    local c = (trk.phrase_type == x) and PHRASE_SELECTED or DIM
    S.pad:led_rgb(x, 1, c[1], c[2], c[3])
  end
end

-- fill up to the dialed-in value (`base`), bright head on the live value
-- (it moves while a modulation runs), dim halo over the reachable range
-- above the base. The selected fader's head blinks.
local function draw_user_page()
  local trk = tracks[S.selected_track]
  for i, sl in ipairs(USER_SLIDERS) do
    local y = 9 - i
    local lo, hi = sl.bounds(trk)
    local live_pad = lin_to_pad(sl.get(trk), lo, hi)
    local r = trk.random_states[sl.id]
    local modulating = r ~= nil and r.enabled and r.base ~= nil
    local base_pad = modulating and lin_to_pad(r.base, lo, hi) or live_pad
    local span = (modulating and r.amount > 0 and hi > lo) and (r.amount / 127) * (hi - lo) / 2 or nil
    local body = scale_color(sl.color, 0.4)
    local head = brighten(sl.color, 0.3)
    local halo = scale_color(sl.color, 0.25)
    for x = 1, 8 do
      local c
      if x == live_pad then
        c = (i == S.last_slider and not S.pulse_phase) and body or head
      elseif x <= base_pad then
        c = body
      else
        c = DIM
        if span then
          -- the value this pad stands for, against the modulation's reach
          local vx = lo + (x - 1) / 7 * (hi - lo)
          local d = math.abs(vx - r.base)
          if sl.wrap then d = math.min(d, (hi - lo + 1) - d) end
          if d <= span + (hi - lo) / 14 then c = halo end
        end
      end
      S.pad:led_rgb(x, y, c[1], c[2], c[3])
    end
  end
end

local function draw_session_page()
  local trk = tracks[S.selected_track]

  -- quantize rows: same two lists and layout as the Drums division rows
  for x = 1, 8 do
    local c = (trk.pattern_quantize == x) and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 8, c[1], c[2], c[3])
  end
  for x = 1, 8 do
    local c = (trk.pattern_quantize == x + 8) and DIVISION_SELECTED or DIM
    S.pad:led_rgb(x, 7, c[1], c[2], c[3])
  end

  -- pattern rows: y=6 (top) -> slots 1-8, down to y=3 -> slots 25-32
  for y = 6, 3, -1 do
    local row_base = (6 - y) * 8
    for x = 1, 8 do
      local slot = row_base + x
      local base
      if slot == trk.current_pattern then
        base = PATTERN_ACTIVE
      elseif trk.patterns[slot] then
        base = PATTERN_SAVED
      else
        base = DIM
      end
      if slot == trk.pending_pattern then
        local c = scale_color(PATTERN_ACTIVE, S.pulse_phase and 1.0 or 0.35)
        S.pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        S.pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end

  -- song chain rows: y=2 -> steps 1-8, y=1 -> steps 9-16
  for y = 2, 1, -1 do
    for x = 1, 8 do
      local pos = (y == 2) and x or (x + 8)
      local base
      if trk.song_enabled and pos == trk.song_pos then
        base = CHAIN_STEP_ACTIVE
      elseif trk.song_chain[pos] then
        base = CHAIN_STEP
      else
        base = DIM
      end
      if pos == S.chain_edit_pos then
        local c = scale_color({127, 127, 127}, S.pulse_phase and 1.0 or 0.35)
        S.pad:led_rgb(x, y, c[1], c[2], c[3])
      else
        S.pad:led_rgb(x, y, base[1], base[2], base[3])
      end
    end
  end
end

local function draw_scenes()
  for t = 1, NUM_TRACKS do
    local y = 9 - t -- track 1 -> y=8 (top) .. track 7 -> y=2 (bottom, above transport)
    local trk = tracks[t]
    local selected = (t == S.selected_track)
    if trk.momentary_mute then
      local c = scale_color(RED, S.pulse_phase and 1.0 or 0.35)
      S.pad:led_rgb(9, y, c[1], c[2], c[3])
    elseif trk.mute then
      if selected then S.pad:led_rgb(9, y, 127, 0, 0) else S.pad:led_rgb(9, y, 20, 0, 0) end
    else
      if selected then S.pad:led_rgb(9, y, AMBER[1], AMBER[2], AMBER[3]) else S.pad:led_rgb(9, y, DIM[1], DIM[2], DIM[3]) end
    end
  end
end

local function draw_transport()
  if S.playing then
    S.pad:led_rgb(9, 1, 0, 127, 0)
  else
    S.pad:led_rgb(9, 1, 20, 0, 0)
  end
end

local function draw_top_row()
  local arrows_active = S.page == "drums" or S.page == "keys"
  for x = 1, 4 do
    if arrows_active then
      S.pad:led_rgb(x, 9, 20, 20, 20)
    else
      S.pad:led_rgb(x, 9, 0, 0, 0)
    end
  end
  if S.page == "session" then S.pad:led_rgb(5, 9, AMBER[1], AMBER[2], AMBER[3]) else S.pad:led_rgb(5, 9, 10, 10, 10) end
  if S.page == "drums" then S.pad:led_rgb(6, 9, AMBER[1], AMBER[2], AMBER[3]) else S.pad:led_rgb(6, 9, 10, 10, 10) end
  if S.page == "keys" then S.pad:led_rgb(7, 9, AMBER[1], AMBER[2], AMBER[3]) else S.pad:led_rgb(7, 9, 10, 10, 10) end
  if S.page == "user" then S.pad:led_rgb(8, 9, AMBER[1], AMBER[2], AMBER[3]) else S.pad:led_rgb(8, 9, 10, 10, 10) end
  if S.logo_on then
    S.pad:led_rgb(9, 9, 127, 127, 127) -- logo flashes on the beat (quarter notes)
  else
    S.pad:led(9, 9, 0)
  end
end

local function redraw_grid()
  if S.page == "drums" then
    draw_drums_page()
  elseif S.page == "keys" then
    draw_keys_page()
  elseif S.page == "user" then
    draw_user_page()
  else
    draw_session_page()
  end
  draw_scenes()
  draw_transport()
  draw_top_row()

  if S.copy_mode_active and S.page == "session" and S.copy_mode_source.track == S.selected_track then
    -- pulse the copy source pad so it's clear what the next tap will paste
    local slot = S.copy_mode_source.slot
    local sy = 6 - math.floor((slot - 1) / 8)
    local sx = ((slot - 1) % 8) + 1
    local c = scale_color({127, 127, 127}, S.pulse_phase and 1.0 or 0.35)
    S.pad:led_rgb(sx, sy, c[1], c[2], c[3])
  end

  S.pad:refresh()
  S.redraw_screen() -- keep the OLED screen in sync too
end

S.redraw_grid = redraw_grid

-- Blink clock: toggles S.pulse_phase every 250 ms (selected step, armed copy
-- mode, pending patterns, the selected fader... pulse with it) and redraws
-- the grid only when something on it is actually blinking. Every 2 s it also
-- resends all the LEDs, in case the Launchpad missed some.
local function start_blink()
  local ticks = 0
  S.pulse_metro = metro.init(function()
    S.pulse_phase = not S.pulse_phase
    -- refresh() only sends the LEDs that changed, so a pad the Launchpad
    -- missed (e.g. right after it switched to Programmer mode) would stay
    -- wrong until it changes. Resend everything every 2 s to heal that.
    ticks = ticks + 1
    if ticks % 8 == 0 and S.pad then S.pad:refresh(true) end
    local needs_redraw = S.selected_step ~= nil or S.copy_mode_active or S.chain_edit_pos ~= nil
      or (S.page == "user" and S.last_slider ~= nil)
    if not needs_redraw then
      for t = 1, NUM_TRACKS do
        if tracks[t].momentary_mute or tracks[t].pending_pattern then
          needs_redraw = true
          break
        end
      end
    end
    if needs_redraw then S.redraw_grid() end
  end, 0.25)
  S.pulse_metro:start()
end

local function stop_blink()
  if S.pulse_metro then metro.free(S.pulse_metro.id) end
end

return {
  start_blink = start_blink,
  stop_blink = stop_blink,
}
