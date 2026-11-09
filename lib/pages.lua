-- pages: Screen sub-pages and held temporary pages: what E2/K2/E3/K3 do on
-- each page, plus page navigation.

local S = require 'lp3seq/lib/state'
local current_subpage, tracks = S.current_subpage, S.tracks
local consts = require 'lp3seq/lib/consts'
local GROOVE_LENGTHS = consts.GROOVE_LENGTHS
local steps = require 'lp3seq/lib/steps'
local pulse_index_map, set_step_microtiming = steps.pulse_index_map, steps.set_step_microtiming
local set_step_probability, step_accent = steps.set_step_probability, steps.step_accent
local step_microtiming, step_probability = steps.step_microtiming, steps.step_probability
local toggle_manual_step, toggle_step_accent = steps.toggle_manual_step, steps.toggle_step_accent
local modulation = require 'lp3seq/lib/modulation'
local RATE_STEPS, USER_SLIDERS = modulation.RATE_STEPS, modulation.USER_SLIDERS
local focused_state, fresh_random_seq = modulation.focused_state, modulation.fresh_random_seq
local set_modulation_enabled = modulation.set_modulation_enabled

-- Each grid page (drums/keys/user) has a list of sub-pages. E1 cycles
-- through them; the grid never changes because of this, only the screen.
-- Each sub-page independently assigns e2/k2/e3/k3, or leaves them nil.
-- On the Drums page, touching the repeats or groove pads also jumps to the
-- matching sub-page (see input.lua).

-- The "step" sub-page is special: it is not part of the list E1 cycles through.
-- It takes over the Drums page's controls for as long as a step is selected
-- (hold a step pad), and is left by deselecting the step.
local step_page = {
  name = "step",
  e2 = {
    label = function() return "prob" end,
    value = function() return step_probability(S.selected_track, S.selected_step) .. "%" end,
    delta = function(d)
      local v = util.clamp(step_probability(S.selected_track, S.selected_step) + d, 0, 100)
      set_step_probability(S.selected_track, S.selected_step, v)
    end,
  },
  k2 = {
    -- unavailable when a generated pulse already occupies this step:
    -- the pulse's own parameters take priority, so there's nothing
    -- manual to toggle from here
    available = function()
      local _, index_at = pulse_index_map(S.selected_track)
      return index_at[S.selected_step] == nil
    end,
    label = function() return "manual" end,
    state = function()
      local m = tracks[S.selected_track].manual[S.selected_step]
      return m and m.active or false
    end,
    action = function() toggle_manual_step(S.selected_track, S.selected_step) end,
  },
  e3 = {
    label = function() return "timing" end,
    value = function() return "+" .. step_microtiming(S.selected_track, S.selected_step) .. "%" end,
    delta = function(d)
      local v = util.clamp(step_microtiming(S.selected_track, S.selected_step) + d, 0, 90)
      set_step_microtiming(S.selected_track, S.selected_step, v)
    end,
  },
  k3 = {
    label = function() return "accent" end,
    state = function() return step_accent(S.selected_track, S.selected_step) end,
    action = function() toggle_step_accent(S.selected_track, S.selected_step) end,
  },
}

local subpages = {
  drums = {
    {name = "velocity",
      e2 = {
        label = function() return "velocity" end,
        value = function() return tostring(tracks[S.selected_track].velocity) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.velocity = util.clamp(trk.velocity + d, 0, 127) end,
      },
      e3 = {
        label = function() return "accent+" end,
        value = function() return tostring(tracks[S.selected_track].accent_amount) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.accent_amount = util.clamp(trk.accent_amount + d, 0, 127) end,
      },
    },
    {name = "repeat",
      e2 = {
        label = function() return "ramp" end,
        value = function() return tostring(tracks[S.selected_track].ramp) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.ramp = util.clamp(trk.ramp + d, -63, 63) end,
      },
      e3 = {
        label = function() return "pace" end,
        value = function() return tostring(tracks[S.selected_track].pace) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.pace = util.clamp(trk.pace + d, -63, 63) end,
      },
    },
    {name = "groove",
      e2 = {
        label = function() return "amount" end,
        value = function() return tostring(tracks[S.selected_track].groove_amount) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.groove_amount = util.clamp(trk.groove_amount + d, 0, 127) end,
      },
      e3 = {
        label = function() return "length" end,
        value = function()
          local trk = tracks[S.selected_track]
          return tostring(GROOVE_LENGTHS[trk.groove_length_index])
        end,
        delta = function(d)
          local trk = tracks[S.selected_track]
          trk.groove_length_index = util.clamp(trk.groove_length_index + d, 1, #GROOVE_LENGTHS)
        end,
      },
    },
  },
  keys = {
    {name = "keys",
      e2 = {
        label = function() return "arp oct" end,
        value = function() return tostring(tracks[S.selected_track].arp_octaves) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.arp_octaves = util.clamp(trk.arp_octaves + d, 1, 4) end,
      },
      k2 = {
        label = function() return "arp" end,
        state = function() return tracks[S.selected_track].arp_enabled end,
        action = function() local trk = tracks[S.selected_track]; trk.arp_enabled = not trk.arp_enabled end,
      },
      e3 = {
        label = function() return "phr rng" end,
        value = function() return tostring(tracks[S.selected_track].phrase_range) end,
        delta = function(d) local trk = tracks[S.selected_track]; trk.phrase_range = util.clamp(trk.phrase_range + d, 0, 127) end,
      },
      k3 = {
        label = function() return "phrase" end,
        state = function() return tracks[S.selected_track].phrase_enabled end,
        action = function() local trk = tracks[S.selected_track]; trk.phrase_enabled = not trk.phrase_enabled end,
      },
    },
  },
  user = {
    {name = "mod",
      -- configures the modulation of whichever fader was last touched
      e2 = {
        available = function() return S.last_slider ~= nil end,
        label = function() return "amount" end,
        value = function()
          local r = focused_state(false)
          return tostring(r and r.amount or 0)
        end,
        delta = function(d)
          local r = focused_state(true)
          r.amount = util.clamp(r.amount + d, 0, 127)
        end,
      },
      k2 = {
        available = function() return S.last_slider ~= nil end,
        label = function() return "on" end,
        state = function()
          local r = focused_state(false)
          return r ~= nil and r.enabled
        end,
        action = function()
          local r = focused_state(true)
          set_modulation_enabled(S.selected_track, USER_SLIDERS[S.last_slider], not r.enabled)
        end,
      },
      e3 = {
        available = function() return S.last_slider ~= nil end,
        label = function() return "every" end,
        value = function()
          local r = focused_state(false)
          return tostring(RATE_STEPS[r and r.rate_index or 1])
        end,
        delta = function(d)
          local r = focused_state(true)
          r.rate_index = util.clamp(r.rate_index + d, 1, #RATE_STEPS)
        end,
      },
      k3 = {
        available = function() return S.last_slider ~= nil end,
        label = function() return "reroll" end,
        state = function() return false end,
        action = function()
          local r = focused_state(true)
          r.seq = fresh_random_seq()
        end,
      },
    },
  },
  session = {
    {name = "session",
      k2 = {
        label = function() return "song" end,
        state = function() return tracks[S.selected_track].song_enabled end,
        action = function()
          local trk = tracks[S.selected_track]
          trk.song_enabled = not trk.song_enabled
        end,
      },
    },
  },
}

-- Held-button pages. Same slot contract as `subpages`; while one is open it
-- replaces the current sub-page on screen.
local temp_pages = {
  tempo = {name = "tempo",
    e2 = {
      label = function() return "tempo" end,
      value = function() return string.format("%.0f", params:get("clock_tempo")) end,
      delta = function(d) params:delta("clock_tempo", d) end,
    },
  },
}

local function open_temp_page(name)
  S.active_temp_page = name
  S.temp_page_used = false
end

-- returns whether any of the page's controls were touched while it was open,
-- so the caller can tell a bare tap from a hold-and-adjust
local function close_temp_page()
  local used = S.temp_page_used
  S.active_temp_page = nil
  S.temp_page_used = false
  return used
end

local function switch_page(new_page)
  S.page = new_page
  S.copy_mode_active = false
  S.redraw_grid()
end

-- the Drums page is locked on the "step" sub-page while a step is selected
local function step_locked()
  return S.page == "drums" and S.selected_step ~= nil
end

-- a held temporary page takes over the controls, then a selected step;
-- otherwise the current page's selected sub-page owns them
local function current_subpage_def()
  if S.active_temp_page then return temp_pages[S.active_temp_page] end
  if step_locked() then return step_page end
  return subpages[S.page][current_subpage[S.page]]
end

-- jumps to a sub-page of the page by name; leaves step editing first, since
-- the step page is only up while a step is selected
local function select_subpage(page, name)
  if page == "drums" then S.selected_step = nil end
  for i, sp in ipairs(subpages[page]) do
    if sp.name == name then current_subpage[page] = i end
  end
end

-- a slot (e2/k2/e3/k3) counts as assigned only if present and, when it
-- declares an `available` guard, currently available
local function slot_ready(slot)
  return slot ~= nil and (slot.available == nil or slot.available())
end

return {
  close_temp_page = close_temp_page,
  current_subpage_def = current_subpage_def,
  open_temp_page = open_temp_page,
  select_subpage = select_subpage,
  slot_ready = slot_ready,
  step_locked = step_locked,
  subpages = subpages,
  switch_page = switch_page,
}
