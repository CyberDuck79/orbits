#!/bin/sh
# Takes real norns screenshots for the README (docs/img/screen-*.png).
# Deploys the working tree, loads the script through the matron REPL, puts it
# in each scene of tools/scenes.lua and exports the screen; then reloads the
# script to reset its state and fetches the images (needs python3 + Pillow
# on this machine).
set -e
cd "$(dirname "$0")/.."
sh tools/deploy.sh 2>/dev/null
scp -q tools/repl.py tools/scenes.lua tools/screenshots.lua norns:/tmp/
repl() { ssh norns "python3 /tmp/repl.py 5555 '$1' ${2:-2}"; }
ssh norns 'rm -f ~/dust/data/orbits/shot_*.png'
repl 'norns.script.load("/home/we/dust/code/orbits/orbits.lua")' 4
repl 'dofile("/tmp/screenshots.lua")' 4
sleep 1
repl 'norns.script.load("/home/we/dust/code/orbits/orbits.lua")' 3
mkdir -p docs/img /tmp/orbits_shots
rm -f /tmp/orbits_shots/*.png
scp -q 'norns:dust/data/orbits/shot_*.png' /tmp/orbits_shots/
python3 - <<'PY'
import glob, os
from PIL import Image
# a norns screenshot is the 128x64 screen at 4x, centred on a black 640x384 canvas;
# crop to the screen and add a thin frame so it stands out on a white page
for f in sorted(glob.glob('/tmp/orbits_shots/shot_*.png')):
    name = os.path.basename(f)[5:-4].replace('_', '-')
    im = Image.open(f).convert('RGB')
    w, h = im.size
    im = im.crop(((w - 512) // 2, (h - 256) // 2, (w - 512) // 2 + 512, (h - 256) // 2 + 256))
    framed = Image.new('RGB', (532, 276), (60, 60, 68))
    framed.paste(im, (10, 10))
    framed.save('docs/img/%s.png' % name)
    print(name)
PY
