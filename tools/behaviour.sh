#!/bin/sh
# Runs tools/behaviour.lua on the norns (stubbed APIs, virtual clock) against
# the working tree and prints ok / FAIL for each check.
set -e
cd "$(dirname "$0")/.."
ssh norns 'rm -rf /tmp/orbits_beh && mkdir -p /tmp/orbits_beh/orbits'
git ls-files -co --exclude-standard | grep -v '^docs/' | tar -c -T - 2>/dev/null | ssh norns 'tar -x -C /tmp/orbits_beh/orbits 2>/dev/null'
{ sed '/-- -* scenario ----/,$d' tools/harness.lua; cat tools/behaviour.lua; } > /tmp/orbits_behaviour.lua
scp -q /tmp/orbits_behaviour.lua norns:/tmp/orbits_behaviour.lua
ssh norns 'cd /tmp && lua orbits_behaviour.lua /tmp/orbits_beh 0 /tmp/orbits_behaviour.log'
