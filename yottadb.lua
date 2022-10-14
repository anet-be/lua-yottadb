-- Copyright 2021-2022 Mitchell. See LICENSE.

local M = {}

--[[ This comment is for LuaDoc.
---
-- Lua-bindings for YottaDB, sponsored by the Library of UAntwerpen, http://www.uantwerpen.be/.
module('yottadb')]]

local lua_version = tonumber( string.match(_VERSION, " ([0-9]+[.][0-9]+)") )

local _yottadb = require('_yottadb')
for k, v in pairs(_yottadb) do if k:find('^YDB_') then M[k] = v end end
M._VERSION = _yottadb._VERSION

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
    return not (tostring(n):find(".", 1, true))
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
    if kind ~= 'string' and (kind ~= 'number' or not isinteger(v)) then
      error(string.format("bad argument #%s to '%s' (string or integer subscript expected at index %s, got %s)", narg, debug.getinfo(2, 'n').name or '?', i, kind), 3)
    end
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

-- Object that represents a YDB node
-- @class table
-- @name
local node = {}
-- old name of YDB node object -- retains the deprecated syntax for backward compatibility
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.incr(varname, subsarray, increment)
end

---
-- Releases all locks held and attempts to acquire all requested locks, waiting if requested.
-- Raises an error if a lock could not be acquired.
-- @param nodes Optional list of {varname[, subs]} variable/nodes to lock.
-- @param timeout Optional timeout in seconds to wait for the lock.
-- @name lock
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
      nodes[i] = getmetatable(v) == node and {v.varname, v.subsarray} or assert_type(v, 'table', 'nodes[' .. i .. ']')
    end
    nodes = nodes_copy
  end
  _yottadb.lock(nodes, timeout)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
-- @param subsarray Optional list of subscripts.
-- @param value String value to set. If this is a number, it is converted to a string.
-- @name set
function M.set(varname, subsarray, value)
  assert_type(varname, 'string', 1)
  if not value then
    assert_type(subsarray, 'string/number', 2) -- value
  else
    assert_type(subsarray, 'table', 2)
    assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
  assert_subscripts(subsarray, 'subsarray', 2)
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
-- Creates and returns a new YottaDB node object.
-- This node has all of the linked methods below as well as the following properties:
--   * _name (this node's subscript or variable name)
--   * _value (this node's value in the YottaDB database)
--   * _data (see data())
--   * _has_value (whether or not this node has a value)
--   * _has_tree (whether or not this node has a subtree)
-- Calling the node with a string value returns a new node further subscripted by string.
-- @param varname String variable name.
-- @param subsarray Used internally. Do not set manually. Call the returned node instead to
--   use subscripts.
-- @return node
-- @name node
-- @usage yottadb.node('varname')
-- @usage yottadb.node('varname')('subscript')
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
function M.node(varname, subsarray)
  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table/nil', 2)
  assert_subscripts(subsarray, 'subsarray', 2)

  local subsarray_copy = {}
  if subsarray then for i, sub in ipairs(subsarray) do subsarray_copy[i] = tostring(sub) end end

  -- For use with subscript_next() and subscript_previous().
  local next_subsarray = {}
  for i = 1, #subsarray_copy - 1 do next_subsarray[i] = subsarray_copy[i] end
  table.insert(next_subsarray, '')

  return setmetatable({
    _varname = varname,
    _subsarray = subsarray_copy,
    _next_subsarray = next_subsarray
  }, node)
end

-- @see get
function node:_get() return M.get(self._varname, self._subsarray) end

-- @see set
function node:_set(value) M.set(self._varname, self._subsarray, assert_type(value, 'string/number', 1)) end

-- @see delete_node
function node:_delete_node() M._delete_node(self._varname, self._subsarray) end

-- @see delete_tree
function node:_delete_tree() M._delete_tree(self._varname, self._subsarray_copy) end

-- @see incr
function node:incr(value)
  return M._incr(self._varname, self._subsarray, assert_type(value, 'string/number/nil', 1))
end

-- @see lock
function node:_lock(timeout) return M.lock({self}, assert_type('number/nil', 1)) end

-- @see lock_incr
function node:_lock_incr(timeout) return M.lock_incr(self._varname, self._subsarray, assert_type(timeout, 'number/nil', 1)) end

-- @see lock_decr
function node:_lock_decr() return M.lock_decr(self._varname, self._subsarray) end

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_next
function node:_subscript_next(reset)
  if reset then self._next_subsarray[#self._next_subsarray] = '' end
  local next_sub = M.subscript_next(self._varname, self._next_subsarray)
  if next_sub then self._next_subsarray[#self._next_subsarray] = next_sub end
  return next_sub
end

-- @param reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see subscript_previous
function node:_subscript_previous(reset)
  if reset then self._next_subsarray[#self._next_subsarray] = '' end
  local prev_sub = M.subscript_previous(self._varname, self._next_subsarray)
  if prev_sub then self._next_subsarray[#self._next_subsarray] = prev_sub end
  return prev_sub
end

-- @see subscripts
function node:_subscripts(reverse)
  return M.subscripts(self._varname, #self._subsarray > 0 and self._subsarray or {''}, reverse)
end

-- Creates and returns a new node with the given subscript added.
-- @param name String subscript name.
function node:__call(name)
  local new_node = self.___new(self._varname, self._subsarray)
  local kind = type(name)
  if kind ~= 'string' and (kind ~= 'number' or not isinteger(name)) then
    error(string.format("bad subscript added '%s' (string or integer expected, got %s)", self, type(name)))
  end
  table.insert(new_node._subsarray, tostring(name))
  return new_node
end

-- Define this to tell __call() whether to create new node using M.node or M.key
node.___new = M.node

-- Returns whether this node is equal to the given object.
-- This is value equality, not reference equality,
--   equivalent to tostring(self)==tostring(other)
-- @param other Alternate node to compare self against
function node:__eq(other)
  if getmetatable(self) ~= getmetatable(other) then return false end
  if self._varname ~= other._varname then return false end
  if #self._subsarray ~= #other._subsarray then return false end
  for i, value in ipairs(self._subsarray) do
    if value ~= other._subsarray[i] then return false end
  end
  return true
end

-- @see incr
function node:__add(value)
  self:incr(assert_type(value, 'string/number', 1))
  return self
end

-- @see incr
function node:__sub(value)
  self:incr(-assert_type(value, 'string/number', 1))
  return self
end

-- Returns the string representation of this node.
function node:__tostring()
  local subs = {}
  for i, name in ipairs(self._subsarray) do subs[i] = M.str2zwr(name) end
  local subscripts = table.concat(subs, ',')
  return subscripts ~= '' and string.format('%s(%s)', self._varname, subscripts) or self._varname
end

-- Define functions to fetch node properties
-- @param node is the node to fetch the property of
local node_properties = {}
function node_properties._name(node)  return node._subsarray[#node._subsarray] or node._varname  end
function node_properties._data(node)  return M.data(node._varname, node._subsarray)  end
function node_properties._has_value(node)  return node._data%2 == 1  end
function node_properties._has_tree(node)  return node._data   >= 10  end
function node_properties._value(node)  return node:_get()  end
node_properties._ = node_properties._value

-- Returns indexes into the node
-- Search order for node attribute k:
--   self[k] (implemented by Lua -- finds self._varname, self._subsarray, self._nextsubsarray)
--   node[k] (i.e. look up in class named 'node' -- finds node._get, node.__call, etc)
--   node_properties[k]
--   if nothing found, returns a new dbase sub-node with subscript k
-- @param k Node attribute to look up
function node.__index(self, k)
  local property = node_properties[k]
  if property then  return property(self)  end
  return node[k] or self(k)
end

-- Sets node's value if k='_' or '_value'
-- otherwise sets the value of dbase sub-node self(k)
function node:__newindex(k, v)
  if k=='_value' or k=='_' then
    self:_set(v)
  else
    -- set sub-node[k] equal to value
    assert(not node_properties[k], 'read-only property')
    self(k):_set(v)
  end
end


-- ~~~ Deprecated M.key() ~~~
-- M.key() is the same as M.node() except that it retains deprecated
-- attribute behaviour and property names (without '_' prefix) for backward compatibility
-- @see M.node
function M.key(varname, subsarray)
  local new_key = M.node(varname, subsarray)
  setmetatable(new_key, key)
  return new_key
end

-- Make target table inherit all the attributes of origin table
-- PLUS copies of attributes starting with '_', renamed to be without '_'
-- return target
function inherit_plus(target, origin)
  for k, v in pairs(origin) do
    target[k] = v
    local attr = k:match('^_(%w[_%w]*)')
    if attr then  target[attr] = v  end
  end
  return target
end

local key_properties = {}
inherit_plus(key_properties, node_properties)
inherit_plus(key, node)
key.___new = M.key

-- Returns indexes into the key
-- Search order for key attribute k:
--   self[k] (implemented by Lua -- finds self._varname, self.varname, etc.)
--   key[k] (i.e. look up in class named 'key' -- finds key._get, key.get, key.__call, etc.)
--   key_properties[k]
--   if nothing found, returns nil
-- @param k Node attribute to look up
function key.__index(self, k)
  local property = key_properties[k]
  if property then  return property(self)  end
  return key[k]
end

-- Sets key properties if possible.
-- Differs from node.__newindex() which can also set value of dbase sub-node k
function key:__newindex(k, v)
  if k == 'value' then
    self:set(v)
  else
    assert(not key_properties[k], 'read-only property')
    rawset(self, k, v)
  end
end

-- handy for debugging
--~ M.key_properties = key_properties
--~ M.node_properties = node_properties
--~ M.k = key
--~ M.n = node


return M
