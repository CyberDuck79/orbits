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
ssh norns 'rm -f ~/dust/data/lp3seq/shot_*.png'
repl 'norns.script.load("/home/we/dust/code/lp3seq/lp3seq.lua")' 4
repl 'dofile("/tmp/screenshots.lua")' 4
sleep 1
repl 'norns.script.load("/home/we/dust/code/lp3seq/lp3seq.lua")' 3
mkdir -p docs/img /tmp/lp3seq_shots
rm -f /tmp/lp3seq_shots/*.png
scp -q 'norns:dust/data/lp3seq/shot_*.png' /tmp/lp3seq_shots/
python3 - <<'PY'
import glob, os
from PIL import Image
# a norns screenshot is the 128x64 screen at 5x, centred on a black 640x384 canvas;
# crop to the screen and add a thin frame so it stands out on a white page
for f in sorted(glob.glob('/tmp/lp3seq_shots/shot_*.png')):
    name = os.path.basename(f)[5:-4].replace('_', '-')
    im = Image.open(f).convert('RGB')
    w, h = im.size
    im = im.crop(((w - 640) // 2, (h - 320) // 2, (w - 640) // 2 + 640, (h - 320) // 2 + 320))
    framed = Image.new('RGB', (660, 340), (60, 60, 68))
    framed.paste(im, (10, 10))
    framed.save('docs/img/%s.png' % name)
    print(name)
PY
