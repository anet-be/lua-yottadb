-- Copyright 2021-2022 Mitchell and Berwyn Hoyt. See LICENSE.

--- Lua-bindings for YottaDB, sponsored by the [University of Antwerp Library](https://www.uantwerpen.be/en/library/).
-- See [README](https://github.com/anet-be/lua-yottadb/blob/master/README.md) for a quick introduction with examples. <br>
-- Home page: [https://github.com/anet-be/lua-yottadb/](https://github.com/anet-be/lua-yottadb/)
-- @module yottadb

local M = {}

local lua_version = tonumber( string.match(_VERSION, " ([0-9]+[.][0-9]+)") )

local _yottadb = require('_yottadb')
for k, v in pairs(_yottadb) do if k:find('^YDB_') then M[k] = v end end
M._VERSION = _yottadb._VERSION


-- The following 5 lines at the start of this file makes this the first-documented
-- section after 'Functions', but the blank lines in between are necessary

--- High level functions
-- @section

--- @section end

-- The following renames documentation section title "Functions" to "Low level functions". Blank line necessary:

--- Low level functions
-- @section

--- Block or unblock YDB signals for while M code is running.
-- This function is designed to be passed to yottadb.init() as the `signal_blocker` parameter.
-- Most signals (listed in `BLOCKED_SIGNALS` in callins.c) are blocked using sigprocmask()
-- but SIGLARM is not blocked; instead, sigaction() is used to set its SA_RESTART flag while
-- in Lua, and cleared while in M. This makes the OS automatically restart IO calls that are 
-- interrupted by SIGALRM. The benefit of this over blocking is that the YDB SIGALRM
-- handler does actually run, allowing YDB to flush the database or IO as necessary without
-- your M code having to call the M command `VIEW "FLUSH"`.
--
-- Note: this function does take time, as OS calls are slow. Using it will increase the M calling
-- overhead by about 1.4 microseconds: 2-5x the bare calling overhead (see `make benchmarks`)
-- The call to init() already saves initial values of SIGALRM flags and Sigmask to reduce
-- OS calls and make it as fast as possible.
-- @function block_M_signals
-- @param bool true to block; false to unblock all YDB signals
-- @return nothing
-- @see init
M.block_M_signals = _yottadb.block_M_signals

--- Initialize ydb and set blocking of M signals.
-- If `signal_blocker` is specified, block M signals which could otherwise interrupt slow IO operations like reading from user/pipe.
-- Also read the notes on signals in the README.
-- Note: any calls to the YDB API also initialize YDB; any subsequent call here will set `signal_blocker` but not re-init YDB.
-- Assert any errors.
-- @function init
-- @param[opt] signal_blocker specifies a Lua callback CFunction (e.g. `yottadb.block_M_signals()`) which will be
-- called with parameter false on entry to M, and with true on exit from M, so as to unblock YDB signals while M is in use.
-- Setting `signal_blocker` to nil switches off signal blocking.
-- Note: Changing this to support a generic Lua function as callback would be possible but slow, as it would require
-- fetching the function pointer from a C closure, and using `lua_call()`.
-- @return nothing
-- @see block_M_signals
M.init = _yottadb.init

--- Lua function to call `ydb_eintr_handler()`.
-- If users wish to handle EINTR errors themselves, instead of blocking signals, they should call
-- `ydb_eintr_handler()` when they get an EINTR error, before restarting the erroring OS system call.
-- @function ydb_eintr_handler
-- @return YDB_OK on success, and >0 on error (with message in ZSTATUS)
-- @see block_M_signals
M.ydb_eintr_handler = _yottadb.ydb_eintr_handler


-- Valid type tables which may be passed to assert_type() below
local _number_boolean = {number=true, boolean=true}
local _number_nil = {number=true, ['nil']=true}
local _string_number = {string=true, number=true}
local _string_number_nil = {string=true, number=true, ['nil']=true}
local _table_nil = {table=true, ['nil']=true}
local _table_number_nil = {table=true, number=true, ['nil']=true}
local _table_boolean_nil = {table=true, boolean=true, ['nil']=true}
local _table_string = {table=true, string=true}
local _table_string_number = {table=true, string=true, number=true}
local _table_string_number_nil = {table=true, string=true, number=true, ['nil']=true}

--- Verify type of v.
--- Asserts that type(`v`) is equal to expected_types (string) or is in `expected_types` (table) 
-- and returns `v`, or calls `error()` with an error message that implicates function argument 
-- number `narg`.
-- Used with API function arguments so users receive more helpful error messages.
-- @param v Value to assert the type of.
-- @param expected_types String of valid type or Table whose keys are valid type names to check against.
-- @param narg The positional argument number `v` is associated with. This is not required to
--   be a number.
-- @usage assert_type(value, _string_nil, 1)
-- @usage assert_type(option.setting, 'number', 'setting') -- implicates key
local function assert_type(v, expected_types, narg)
  local t = type(v)
  if t == expected_types or expected_types[t] then  return v  end
  -- Note: do not use assert for performance reasons.
  if not _table_string[type(expected_types)] then
    error(string.format("bad argument #2 to '%s' (table/string expected, got %s)",
      debug.getinfo(1, 'n').name, type(expected_types)), 2)
  elseif narg == nil then
    error(string.format("bad argument #3 to '%s' (value expected, got %s)",
      debug.getinfo(1, 'n').name, type(narg)), 2)
  end
  local expected_list = {}
  if type(expected_types) == 'string' then
    table.insert(expected_list, expected_types)
  else
    for t in pairs(expected_types) do  table.insert(expected_list, t)  end
  end
  error(string.format("bad argument #%s to '%s' (%s expected, got %s)", narg,
    debug.getinfo(2, 'n').name or '?', table.concat(expected_list, '/'), type(v)), 3)
end

--- Asserts that all items in table *t* are strings, or calls `error()` with an error message
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

-- ~~~ Support for Lua versions prior to 5.4 ~~~

--- Create isinteger(n) that also works in Lua < 5.3 but is fast in Lua >=5.3
-- @function isinteger
-- @param n number to test
-- @local
local isinteger
if lua_version >= 5.3 then
  function isinteger(n)
    return math.type(n) == 'integer'
  end
else
  function isinteger(n)
    return type(n) == 'number' and n % 1 == 0
  end
end

if lua_version < 5.4 then
  local function argcheck(cond, i, f, extra)
    if not cond then
      error("bad argument #"..i.." to '"..f.."' ("..extra..")", 2)
    end
  end
  -- implement table.move
  function table.move(a1, f, e, t, a2)
    a2 = a2 or a1
    argcheck(isinteger(f), 2, "table.move", "integer expected, got "..type(f))
    argcheck(f>0, 2, "table.move", "initial position must be positive")
    argcheck(isinteger(e), 3, "table.move", "integer expected, got "..type(e))
    argcheck(isinteger(t), 4, "table.move", "integer expected, got "..type(e))
    if e >= f then
      local m, n, d = 0, e-f, 1
      if t > f then m, n, d = n, m, -1 end
      for i = m, n, d do
        a2[t+i] = a1[f+i]
      end
    end
    return a2
  end
end


--- Asserts that all items in table *t* are strings or integers, as befits subscripts.
-- Otherwise calls `error()` with an error message
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

--- Convert str to number if the lua representation is identical.
-- Otherwise return nil
-- @param str string for potential conversion to a number
-- @return number or nil
local function q_number(str)
  local num = tonumber(str)
  return num and tostring(num)==str and num or nil
end

--- Get the YDB error code (if any) contained in the given error message.
-- @param message String error message.
-- @return the YDB error code (if any) for the given error message,
-- @return or `nil` if the message is not a YDB error.
function M.get_error_code(message)
  return tonumber(assert_type(message, 'string', 1):match('YDB Error: (%-?%d+):'))
end

-- Object that represents a YDB node.
local node = {}

-- Deprecated object that represents a YDB node.
-- old name of YDB node object -- retains the deprecated syntax for backward compatibility
local key = {}

--- Get information about a variable/node (except intrinsic variables).
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @return yottadb.YDB_DATA_UNDEF (no value or subtree)
-- @return or yottadb.YDB_DATA_VALUE_NODESC (value, no subtree)
-- @return or yottadb.YDB_DATA_NOVALUE_DESC (no value, subtree)
-- @return or yottadb.YDB_DATA_VALUE_NODESC (value and subtree)
function M.data(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.data(varname, subsarray)
end

--- Deletes the value of a single database variable/node.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
function M.delete_node(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_NODE)
end

--- Deletes a database variable/node tree/subtree.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
function M.delete_tree(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_TREE)
end

--- Gets and returns the value of a database variable/node, or `nil` if the variable/node does not exist.
-- @param varname String variable name.
-- @param[opt] ... list of subscripts or table {subscripts}
-- @return string value or `nil`
function M.get(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  local ok, value = pcall(_yottadb.get, varname, subsarray)
  if ok then return value end
  local code = M.get_error_code(value)
  if code == _yottadb.YDB_ERR_GVUNDEF or code == _yottadb.YDB_ERR_LVUNDEF then return nil end
  if code == _yottadb.YDB_ERR_INVVARNAME then  value = string.format("%s ydb_get('%.32s')", value, varname)  end
  error(value) -- propagate
end

--- Increments the numeric value of a database variable/node.
-- Raises an error on overflow.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @param increment String or number amount to increment by.
--  Optional only if subsarray is a table (default=1).
-- @return the new value
function M.incr(varname, ...) -- Note: '...' is {sub1, sub2, ...}, increment  OR  sub1, sub2, ..., increment
  local subsarray, increment
  if ... and type(...)=='table' then
    subsarray, increment = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), _string_number, '<last>')  end
    subsarray = {...}
    increment = table.remove(subsarray) -- pop
  end

  assert_type(varname, 'string', 1)
  if not increment then
    assert_type(subsarray, _table_string_number_nil, 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(increment, _string_number_nil, '<last>')
  end
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.incr(varname, subsarray, increment)
end

--- Releases all locks held and attempts to acquire all requested locks, waiting if requested.
-- Returns 0 (always).
-- Raises an error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
-- @param[opt] nodes list containing {varname[, subs]} or node objects that specify the lock names to lock.
-- @param[opt] timeout timeout in seconds to wait for the lock.
function M.lock(nodes, timeout)
  if not timeout then
    assert_type(nodes, _table_number_nil, 1)
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

--- Attempts to acquire or increment a lock of the same name as {varname, subsarray}, waiting if requested.
-- Returns 0 (always)
-- Raises a error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @param timeout Seconds to wait for the lock.
--  Optional only if subscripts is a table.
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
    assert_type(subsarray, _table_number_nil, 2)
  else
    assert_type(subsarray, 'table', 2)
    assert_type(timeout, _number_nil, '<last>')
  end
  assert_subscripts(subsarray, 'subsarray', 2)
  _yottadb.lock_incr(varname, subsarray, timeout)
end

--- Decrements a lock of the same name as {varname, subsarray}, releasing it if possible.
-- Returns 0 (always).
-- Releasing a lock cannot create an error unless the varname/subsarray names are invalid.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
function M.lock_decr(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.lock_decr(varname, subsarray)
end

--- Returns the full subscript list ('path') of the next node after a database variable/node.
-- A next node chain started from varname will eventually reach all nodes under that varname in order.
--
-- Note: `node:gettree()` may be a better way to iterate a node tree (see comment on `yottadb.nodes()`)
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @return list of subscripts for the node, or nil if there isn't a next node
function M.node_next(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.node_next(varname, subsarray)
end

--- Returns the full subscript list ('path') of the previous node after a database variable/node.
-- A previous node chain started from varname will eventually reach all nodes under that varname in reverse order.
--
-- Note: `node:gettree()` may be a better way to iterate a node tree (see comment on `yottadb.nodes()`)
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @return list of subscripts for the node, or nil if there isn't a previous node
function M.node_previous(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.node_previous(varname, subsarray)
end

--- Deprecated; returns an iterator that yields a full subscript 'path' for each node.
-- `yottadb.nodes(varname)` will iterate all nodes under that varname.
-- `yottadb.nodes(varname, {subsarray})` will only iterate nodes under varname
-- that come after varname(subsarray) in order.
--
-- Note: `node:gettree()` is the preferred way to iterate a node tree because
--
-- * it only iterates nodes beneath (i.e. deeper than) `node` rather than all subsequent
--    nodes under varname
-- * it should be faster once lua-yottadb cached subsarrays are implemented
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}
-- @param reverse Flag that indicates whether to iterate backwards.
--   Optional only if subscripts is a table.
-- @return iterator
-- @usage for node_subscripts in yottadb.nodes(varname, subsarray) do ... end
function M.nodes(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, reverse  OR  sub1, sub2, ..., reverse
  local subsarray, reverse
  -- First do parameter checking
  if ... and type(...)=='table' then
    subsarray, reverse = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), _number_boolean, '<last>')  end
    subsarray = {...}
    reverse = table.remove(subsarray) -- pop
  end
  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, _table_boolean_nil, 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
  end
  assert_subscripts(subsarray, 'subsarray', 2)

  -- Now do the actual work
  local subsarray_copy = {}
  for i, v in ipairs(subsarray) do subsarray_copy[i] = v end
  local actuator = not reverse and _yottadb.node_next or _yottadb.node_previous
  local initialized = false
  return function()
    if not initialized then
      local status = _yottadb.data(varname, reverse and subsarray_copy or nil)
      if not reverse then
        initialized = true
        if #subsarray_copy == 0 and (status == 1 or status == 11) then  -- if root node and it has a value
          return subsarray_copy
        end
      else
        -- This code is Mitchell's. It searches for maximum depth of previous node because,
        -- for some reason, node_previous() doesn't do this, and
        -- subscript_previous() only adds one depth level at a time.
        -- I don't understand the reason for either fact: some quirk of ydb reverse $ORDER
        if status > 0 then table.insert(subsarray_copy, '') end
        while not initialized do
          local sub_prev = _yottadb.subscript_previous(varname, subsarray_copy)
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
    subsarray_copy = actuator(varname, subsarray_copy)
    return subsarray_copy
  end
end

--- Sets the value of a database variable/node.
-- @param varname string variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @param value string/number/nil value to set. If this is a number, it is converted to a string. If it is nil, the value is deleted.
-- @return value
function M.set(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, value  OR  sub1, sub2, ..., value
  local subsarray, value
  --[[
    Handle the following parameter scenarios
      0. varname only (error)
      1. varname, value (set root node)
      1.1 varname, nil (delete root node value)
      2. varname, {subsarray}, value (set node value)
      2.1 varname, {subsarray}, nil (delete node value)
      3. varname, sub, sub, ..., value (set node value)
      3.1 varname, sub, sub, ..., nil (delete node value)
    ]]
  -- handle scenario 0
  if select('#', ...)==0 then  error(string.format("no `value` argument #3 supplied to set(%q)", varname))  end
  if type(...) == 'table' then
    -- handle scenarios 2 and 2.1
    subsarray, value = ...
    assert(value or select(-1, ...) == nil, string.format('no `value` argument #3 supplied when setting %s("%s")', varname, table.concat(subsarray, '","')))
  else
    -- handle scenario 3.1 -- special handling to detect that a nil value was specified
    if select(-1, ...) == nil then  subsarray, value = {...}, nil
    -- handle scenario 3
    else  subsarray = {...}  value = table.remove(subsarray)  end  -- pop
  end

  assert_type(varname, 'string', 1)
  assert_type(subsarray, 'table', 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  if value == nil then  _yottadb.delete(varname, subsarray, _yottadb.YDB_DEL_NODE)  return nil  end
  assert_type(value, _string_number, '<last>')
  _yottadb.set(varname, subsarray, value)
  return value
end

--- Returns the next subscript for a database variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @return string subscript name or nil if there are no more subscripts
function M.subscript_next(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.subscript_next(varname, subsarray)
end

--- Returns the previous subscript for a database variable/node, or `nil` if there isn't one.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}.
-- @return string subscript name or nil if there are no previous subscripts
function M.subscript_previous(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(varname, 'string', 1)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  return _yottadb.subscript_previous(varname, subsarray)
end

--- Returns an iterator for iterating over database *sibling* subscripts starting from given varname(subs).
-- Note: this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
-- It operates differently than `node:subscipts()` which yields all subscripts that are *children* of the given node.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}
-- @param reverse Flag that indicates whether to iterate backwards. 
--   Optional only if subscripts is a table.
-- @return iterator
-- @usage for name in yottadb.subscripts(varname, subsarray) do ... end
function M.subscripts(varname, ...)  -- Note: '...' is {sub1, sub2, ...}, reverse  OR  sub1, sub2, ..., reverse
  local subsarray, reverse
  -- First do parameter checking
  if ... and type(...)=='table' then
    subsarray, reverse = ...
  else
    -- Additional check last param is not nil before turning into a table, which loses the last element
    if ... then  assert_type(select(-1, ...), _number_boolean, '<last>')  end
    subsarray = {...}
    reverse = table.remove(subsarray) -- pop
  end
  assert_type(varname, 'string', 1)
  if reverse == nil then
    assert_type(subsarray, _table_boolean_nil, 2)
    if type(subsarray) ~= 'table' then subsarray, reverse = {}, subsarray end
  else
    assert_type(subsarray, 'table', 2)
    assert_subscripts(subsarray, 'subsarray', 2)
  end

  -- Now do the actual work
  local subsarray_copy = {}
  if type(subsarray) == 'table' then for i, v in ipairs(subsarray) do subsarray_copy[i] = v end end
  local actuator = reverse and _yottadb.subscript_previous or _yottadb.subscript_next
  return function()
    local next_or_prev = actuator(varname, subsarray_copy)
    if #subsarray_copy > 0 then
      subsarray_copy[#subsarray_copy] = next_or_prev
    else
      varname = next_or_prev
    end
    return next_or_prev
  end
end

--- Returns the zwrite-formatted version of the given string.
-- @param s String to format.
-- @return formatted string
function M.str2zwr(s) return _yottadb.str2zwr(assert_type(s, 'string', 1)) end

--- Returns the string described by the given zwrite-formatted string.
-- @param s String in zwrite format.
-- @return string
function M.zwr2str(s) return _yottadb.zwr2str(assert_type(s, 'string', 1)) end

-- The following 6 lines defines the 'High level functions' section to appear
-- before 'Transactions' in the docs. The blank lines in between are necessary:

--- @section end

--- Transactions
-- @section

--- Initiates a transaction (low level function).
-- @param[opt] id optional string transaction id. For special ids `BA` or `BATCH`, see [ydb docs here](https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing).
-- @param[opt] varnames optional table of local M variable names to restore on transaction restart
--   (or `{'*'}` for all locals) -- restoration does apply to rollback
-- @param f Function to call. The transaction's affected globals are:
--
-- * committed if the function returns nothing or `yottadb.YDB_OK`
-- * restarted if the function returns `yottadb.YDB_TP_RESTART` (`f` will be called again) <br>
--    Note: restarts are subject to `$ZMAXTPTIME` after which they cause error `%YDB-E-TPTIMEOUT`
-- * not committed if the function returns `yottadb.YDB_TP_ROLLBACK` or errors out.
-- @param[opt] ... arguments to pass to `f`
-- @see transaction
function M.tp(id, varnames, f, ...)
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

--- Returns a high-level transaction-safed version of the given function. It will be called within
--   a yottadb transaction and the dbase globals restored on error or trollback()
-- @param[opt] id optional string transaction id. For special ids `BA` or `BATCH`, see [ydb docs here](https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing).
-- @param[opt] varnames optional table of local M variable names to restore on transaction trestart()
--   (or `{'*'}` for all locals) -- restoration does apply to rollback
-- @param f Function to call. The transaction's affected globals are:
--
-- * committed if the function returns nothing or `yottadb.YDB_OK`
-- * restarted if the function returns `yottadb.YDB_TP_RESTART` (`f` will be called again) <br>
--    Note: restarts are subject to `$ZMAXTPTIME` after which they cause error `%YDB-E-TPTIMEOUT`
-- * not committed if the function returns `yottadb.YDB_TP_ROLLBACK` or errors out.
-- @return transaction-safed function.
-- @see tp
function M.transaction(id, varnames, f)
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

--- Make the currently running transaction function restart immediately.
function M.trestart()
  error(_yottadb.message(_yottadb.YDB_TP_RESTART))
end

--- Make the currently running transaction function rollback immediately and produce a rollback error.
function M.trollback()
  error(_yottadb.message(_yottadb.YDB_TP_ROLLBACK))
end

--- @section end


-- ~~~ Functions to handle calling M routines from Lua ~~~

--- High level functions
-- @section

local param_type_enums = _yottadb.YDB_CI_PARAM_TYPES
string_pack = string.pack or _yottadb.string_pack  -- string.pack only available from Lua 5.3
if lua_version < 5.2 then
  string.format = _yottadb.string_format  -- make it also print tables in Lua 5.1
  table.unpack = _yottadb.table_unpack
end

--- Parse ydb call-in type of the typical form: IO:ydb_int_t*.
-- Spaces must be removed before calling this function.
-- Asserts any errors.
-- @return a string of type info packed into a string matching callins.h struct type_spec
local function pack_type(type_str, param_id)
  local pattern = '(I?)(O?):([%w_]+%*?)(.*)'
  local i, o, typ, alloc_str = type_str:match(pattern)
  assert(typ, string.format("ydb parameter %s not found in YDB call-in table specification %q", param_id, type_str))
  local type_enum = param_type_enums[typ]
  assert(type_enum, string.format("unknown parameter %s '%s' in YDB call-in table specification", param_id, typ))
  local input = i:upper()=='I' and 1 or 0
  local output = o:upper()=='O' and 1 or 0
  assert(output==0 or typ:find('*', 1, true), string.format("call-in output parameter %s '%s' must be a pointer type", param_id, typ))
  local alloc_str = alloc_str:match('%[(%d+)%]')
  local preallocation = tonumber(alloc_str) or -1
  assert(preallocation==-1 or type_enum>0x80, string.format("preallocation is meaningless for number type call-in parameter %s: '%s'", param_id, typ))
  assert(preallocation==-1 or output==1, string.format("preallocation is pointless for input-only parameter %s: '%s'", param_id, typ))
  assert(preallocation==-1 or typ~='ydb_char_t*', string.format("preallocation for ydb_char_t* output parameter %s is forced to [%d] to prevent overruns", param_id, _yottadb.YDB_MAX_STR))
  return string_pack('!=TBBBXT', preallocation, type_enum, input, output)
end

--- Parse one-line string of the ydb call-in file format.
-- Assert any errors.
-- @param line is the text in the current line of the call-in file
-- @param ci_handle handle of call-in table
-- @return C name for the M routine
-- @return a function to invoke the M routine
-- @return or return nil, nil if the line did not contain a function prototype
local function parse_prototype(line, ci_handle)
  line = line:gsub('//.*', '')  -- remove comments
  -- example prototype line: test_Run: ydb_string_t* %Run^test(I:ydb_string_t*, I:ydb_int_t, I:ydb_int_t)
  local pattern = '%s*([^:%s]+)%s*:%s*([%w_]+%s*%*?[%s%[%]%d]*)%s*([^(%s]+)%s*%(([^)]*)%)'
  local routine_name, ret_type, entrypoint, params = line:match(pattern)
  if not routine_name then  return nil, nil  end
  assert(params, string.format("Line does not match YDB call-in table specification: '%s'", line))
  local ret_type = ret_type:gsub('%s*', '') -- remove spaces
  local param_info = {pack_type(ret_type=='void' and ':void' or 'O:'..ret_type, "'return_value'")}
  -- now iterate each parameter
  params = params:gsub('%s*', '') -- remove spaces
  local i = 0
  for type_str in params:gmatch('([^,%)]+)') do
    i = i+1
    table.insert(param_info, pack_type(type_str, i))
  end
  local param_info_string = table.concat(param_info)
  local routine_name_handle = _yottadb.register_routine(routine_name, entrypoint)
  -- create a table used by func() below to reference the routine_name string to ensure it isn't garbage collected
  -- because it's used by C userdata in 'routine_name_handle', but and not referenced by Lua func()
  local routine_name_table = {routine_name_handle, routine_name}
  -- create the actual wrapper function
  local function func(...)
    return _yottadb.cip(ci_handle, routine_name_table[1], param_info_string, ...)
  end
  return routine_name, func
end

--- Import Mumps routines as Lua functions specified in ydb 'call-in' file. <br>
-- See example call-in file [arithmetic.ci](https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.ci)
-- and matching M file [arithmetic.m](https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.m)
-- @param Mprototypes is a list of lines in the format of ydb 'callin' files per ydb_ci().
-- If the string contains `:` it is considered to be the call-in specification itself;
-- otherwise it is treated as the filename of a call-in file to be opened and read.
-- @return A table of functions analogous to a Lua module.
-- Each function in the table will call an M routine specified in `Mprototypes`.
function M.require(Mprototypes)
  local routines = {}
  if not Mprototypes:find(':', 1, true) then
    -- read call-in file
    routines.__ci_filename_original = Mprototypes
    local f = assert(io.open(Mprototypes))
    Mprototypes = f:read('a')
    f:close()
  end
  -- preprocess call-in types that can't be used with wrapper caller ydb_call_variadic_plist_func()
  Mprototypes = Mprototypes:gsub('ydb_double_t%s*%*?', 'ydb_double_t*')
  Mprototypes = Mprototypes:gsub('ydb_float_t%s*%*?', 'ydb_float_t*')
  Mprototypes = Mprototypes:gsub('ydb_int_t%s*%*?', 'ydb_int_t*')
  -- remove preallocation specs for ydb which (as of r1.34) can only process them in call-out tables
  local ydb_prototypes = Mprototypes:gsub('%b[]', '')
  -- write call-in file and load into ydb
  local filename = os.tmpname()
  local f = assert(io.open(filename, 'w'), string.format("cannot open temporary call-in file %q", filename))
  assert(f:write(ydb_prototypes), string.format("cannot write to temporary call-in file %q", filename))
  f:close()
  local ci_handle = _yottadb.ci_tab_open(filename)
  routines.__ci_filename = filename
  routines.__ci_table_handle = ci_handle
  -- process ci-table ourselves to get routine names and types to cast
  local line_no = 0
  for line in Mprototypes:gmatch('([^\n]*)\n?') do
    line_no = line_no+1
    local ok, routine, func = pcall(parse_prototype, line, ci_handle)
    if routine then  routines[routine] = func end
  end
  os.remove(filename) -- cleanup
  return routines
end

--- @section end


--- Node object creation
-- @section

-- raw node creation
local function ___new_node(varname, subsarray)
  local subsarray_copy = {}
  if subsarray then for i, sub in ipairs(subsarray) do subsarray_copy[i] = tostring(sub) end end
  return setmetatable({
    __varname = varname,
    __subsarray = subsarray_copy,
  }, node)
end

--- Creates and returns a new YottaDB node object.
-- This node has all of the class methods defined below.
-- Calling the returned node with one or more string parameters returns a new node further subscripted by those strings.
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or a table of {subscripts}
-- @return node object with metatable yottadb._node
-- @usage yottadb.node('varname')
-- @usage yottadb.node('varname')('sub1', 'sub2')
-- @usage yottadb.node('varname', 'sub1', 'sub2')
-- @usage yottadb.node('varname', {'sub1', 'sub2'})
-- @usage yottadb.node('varname').sub1.sub2
-- @usage yottadb.node('varname')['sub1']['sub2']
function M.node(varname, ...)
  local subsarray = ... and type(...)=='table' and ... or {...}
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  -- make it possible to inherit from either node or key objects
  local mt = getmetatable(varname)
  if mt==node or mt==key then
    local new_subsarray = table.move(varname.__subsarray, 1, #varname.__subsarray, 1, {})
    table.move(subsarray, 1, #subsarray, #new_subsarray+1, new_subsarray)
    varname = varname.__varname
    subsarray = new_subsarray
  end
  assert_type(varname, 'string', 1)
  return ___new_node(varname, subsarray)
end

--- @section end

-- Define this to tell __call() whether to create new node using ___new_node() or ___new_key()
node.___new = ___new_node

-- Note: the following doc must be here instead of up at the definition of node to retain its position in the html doc

--- Object that represents a YDB node.
--
-- **Note1:** Although the syntax `node:method()` is pretty, be aware that it is slow. If you are concerned
-- about speed, use `node:__method()` instead, which is equivalent but 15x faster.
-- This is because Lua expands `node:method()` to `node.method(node)`, so lua-yottadb creates
-- an intermediate object of database subnode `node.method`, thinking it is is a database subnode access.
-- Then, when this object gets called with `()`, lua-yottadb discovers that its first parameter is of type `node` --
-- at which point it finally knows invoke `node.__method()` instead of treating it as a database subnode access.
--
-- **Note2:** Because lua-yottadb's underlying method access is with the `__` prefix, database node names
-- starting with two underscores are not accessable using dot notation: instead use mynode('__nodename') to 
-- access a database node named `__nodename`. In addition, Lua object methods starting with two underscores,
-- like `__tostring`, are only accessible with an *additional* `__` prefix, for example, `node:____tostring()`.
--
-- **Note3:** Several standard Lua operators work on nodes. These are: `+ - = pairs() tostring()`
-- @type node

--- Get node's value.
-- Equivalent to (but 2.5x slower than) `node.__`
-- @param[opt] default return value if the node has no data; if not supplied, nil is the default
-- @return value of the node
-- @see get
function node:get(default) return M.get(self.__varname, self.__subsarray) or default  end

--- Set node's value.
-- Equivalent to (but 4x slower than) `node.__ = x`
-- @param value New value or nil to delete node
-- @see set
function node:set(value) M.set(self.__varname, self.__subsarray, assert_type(value, _string_number_nil, 1)) end

--- Delete database tree pointed to by node object
-- @see delete_tree
function node:delete_tree() M.delete_tree(self.__varname, self.__subsarray) end

--- Increment node's value
-- @param[opt=1] increment Amount to increment by (negative to decrement)
-- @return the new value
-- @see incr
function node:incr(increment)
  return M.incr(self.__varname, self.__subsarray, assert_type(increment, _string_number_nil, 1))
end

--- Releases all locks held and attempts to acquire a lock matching this node, waiting if requested.
-- @see lock
function node:lock(timeout) return M.lock({self}, assert_type(_number_nil, 1)) end

--- Attempts to acquire or increment a lock matching this node, waiting if requested.
-- @see lock_incr
function node:lock_incr(timeout) return M.lock_incr(self.__varname, self.__subsarray, assert_type(timeout, _number_nil, 1)) end

--- Decrements a lock matching this node, releasing it if possible.
-- @see lock_decr
function node:lock_decr() return M.lock_decr(self.__varname, self.__subsarray) end

--- Return iterator over the *child* subscripts of a node (in M terms, collate from "" to "").
-- Unlike `yottadb.subscripts()`, `node:subscripts()` returns all *child* subscripts, not subsequent *sibling* subscripts in the same level.
-- Note that subscripts() order is guaranteed to equal the M collation sequence
-- @param[opt] reverse set to true to iterate in reverse order
-- @usage for subscript in node:subscripts() do ...
-- @return iterator over *child* subscripts of a node, returning a sequence of subscript name strings
function node:subscripts(reverse)
  local actuator = reverse and _yottadb.subscript_previous or _yottadb.subscript_next
  local next_or_prev = ''  -- NOTE: must be an upvalue of iterator so that it retains ref to string in cachearray for next iteration
  local cachearray = _yottadb.cachearray_fromtable(self.__varname, self.__subsarray, next_or_prev)
  local depth = #self.__subsarray + 1
  local function iterator()
    next_or_prev = actuator(self.__varname, cachearray)
    --self.__name = next_or_prev
    _yottadb.cachearray_replace(cachearray, depth, next_or_prev or '')
    return next_or_prev
  end
  return iterator, nil, ''  -- iterate using child from ''
end

-- Constant that may be passed to `node:settree()`
-- declare a unique flag value yottadb.DELETE to pass to settree to instruct deletion of a value
-- @see node:settree
M.DELETE = {}

--- High level functions
-- @section

--- Populate database from a table. In its simpest form:
--    node:settree({__='berwyn', weight=78, ['!@#$']='junk', appearance={__='handsome', eyes='blue', hair='blond'}, age=yottadb.DELETE})
-- @param tbl is the table to store into the database:
--
-- * special field name `__` sets the value of the node itself, as opposed to a subnode
-- * assign special value `yottadb.DELETE` to a node to delete the value of the node. You cannot delete the whole subtree
-- @param[opt] filter optional function(node, key, value) or nil
-- 
-- * if filter is nil, all values are set unfiltered
-- * if filter is a function(node, key, value) it is invoked on every node
-- to allow it to cast/alter every key name and value
-- * filter must return the same or altered: key, value
-- * type errors can be handled (or ignored) using this function, too.
-- * if filter returns yottadb.DELETE as value, the key is deleted
-- * if filter returns nil as key or value, settree will simply not update the current database value
-- @param[opt] _seen is for internal use only (to prevent accidental duplicate sets: bad because order setting is not guaranteed)
function node:settree(tbl, filter, _seen)
  _seen = _seen or {}
  for k,v in pairs(tbl) do
    if filter then  k,v = filter(self,k,v)  end
    if k and v~=nil then  -- if filter returned nil as k or v, => special do-nothing flag
      assert(_string_number[type(k)], string.format("Cannot set %s subscript of type %s: must be string/number", self, type(k)))
      local child = k=='__' and self or self(k)
      if v==M.DELETE then
        assert(not _seen[tostring(child)], string.format("Node already updated (when trying to delete node %s)", child, v), 2)
        node.set(child, nil)
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

--- Fetch database node and subtree and return a Lua table of it.
-- But be aware that order is not preserved by Lua tables.
--
--  Note: special field name `__` in the returned table indicates the value of the node itself.
-- @param[opt] maxdepth subscript depth to fetch (nil=infinite; 1 fetches first layer of subscript's values only)
-- @param[opt] filter optional `function(node, node_top_subscript_name, value, recurse, depth)` or nil
--
-- * if filter is nil, all values are fetched unfiltered
-- * if filter is a function it is invoked on every subscript
-- to allow it to cast/alter every value and recurse flag;
-- note that at node root (depth=0), subscript passed to filter is the empty string ""
-- * filter may optionally return two items: `value`, `recurse` -- copies of the input parameters, optionally altered:
--    * if filter returns `value` then gettree will store it in the table for that database subscript/value; or store nothing if `value=nil`
--    * if filter returns `recurse=false`, it will prevent recursion deeper into that particular subscript; if `nil`, it will use the original value of recurse
-- @param[opt] _value is for internal use only (to avoid duplicate value fetches, for speed)
-- @param[opt] _depth is for internal use only (to record depth of recursion) and must start unspecified (nil)
-- @return Lua table containing data
-- @usage t = node:gettree()
-- @usage node:gettree(nil, print) end)
-- -- prints details of every node in the tree
-- @see settree
function node:gettree(maxdepth, filter, _value, _depth)
  if not _depth then  -- i.e. if this is the first time the function is called
    _depth = _depth or 0
    maxdepth = maxdepth or 1/0  -- or infinity
    _value = node.get(self)
    if filter then  _value = filter(self, '', _value, true, _depth)  end
  end
  local tbl = {}
  if _value then  tbl.__ = _value  end
  _depth = _depth + 1
  for subnode, _value, subscript in self:__pairs() do   -- use self:__pairs() instead of pairs(self) so that it works in Lua 5.1
    local recurse = _depth <= maxdepth and node.data(subnode) >= 10
    if filter then
      local _recurse
      _value, _recurse = filter(subnode, subscript, _value, recurse, _depth)
      if _recurse~=nil then  recurse = _recurse  end  -- necessary in case user doesn't return recurse
    end
    if recurse then
      _value = node.gettree(subnode, maxdepth, filter, _value, _depth)
    end
    if _value then  tbl[subscript] = _value  end
  end
  return tbl
end

--- Dump the specified node and its children
-- @param[opt=30] maxlines Maximum number of lines to output before stopping dump
-- @return dump as a string
function node:dump(maxlines)
  return M.dump(self, {}, maxlines)
end

--- @section end

--- Class node
-- @section

--- Makes pairs() work - iterate over the child subscripts, values of given node.
-- You can use either `pairs(node)` or `node:pairs()`.
-- If you need to iterate in reverse (or in Lua 5.1), use node:pairs(reverse) instead of pairs(node).
-- Note that pairs() order is guaranteed to equal the M collation sequence order
--   (even though pairs() order is not normally guaranteed for Lua tables).
--   This means that pairs() is a reasonable substitute for ipairs which is not implemented.
-- @function node:__pairs
-- @param[opt] reverse Boolean flag iterates in reverse if true
-- @usage for subscript,subnode in pairs(node) do ...
--     where subnode is a node/key object. If you need its value use node._
-- @return subnode, subnode subnode_value_or_nil, subscript
function node:__pairs(reverse)
  local sub_iter, state, start = node.subscripts(self, reverse)
  local function iterator()
    local subscript=sub_iter()
    if subscript==nil then return nil end
    local subnode = self(subscript)
    return subnode, node.get(subnode), subscript
  end
  return iterator, state, start
end
node.pairs = node.__pairs

--- Not implemented - use `pairs(node)` or `node:__pairs()` instead.
-- See alternative usage below.
-- The reason this is not implemented is that since
--  Lua >=5.3 implements ipairs via `__index()`.
--  This would mean that `__index()` would have to treat integer subscript lookup specially, so:
--
-- * although `node['abc']`  => produces a new node so that `node.abc.def.ghi` works
-- * `node[1]`  => would have to produce value `node(1).__` so ipairs() works <br>
--  Since ipairs() will be little used anyway, the consequent inconsistency discourages implementation.
--
-- Alternatives using pairs() are as follows:
-- @function node:__ipairs
-- @usage for k,v in pairs(node) do   if not tonumber(k) break end   <do_your_stuff with k,v>   end
-- (this works since standard M order is numbers first -- unless your db specified another collation)
-- @usage `for i=1,1/0 do   v=node[i].__  if not v break then   <do_your_stuff with k,v>   end`
-- (alternative that ensures integer keys)

-- Creates and returns a new node with the given subscript(s) ... added.
-- If no subscripts supplied, return the value of the node
-- @param ... subscript array
function node:__call(...)
  -- implement invoking method with mynode.method()
  assert(..., string.format("attempt to invoke subnode %s() without parameters", self))
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
  node.incr(self, assert_type(value, _string_number, 1))
  return self
end

-- @see incr
function node:__sub(value)
  node.incr(self, -assert_type(value, _string_number, 1))
  return self
end

-- Returns the string representation of this node.
function node:__tostring()
  local subs = {}
  -- ensure numeric subscripts are not quoted so node name strings look more like in M but still Lua-compatible
  -- prior to lua-yottadb version 1.2 used M.str2zwr() which was slower and produced strings that Lua does not understand
  for i, name in ipairs(self.__subsarray) do  subs[i] = q_number(name) or string.format('%q', name)  end
  local subscripts = table.concat(subs, ',')
  return subscripts == '' and self.__varname or string.format('%s(%s)', self.__varname, subscripts)
end

-- Returns indexes into the node
-- Search order for node attribute k:
--   self[k] (implemented by Lua -- finds self.__varname, self.__subsarray)
--   node value, if k=='__' (the only node property)
--   node method, if k starts with '__' (k:__method() is the same as k:method() but 15x faster at ~200ns)
--   if nothing found, returns a new dbase subnode with subscript k
--   node:method() also works as a method as follows:
--      lua translates the ':' to node.method(self)
--      so first as subnode called node.method is created
--      and when invoked with () it checks whether the first parameter is self
--      and if so, invokes the method itself if it is a member of metatable 'node'
-- @param k Node attribute to look up
function node:__index(k)
  if k == '__' then  return M.get(self.__varname, self.__subsarray)  end
  local __end = '__\xff'
  if type(k)=='string' and k < __end and k >= '__' then  -- fastest way to check if k:startswith('__') -- with majority case (lowercase key values) falling through fastest
    return node[k:sub(3)]  -- remove leading '__' to return node:method
  end
  return self(k)
end

-- Sets node's value if k='__'
-- It's tempting to implement db assignment node.subnode = 3
-- but that would not work consistently, e.g. node = 3 would set lua local
function node:__newindex(k, v)
  if k == '__' then
    M.set(self.__varname, self.__subsarray, assert_type(v, _string_number_nil, 1))
  else
    error(string.format("Tried to set node object %s. Did you mean to set %s.__ instead?", self(k), self(k)), 2)
  end
end

--- @section end

--- Get node properties
-- @section

--- Fetch the name of the node, i.e. the rightmost subscript
function node:name()  return self.__subsarray[#self.__subsarray] or self.__varname  end
--- Fetch the 'data' flags of the node @see data
function node:data()  return M.data(self.__varname, self.__subsarray)  end
--- Return true if the node has a value; otherwise false
function node:has_value()  return node.data(self)%2 == 1  end
--- Return true if the node has a tree; otherwise false
function node:has_tree()  return node.data(self)   >= 10  end


-- ~~~ Deprecated object that represents a YDB node ~~~

--- Node object creation
-- @section

-- raw key creation
local function ___new_key(varname, subsarray)
  local new_key = ___new_node(varname, subsarray)
  setmetatable(new_key, key)
  new_key.varname = new_key.__varname
  new_key.subsarray = new_key.__subsarray
  return new_key
end

--- Deprecated object that represents a YDB node.
--
-- `key` is the same as `node` except that it retains
-- deprecated property names as follows for backward compatibility:
--
-- * `name` (this node's subscript or variable name) <br>
-- * `value` (this node's value in the YottaDB database) <br>
-- * `data` (see data()) <br>
-- * `has_value` (whether or not this node has a value) <br>
-- * `has_tree` (whether or not this node has a subtree) <br>
-- and deprecated definitions of `key:subscript()`, `key:subscript_next()`, `key:subscript_previous()`. <br>
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table {subscripts}
-- @return node object with metatable yottadb._key
-- @see node, data
function M.key(varname, subsarray)
  assert_type(subsarray, _table_nil, 2)
  assert_subscripts(subsarray, 'subsarray', 2)
  assert_type(varname, 'string', 1)
  return ___new_key(varname, subsarray)
end

--- Deprecated object that represents a YDB node.
--- @type key

for k, v in pairs(node) do  key[k]=v  end
key.___new = ___new_key

--- Properties of key object listed here, accessed with dot instead of colon.
-- This kind of property access is for backward compatibility.
--
-- For example, access data property with: `key.data`
-- @table property
-- @field name equivalent to `node:name()`
-- @field data equivalent to `node:data()`
-- @field has_value equivalent to `node:has_value()`
-- @field has_tree equivalent to `node:has_tree()`
-- @field value equivalent to `node.__`
key_properties = {
  name = key.name, -- equivalent to node::name()
  data = key.data, -- :name()
  has_value = key.has_value,
  has_tree = key.has_tree,
  value = key.get,
}

--- All node methods are inherited, plus key-specific method overrides shown here.
-- These methods are for backward compatibility.
-- @function key:_methods_

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

--- Deprecated way to delete database node value pointed to by node object. Prefer node:set(nil)
-- @see delete_node, set
function key:delete_node() M.delete_node(self.__varname, self.__subsarray) end

--- Deprecated way to get next *sibling* subscript.
-- Note: this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
-- It operates differently than `node:subscipts()` which yields all subscripts that are *children* of the given node.
-- Deprecated because:
--
-- * it keeps dangerous state in the object: causes bugs where old references to it think it's still original
-- * it is more Lua-esque to iterate all subscripts in the node (think table) using pairs()
-- * if sibling access becomes a common use-case, it should be reimplemented differently, by
--      returning a fresh node object (after completing node efficiency improvements that avoid
--      subsarray duplication)
-- @param[opt] reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see pairs, subscript_previous
function key:subscript_next(reset)
  -- Ensure we have a next_subsarray -- used only by key:subscript_next() and key:subscript_previous()
  if not self.__next_subsarray then
    self.__next_subsarray = table.move(self.__subsarray, 1, #self.__subsarray, 1, {})
    table.insert(self.__next_subsarray, '')
  end
  if reset then self.__next_subsarray[#self.__next_subsarray] = '' end
  local next_sub = M.subscript_next(self.__varname, self.__next_subsarray)
  if next_sub then self.__next_subsarray[#self.__next_subsarray] = next_sub end
  return next_sub
end


--- Deprecated way to get previous *sibling* subscript.
-- @param[opt] reset If `true`, resets to the original subscript before any calls to subscript_next()
--   or subscript_previous()
-- @see key:subscript_next, pairs
function key:subscript_previous(reset)
  -- Ensure we have a next_subsarray -- used only by key:subscript_next() and key:subscript_previous()
  if not self.__next_subsarray then
    self.__next_subsarray = table.move(self.__subsarray, 1, #self.__subsarray, 1, {})
    table.insert(self.__next_subsarray, '')
  end
  if reset then self.__next_subsarray[#self.__next_subsarray] = '' end
  local prev_sub = M.subscript_previous(self.__varname, self.__next_subsarray)
  if prev_sub then self.__next_subsarray[#self.__next_subsarray] = prev_sub end
  return prev_sub
end

--- Deprecated way to get same-level subscripts from this node onward.
-- Deprecated because:
--
-- * pairs() is more Lua-esque
-- * it was is non-intuitive that k:subscripts() iterates only subsequent subscripts, not all child subscripts
-- @param[opt] reverse boolean
-- @see subscripts
function key:subscripts(reverse)
  return M.subscripts(self.__varname, #self.__subsarray > 0 and self.__subsarray or {''}, reverse)
end

--- @section end

-- ~~~ High level utility functions ~~~

--- High level functions
-- @section

--- Dump the specified node and its children
-- @param node Either a node object with `...` subscripts or glvn varname with `...` subsarray
-- @param[opt] subsarray Table of subscripts to add to node -- valid only if the second parameter is a table
-- @param[opt=30] maxlines Maximum number of lines to output before stopping dump
-- @return dump as a string
-- @usage ydb.dump(node, {subsarray, ...}[, maxlines])  OR  ydb.dump(node, sub1, sub2, ...)
function M.dump(node, ...)
  -- check whether maxlines was supplied as last parameter
  local subs, maxlines
  if select('#',...)>0 and type(...)=='table' then subs, maxlines = ...
  else  subs, maxlines = {...}, nil  end
  maxlines = maxlines or 30
  node = M.node(node, subs)  -- ensure it's a node object, not a varname

  local too_many_lines_error = "Too many lines"
  local output = {}
  local function print_func(node, sub, val)
    if not val then  return  end
    table.insert(output, string.format('%s=%s', node, q_number(val) or string.format('%q',val)))
    assert(#output < maxlines, too_many_lines_error)
  end
  local ok, err = pcall(node.gettree, node, nil, print_func)
  if not ok then
    if err==too_many_lines_error then
      table.insert(output, string.format("...etc.   -- stopped at %s lines; to show more use yottadb.dump(node, {subscripts}, maxlines)", maxlines))
    else  error(err)  end
  end
  if #output == 0 then  return tostring(node)  end
  return table.concat(output, '\n')
end


-- Useful for user to check whether an object's metatable matches node type
M._node = node
M._key = key
M._key_properties = key_properties

return M
