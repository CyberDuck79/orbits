-- input: Launchpad pad handling: one handler per page, the arrow buttons, and
-- `on_key` which routes everything.

local S = require 'orbits/lib/state'
local current_subpage, tracks = S.current_subpage, S.tracks
local consts = require 'orbits/lib/consts'
local DIVISIONS_OTHER, DIVISIONS_STRAIGHT = consts.DIVISIONS_OTHER, consts.DIVISIONS_STRAIGHT
local NATURAL_OFFSETS, REPEATS_VALUES = consts.NATURAL_OFFSETS, consts.REPEATS_VALUES
local SHARP_OFFSETS = consts.SHARP_OFFSETS
local theory = require 'orbits/lib/theory'
local shift_octave_view, snap_notes_to_scale = theory.shift_octave_view, theory.snap_notes_to_scale
local toggle_note, transpose_notes = theory.toggle_note, theory.transpose_notes
local view_root = theory.view_root
local modulation = require 'orbits/lib/modulation'
local USER_SLIDERS = modulation.USER_SLIDERS
local patterns = require 'orbits/lib/patterns'
local copy_pattern, delete_pattern = patterns.copy_pattern, patterns.delete_pattern
local paste_pattern, queue_pattern_switch = patterns.paste_pattern, patterns.queue_pattern_switch
local redo, undo = patterns.redo, patterns.undo
local set_chain, slot_filled = patterns.set_chain, patterns.slot_filled
local engine = require 'orbits/lib/engine'
local toggle_play = engine.toggle_play
local pages = require 'orbits/lib/pages'
local close_temp_page, select_subpage = pages.close_temp_page, pages.select_subpage
local open_temp_page, switch_page = pages.open_temp_page, pages.switch_page

local function select_track(t)
  S.selected_track = t
  S.delete_armed = nil
  S.redraw_grid()
end

local function enter_step_edit(i)
  S.selected_step = i
  S.pulse_phase = true
  S.redraw_grid()
end

local function exit_step_edit()
  S.selected_step = nil
  current_subpage.drums = 1
  S.redraw_grid()
end

local function step_index(x, y)
  return (y == 8) and x or (x + 8)
end

local function handle_drums_key(x, y, z)
  if y == 5 or y == 6 then
    if z == 1 then
      local list = (y == 6) and DIVISIONS_STRAIGHT or DIVISIONS_OTHER
      tracks[S.selected_track].division = list[x]
      S.redraw_grid()
    end
    return
  end

  if y == 3 or y == 4 then
    if z == 1 then
      local list = (y == 4) and DIVISIONS_STRAIGHT or DIVISIONS_OTHER
      tracks[S.selected_track].repeat_time = list[x]
      S.redraw_grid()
    end
    return
  end

  if y == 2 then
    if z == 1 then
      tracks[S.selected_track].repeats = REPEATS_VALUES[x]
      select_subpage("drums", "repeat") -- even when the touched pad is already the selected one
      S.redraw_grid()
    end
    return
  end

  if y == 1 then
    if z == 1 then
      tracks[S.selected_track].groove = x
      select_subpage("drums", "groove")
      S.redraw_grid()
    end
    return
  end

  if y ~= 7 and y ~= 8 then return end
  local i = step_index(x, y)

  if z == 1 then
    S.hold_pending = i
    S.hold_metro.event = function()
      if S.hold_pending == i then
        -- a long press always (re-)enters edit mode on this pad, even if
        -- another pad was already selected -- jumps straight to it
        enter_step_edit(i)
        S.hold_pending = nil
      end
    end
    S.hold_metro:start()
  else -- release
    if S.hold_pending == i then
      -- short tap: didn't reach the long-press threshold
      S.hold_metro:stop()
      S.hold_pending = nil
      if S.selected_step ~= nil then
        exit_step_edit()
      else
        tracks[S.selected_track].length = i
        tracks[S.selected_track].pulses = util.clamp(tracks[S.selected_track].pulses, 0, i)
        S.redraw_grid()
      end
    end
  end
end

local function handle_keys_key(x, y, z)
  if z ~= 1 then return end
  local trk = tracks[S.selected_track]

  if y == 7 or y == 8 then
    local view = view_root(S.selected_track)
    if y == 7 then
      toggle_note(S.selected_track, view + NATURAL_OFFSETS[x])
    else
      local offset = SHARP_OFFSETS[x]
      if offset ~= nil then toggle_note(S.selected_track, view + offset) end
    end
    S.redraw_grid()
    return
  end

  if y == 6 or y == 5 then
    local pc
    if y == 5 then
      pc = NATURAL_OFFSETS[x] % 12
    else
      local offset = SHARP_OFFSETS[x]
      if offset == nil then return end
      pc = offset % 12
    end
    trk.root_pc = pc
    snap_notes_to_scale(S.selected_track)
    S.redraw_grid()
    return
  end

  if y == 4 or y == 3 then
    local idx = (y == 4) and x or (x + 8)
    trk.scale_index = idx
    snap_notes_to_scale(S.selected_track)
    S.redraw_grid()
    return
  end

  if y == 2 then
    trk.arp_style = x
    S.redraw_grid()
    return
  end

  if y == 1 then
    trk.phrase_type = x
    S.redraw_grid()
    return
  end
end

local function handle_user_key(x, y, z)
  if z ~= 1 then return end
  local i = 9 - y
  if USER_SLIDERS[i] == nil then return end
  -- selection only: which pad within the row doesn't matter, just which row
  S.last_slider = i
  S.redraw_grid()
end

-- Session page. Patterns: tap = switch, hold = arm deletion (then tap the
-- same pad to delete, anywhere else to cancel). With the up arrow held a
-- tap copies the pattern, with the down arrow held it pastes. Chain: tap a
-- position to arm it and a pattern to fill it, hold a position to clear it.
local function handle_session_key(x, y, z)
  local in_patterns = y >= 3 and y <= 6
  local slot = in_patterns and ((6 - y) * 8 + x) or nil

  -- deletion armed: the next press either confirms (same pad) or cancels
  if S.delete_armed then
    if z == 1 then
      local armed = S.delete_armed
      S.delete_armed = nil
      if slot and armed.track == S.selected_track and armed.slot == slot then
        delete_pattern(S.selected_track, slot)
      else
        S.redraw_grid()
      end
    end
    return
  end

  -- a Session arrow is held: tapping a pattern copies / pastes it
  if S.arrow_held and slot then
    if z == 1 then
      if S.arrow_held == 1 then
        copy_pattern(S.selected_track, slot)
      else
        paste_pattern(S.selected_track, slot)
      end
    end
    return
  end

  -- a chain position is armed: any pattern tap fills it and exits
  if S.chain_edit_pos and slot and z == 1 then
    set_chain(S.selected_track, S.chain_edit_pos, slot)
    S.chain_edit_pos = nil
    S.redraw_grid()
    return
  end

  if y == 8 or y == 7 then -- quantize: same layout as Drums' division rows
    if z == 1 then
      local trk = tracks[S.selected_track]
      local value = (y == 8) and x or (x + 8)
      if trk.song_enabled then trk.song_length = value else trk.quantize = value end
      S.redraw_grid()
    end
    return
  end

  if slot then
    if z == 1 then
      S.session_hold_pending = slot
      S.hold_metro.event = function()
        if S.session_hold_pending == slot then
          S.session_hold_pending = nil
          -- holding a filled pattern arms its deletion
          if slot_filled(S.selected_track, slot) then
            S.delete_armed = {track = S.selected_track, slot = slot}
            S.pulse_phase = true
            S.redraw_grid()
          end
        end
      end
      S.hold_metro:start()
    else -- release
      if S.session_hold_pending == slot then
        -- short tap: didn't reach the long-press threshold
        S.hold_metro:stop()
        S.session_hold_pending = nil
        -- in song mode the chain decides which pattern plays: a tap does nothing
        if not tracks[S.selected_track].song_enabled then
          queue_pattern_switch(S.selected_track, slot)
        end
      end
    end
    return
  end

  if y == 1 or y == 2 then
    -- chain steps: tap to arm for assignment (next pattern tap fills it),
    -- long-press to clear
    local pos = (y == 2) and x or (x + 8)
    if z == 1 then
      S.chain_hold_pending = pos
      S.hold_metro.event = function()
        if S.chain_hold_pending == pos then
          set_chain(S.selected_track, pos, nil)
          S.chain_hold_pending = nil
          S.redraw_grid()
        end
      end
      S.hold_metro:start()
    else -- release
      if S.chain_hold_pending == pos then
        S.hold_metro:stop()
        S.chain_hold_pending = nil
        S.chain_edit_pos = pos
        S.redraw_grid()
      end
    end
    return
  end
end

local function handle_arrow(x, z)
  if S.page == "session" then
    -- up / down are held as modifiers (copy / paste); left / right undo / redo
    if x == 1 or x == 2 then
      S.arrow_held = (z == 1) and x or nil
      S.pulse_phase = true
      S.redraw_grid() -- shows / hides the clipboard marker
    elseif z == 1 then
      if x == 3 then undo(S.selected_track) else redo(S.selected_track) end
    end
    return
  end
  if z ~= 1 then return end
  local trk = tracks[S.selected_track]
  if S.page == "drums" then
    if x == 1 then -- up: +1 pulse
      trk.pulses = util.clamp(trk.pulses + 1, 0, trk.length)
    elseif x == 2 then -- down: -1 pulse
      trk.pulses = util.clamp(trk.pulses - 1, 0, trk.length)
    elseif x == 3 then -- left: rotate earlier
      trk.rotation = trk.rotation - 1
    elseif x == 4 then -- right: rotate later
      trk.rotation = trk.rotation + 1
    end
  elseif S.page == "keys" then
    if x == 1 then -- up: view octave up (does not move selected notes)
      shift_octave_view(S.selected_track, 1)
    elseif x == 2 then -- down: view octave down (does not move selected notes)
      shift_octave_view(S.selected_track, -1)
    elseif x == 3 then -- left: transpose selected notes down a semitone
      transpose_notes(S.selected_track, -1)
    elseif x == 4 then -- right: transpose selected notes up a semitone
      transpose_notes(S.selected_track, 1)
    end
  end
  S.redraw_grid()
end

local function on_key(x, y, z)
  if x == 9 and y == 1 then
    -- Stop Solo Mute: bare tap = play/pause; held = shift for mute AND opens
    -- the tempo page, so a hold-and-adjust doesn't also toggle transport
    if z == 1 then
      S.shift_held = true
      S.shift_used = false
      open_temp_page("tempo")
      S.redraw_screen()
    else
      local adjusted = close_temp_page()
      if not S.shift_used and not adjusted then toggle_play() end
      S.shift_held = false
      S.redraw_screen()
    end
  elseif x == 9 and y >= 2 and y <= 8 then
    local t = 9 - y -- y=8 (top) -> track 1 .. y=2 (bottom) -> track 7
    if z == 1 then
      if S.shift_held then
        S.shift_used = true
        S.mute_hold_pending = t
        S.mute_hold_metro.event = function()
          if S.mute_hold_pending == t then
            tracks[t].momentary_mute = true
            S.mute_hold_pending = nil
            S.redraw_grid()
          end
        end
        S.mute_hold_metro:start()
      else
        select_track(t)
      end
    else -- release
      if S.mute_hold_pending == t then
        S.mute_hold_metro:stop()
        S.mute_hold_pending = nil
        tracks[t].mute = not tracks[t].mute
        S.redraw_grid()
      elseif tracks[t].momentary_mute then
        tracks[t].momentary_mute = false
        S.redraw_grid()
      end
    end
  elseif x == 9 and y == 9 then
    -- logo: unused
  elseif y == 9 and x >= 1 and x <= 4 then
    handle_arrow(x, z)
  elseif y == 9 and x == 6 then
    if z == 1 then switch_page("drums") end
  elseif y == 9 and x == 7 then
    if z == 1 then switch_page("keys") end
  elseif y == 9 and x == 8 then
    if z == 1 then switch_page("user") end
  elseif y == 9 and x == 5 then
    if z == 1 then switch_page("session") end
  elseif y == 9 then
    -- unused
  else
    if S.page == "drums" then
      handle_drums_key(x, y, z)
    elseif S.page == "keys" then
      handle_keys_key(x, y, z)
    elseif S.page == "user" then
      handle_user_key(x, y, z)
    elseif S.page == "session" then
      handle_session_key(x, y, z)
    end
  end
end

-- One-shot timers used to tell a tap from a long press: `hold_metro` for
-- steps and pattern slots, `mute_hold_metro` for shift + scene button. Their
-- `event` is set per press (see the handlers above).
local function create_timers()
  S.hold_metro = metro.init(function() end, 0.45, 1)
  S.mute_hold_metro = metro.init(function() end, 0.3, 1)
  S.flash_metro = metro.init(function()
    S.copy_flash = nil
    S.redraw_grid()
  end, 0.35, 1)
end

local function free_timers()
  if S.hold_metro then metro.free(S.hold_metro.id) end
  if S.mute_hold_metro then metro.free(S.mute_hold_metro.id) end
  if S.flash_metro then metro.free(S.flash_metro.id) end
end

return {
  create_timers = create_timers,
  free_timers = free_timers,
  on_key = on_key,
}
