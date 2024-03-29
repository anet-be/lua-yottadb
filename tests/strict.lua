-- strict.lua -- used by test.lua to prevent assignment to undeclared global variables in functions

local getinfo, error, rawset, rawget = debug.getinfo, error, rawset, rawget
local warn = warn

local mt = getmetatable(_G)
if mt == nil then
  mt = {}
  setmetatable(_G, mt)
end

mt.__declared = {}

local function what ()
  local d = getinfo(3, "S")
  return d and d.what or "C"
end

mt.__newindex = function (t, n, v)
  if not mt.__declared[n] then
    local w = what()
    if w ~= "main" and w ~= "C" then
      error(debug.traceback("assign to undeclared variable '"..n.."'", 2), 2)
    end
    mt.__declared[n] = true
  end
  rawset(t, n, v)
end
  
mt.__index = function (t, n)
  if not mt.__declared[n] and what() ~= "C" then
    error(debug.traceback("variable '"..n.."' is not declared", 2), 2)
  end
  return rawget(t, n)
end
