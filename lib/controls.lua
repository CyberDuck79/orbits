-- controls: The norns hardware: encoder and key handlers, dispatched to the
-- current sub-page.

local S = require 'lp3seq/lib/state'
local current_subpage = S.current_subpage
local pages = require 'lp3seq/lib/pages'
local current_subpage_def, slot_ready = pages.current_subpage_def, pages.slot_ready
local step_locked = pages.step_locked
local subpages = pages.subpages

local function enc(n, d)
  if n == 1 then
    -- a temp page and the step page are single views; nothing to cycle
    if S.active_temp_page or step_locked() then return end
    local list = subpages[S.page]
    current_subpage[S.page] = ((current_subpage[S.page] - 1 + d) % #list) + 1
    S.redraw_screen()
  elseif n == 2 then
    local sp = current_subpage_def()
    if slot_ready(sp.e2) then
      sp.e2.delta(d)
      if S.active_temp_page then S.temp_page_used = true end
      S.redraw_grid()
    end
    S.redraw_screen()
  elseif n == 3 then
    local sp = current_subpage_def()
    if slot_ready(sp.e3) then
      sp.e3.delta(d)
      if S.active_temp_page then S.temp_page_used = true end
      S.redraw_grid()
    end
    S.redraw_screen()
  end
end

local function key(n, z)
  if n == 1 then return end -- K1 is unused

  if z ~= 1 then return end
  local sp = current_subpage_def()
  if n == 2 and slot_ready(sp.k2) then
    sp.k2.action()
    if S.active_temp_page then S.temp_page_used = true end
    S.redraw_grid()
  elseif n == 3 and slot_ready(sp.k3) then
    sp.k3.action()
    if S.active_temp_page then S.temp_page_used = true end
    S.redraw_grid()
  end
end

return {
  enc = enc,
  key = key,
}
