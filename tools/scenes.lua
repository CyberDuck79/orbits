-- Scenes used for the README pictures: each one puts the script in a known
-- state (through the real state table), ready to be drawn.
--
-- Used by render.lua (Launchpad SVGs, headless) and screenshots.lua (real norns
-- screen captures).
--
--   local scenes = dofile("scenes.lua")(S, consts, modulation)
--   scenes.drums()

return function(S, consts, modulation)
  local T = S.tracks
  local scenes = {}

  local function reset()
    S.init_tracks()
    S.page = "drums"
    S.selected_track = 1
    S.playing = false
    S.selected_step = nil
    S.last_slider = nil
    S.active_temp_page = nil
    S.delete_armed, S.clipboard, S.arrow_held = nil, nil, nil
    S.chain_edit_pos = nil
    S.pulse_phase = true
    S.logo_on = false
    for k in pairs(S.current_subpage) do S.current_subpage[k] = 1 end
  end

  local function slider(id)
    for _, s in ipairs(modulation.USER_SLIDERS) do if s.id == id then return s end end
  end

  -- Drums page, stopped: a 16-step pattern with an accent, a manual
  -- step, repeats, two muted tracks. The playhead (step 5) sits between pulses,
  -- so it cannot be mistaken for an accent.
  function scenes.drums()
    reset()
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
    S.playing, trk.step = true, 4 -- playhead on step 5
    S.logo_on = true
  end

  -- a step selected for editing (its pad is shown in the dim half of the blink)
  function scenes.drums_edit()
    scenes.drums()
    S.selected_step = 8
    S.pulse_phase = false
    T[1].manual[8] = {active = true, accent = true, probability = 75, microtiming = 10}
  end

  function scenes.keys()
    reset()
    S.page = "keys"
    local k = T[1]
    k.root_pc, k.scale_index = 0, 7
    k.notes = {[36] = true, [39] = true, [43] = true}
    k.arp_style, k.phrase_type = 3, 4
    k.arp_enabled, k.phrase_enabled = true, true
  end

  function scenes.user()
    reset()
    S.page = "user"
    local u = T[1]
    u.length, u.pulses, u.rotation = 16, 5, 2
    u.velocity, u.repeats, u.ramp, u.pace = 100, 3, 20, -10
    u.groove_amount, u.groove = 60, 7
    local function enable(id, amount, rate)
      modulation.set_modulation_enabled(1, slider(id), true)
      local r = u.random_states[id]
      r.amount, r.rate_index = amount, rate
      return r
    end
    local r1 = enable("velocity", 40, 3)
    r1.pos = 3
    slider("velocity").set(u, 80)
    r1.last = 80
    local r2 = enable("pulses", 50, 2)
    r2.pos = 5
    slider("pulses").set(u, 7)
    r2.last = 7
    S.last_slider = 3
  end

  function scenes.session()
    reset()
    S.page = "session"
    local s = T[1]
    for _, slot in ipairs({1, 2, 3, 5, 9, 12}) do s.patterns[slot] = {} end
    s.current_pattern, s.pending_pattern = 2, 3
    s.pattern_quantize = 3
    s.song_chain = {[1] = 1, [2] = 2, [3] = 2, [4] = 5}
    s.song_enabled, s.song_pos = true, 2
    S.clipboard = {snap = {}, track = 1, slot = 5} -- a copied pattern, pulsing white
  end

  -- a long-pressed pattern waiting to be deleted (tap it) or cancelled (tap elsewhere)
  function scenes.session_delete()
    scenes.session()
    S.clipboard = nil
    S.delete_armed = {track = 1, slot = 3}
    T[1].pending_pattern = nil
  end

  -- screens ---------------------------------------------------------------

  function scenes.screen_drums()
    reset()
    local t = T[1]
    t.length, t.pulses = 16, 5
    t.repeats, t.groove = 3, 7
  end

  function scenes.screen_drums_step()
    scenes.drums_edit()
    S.pulse_phase = true
  end

  function scenes.screen_drums_repeat() reset(); S.current_subpage.drums = 2 end
  function scenes.screen_drums_groove() reset(); S.current_subpage.drums = 3 end

  function scenes.screen_keys()
    reset()
    S.page = "keys"
    local t = T[1]
    t.scale_index, t.arp_enabled, t.arp_style = 7, true, 3
    t.phrase_enabled, t.phrase_type, t.phrase_range = true, 4, 40
    t.arp_octaves = 2
  end

  function scenes.screen_user()
    reset()
    S.page = "user"
    S.last_slider = 3
    modulation.set_modulation_enabled(1, slider("velocity"), true)
    local r = T[1].random_states.velocity
    r.amount, r.rate_index = 40, 3
  end

  function scenes.screen_user_empty() reset(); S.page = "user" end

  function scenes.screen_session()
    reset()
    S.page = "session"
    T[1].patterns[2] = {}
    T[1].current_pattern = 2
    T[1].song_enabled, T[1].song_pos = true, 2
  end

  function scenes.screen_tempo() reset(); S.active_temp_page = "tempo" end

  scenes.reset = reset
  return scenes
end
