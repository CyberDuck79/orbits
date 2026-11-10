# tools

- `deploy.sh` copies the script to the norns.
- `check.sh <git-ref>` compares the working tree against an earlier version by replaying a long scripted session on both (see the header of `harness.lua`). Used to make sure refactors don't change behaviour.
- `harness.lua` is the headless test driver (stub norns/lp3 APIs, virtual clock, deterministic pseudo-random events, optional line coverage with `COVER=1`).
- `render.sh` regenerates the SVG pictures of the README (`docs/img/`) by running `render.lua` on the norns: the real LED and screen code is run against stubbed APIs and its output drawn as SVG.
- `behaviour.sh` runs `behaviour.lua` on the norns: checks of pattern changes (quantize, song length, chain, same pattern repeated) on a virtual clock. Prints `ok` / `FAIL` per check.
