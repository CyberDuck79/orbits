# lp3seq: technical documentation

A 7-track Euclidean sequencer for norns, played from a Novation Launchpad Mini MK3 through the `lp3` mod. Notes go out through `nb` (one voice per track). Any `nb` player can be assigned to a track: internal synths and engines, but also external MIDI devices, since `nb` exposes every connected MIDI port as a player (channel, modulation CC and bend range are set in its params).

This document explains **how the script is built, why, and where to look when you want to change something**. For usage, see the user documentation.

## 1. Overview

```
        Launchpad                                   norns (encoders, keys, screen)
            │ pads                                          │
      lp3 (mod) ──► input.on_key                  controls.enc / controls.key
                        │                                   │
                        ▼                                   ▼
                  ┌───────────────  state (S)  ───────────────┐
                  │  tracks[1..7], page, playing, selection…  │
                  └───────────────────────────────────────────┘
                     ▲            ▲             │            │
          engine (clocks)     modulation    leds.redraw_grid   display.redraw
          plays the notes   (faders+random)   → Launchpad       → OLED screen
                     │
                     ▼
                nb players  ──► voices (one per track)
```

Three ideas shape the whole script:

1. **One shared state** (`lib/state.lua`). Pads, encoders, engine, screen and Launchpad all read and write the same table `S`. Modules do not send each other messages.
2. **The engine is autonomous.** Each track runs in its own clock coroutine, at its own division. That is what gives polymeter and polyrhythm without any special code.
3. **The interface is redrawn from the state.** No module remembers "what is displayed": `leds.redraw_grid()` and `display.redraw()` start from scratch on every call.

## 2. File layout

```
lp3seq.lua            entry point: wiring, init(), cleanup()
lib/
  colors.lua          RGB palette, brighten / scale_color
  consts.lua          constants and data tables (divisions, scales, grooves…)
  state.lua           the shared state S + creation of the 7 tracks
  theory.lua          pure music logic: scales, transposition, arp, phrase, groove
  steps.lua           step model: Euclid + manual steps, accents, probability, micro-timing
  modulation.lua      User-page faders + random modulation
  patterns.lua        pattern snapshots, switching, duplication, pset saving
  engine.lua          clocks, note triggering, repeats, arp, song chain
  leds.lua            Launchpad drawing (one function per page)
  pages.lua           screen sub-pages and temporary pages (the E2/K2/E3/K3 contract)
  display.lua         OLED screen drawing
  controls.lua        norns encoder and key handlers
  input.lua           pad handlers (one per page) and routing
  euclid.lua          Bjorklund algorithm (third-party file, unchanged)
  nb/                 nb library (third-party, unchanged)
tools/                deployment and tests (see §8)
docs/                 this documentation
```

## 3. Layers and dependencies

The `require`s form a graph **without cycles**. Each module only depends on those below it:

| Layer | Modules | Depends on |
|---|---|---|
| Data | `colors`, `consts` | nothing |
| State | `state` | `consts` |
| Pure logic | `theory`, `steps`, `modulation` | data, `state` |
| Persistence | `patterns` | `consts`, `state` |
| Engine | `engine` | logic, `patterns` |
| Interface | `leds`, `pages`, `display` | logic, `state` |
| Input | `controls`, `input` | `pages`, `engine`, `patterns`… |

Some lower modules still need to call "upward": for instance `engine` wants the Launchpad and the screen redrawn after a step. To avoid a cycle, `state` exposes two **hooks**:

```lua
S.redraw_grid()    -- filled in by leds.lua when it loads
S.redraw_screen()  -- filled in by display.lua when it loads
```

They start as empty functions. Any module can call them without knowing `leds` or `display`.

## 4. The state (`lib/state.lua`)

`S` holds:

- **Session globals**: `pad` (the Launchpad), `selected_track`, `page` (`drums | keys | user | session`), `current_subpage[page]`, `playing`.
- **Interaction**: `shift_held`, `selected_step`, `last_slider`, `active_temp_page`, `copy_mode_*`, `chain_edit_pos`, and the `*_pending` / `*_metro` fields used for long presses.
- **Visual clock**: `pulse_phase` (250 ms blink), `logo_on`, `groove_pos`.
- **`tracks[1..7]`**: everything that defines a track. Every field is commented in `S.init_tracks()`.

Conventions:
- Mutable scalars are written `S.x`, never copied into a local (a local copy goes stale).
- `tracks` and `current_subpage` are also exposed as locals, since they are never reassigned.
- `S.play_epoch` is incremented on every start/stop. Repeat and arp coroutines copy it when they start and bail out if it changed (this is what cuts in-flight repeats when you stop).

## 5. The engine (`lib/engine.lua`)

`start_sequencer()` launches, once and for all from `init()`, 9 `clock.run` coroutines:

| Coroutine | Rate | Role |
|---|---|---|
| `start_track_sequencer(t)` ×7 | `tracks[t].division` | advances the track, fires steps, applies modulation |
| `start_logo_beat` | quarter note | flashes the logo |
| `start_groove_clock` | sixteenth note | advances `groove_pos`, runs pattern switches and the song chain |

All of them check `S.playing`. Stop does not kill the coroutines, it makes them inert.

**One step** (`start_track_sequencer`): `random_tick(t)` first updates the modulated parameters. Then, if the track is not muted, it takes the position, tests `step_active` and the probability, applies micro-timing (a delay through a coroutine), and calls `trigger_track`.

**`trigger_track`** computes the velocity (accent, groove curve), then:
- arp on → `trigger_arp_burst` (the burst walks through the arp sequence);
- otherwise → note_on for the chord (phrase applied), note_off after 1/8 of a beat, then `trigger_repeats`.

**Repeats** use `repeats`, `repeat_time`, `ramp` (velocity slope) and `pace` (acceleration). The arp reuses the same settings: there, `repeats` sets the number of notes in the burst.

**Pattern switching** is deliberately done in `start_groove_clock`: a single always-on sixteenth-note clock guarantees that "next bar" means the same instant for every track, whatever its own division.

## 6. Data models

### Steps (`steps.lua`)
A step is active if it lands on a Euclidean pulse (`euclid.lua`, after rotation) **or** was added by hand (`trk.manual[step]`). Accents, probabilities and micro-timings of generated pulses are indexed by **pulse number** (`pulse_accents[n]`), not by position: they follow their pulse when length, density or rotation change. Manual steps carry their own values.

### Modulation (`modulation.lua`)
The User page exposes 8 faders (`USER_SLIDERS`). Each one describes its range, how to read/write a track's value, and its colour. A modulation lives in `trk.random_states[id]`:

```
{enabled, amount, rate_index, seq[16], pos, step_counter, base, last}
```

At every step: `value = base + seq[pos] × (amount/127) × (hi−lo)/2`, clamped (or wrapped for rotation). `seq` is a random list of 16 values, advanced every `RATE_STEPS[rate_index]` steps. `last` remembers the last value written: if it differs from the current value, someone changed the parameter by hand, and `base` follows. Disabling restores `base`. Several modulations run in parallel; only the selected fader's one is editable on screen.

### Patterns (`patterns.lua`)
A pattern is a **snapshot** of the fields listed in `PATTERN_FIELDS` (rhythm, notes, velocities, repeats, groove, scale, arp, phrase, modulations). Neither the voice nor the mute is part of it. There is no "save" action: switching pattern first re-captures the active one into its slot. 32 slots per track (`trk.patterns`), and a 16-position song chain (`trk.song_chain`).

### Saving
Patterns are not flat norns params. `install_persistence()` hooks `params.action_write` / `action_read` to write a sidecar file `<pset>.lp3seqdata` next to the `.pset` (the same technique n.kria uses). Tempo and voices go through the normal pset mechanism.

## 7. Interface

### Launchpad (`leds.lua`, `input.lua`)
The 8×8 grid changes meaning with `S.page`. Each page has **a drawer** (`draw_*_page` in `leds.lua`) and **a handler** (`handle_*_key` in `input.lua`): they are the two faces of the same page and must stay consistent. The right column (tracks/scenes), the arrows and the top row (page switching) are shared.

`on_key(x, y, z)` routes: Stop/Solo/Mute button (tap = play, held = shift + tempo page), tracks, arrows, page buttons, otherwise the current page's handler.

`redraw_grid()` redraws everything into the `lp3` mod's buffer, then calls `refresh()` (incremental: only the LEDs that changed are sent).

Long presses (steps, slots, shift+track) use two one-shot metros, `hold_metro` and `mute_hold_metro`, created in `create_timers()`.

### Screen and encoders (`pages.lua`, `display.lua`, `controls.lua`)
The screen does not repeat what the grid already shows. Each grid page has **sub-pages** (`subpages[page]`), cycled with E1. A sub-page describes up to four **slots**:

```lua
{name = "velocity",
 e2 = {available = fn?, label = fn, value = fn, delta = fn(d)},
 k2 = {available = fn?, label = fn, state = fn, action = fn},
 e3 = …, k3 = …}
```

The Drums page has one exception: its **step** sub-page is not in the `subpages.drums` list E1 cycles through. It is a separate `step_page` that `current_subpage_def()` returns whenever `step_locked()` is true (Drums page and `S.selected_step ~= nil`), so it exists exactly as long as a step is selected, and E1 is locked meanwhile (`controls.lua`, `display.lua` draws a blinking marker). Touching the repeats or groove pads in `input.lua` calls `pages.select_subpage()`, which deselects the step and jumps to that sub-page.

`controls.lua` knows no page: it calls the slot of the current sub-page (`current_subpage_def()`) if `slot_ready` (present and `available()` true). `display.lua` draws the same slots, so what you see is what you control. **Temporary pages** (`temp_pages`, currently only "tempo") follow the same contract and replace the sub-page while their button is held.

Redraw guard: `display.redraw()` does nothing while a norns system menu is open; otherwise the clocks would overwrite the menu's screen.

## 8. Tools and tests (`tools/`)

- `deploy.sh`: copies the script to the norns (`ssh norns`).
- `check.sh <git-ref> [seed]`: checks that a refactor changes nothing. It replays a long scripted session (pads, encoders, keys, virtual clock, stubbed norns APIs) on the old version and on the current folder, then compares the LEDs, screen calls and emitted notes **byte for byte**.
- `render.sh` / `render.lua`: regenerate the README pictures (`docs/img/*.svg`) from the real code. Re-run after changing anything visible (colours, layouts, screen).
- `harness.lua`: the test driver (deterministic randomness per seed, `COVER=1` for line coverage).

The harness only covers simulated I/O: it proves there is no regression, not that the hardware works. It does not simulate the system menu either. An **intended** behaviour change makes the test diverge: that is expected, and the diff then has to be reviewed by hand.

## 9. Known pitfalls

- **`include` vs `require`.** `include` does not cache; `require` does. `lp3seq.lua` therefore purges the `package.loaded` entries starting with `lp3seq/` at startup, otherwise reloading the script would reuse stale modules.
- **Lua version.** norns (matron) runs Lua 5.3, the shell has 5.1/LuaJIT. Avoid what differs (integer operators, `//`) or check it on the device.
- **Accidental globals.** Only `init`, `cleanup`, `enc`, `key`, `redraw` should be global. Check: `luac -l` (the shell's Lua 5.1) on each file; only `GETGLOBAL` accesses to the standard library and the norns APIs are normal.
- **Screen drawing.** `screen.rect` is safe; `screen.circle` followed by `stroke` leaves stray lines (Cairo's current point). The round dots (`draw_round_dot`) are therefore made of three filled `rect`s, with no arc.
- **`lp3` mod.** `connect()` returns `false` when no Launchpad is plugged in but keeps waiting for one; `pad.status` is optional and drives the "Launchpad unplugged" indicator; the module is cached when matron starts (restart matron after changing the mod).
- **`clock.lua:62 bad argument #1 to 'resume'`** in the log when switching scripts: an internal norns race, not caused by this script, harmless.
- **Redrawing from a clock.** Calling `S.redraw_grid()` from a coroutine is normal, but each call also triggers `redraw_screen`. This is intentional (simple) and light enough here.

## 10. Where to change what

| I want to… | I touch… |
|---|---|
| Add a division, scale, groove or arp style | `consts.lua` (and the drawer/handler if a displayed grid changes) |
| Change a colour | `colors.lua` (parameter colours: `modulation.lua`, `USER_SLIDERS`) |
| Add a track parameter | `state.lua` (`init_tracks`); `patterns.lua` (`PATTERN_FIELDS` **and** `fresh_pattern_snapshot`) if it belongs to a pattern; its use in `engine.lua` |
| Change how a note is played (velocity, length, repeats) | `engine.lua` (`trigger_track`, `trigger_repeats`, `trigger_arp_burst`) |
| Change the arp or the phrase | `theory.lua` (`arp_sequence`, `apply_phrase`) |
| Change step logic (accent, probability, micro-timing) | `steps.lua` |
| Add a modulatable fader | `modulation.lua`: one entry in `USER_SLIDERS` (the User page and the screen pick it up) |
| Change the behaviour of a Launchpad page | `leds.lua` (`draw_*_page`) **and** `input.lua` (`handle_*_key`) |
| Add or change what E2/K2/E3/K3 do | `pages.lua`: the relevant sub-page (`controls.lua` stays as is) |
| Change the look of the screen (icons, layout) | `display.lua` |
| Change the page buttons, arrows, play/shift, mute | `input.lua` (`on_key`, `handle_arrow`) |
| Change pattern switching or the song chain | `engine.lua` (`start_groove_clock`) and `patterns.lua` |
| Change what gets saved | `patterns.lua` (`install_persistence`) |
| Change init / cleanup | `lp3seq.lua` |

After any change: `sh tools/check.sh <ref>` (for a refactor), then `sh tools/deploy.sh` and a test on the hardware.
