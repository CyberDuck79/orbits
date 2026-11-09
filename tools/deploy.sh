#!/bin/sh
# Copy the script to the norns (host alias `norns`). The script is loaded
# from disk each time it is launched, so just relaunch it from the menu.
cd "$(dirname "$0")/.." || exit 1
rsync -a --exclude .git --exclude tools --exclude docs ./ norns:dust/code/orbits/
