#!/bin/sh
# Regenerates docs/img/*.svg: runs tools/render.lua on the norns (it has the
# Lua interpreter) against the working tree and copies the pictures back.
set -e
cd "$(dirname "$0")/.."
ssh norns 'rm -rf /tmp/lp3seq_render /tmp/lp3seq_img && mkdir -p /tmp/lp3seq_render/lp3seq /tmp/lp3seq_img'
git ls-files -co --exclude-standard | grep -v '^docs/' | tar -c -T - 2>/dev/null | ssh norns 'tar -x -C /tmp/lp3seq_render/lp3seq 2>/dev/null'
scp -q tools/render.lua norns:/tmp/render.lua
ssh norns 'cd /tmp && lua render.lua /tmp/lp3seq_render /tmp/lp3seq_img'
mkdir -p docs/img
ssh norns 'tar -c -C /tmp/lp3seq_img .' | tar -x -C docs/img 2>/dev/null
ls docs/img
