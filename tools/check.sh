#!/bin/sh
# Non-regression check, run on the norns (it has the Lua interpreter).
#
#   tools/check.sh <baseline-git-ref> [seed...]
#
# Replays the same long scripted session (tools/harness.lua) against the
# baseline version and the working tree, with stubbed norns/lp3 APIs on a
# virtual clock, and compares everything observable: every LED change,
# every screen draw call, every note sent to the voices. Also checks syntax
# and lists the globals each file touches (anything unexpected there is a
# variable that lost its scope).
set -e
ref=${1:?usage: check.sh <baseline-git-ref> [seed...]}; shift
seeds=${*:-12345}
cd "$(dirname "$0")/.."
ssh norns 'rm -rf /tmp/lp3seq_base /tmp/lp3seq_new && mkdir -p /tmp/lp3seq_base/lp3seq /tmp/lp3seq_new/lp3seq'
git archive "$ref" | ssh norns 'tar -x -C /tmp/lp3seq_base/lp3seq'
git ls-files -co --exclude-standard | grep -v '^docs/' | tar -c -T - | ssh norns 'tar -x -C /tmp/lp3seq_new/lp3seq'
scp -q tools/harness.lua norns:/tmp/harness.lua
ssh norns 'cd /tmp/lp3seq_new/lp3seq && for f in lp3seq.lua lib/*.lua; do luac -p $f; done && echo "syntax ok"'
for s in $seeds; do
  ssh norns "cd /tmp; SEED=$s lua harness.lua /tmp/lp3seq_base 3000 /tmp/base_$s.log & SEED=$s lua harness.lua /tmp/lp3seq_new 3000 /tmp/new_$s.log; wait"
  if ssh norns "cmp /tmp/base_$s.log /tmp/new_$s.log"; then echo "seed $s: identical"; else echo "seed $s: DIFFERENT"; fi
done
