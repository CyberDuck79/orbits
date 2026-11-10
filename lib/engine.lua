-- engine: The sequencer proper: per-track clock coroutines, note triggering
-- with repeats and arp bursts, the groove clock that drives pattern switching
-- and the song chain, the logo beat, transport.

local S = require 'orbits/lib/state'
local tracks = S.tracks
local consts = require 'orbits/lib/consts'
local NUM_TRACKS = consts.NUM_TRACKS
local QUANT_LOOPS, QUANT_SIXTEENTHS = consts.QUANT_LOOPS, consts.QUANT_SIXTEENTHS
local theory = require 'orbits/lib/theory'
local apply_phrase, arp_sequence = theory.apply_phrase, theory.arp_sequence
local groove_curve_value = theory.groove_curve_value
local steps = require 'orbits/lib/steps'
local step_accent, step_active = steps.step_accent, steps.step_active
local step_microtiming, step_probability = steps.step_microtiming, steps.step_probability
local track_muted = steps.track_muted
local modulation = require 'orbits/lib/modulation'
local random_tick, rewind = modulation.random_tick, modulation.rewind
local patterns = require 'orbits/lib/patterns'
local do_pattern_switch = patterns.do_pattern_switch

local function toggle_play()
  S.playing = not S.playing
  S.play_epoch = S.play_epoch + 1
  -- every run starts from the same place: random sequences and arp position
  for t = 1, NUM_TRACKS do
    rewind(t)
    tracks[t].arp_pos = 0
  end
  if not S.playing then
    for t = 1, NUM_TRACKS do
      tracks[t].step = 0
      tracks[t].song_pos = 0
    end
    S.groove_pos = 0
  end
  S.redraw_grid()
end

-- Note Repeater: `repeats` extra triggers after the initial hit, spaced by
-- `repeat_time`. `ramp` (-63..63) shapes velocity rising/falling across the
-- series; `pace` (-63..63) shapes the spacing speeding up/slowing down.
local function trigger_repeats(t, notes_to_play, base_vel)
  local trk = tracks[t]
  if trk.repeats <= 0 then return end
  local player = params:lookup_param("voice_t" .. t):get_player()
  local epoch = S.play_epoch
  clock.run(function()
    for i = 1, trk.repeats do
      local progress = (i - 1) / math.max(trk.repeats - 1, 1)
      local pace_factor = math.max(1 - (trk.pace / 63) * progress * 0.5, 0.1)
      clock.sync(trk.repeat_time * pace_factor)
      if epoch ~= S.play_epoch then return end -- stopped (or restarted) meanwhile: drop the rest of the series
      local vel = util.clamp(base_vel + trk.ramp * (i / trk.repeats), 0, 127)
      for _, note in ipairs(notes_to_play) do
        player:note_on(note, vel / 127)
      end
      clock.run(function()
        clock.sync(trk.repeat_time / 2)
        for _, note in ipairs(notes_to_play) do
          player:note_off(note)
        end
      end)
    end
  end)
end

-- Arp reuses the Note Repeater's own controls instead of a separate rate:
-- Repeats sets how many notes the run contains (1 + repeats total), Time
-- sets its speed, Ramp/Pace shape it -- exactly like a plain repeat, except
-- each note in the burst steps through the arp sequence instead of
-- replaying the same chord. arp_pos persists across pulses so the line
-- keeps moving forward rather than restarting every hit.
local function trigger_arp_burst(t, pos, base_vel)
  local trk = tracks[t]
  local player = params:lookup_param("voice_t" .. t):get_player()
  local seq = arp_sequence(t)
  if #seq == 0 then return end
  local burst_count = 1 + trk.repeats
  local epoch = S.play_epoch
  clock.run(function()
    for i = 1, burst_count do
      if i > 1 then
        local progress = (i - 2) / math.max(burst_count - 2, 1)
        local pace_factor = math.max(1 - (trk.pace / 63) * progress * 0.5, 0.1)
        clock.sync(trk.repeat_time * pace_factor)
        if epoch ~= S.play_epoch then return end -- stopped (or restarted) meanwhile: drop the rest of the burst
      end
      trk.arp_pos = trk.arp_pos % #seq
      local note = apply_phrase(t, pos, seq[trk.arp_pos + 1])
      trk.arp_pos = trk.arp_pos + 1
      local vel = util.clamp(base_vel + trk.ramp * (i / burst_count), 0, 127)
      player:note_on(note, vel / 127)
      clock.run(function()
        clock.sync(trk.repeat_time / 2)
        player:note_off(note)
      end)
    end
  end)
end

local function trigger_track(t, pos)
  local trk = tracks[t]
  local player = params:lookup_param("voice_t" .. t):get_player()
  local vel = step_accent(t, pos) and util.clamp(trk.velocity + trk.accent_amount, 0, 127) or trk.velocity
  -- accent groove: bipolar velocity modulation over time, layered on top
  vel = util.clamp(vel + groove_curve_value(t) * trk.groove_amount, 0, 127)

  if trk.arp_enabled then
    trigger_arp_burst(t, pos, vel)
    return
  end

  local notes_to_play = {}
  for note, _ in pairs(trk.notes) do
    table.insert(notes_to_play, apply_phrase(t, pos, note))
  end
  for _, note in ipairs(notes_to_play) do
    player:note_on(note, vel / 127)
  end
  if #notes_to_play == 0 then return end
  clock.run(function()
    clock.sync(1 / 8)
    for _, note in ipairs(notes_to_play) do
      player:note_off(note)
    end
  end)

  trigger_repeats(t, notes_to_play, vel)
end

-- the value (1..16, see consts.quant_label) that currently decides when
-- track t's pattern changes: the song length in song mode, else the quantize
local function change_value(trk)
  return trk.song_enabled and trk.song_length or trk.quantize
end

-- does the change due for track t apply now? True when the track has
-- something to change to: song mode (the chain decides), or a tapped pattern
local function change_pending(trk)
  return trk.song_enabled or trk.pending_pattern ~= nil
end

-- makes the pattern change due for track t: the next position of the song
-- chain (empty positions are skipped), or the pattern that was tapped
local function change_pattern(t)
  local trk = tracks[t]
  if trk.song_enabled then
    local start = trk.song_pos
    for _ = 1, 16 do
      trk.song_pos = (trk.song_pos % 16) + 1
      if trk.song_chain[trk.song_pos] then
        do_pattern_switch(t, trk.song_chain[trk.song_pos])
        break
      end
      if trk.song_pos == start then break end -- chain is empty
    end
  elseif trk.pending_pattern then
    do_pattern_switch(t, trk.pending_pattern)
  end
  if t == S.selected_track then S.redraw_grid() end
end

-- one coroutine per track, each free-running at that track's own division --
-- this is what makes per-track polymeter/polyrhythm possible.
local function start_track_sequencer(t)
  clock.run(function()
    while true do
      clock.sync(tracks[t].division)
      if S.playing then
        local trk = tracks[t]
        random_tick(t)
        if not track_muted(t) and trk.length > 0 then
          -- a change measured in loops of this pattern is due when a whole
          -- number of those loops is done (the new pattern then starts on
          -- this very tick). Held while the track is muted, as its step is.
          local v = change_value(trk)
          if v > 8 and change_pending(trk) and trk.step > 0 and trk.step % trk.length == 0
              and math.floor(trk.step / trk.length) % QUANT_LOOPS[v - 8] == 0 then
            change_pattern(t)
          end
          local pos = (trk.step % trk.length) + 1
          if step_active(t, pos) and math.random(100) <= step_probability(t, pos) then
            local micro = step_microtiming(t, pos)
            if micro > 0 then
              clock.run(function()
                clock.sync(trk.division * (micro / 100))
                trigger_track(t, pos)
              end)
            else
              trigger_track(t, pos)
            end
          end
          trk.step = trk.step + 1
        end
        if t == S.selected_track then
          S.redraw_grid() -- reflects the step that was just triggered, before advancing
        end
      end
    end
  end)
end

-- flashes the logo on every quarter note, independent of any track's division
local function start_logo_beat()
  clock.run(function()
    while true do
      clock.sync(1)
      if S.playing then
        S.logo_on = true
        S.redraw_grid()
        clock.sleep(0.08)
        S.logo_on = false
        S.redraw_grid()
      end
    end
  end)
end

-- advances the shared accent-groove phase at a fixed 16th-note rate,
-- independent of any track's own division
local function start_groove_clock()
  clock.run(function()
    while true do
      clock.sync(1 / 4)
      if S.playing then
        S.groove_pos = S.groove_pos + 1

        -- pattern changes measured in bars: checked here (a shared, always-on
        -- 16th note clock) so "next bar" means the same musical moment for
        -- every track, whatever its own division. Changes measured in loops
        -- of the track's pattern are made by the track itself, see below.
        for t = 1, NUM_TRACKS do
          local trk = tracks[t]
          local v = change_value(trk)
          if change_pending(trk) and v <= 8 and S.groove_pos % QUANT_SIXTEENTHS[v] == 0 then
            change_pattern(t)
          end
        end
      end
    end
  end)
end

local function start_sequencer()
  for t = 1, NUM_TRACKS do
    start_track_sequencer(t)
  end
  start_logo_beat()
  start_groove_clock()
end

return {
  start_sequencer = start_sequencer,
  toggle_play = toggle_play,
}
