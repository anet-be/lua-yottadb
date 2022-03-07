-- Copyright 2021-2022 Mitchell. See LICENSE.

local M = {}

--[[ This comment is for LuaDoc.
---
-- Lua-bindings for YottaDB.
module('yottadb')]]

local _yottadb = require('_yottadb')
for k, v in pairs(_yottadb) do if k:find('^YDB_') then M[k] = v end end

-- Asserts that value *v* has type string *expected_type* and returns *v*, or calls `error()`
-- with an error message that implicates function argument number *narg*.
-- This is intended to be used with API function arguments so users receive more helpful error
-- messages.
-- @param v Value to assert the type of.
-- @param expected_type String type to assert. It may be a non-letter-delimited list of type
--   options.
-- @param narg The positional argument number *v* is associated with. This is not required to
--   be a number.
-- @usage assert_type(value, 'string/nil', 1)
-- @usage assert_type(option.setting, 'number', 'setting') -- implicates key
local function assert_type(v, expected_type, narg)
  if type(v) == expected_type then return v end
  -- Note: do not use assert for performance reasons.
  if type(expected_type) ~= 'string' then
    error(string.format("bad argument #2 to '%s' (string expected, got %s)",
      debug.getinfo(1, 'n').name, type(expected_type)), 2)
  elseif narg == nil then
    error(string.format("bad argument #3 to '%s' (value expected, got %s)",
      debug.getinfo(1, 'n').name, type(narg)), 2)
  end
  for type_option in expected_type:gmatch('%a+') do if type(v) == type_option then return v end end
  error(string.format("bad argument #%s to '%s' (%s expected, got %s)", narg,
    debug.getinfo(2, 'n').name or '?', expected_type, type(v)), 3)
end

-- Asserts that all items in table *t* are strings, or calls `error()` with an error message
-- that implicates function argument number *narg* named *name*.
-- Like `assert_type()`, this is intended for improved readability of API input errors.
-- @param t Table to check. If it is not a table, the assertion passes.
-- @param name String argument name to use in error messages.
-- @param narg The position argument number *t* is associated with.
-- @usage assert_strings(subsarray, 'subsarray', 2)
-- @see assert_type
local function assert_strings(t, name, narg)
  if type(t) ~= 'table' then return t end
  for i, v in ipairs(t) do
    if type(v) == 'string' then goto continue end
    error(string.format("bad argument #%s to '%s' (string expected at index %s, got %s)", narg, debug.getinfo(2, 'n').name or '?', i, type(v)), 3)
    ::continue::
  end
  return t
end

---
-- Returns the YDB error code (if any) for the given error message.
-- Returns `nil` if the message is not a YDB error.
-- @param message String error message.
-- @return numeric YDB error code or nil
-- @name get_error_code
function M.get_error_code(message)
  return tonumber(assert_type(message, 'string', 1):match('YDB Error: (%-?%d+):'))
end

-- Object that represents a YDB key.
-- @class table
-- @name
local key = {}

---
-- Returns information about a variable/node (except intrinsic variables).
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @name data
-- @return yottadb.YDB_DATA_UNDEF (no value or subtree) or
--   yottadb.YDB_DATA_VALUE_NODESC (value, no subtree) or
--   yottadb.YDB_DATA_NOVALUE_DESC (no value, subtree) or
--   yottadb.YDB_DATA_VALUE_NODESC (value and subtree)
function M.data(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  return _yottadb.data(varname, subsarray)
end

---
-- Deletes a single variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @name delete_node
function M.delete_node(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_NODE)
end

---
-- Deletes a variable/node tree/subtree.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @name delete_tree
function M.delete_tree(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_TREE)
end

---
-- Gets and returns the value of a variable/node, or `nil` if the variable/node does not exist.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @return string value or `nil`
-- @name get
function M.get(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  local ok, value = pcall(_yottadb.get, varname, subsarray)
  if ok then return value end
  local code = M.get_error_code(value)
  if code == _yottadb.YDB_ERR_GVUNDEF or code == _yottadb.YDB_ERR_LVUNDEF then return nil end
  error(value) -- propagate
end

---
-- Increments the numeric value of a variable/node.
-- Raises an error on overflow.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @param increment Optional string or number amount to increment by.
-- @return the new value
-- @name incr
function M.incr(varname, subsarray, increment)
  assert_type(varname, 'string', 1)
  if not increment then
    assert_type(subsarray, 'table/string/number/nil', 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(increment, 'string/number/nil', 3)
  end
  assert_strings(subsarray, 'subsarray', 2)
  return _yottadb.incr(varname, subsarray, increment)
end

---
-- Releases all locks held and attempts to acquire all requested locks, waiting if requested.
-- Raises an error if a lock could not be acquired.
-- @param keys Optional list of {varname[, subs]} variable/nodes to lock.
-- @param timeout Optional timeout in seconds to wait for the lock.
-- @name lock
function M.lock(keys, timeout)
  if not timeout then
    assert_type(keys, 'table/number/nil', 1)
  else
    assert_type(keys, 'table', 1)
    assert_type(timeout, 'number', 2)
  end
  local keys_copy = {}
  if type(keys) == 'table' then
    for i, v in ipairs(keys) do
      keys[i] = getmetatable(v) == key and {v.varname, v.subsarray} or assert_type(v, 'table', 'keys[' .. i .. ']')
    end
    keys = keys_copy
  end
  _yottadb.lock(keys, timeout)
end

---
-- Attempts to acquire or increment a lock on a variable/node, waiting if requested.
-- Raises an error if a lock could not be acquired.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @param timeout Optional timeout in seconds to wait for the lock.
-- @name lock_incr
function M.lock_incr(varname, subsarray, timeout)
  assert_type(varname, 'string', 1)
  if not timeout then
    assert_type(subsarray, 'table/number/nil', 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(timeout, 'number/nil', 3)
  end
  assert_strings(subsarray, 'subsarray', 2)
  _yottadb.lock_incr(varname, subsarray, timeout)
end

---
-- Decrements a lock on a variable/node, releasing it if possible.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @name lock_decr
function M.lock_decr(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  return _yottadb.lock_decr(varname, subsarray)
end

---
-- Returns the next node for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @return list of subscripts for the node, or nil
-- @name node_next
function M.node_next(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  local ok, node_next = pcall(_yottadb.node_next, varname, subsarray)
  assert(ok or M.get_error_code(node_next) == _yottadb.YDB_ERR_NODEEND, node_next)
  return ok and node_next or nil
end

---
-- Returns the previous node for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @return list of subscripts for the node, or nil
-- @name node_previous
function M.node_previous(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  local ok, node_prev = pcall(_yottadb.node_previous, varname, subsarray)
  assert(ok or M.get_error_code(node_prev) == _yottadb.YDB_ERR_NODEEND, node_prev)
  return ok and node_prev or nil
end

---
-- Returns an iterator for iterating over all nodes in a variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts
-- @param reverse Optional flag that indicates whether to iterate backwards. The default value is
--   `false`.
-- @return iterator
-- @usage for node_subscripts in yottadb.nodes(varname, subsarray) do ... end
-- @name nodes
function M.nodes(varname, subsarray, reverse)
  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, 'table/boolean/nil', 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
  end
  assert_strings(subsarray, 'subsarray', 2)
  local subsarray_copy = {}
  for i, v in ipairs(subsarray) do subsarray_copy[i] = v end
  local f = not reverse and M.node_next or M.node_previous
  local initialized = false
  return function()
    if not initialized then
      local status = _yottadb.data(varname, reverse and subsarray_copy or nil)
      if not reverse then
        initialized = true
        if type(subsarray_copy) == 'table' and #subsarray_copy == 0 and (status == 1 or status == 11) then
          return subsarray_copy
        end
      else
        if status > 0 then table.insert(subsarray_copy, '') end
        while not initialized do
          local sub_prev = M.subscript_previous(varname, subsarray_copy)
          if sub_prev then
            table.insert(subsarray_copy, #subsarray_copy, sub_prev)
          else
            table.remove(subsarray_copy) -- pop
            initialized = true
          end
        end
        return subsarray_copy
      end
    end
    subsarray_copy = f(varname, subsarray_copy)
    return subsarray_copy
  end
end

---
-- Sets the value of a variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @param value String value to set. If this is a number, it is converted to a string.
-- @name set
function M.set(varname, subsarray, value)
  assert_type(varname, 'string', 1)
  if not value then
    assert_type(subsarray, 'string/number', 2) -- value
  else
    assert_type(subsarray, 'table', 2)
    assert_strings(subsarray, 'subsarray', 2)
    assert_type(value, 'string/number', 3)
  end
  _yottadb.set(varname, subsarray, value)
end

---
-- Returns the zwrite-formatted version of the given string.
-- @param s String to format.
-- @return formatted string
-- @name str2zwr
function M.str2zwr(s) return _yottadb.str2zwr(assert_type(s, 'string', 1)) end

---
-- Returns the next subscript for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @return string subscript name or nil
-- @name subscript_next
function M.subscript_next(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  local ok, sub_next = pcall(_yottadb.subscript_next, varname, subsarray)
  assert(ok or M.get_error_code(sub_next) == _yottadb.YDB_ERR_NODEEND, sub_next)
  return ok and sub_next or nil
end

---
-- Returns the previous subscript for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts.
-- @return string subscript name or nil
-- @name subscript_previous
function M.subscript_previous(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)
  local ok, sub_prev = pcall(_yottadb.subscript_previous, varname, subsarray)
  assert(ok or M.get_error_code(sub_prev) == _yottadb.YDB_ERR_NODEEND, sub_prev)
  return ok and sub_prev or nil
end

---
-- Returns an iterator for iterating over all subscripts in a variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts
-- @param reverse Optional flag that indicates whether to iterate backwards. The default value is
--   `false`.
-- @return iterator
-- @usage for name in yottadb.subscripts(varname, subsarray) do ... end
-- @name subscripts
function M.subscripts(varname, subsarray, reverse)
  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, 'table/boolean/nil', 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
    assert_strings(subsarray, 'subsarray', 2)
  end
  local subsarray_copy = {}
  if type(subsarray) == 'table' then for i, v in ipairs(subsarray) do subsarray_copy[i] = v end end
  local f = not reverse and M.subscript_next or M.subscript_previous
  return function()
    local next_or_prev = f(varname, subsarray_copy)
    if #subsarray_copy > 0 then
      subsarray_copy[#subsarray_copy] = next_or_prev
    else
      varname = next_or_prev
    end
    return next_or_prev
  end
end

---
-- Initiates a transaction.
-- @param id Optional string transaction id.
-- @param varnames Optional list of variable names to restore on transaction restart.
-- @param f Function to call. The transaction is committed if the function returns nothing or
--   yottadb.YDB_OK, restarted if the function returns yottadb.YDB_TP_RESTART (f will be called
--   again), or not committed if the function returns yottadb.YDB_TP_ROLLBACK or errors.
-- @param ... Optional arguments to pass to f.
-- @name tp
function M.tp(id, varnames, f, ...)
  if not varnames and not f then
    assert_type(id, 'function', 1)
  elseif not f then
    assert_type(id, 'string/table', 1)
    assert_type(varnames, 'function', 2)
  else
    assert_type(id, 'string', 1)
    assert_type(varnames, 'table', 2)
    assert_type(f, 'function', 3)
  end
  assert_strings(varnames, 'varnames', 2)
  _yottadb.tp(id, varnames, f, ...)
end

---
-- Returns a transaction-safe version of the given function such that it can be called with
-- YottaDB Transaction Processing.
-- @param f Function to convert. The transaction is committed if the function returns nothing
--   or yottadb.YDB_OK, restarted if the function returns yottadb.YDB_TP_RESTART (f will be
--   called again), or not committed if the function returns yottadb.YDB_TP_ROLLBACK or errors.
-- @return transaction-safe function.
-- @see tp
-- @name transaction
function M.transaction(f)
  return function(...)
    local args = {...}
    local function wrapped_transaction()
      local ok, result = pcall(f, table.unpack(args))
      if ok and not result then
        result = _yottadb.YDB_OK
      elseif not ok and M.get_error_code(result) == _yottadb.YDB_TP_RESTART then
        result = _yottadb.YDB_TP_RESTART
      elseif not ok then
        error(result, 2)
      end
      return result
    end
    return _yottadb.tp(wrapped_transaction, ...)
  end
end

---
-- Returns the string described by the given zwrite-formatted string.
-- @param s String in zwrite format.
-- @return string
-- @name zwr2str
function M.zwr2str(s) return _yottadb.zwr2str(assert_type(s, 'string', 1)) end

---
-- Creates and returns a new YottaDB key object.
-- This key has all of the linked methods below as well as the following fields:
--   * name (this key's subscript or variable name)
--   * value (this key's value in the YottaDB database)
--   * data (see data())
--   * has_value (whether or not this key has a value)
--   * has_tree (whether or not this key has a subtree)
-- Calling the key with a string value returns a subscripted key.
-- @param varname String variable name.
-- @param subsarray Used internally. Do not set manually. Call the returned key instead to
--   use subscripts.
-- @return key
-- @name key
-- @usage yottadb.key('varname')
-- @usage yottadb.key('varname')('subscript')
-- @see delete_node
-- @see delete_tree
-- @see get
-- @see incr
-- @see lock
-- @see lock_incr
-- @see lock_decr
-- @see set
-- @see subscript_next
-- @see subscript_previous
-- @see subscripts
function M.key(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_strings(subsarray, 'subsarray', 2)

  local subsarray_copy = {}
  if subsarray then for i, sub in ipairs(subsarray) do subsarray_copy[i] = sub end end

  -- For use with subscript_next() and subscript_previous().
  local next_subsarray = {}
  for i = 1, #subsarray_copy - 1 do next_subsarray[i] = subsarray_copy[i] end
  table.insert(next_subsarray, '')

  return setmetatable({
    varname = varname,
    subsarray = subsarray_copy,
    _next_subsarray = next_subsarray
  }, key)
end

-- @see get
function key:get() return M.get(self.varname, self.subsarray) end

-- @see set
function key:set(value) M.set(self.varname, self.subsarray, assert_type(value, 'string/number', 1)) end

-- @see delete_node
function key:delete_node() M.delete_node(self.varname, self.subsarray) end

-- @see delete_tree
function key:delete_tree() M.delete_tree(self.varname, self.subsarray_copy) end

-- @see incr
function key:incr(value)
  return M.incr(self.varname, self.subsarray, assert_type(value, 'string/number/nil', 1))
end

-- @see lock
function key:lock(timeout) return M.lock({self}, assert_type('number/nil', 1)) end

-- @see lock_incr
function key:lock_incr(timeout) return M.lock_incr(self.varname, self.subsarray, assert_type(timeout, 'number/nil', 1)) end

-- @see lock_decr
function key:lock_decr() return M.lock_decr(self.varname, self.subsarray) end

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_next
function key:subscript_next(reset)
  if reset then self._next_subsarray[#self._next_subsarray] = '' end
  local next_sub = M.subscript_next(self.varname, self._next_subsarray)
  if next_sub then self._next_subsarray[#self._next_subsarray] = next_sub end
  return next_sub
end

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_previous
function key:subscript_previous(reset)
  if reset then self._next_subsarray[#self._next_subsarray] = '' end
  local prev_sub = M.subscript_previous(self.varname, self._next_subsarray)
  if prev_sub then self._next_subsarray[#self._next_subsarray] = prev_sub end
  return prev_sub
end

-- @see subscripts
function key:subscripts(reverse)
  return M.subscripts(self.varname, self.subsarray, reverse)
end

-- Creates and returns a new key with the given subscript.
-- @param name String subscript name.
function key:__call(name)
  local new_key = M.key(self.varname, self.subsarray)
  table.insert(new_key.subsarray, assert_type(name, 'string', 1))
  return new_key
end

-- Returns whether this key is equal to the given object.
-- This is value equality, not reference equality.
function key:__eq(other)
  if getmetatable(self) ~= getmetatable(other) then return false end
  if self.varname ~= other.varname then return false end
  if #self.subsarray ~= #other.subsarray then return false end
  for i, value in ipairs(self.subsarray) do
    if value ~= other.subsarray[i] then return false end
  end
  return true
end

-- @see incr
function key:__add(value)
  self:incr(assert_type(value, 'string/number', 1))
  return self
end

-- @see incr
function key:__sub(value)
  self:incr(-assert_type(value, 'string/number', 1))
  return self
end

-- Returns the string representation of this key.
function key:__tostring()
  local subs = {}
  for i, name in ipairs(self.subsarray) do subs[i] = M.str2zwr(name) end
  local subscripts = table.concat(subs, ',')
  return subscripts ~= '' and string.format('%s(%s)', self.varname, subscripts) or self.varname
end

-- Returns various key properties.
function key:__index(k)
  if k == 'name' then
    return self.subsarray[#self.subsarray] or self.varname
  elseif k == 'value' then
    return self:get()
  elseif k == 'data' then
    return M.data(self.varname, self.subsarray)
  elseif k == 'has_value' then
    return self.data == _yottadb.YDB_DATA_VALUE_NODESC or self.data == _yottadb.YDB_DATA_VALUE_DESC
  elseif k == 'has_tree' then
    return self.data == _yottadb.YDB_DATA_NOVALUE_DESC or self.data == _yottadb.YDB_DATA_VALUE_DESC
  end
  return rawget(self, k) or key[k]
end

-- Sets key properties if possible.
function key:__newindex(k, v)
  if k == 'value' then
    self:set(v)
  else
    assert(k ~= 'name' and k ~= 'data' and k ~= 'has_value' and k ~= 'has_tree', 'read-only property')
    rawset(self, k, v)
  end
end

return M
