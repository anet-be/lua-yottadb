-- Copyright 2021-2022 Mitchell and Berwyn Hoyt. See LICENSE.

local M = {}

--[[ This comment is for LuaDoc.
---
-- Lua-bindings for YottaDB, sponsored by the Library of UAntwerpen, http://www.uantwerpen.be/.
module('yottadb')]]

local lua_version = tonumber( string.match(_VERSION, " ([0-9]+[.][0-9]+)") )

local _yottadb = require('_yottadb')
for k, v in pairs(_yottadb) do if k:find('^YDB_') then M[k] = v end end
M._VERSION = _yottadb._VERSION

_string_number = {string=true, number=true}
_string_number_nil = {string=true, number=true, ['nil']=true}
_table_string_number = {table=true, string=true, number=true}

_string_number = {string=true, number=true}
_string_number_nil = {string=true, number=true, ['nil']=true}

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
    if type(v) ~= 'string' then
      error(string.format("bad argument #%s to '%s' (string expected at index %s, got %s)", narg, debug.getinfo(2, 'n').name or '?', i, type(v)), 3)
    end
  end
  return t
end

-- create isinteger(n) that also works in Lua < 5.3 but is fast in Lua >=5.3
local isinteger
if lua_version >= 5.3 then
  function isinteger(n)
    return math.type(n) == 'integer'
  end
else
  function isinteger(n)
    return type(n) == 'number' and not (tostring(n):find(".", 1, true))
  end
end

-- Asserts that all items in table *t* are strings or integers, as befits subscripts;
-- otherwise calls `error()` with an error message
-- that implicates function argument number *narg* named *name*.
-- Like `assert_type()`, this is intended for improved readability of API input errors.
-- @param t Table to check. If it is not a table, the assertion passes.
-- @param name String argument name to use in error messages.
-- @param narg The position argument number *t* is associated with.
-- @usage assert_strings_integers(subsarray, 'subsarray', 2)
-- @see assert_type
local function assert_subscripts(t, name, narg)
  if type(t) ~= 'table' then return t end
  for i, v in ipairs(t) do
    local kind = type(v)
    if kind ~= 'string' and not isinteger(v) then
      error(string.format("bad argument #%s to '%s' (string or integer subscript expected at index %s, got %s)", narg, debug.getinfo(2, 'n').name or '?', i, kind), 3)
    end
  end
  return t
end

---
-- Get the YDB error code (if any) for the given error message.
-- @param message String error message.
-- @return the YDB error code (if any) for the given error message.
-- @return `nil` if the message is not a YDB error.
function M.get_error_code(message)
  return tonumber(assert_type(message, 'string', 1):match('YDB Error: (%-?%d+):'))
end

-- Object that represents a YDB node
-- @class table
-- @name
local node = {}
-- old name of YDB node object -- retains the deprecated syntax for backward compatibility
local key = {}

--- Get information about a variable/node (except intrinsic variables).
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @return yottadb.YDB_DATA_UNDEF (no value or subtree) or
--   yottadb.YDB_DATA_VALUE_NODESC (value, no subtree) or
--   yottadb.YDB_DATA_NOVALUE_DESC (no value, subtree) or
--   yottadb.YDB_DATA_VALUE_NODESC (value and subtree)
function M.data(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.data(varname, subsarray)
end

---
-- Deletes the value of a single variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
function M.delete_node(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_NODE)
end

---
-- Deletes a variable/node tree/subtree.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
function M.delete_tree(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_TREE)
end

---
-- Gets and returns the value of a variable/node, or `nil` if the variable/node does not exist.
-- @param varname String variable name.
-- @param subsarray ... Optional list of subscripts or table {subscripts}
-- @return string value or `nil`
function M.get(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
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
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @param increment String or number amount to increment by.
--     Optional only if subsarray is a table.
-- @return the new value
function M.incr(varname, ...) -- Note: '...' is {sub1, sub2, ...}, increment  OR  sub1, sub2, ..., increment
  local subsarray, increment
  if ... and type(...)=='table' then
    subsarray, increment = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), 'string/number', '<last>')  end
    subsarray = {...}
    increment = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if not increment then
    assert_type(subsarray, 'table/string/number/nil', 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(increment, 'string/number/nil', '<last>')
  end
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.incr(varname, subsarray, increment)
end

---
-- Releases all locks held and attempts to acquire all requested locks, waiting if requested.
-- Returns 0 (always)
-- Raises a error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
-- @param nodes Optional list containing {varname[, subs]} or node objects that specify the lock names to lock.
-- @param timeout Optional timeout in seconds to wait for the lock.
function M.lock(nodes, timeout)
  if not timeout then
    assert_type(nodes, 'table/number/nil', 1)
  else
    assert_type(nodes, 'table', 1)
    assert_type(timeout, 'number', 2)
  end
  local nodes_copy = {}
  if type(nodes) == 'table' then
    for i, v in ipairs(nodes) do
      local mt = getmetatable(v)
      nodes[i] = (mt==node or mt==key) and {v.__varname, v.__subsarray} or assert_type(v, 'table', 'nodes[' .. i .. ']')
    end
    nodes = nodes_copy
  end
  _yottadb.lock(nodes, timeout)
end

---
-- Attempts to acquire or increment a lock of the same name as {varname, subsarray}, waiting if requested.
-- Returns 0 (always)
-- Raises a error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @param timeout Seconds to wait for the lock.
--          Optional only if subscripts is a table.
function M.lock_incr(varname, ...) -- Note: '...' is {sub1, sub2, ...}, timeout  OR  sub1, sub2, ..., timeout
  local subsarray, timeout
  if ... and type(...)=='table' then
    subsarray, timeout = ...
  else
    -- Additional check last parameter is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), 'number', '<last>') end
    subsarray = {...}
    timeout = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if not timeout then
    assert_type(subsarray, 'table/number/nil', 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(timeout, 'number/nil', '<last>')
  end
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.lock_incr(varname, subsarray, timeout)
end

---
-- Decrements a lock of the same name as {varname, subsarray}, releasing it if possible.
-- Returns 0 (always)
-- Releasing a lock cannot create an error unless the varname/subsarray names are invalid
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
function M.lock_decr(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.lock_decr(varname, subsarray)
end

---
-- Returns the next node for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @return list of subscripts for the node, or nil
function M.node_next(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  local ok, node_next = pcall(_yottadb.node_next, varname, subsarray)
  assert(ok or M.get_error_code(node_next) == _yottadb.YDB_ERR_NODEEND, node_next)
  return ok and node_next or nil
end

---
-- Returns the previous node for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @return list of subscripts for the node, or nil
function M.node_previous(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  local ok, node_prev = pcall(_yottadb.node_previous, varname, subsarray)
  assert(ok or M.get_error_code(node_prev) == _yottadb.YDB_ERR_NODEEND, node_prev)
  return ok and node_prev or nil
end

---
-- Returns an iterator for iterating over all nodes in a variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}
-- @param reverse Flag that indicates whether to iterate backwards.
--          Optional only if subscripts is a table.
-- @return iterator
-- @usage for node_subscripts in yottadb.nodes(varname, subsarray) do ... end
function M.nodes(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, reverse  OR  sub1, sub2, ..., reverse
  local subsarray, reverse
  if ... and type(...)=='table' then
    subsarray, reverse = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), 'number/boolean', '<last>')  end
    subsarray = {...}
    reverse = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, 'table/boolean/nil', 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
  end
  assert_subscripts(subsarray, 'subsarray', 2)
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
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @param value String value to set. If this is a number, it is converted to a string.
function M.set(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, value  OR  sub1, sub2, ..., value
  local subsarray, value
  if ... and type(...)=='table' then
    subsarray, value = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), 'string/number', '<last>')  end
    subsarray = {...}
    value = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if not value then
    assert_type(subsarray, 'string/number', 2) -- value
  else
    assert_type(subsarray, 'table', 2)
    assert_subscripts(subsarray, 'subsarray', 2)
    assert_type(value, 'string/number', '<last>')
  end
  _yottadb.set(varname, subsarray, value)
end

---
-- Returns the zwrite-formatted version of the given string.
-- @param s String to format.
-- @return formatted string
function M.str2zwr(s) return _yottadb.str2zwr(assert_type(s, 'string', 1)) end

---
-- Returns the next subscript for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @return string subscript name or nil
function M.subscript_next(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  local ok, sub_next = pcall(_yottadb.subscript_next, varname, subsarray)
  assert(ok or M.get_error_code(sub_next) == _yottadb.YDB_ERR_NODEEND, sub_next)
  return ok and sub_next or nil
end

---
-- Returns the previous subscript for a variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}.
-- @return string subscript name or nil
function M.subscript_previous(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  local ok, sub_prev = pcall(_yottadb.subscript_previous, varname, subsarray)
  assert(ok or M.get_error_code(sub_prev) == _yottadb.YDB_ERR_NODEEND, sub_prev)
  return ok and sub_prev or nil
end

---
-- Returns an iterator for iterating over all subscripts in a variable/node.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}
-- @param reverse Flag that indicates whether to iterate backwards. 
--          Optional only if subscripts is a table.
-- @return iterator
-- @usage for name in yottadb.subscripts(varname, subsarray) do ... end
function M.subscripts(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, reverse  OR  sub1, sub2, ..., reverse
  local subsarray, reverse
  if ... and type(...)=='table' then
    subsarray, reverse = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), 'number/boolean', '<last>')  end
    subsarray = {...}
    reverse = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, 'table/boolean/nil', 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
    assert_subscripts(subsarray, 'subsarray', 2)
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
-- @param id Optional string transaction id. See ydb docs for special ids 'BA' or 'BATCH':
--   https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing
-- @param varnames Optional table of local M variable names to restore on transaction restart
--   (or {'*'} for all locals) -- restoration does apply to rollback
-- @param f Function to call. The transaction's affected globals are committed if the function returns nothing or
--   yottadb.YDB_OK, restarted if the function returns yottadb.YDB_TP_RESTART (f will be called
--   again), or not committed if the function returns yottadb.YDB_TP_ROLLBACK or errors.
--   Note: restarts are subject to $ZMAXTPTIME after which they cause error %YDB-E-TPTIMEOUT
-- @param ... Optional arguments to pass to f.
function M.tp(id, varnames, f, ...) -- optional: id, varnames
  -- fill in missing inputs if necessary
  local args={id, varnames, f, ...}
  local inserted = 0
  if type(args[1]) ~= 'string' then  table.insert(args, 1, "")  inserted = inserted+1 end
  if type(args[2]) ~= 'table' then  table.insert(args, 2, {})  inserted = inserted+1 end
  id, varnames, f = args[1], args[2], args[3]

  assert_type(id, 'string', 1)
  assert_type(varnames, 'table', 2-inserted)
  assert_strings(varnames, 'varnames', 2-inserted)
  assert_type(f, 'function', 3-inserted)
  _yottadb.tp(id, varnames, f, table.unpack(args, 4))
end

---
-- Returns a transaction-safed version of the given function such that it will be called within
--   a yottadb transaction and the dbase globals restored on error or rollback()
-- @param id Optional string transaction id. See ydb docs for special ids 'BA' or 'BATCH':
--   https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing
-- @param varnames Optional table of local M variable names to restore on transaction restart
--   (or {'*'} for all locals) -- restoration does apply to rollback
-- @param f Function to convert. The transaction's affected globals are committed if the function returns nothing
--   or yottadb.YDB_OK, restarted if the function returns yottadb.YDB_TP_RESTART (f will be
--   called again), or not committed if the function returns yottadb.YDB_TP_ROLLBACK or errors.
--   Note: restarts are subject to $ZMAXTPTIME after which they cause error %YDB-E-TPTIMEOUT
-- @return transaction-safed function.
-- @see tp
function M.transaction(id, varnames, f) -- optional: id, varnames
  -- fill in missing inputs if necessary
  if type(id) ~= 'string' then  id, varnames, f = "", id, varnames  end
  if type(varnames) ~= 'table' then  varnames, f = {}, varnames  end

  return function(...)
    local args = {...}
    local function wrapped_transaction()
      local ok, result = pcall(f, table.unpack(args))
      if ok and not result then
        result = _yottadb.YDB_OK
      elseif not ok and M.get_error_code(result) == _yottadb.YDB_TP_RESTART then
        result = _yottadb.YDB_TP_RESTART
      elseif not ok and M.get_error_code(result) == _yottadb.YDB_TP_ROLLBACK then
        result = _yottadb.YDB_TP_ROLLBACK
      elseif not ok then
        error(result, 2)
      end
      return result
    end
    return _yottadb.tp(id, varnames, wrapped_transaction, ...)
  end
end

-- Make the currently running transaction function restart immediately.
function M.trestart()
  error(_yottadb.message(_yottadb.YDB_TP_RESTART))
end

-- Make the currently running transaction function rollback immediately and produce a rollback error.
function M.trollback()
  error(_yottadb.message(_yottadb.YDB_TP_ROLLBACK))
end

---
-- Returns the string described by the given zwrite-formatted string.
-- @param s String in zwrite format.
-- @return string
function M.zwr2str(s) return _yottadb.zwr2str(assert_type(s, 'string', 1)) end

---
-- Creates and returns a new YottaDB node object.
-- This node has all of the class methods defined below it as well as the following properties:
--   * _name (this node's subscript or variable name)
--   * _value (this node's value in the YottaDB database)
--   * _data (see data())
--   * _has_value (whether or not this node has a value)
--   * _has_tree (whether or not this node has a subtree)
-- Calling the node with a string value returns a new node further subscripted by string.
-- @param varname String variable name.
-- @param subsarray Optional list of subscripts or table {subscripts}
-- @return node
-- @usage yottadb.node('varname')
-- @usage yottadb.node('varname')('subscript')
function M.node(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
<<<<<<< HEAD
  -- make it possible to inherit from node or key objects
  local mt = getmetatable(varname)
  if mt==node or mt==key then
    local new_subsarray = {}
    table.move(varname.__varname, 1, #varname.__varname, 1, new_subsarray)
    table.move(subsarray, 1, #subsarray, #new_subsarray+1, new_subsarray)
    varname = varname.__varname
    subsarray = new_subsarray
  end
  assert_type(varname, 'string', 1)
=======
>>>>>>> b723b7d (Support integer subscripts auto-converted to strings in all db access functions)

  local subsarray_copy = {}
  if subsarray then for i, sub in ipairs(subsarray) do subsarray_copy[i] = tostring(sub) end end

  -- For use with subscript_next() and subscript_previous().
  local next_subsarray = {}
  for i = 1, #subsarray_copy - 1 do next_subsarray[i] = subsarray_copy[i] end
  table.insert(next_subsarray, '')

  return setmetatable({
    __varname = varname,
    __subsarray = subsarray_copy,
    __next_subsarray = next_subsarray
  }, node)
end

-- Define this to tell __call() whether to create new node using M.node or M.key
node.___new = M.node

-- @see get
function node:get(default) return M.get(self.__varname, self.__subsarray) or default  end

-- @see set
function node:set(value) M.set(self.__varname, self.__subsarray, assert_type(value, 'string/number', 1)) end

-- @see delete_node
function node:delete_node() M.delete_node(self.__varname, self.__subsarray) end

-- @see delete_tree
function node:delete_tree() M.delete_tree(self.__varname, self.__subsarray) end

-- @see incr
function node:incr(value)
  return M.incr(self.__varname, self.__subsarray, assert_type(value, 'string/number/nil', 1))
end

-- @see lock
function node:lock(timeout) return M.lock({self}, assert_type('number/nil', 1)) end

-- @see lock_incr
function node:lock_incr(timeout) return M.lock_incr(self.__varname, self.__subsarray, assert_type(timeout, 'number/nil', 1)) end

-- @see lock_decr
function node:lock_decr() return M.lock_decr(self.__varname, self.__subsarray) end

-- declare a unique flag value yottadb.DELETE to pass to settree to instruct deletion of a value
M.DELETE = {}

-- Populate db from tbl. In its simpest form:
--    > node:settree({_='berwyn', weight=78, ['!@#$']='junk', appearance={_='handsome', eyes='blue', hair='blond'}, age=yottadb.DELETE})
-- @param tbl is the table to store into the databse
--    special field name _ sets the value of the node itself, as opposed to a subnode
--    assign special value yottadb.DELETE to a node to delete the _value of the node. You cannot delete the whole subtree
-- @param filter Optional function(node, key, value) or nil
--    if filter is nil, all values are set unfiltered
--    if filter is a function(node, key, value) it is invoked on every node
--        to allow it to cast/alter every key name and value
--    it must return the same or altered: key, value
--    type errors can be handled (or ignored) using this function, too.
--    if filter returns yottadb.DELETE as value, the key is deleted
--    if filter returns nil as key or value,
--        _settree will simply not update the current database value
-- @param _seen is for internal use only (to prevent accidental duplicate sets: bad because order setting is not guaranteed)
function node:settree(tbl, filter, _seen)
  _seen = _seen or {}
  for k,v in pairs(tbl) do
    if filter then  k,v = filter(self,k,v)  end
    if k and v~=nil then  -- if filter returned nil as k or v, => special do-nothing flag
      assert(_string_number[type(k)], string.format("Cannot set %s subscript of type %s: must be string/number", self, type(k)))
      local child = k=='_' and self or self(k)
      if v==M.DELETE then
        assert(not _seen[tostring(child)], string.format("Node already updated (when trying to delete node %s)", child, v), 2)
        node.delete_node(child)
      elseif type(v) == 'table' then
        node.settree(child, v, filter, _seen)  -- recurse into sub-table
      else
        assert(not _seen[tostring(child)], string.format("Node already updated (when trying to set node %s to %s)", child, v), 2)
        _seen[tostring(child)] = true
        assert(_table_string_number[type(v)], string.format("Cannot set node %s to type %s", child, v))
        node.set(child, v)
      end
    end
  end
end

-- Fetch database node and subtree and return a Lua table of it. But be aware that order is not preserved by Lua tables.
-- In its simplest form:
--    > node:gettree()
--    {_='berwyn', weight=78, ['!@#$']='junk', appearance={_='handsome', eyes='blue', hair='blond'}, age=49}
--  Note: special field name _ indicates the value of the node itself
-- @param maxdepth Optional subscript depth to fetch (nil=infinite; 1 fetches first layer of subscript's values only)
-- @param filter Optional function(node, node_subscript, value, recurse, depth) or nil
--    if filter is nil, all values are fetched unfiltered
--    if filter is a function(node, node_subscript, value, recurse, depth) it is invoked on every subscript
--        to allow it to cast/alter every _value and recurse flag
--        note that at node root (depth=0), subscript passed to filter is ''
--    it must return the same or an altered _value (string/number/nil) and recurse flag
--    if filter returns a nil _value then _gettree will store nothing in the table for that database value
--    if filter return false recurse flag, it will prevent recursion deeper into that particular subscript
-- @param _value is for internal use only (to avoid duplicate value fetches, for speed)
-- @param _depth is for internal use only (to record depth of recursion) and must start unspecified (nil)
function node:gettree(maxdepth, filter, _value, _depth)
  if not _depth then  -- i.e. if this is the first time the function is called
    _depth = _depth or 0
    maxdepth = maxdepth or 1/0  -- or infinity
    _value = node.get(self)
    if filter then  _value = filter(self, '', _value, true, _depth)  end
  end
  local tbl = {}
  if _value then  tbl._ = _value  end
  _depth = _depth + 1
  for subscript, subnode in pairs(self) do
    local recurse = _depth <= maxdepth and node.data(subnode) >= 10
    _value = node.get(subnode)
    if filter then  _value, recurse = filter(subnode, subscript, _value, recurse, _depth)  end
    if recurse then
      _value = node.gettree(subnode, maxdepth, filter, _value, _depth)
    end
    if _value then  tbl[subscript] = _value  end
  end
  return tbl
end

-- Return iterator over the child subscripts of a node (in M terms, collate from "" to "")
-- Unlike the deprecated key:subscripts(), node:subscripts() returns all *child* subscripts, not all subsequent subscripts in the same level
-- @param reverse Optional set to true to iterate in reverse order
-- @usage: for subscript in node:subscripts() do ...
-- @Note that subscripts() order is guaranteed to equal the M collation sequence order
function node:subscripts(reverse)
  local actuator = not reverse and M.subscript_next or M.subscript_previous
  local subsarray = table.move(self.__subsarray, 1, #self.__subsarray, 1, {})
  table.insert(subsarray, '')  -- empty subscript is starting point for iterating all subscripts
  local function iterator()
    local next_or_prev = actuator(self.__varname, subsarray)
    subsarray[#subsarray] = next_or_prev
    return next_or_prev
  end
  return iterator, subsarray, ''  -- iterate using child from ''
end

-- Define methods to fetch node properties
-- @param node is the node to fetch the property of
function node:name()  return self.__subsarray[#self.__subsarray] or self.__varname  end
function node:data()  return M.data(self.__varname, self.__subsarray)  end
function node:has_value()  return node.data(self)%2 == 1  end
function node:has_tree()  return node.data(self)   >= 10  end

-- Makes pairs() work - iterate over the child subscripts, values of given node
-- If you need to iterate in reverse, use node:pairs(reverse) instead of pairs(node)
-- @usage: for subscript,subnode in pairs(node) do ...
--     where subnode is a node/key object. If you need its value use node._
-- @Note2 that pairs() order is guaranteed to equal the M collation sequence order
--   (even though pairs() order is not normally guaranteed for Lua tables)
--   This means that pairs() is a reasonable substitute for ipairs -- see ipairs() below
function node:__pairs(reverse)
  local sub_iter, state, start = node.subscripts(self, reverse)
  local function iterator()
    local sub=sub_iter()
    if sub==nil then return nil end
    return sub, self(sub)
  end
  return iterator, state, start
end
node.pairs = node.__pairs

-- ipairs() -- not implemented
-- Instead use pairs() as follows:
--    for k,v in pairs(node) do   if not tonumber(k) break end   <do_your_stuff with k,v>   end
-- (this works since standard M sequence is: numbers first -- unless your db specified another collation)
-- Alternative, to ensure integer keys: use a numeric loop as follows:
--    for i=1,1/0 do   v=node[i]._  if not v break then   <do_your_stuff with k,v>   end
-- Reason:
--  Lua >=5.3 implements ipairs to invoke __index()
--  This would mean that __index() would have to treat integer subscript lookup specially, so:
--    node['abc']  => produces a new node so that node.abc.def.ghi works
--    but node[1]  => would have to produce value node(1)._ so ipairs() works
--  Since ipairs() will be little used anyway, the consequent inconsistency discourages implementation

-- Creates and returns a new node with the given subscript(s) ... added.
-- If no subscripts supplied, return the value of the node
-- @param ... subscript array
function node:__call(...)
  -- implement invoking method with mynode.method()
  assert(..., "no argument #1 supplied when creating new subnode")
  if getmetatable(...)==node then
    local method = node[node.name(self)]
    assert(method, string.format("could not find node method '%s()' on node %s", node.name(self), ...))
    return method(...) -- first parameter of '...' is parent, as the method call will expect
  end
  local new_node = getmetatable(self).___new(self.__varname, self.__subsarray)
  for i = 1, select('#', ...) do
    local name = select(i, ...)
    if type(name) ~= 'string' and not isinteger(name) then
      error(string.format("bad subscript added to '%s' (string or integer expected, got %s)", self, type(name)))
    end
    table.insert(new_node.__subsarray, tostring(name))
  end
  -- also add to __next_subsarray so that subscript_next() works
  for i = #new_node.__next_subsarray, #new_node.__subsarray-1 do  new_node.__next_subsarray[i] = new_node.__subsarray[i] end
  table.insert(new_node.__next_subsarray, '')
  return new_node
end

-- Returns whether this node is equal to the given object.
-- This is value equality, not reference equality,
--   equivalent to tostring(self)==tostring(other)
-- @param other Alternate node to compare self against
function node:__eq(other)
  if getmetatable(self) ~= getmetatable(other)
  or self.__varname ~= other.__varname
  or #self.__subsarray ~= #other.__subsarray
  then  return false  end
  for i, value in ipairs(self.__subsarray) do
    if value ~= other.__subsarray[i] then  return false  end
  end
  return true
end

-- @see incr
function node:__add(value)
  node.incr(self, assert_type(value, 'string/number', 1))
  return self
end

-- @see incr
function node:__sub(value)
  node.incr(self, -assert_type(value, 'string/number', 1))
  return self
end

-- Returns the string representation of this node.
function node:__tostring()
  local subs = {}
  for i, name in ipairs(self.__subsarray) do subs[i] = M.str2zwr(name) end
  local subscripts = table.concat(subs, ',')
  return subscripts == '' and self.__varname or string.format('%s(%s)', self.__varname, subscripts)
end

-- Returns indexes into the node
-- Search order for node attribute k:
--   self[k] (implemented by Lua -- finds self.__varname, self.__subsarray, self.__next_subsarray)
--   node value, if k=='_' (the only node property)
--   node method, if k starts with '__' (k:__method() is the same as k:method() but 15x faster at ~200ns)
--   if nothing found, returns a new dbase subnode with subscript k
--   node:method() also works as a method as follows:
--      lua translates the ':' to node.method(self)
--      so first as subnode called node.method is created
--      and when invoked with () it checks whether the first parameter is self
--      and if so, invokes the method itself if it is a member of metatable 'node'
-- @param k Node attribute to look up
function node:__index(k)
  if k == '_' then  return M.get(self.__varname, self.__subsarray)  end
  local __end = '__\xff'
  if k < __end and k >= '__' then  -- fastest way to check if k:startswith('__') -- with majority case lowercase key values falling through fastest
    return node[k:sub(3)]  -- remove leading '__' to return node:method
  end
  return self(k)
end

-- Sets node's value if k='_'
-- It's tempting to implement db assignment node.subnode = 3
-- but that would not work consistently, e.g. node = 3 would set lua local
function node:__newindex(k, v)
  if k == '_' then
    M.set(self.__varname, self.__subsarray, assert_type(v, 'string/number', 1))
  else
    error(string.format("Tried to set node object %s. Did you mean to set %s._ instead?", self(k), self(k)), 2)
  end
end


-- ~~~ Deprecated M.key() ~~~
-- M.key() is the same as M.node() except that it retains:
--   deprecated attribute behaviour and property names (without '_' prefix) for backward compatibility
--   deprecated defintions of key:subscript(), key:subscript_next(), key:subscript_previous()
-- @see M.node
function M.key(varname, subsarray)
  assert_type(subsarray, 'table/nil', 2)
  local new_key = M.node(varname, subsarray)
  setmetatable(new_key, key)
  new_key.varname = new_key.__varname
  new_key.subsarray = new_key.__subsarray
  return new_key
end

for k, v in pairs(node) do  key[k]=v  end
key.___new = M.key

key_properties = {
  name = key.name,
  data = key.data,
  has_value = key.has_value,
  has_tree = key.has_tree,
  value = key.get,
}

-- Returns indexes into the key
-- Search order for key attribute k:
--   self[k] (implemented by Lua -- finds self.__varname, self.varname, etc.)
--   key_properties[k]
--   key[k] (i.e. look up in class named 'key' -- finds key.get, key.__call, etc.)
--   if nothing found, returns nil
-- @param k Node attribute to look up
function key:__index(k)
  local property = key_properties[k]
  if property then  return property(self)  end
  return key[k]
end

-- Sets dbase node value if k is 'value'; otherwise set self[k] = v
-- Differs from node.__newindex() as this can also set fields of self
function key:__newindex(k, v)
  if k == 'value' then
    key.set(self, v)
  else
    assert(not key_properties[k], 'read-only property')
    rawset(self, k, v)
  end
end

-- ~~~ Deprecated functionality for M.key() as it's not Lua-esque: use pairs(key) instead ~~~

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_next
-- @deprecated because:
--   a) it keeps dangerous state in the object: causes bugs where old references to it think it's still original
--   b) it is more Lua-esque to iterate all subscripts in the node (think table) using pairs()
--   c) if this is a common use-case, it should be reimplemented for node:subscript_next() by
--      returning a fresh node object (after node efficiency improvement to avoid subsarray duplication)
function key:subscript_next(reset)
  if reset then self.__next_subsarray[#self.__next_subsarray] = '' end
  local next_sub = M.subscript_next(self.__varname, self.__next_subsarray)
  if next_sub then self.__next_subsarray[#self.__next_subsarray] = next_sub end
  return next_sub
end

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_previous
-- @deprecated: see key:subscript_next()
function key:subscript_previous(reset)
  if reset then self.__next_subsarray[#self.__next_subsarray] = '' end
  local prev_sub = M.subscript_previous(self.__varname, self.__next_subsarray)
  if prev_sub then self.__next_subsarray[#self.__next_subsarray] = prev_sub end
  return prev_sub
end

-- @see subscripts
-- @deprecated because:
--   a) pairs() is more Lua-esque
--   b) it was is non-intuitive that k:subscripts() iterates only subsequent subscripts, not all child subscripts
function key:subscripts(reverse)
  return M.subscripts(self.__varname, #self.__subsarray > 0 and self.__subsarray or {''}, reverse)
end


-- ~~~ High level utility functions ~~~

-- Dump the specified node and its children
-- @usage: ydb.dump(node, {subsarray, ...}[, maxlines])  OR  ydb.dump(node, sub1, sub2, ...)
-- @param node: Either a node object with `...` subscripts or glvn varname with `...` subsarray
-- @param maxlines: maximum number of lines to output before stopping dump
-- return dump as a string
function M.dump(node, ...)
  -- check whether maxlines was supplied as last parameter
  local subs, maxlines
  if select('#',...)>0 and type(...)=='table' then  subs=...  maxlines=select(2, ...)
  else  subs, maxlines = {...}, 30  end
  node = M.node(node, subs)  -- ensure it's a node object, not a varname
  local function _dump(node, output)
    if #output >= maxlines then  return  end
    local value = node._
    if value then
      local subscripts = #node.__subsarray==0 and '' or string.format('("%s")', table.concat(node.__subsarray, '","'))
      table.insert(output, string.format('%s%s=%q', node.__varname, subscripts, value))
    end
    for subscript, subnode in pairs(node) do
      _dump(subnode, output)
    end
  end
  local output = {}
  _dump(node, output)
  if #output >= maxlines then
    table.insert(output, string.format("...etc.   -- stopped at %s lines; to show more use yottadb.dump(node, {subscripts}, maxlines)", maxlines))
  end
  return table.concat(output, '\n')
end



-- Handy for debugging
if os.getenv('developer_mode') then
  M._node = node
  M._key = key
  M._key_properties = key_properties
end

return M
