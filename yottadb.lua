--

local _yottadb = require('_yottadb')

local M = {}

---
-- Returns the YDB error code (if any) for the given error message.
-- Returns `nil` if the message is not a YDB error.
-- @param message String error message.
-- @return numeric YDB error code or nil
-- @name get_error_code
function M.get_error_code(message)
  return tonumber(message:match('^YDB Error: (%-?%d+):'))
end

local key = {}

function M.key(varname, subsarray)
  if subsarray and getmetatable(subsarray) == key then
    local key_ = subsarray
    return key_:sub(varname)
  end

  local key_ = {varname = varname, subsarray = subsarray or {}}
  return setmetatable(key_, key)
end

function key:sub(name)
  table.insert(self.subsarray, name)
  return self
end

function key:incr(value)
  _yottadb.incr(self.varname, self.subsarray, value)
  return self.value
end

function key:__add(value)
  self:incr(value)
  return self
end

function key:__sub(value)
  self:incr(-value)
  return self
end

function key:__eq(other)
  if getmetatable(self) ~= getmetatable(other) then return false end
  if self.varname ~= other.varname then return false end
  if #self.subsarray ~= #other.subsarray then return false end
  for i, value in ipairs(self.subsarray) do
    if value ~= other.subsarray[i] then return false end
  end
  return true
end

function key:__tostring()
  local subs = {}
  for i, name in ipairs(self.subsarray) do subs[i] = string.format('%q', name) end
  return string.format('%s(%s)', self.varname, table.concat(subs, ','))
end

function key:__index(k)
  if k == 'name' then
    return self.subsarray[#self.subsarray] or self.varname
  elseif k == 'value' then
    local ok, value = pcall(_yottadb.get, self.varname, self.subsarray)
    if ok then return value end
    local code = M.get_error_code(value)
    if code == _yottadb.YDB_ERR_GVUNDEF or code == _yottadb.YDB_ERR_LVUNDEF then return nil end
    error(value) -- propagate
  else
    return rawget(self, k) or key[k]
  end
end

function key:__newindex(k, v)
  if k == 'value' then
    _yottadb.set(self.varname, self.subsarray, v)
  else
    rawset(self, k, v)
  end
end

return M
