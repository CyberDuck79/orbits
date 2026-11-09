#!/bin/sh
# Regenerates the Launchpad pictures docs/img/pad-*.svg: runs tools/render.lua
# on the norns (it has the Lua interpreter) against the working tree and
# copies the files back. For the screen pictures see screenshots.sh.
set -e
cd "$(dirname "$0")/.."
ssh norns 'rm -rf /tmp/orbits_render /tmp/orbits_img && mkdir -p /tmp/orbits_render/orbits /tmp/orbits_img'
git ls-files -co --exclude-standard | grep -v '^docs/' | tar -c -T - 2>/dev/null | ssh norns 'tar -x -C /tmp/orbits_render/orbits 2>/dev/null'
scp -q tools/render.lua tools/scenes.lua norns:/tmp/
ssh norns 'cd /tmp && lua render.lua /tmp/orbits_render /tmp/scenes.lua /tmp/orbits_img'
mkdir -p docs/img
ssh norns 'tar -c -C /tmp/orbits_img .' | tar -x -C docs/img 2>/dev/null
ls docs/img
