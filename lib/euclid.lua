-- euclid: Bjorklund's algorithm for Euclidean rhythms.
local euclid = {}

--- returns a boolean array of `length` where `pulses` onsets are spread
--- as evenly as possible (Bjorklund's algorithm).
function euclid.pattern(length, pulses)
  if length < 1 then return {} end
  pulses = util.clamp(pulses, 0, length)
  if pulses == 0 then
    local out = {}
    for i = 1, length do out[i] = false end
    return out
  end
  if pulses == length then
    local out = {}
    for i = 1, length do out[i] = true end
    return out
  end

  local groups = {}
  for i = 1, pulses do groups[i] = {true} end
  local remainders = {}
  for i = 1, length - pulses do remainders[i] = {false} end

  while #remainders > 1 do
    local n = math.min(#groups, #remainders)
    local new_groups = {}
    for i = 1, n do
      local g = groups[i]
      for _, v in ipairs(remainders[i]) do table.insert(g, v) end
      new_groups[i] = g
    end
    local leftover_groups = {}
    for i = n + 1, #groups do table.insert(leftover_groups, groups[i]) end
    local leftover_remainders = {}
    for i = n + 1, #remainders do table.insert(leftover_remainders, remainders[i]) end

    if #leftover_groups > 0 then
      groups = new_groups
      remainders = leftover_groups
    else
      groups = new_groups
      remainders = leftover_remainders
    end
    if #leftover_groups == 0 and #leftover_remainders == 0 then break end
  end

  local out = {}
  for _, g in ipairs(groups) do
    for _, v in ipairs(g) do table.insert(out, v) end
  end
  for _, r in ipairs(remainders) do
    for _, v in ipairs(r) do table.insert(out, v) end
  end
  return out
end

--- rotate a pattern array by `amount` steps (positive = shift right/later)
function euclid.rotate(pattern, amount)
  local n = #pattern
  if n == 0 then return pattern end
  amount = amount % n
  if amount == 0 then return pattern end
  local out = {}
  for i = 1, n do
    local src = ((i - 1 - amount) % n) + 1
    out[i] = pattern[src]
  end
  return out
end

return euclid
