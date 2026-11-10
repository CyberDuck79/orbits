#!/bin/sh
# Stress test, run on the norns (stubbed APIs, virtual clock) against the
# working tree: see tools/stress.lua for what is checked.
#
#   tools/stress.sh [seed...]        e.g. tools/stress.sh 1 2 3
#
# Environment: BPM (default 300), ROUNDS, CHAOS, OPS (sizes of the layers).
set -e
cd "$(dirname "$0")/.."
seeds=${*:-1}
ssh norns 'rm -rf /tmp/orbits_stress && mkdir -p /tmp/orbits_stress/orbits'
git ls-files -co --exclude-standard | grep -v '^docs/' | tar -c -T - 2>/dev/null | ssh norns 'tar -x -C /tmp/orbits_stress/orbits 2>/dev/null'
{ sed '/-- -* scenario ----/,$d' tools/harness.lua; cat tools/stress.lua; } > /tmp/orbits_stress.lua
scp -q /tmp/orbits_stress.lua norns:/tmp/orbits_stress.lua
status=0
for s in $seeds; do
  echo "--- seed $s"
  ssh norns "cd /tmp && SEED=$s BPM=${BPM:-300} ROUNDS=${ROUNDS:-12} CHAOS=${CHAOS:-3000} OPS=${OPS:-1500} lua orbits_stress.lua /tmp/orbits_stress 0 /tmp/orbits_stress_$s.log" || status=1
done
exit $status
