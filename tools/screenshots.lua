-- Takes the real norns screenshots of the README (run inside matron, see
-- screenshots.sh): puts the loaded script in each scene of scenes.lua, redraws
-- it and exports the screen to ~/dust/data/orbits/shot_<scene>.png.
local S = require 'orbits/lib/state'
local consts = require 'orbits/lib/consts'
local modulation = require 'orbits/lib/modulation'
local splash = require 'orbits/lib/splash'
splash.stop() -- the start-up animation may still be up
local scenes = dofile("/tmp/scenes.lua")(S, consts, modulation)

local list = {
  "screen_drums", "screen_drums_step", "screen_drums_repeat",
  "screen_drums_groove", "screen_keys", "screen_user", "screen_user_empty",
  "screen_session", "screen_session_chain", "screen_tempo", "screen_disconnected",
}

for _, name in ipairs(list) do
  if name == "screen_disconnected" then
    scenes.screen_drums()
    S.pad.connected = false
  else
    scenes[name]()
  end
  redraw()
  screen.export_screenshot("shot_" .. name)
  if name == "screen_disconnected" then S.pad.connected = true end
end
print("orbits screenshots done")
