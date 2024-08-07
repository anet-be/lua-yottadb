-- Copyright 2021-2022 Mitchell and Berwyn Hoyt. See LICENSE.

--- Lua-bindings for YottaDB, sponsored by the [University of Antwerp Library](https://www.uantwerpen.be/en/library/).
-- See [README](https://github.com/anet-be/lua-yottadb#overview) for a quick introduction with examples. <br>
-- Home page: [https://github.com/anet-be/lua-yottadb/](https://github.com/anet-be/lua-yottadb/)
-- @module yottadb

local M = {}

local lua_version = tonumber( string.match(_VERSION, " ([0-9]+[.][0-9]+)") )

local _yottadb = require('_yottadb')
for k, v in pairs(_yottadb) do if k:find('^YDB_') then M[k] = v end end
M._VERSION = _yottadb._VERSION

local ydb_release = tonumber( string.match(_yottadb.get('$ZYRELEASE'), "[A-Za-z]+ r([0-9]+[.][0-9]+)") )


-- The following renames documentation section title "Functions" to "Low level functions". Blank line necessary:

--- Basic low level functions
-- @section

--- Block or unblock YDB signals while M code is running.
-- This function is designed to be passed as a callback to yottadb.init() as the `signal_blocker` parameter.
-- The function accepts one boolean parameter: `true` for entering Lua and `false` for exiting Lua:
--
-- * When `true` is passed to this function it blocks all the signals listed in `BLOCKED_SIGNALS` in `callins.c`
-- using OS call `sigprocmask()`. `SIGALRM` is treated specially: instead of being blocked OS call sigaction()
-- is used to set the `SA_RESTART` flag for `SIGALRM`. This makes the OS automatically restart IO calls that are
-- interrupted by `SIGALRM`. The benefit of this over blocking is that the YottaDB `SIGALRM` handler does
-- actually run, even during Lua code, allowing YottaDB to flush the database or IO as necessary (otherwise
-- M code would need to run the M command `VIEW "FLUSH"` after calling Lua code).
-- * When `false` is passed to this function it will reverse the effect, unblocking and clearing `SA_RESTART` for
-- the same signals manipulated when `true` is passed.
--
-- *Note:* This function does take time, as OS calls are slow. Using it will increase the M calling overhead
-- by a factor of 2-5 times the bare calling overhead (on the order of 1.4 microseconds on a typical
-- 2020s x86_64 CPU; see `make benchmarks`)
-- @function block_M_signals
-- @param bool true to block; false to unblock YottaDB signals
-- @return nothing
-- @see init
M.block_M_signals = _yottadb.block_M_signals

--- Initialize ydb and set blocking of M signals.
-- If `signal_blocker` is specified, block M signals which could otherwise interrupt slow IO operations like reading from stdin or a pipe.
-- Raise any errors.
-- See also the notes on signals in the [README](https://github.com/anet-be/lua-yottadb#signals--eintr-errors).
--
-- *Note:* any calls to the YDB API also initialize YDB; any subsequent call here will set `signal_blocker` but not re-init YDB.
-- @function init
-- @param[opt] signal_blocker Specifies a Lua callback CFunction (e.g. `yottadb.block_M_signals()`) which will be
-- called with its one parameter set to false on entry to M, and with true on exit from M, so as to unblock YDB signals while M is in use.
-- Setting `signal_blocker` to `nil` switches off signal blocking.
--
-- *Note:* Changing this to support a generic Lua function as callback would be possible but slow, as it would require
-- fetching the function pointer from a C closure, and using `lua_call()`.
-- @return nothing
-- @see block_M_signals
M.init = _yottadb.init

--- Lua function to call `ydb_eintr_handler()`.
-- Code intended to handle EINTR errors, instead of blocking signals, should call `ydb_eintr_handler()` when it gets an EINTR return code,
-- before re-issuing the interrupted system call.
-- @function ydb_eintr_handler
-- @return YDB_OK on success, and greater than zero on error (with message in ZSTATUS)
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
local _function_nil = {['function']=true, ['nil']=true}

--- Verify type of v.
-- Asserts that type(`v`) is equal to expected_types (string) or is in `expected_types` (table)
-- and returns `v`, or calls `error()` with an error message that implicates function argument
-- number `narg`.
-- Used with API function arguments so users receive more helpful error messages.
-- @invocation assert_type(value, _string_nil, 1)
-- @invocation assert_type(option.setting, 'number', 'setting') -- implicates key
-- @param v Value to assert the type of.
-- @param expected_types String of valid type or Table whose keys are valid type names to check against.
-- @param narg Integer positional argument number `v` is associated with. This is not required to be a number.
-- @param[opt] funcname String override the name of the calling function (useful for object methods which cannot be auto-detected)
local function assert_type(v, expected_types, narg, funcname)
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
    debug.getinfo(2, 'n').name or funcname or '?', table.concat(expected_list, '/'), type(v)), 3)
end

--- Asserts that all items in table *t* are strings.
-- On failuare, calls `error()` with an error message
-- that implicates function argument number *narg* named *name*.
-- Like `assert_type()`, this is intended for improved readability of API input errors.
-- @invocation assert_strings(subsarray, 'subsarray', 2)
-- @param t Table to check. If it is not a table, the assertion passes.
-- @param name String argument name to use in error messages.
-- @param narg The position argument number *t* is associated with.
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

local function rawtostring(value)
  local setmeta = type(value)=='userdata' and _yottadb.cachearray_setmetatable or setmetatable
  local metatable = getmetatable(value)
  setmeta(value, nil)
  local result = tostring(value)
  setmeta(value, metatable)
  return result
end

-- ~~~ Support for Lua versions prior to 5.4 ~~~

--- Create isinteger(n) that also works in Lua < 5.3 but is fast in Lua >=5.3.
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

--- Convert str to number if the lua representation is identical.
-- Otherwise return `nil`
-- @param str string for potential conversion to a number
-- @return number or `nil`
local function q_number(str)
  local num = tonumber(str)
  return num and tostring(num)==str and num or nil
end

--- Get the YDB error code (if any) contained in the given error message.
-- @param message String error message.
-- @return the YDB error code (if any) for the given error message,
-- @return or `nil` if the message is not a YDB error.
-- @example
-- ydb = require('yottadb')
-- ydb.get_error_code('YDB Error: -150374122: %YDB-E-ZGBLDIRACC, Cannot access global directory !AD!AD!AD.')
-- -- -150374122
function M.get_error_code(message)
  return tonumber(assert_type(message, 'string', 1):match('YDB Error: (%-?%d+):'))
end

-- Class metatable for an object that represents a YDB node.
local node = {}

-- Deprecated object that represents a YDB node.
-- old name of YDB node object -- retains the deprecated syntax for backward compatibility
--- @deprecated v1.0
local key = {}

--- Return whether a node has a value or subtree.
-- @function data
-- @invocation yottadb.data('varname'[, {subsarray}][, ...])
-- @invocation yottadb.data(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @return 0: (node has neither value nor subtree)
-- @return 1: node has value, not subtree
-- @return 10: node has no value, but does have a subtree
-- @return 11: node has both value and subtree
-- @example
-- -- include setup from example at yottadb.set()
-- ydb.data('^Population')
-- -- 10.0
-- ydb.data('^Population', {'USA'})
-- -- 11.0
M.data = _yottadb.data

--- Deprecated and replaced by `set(varname[, subsarray[, ...]], nil)`.
-- @function delete_node
-- @invocation yottadb.delete_node('varname'[, {subsarray}][, ...])
-- @invocation yottadb.delete_node(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
--- @deprecated v3.0
-- @example
-- ydb = require('yottadb')
-- ydb.set('^Population', {'Belgium'}, 1367000)
-- ydb.delete_node('^Population', {'Belgium'})  -- or ydb.set('^Population', {'Belgium'}, nil)
-- ydb.get('^Population', {'Belgium'})
-- -- nil
M.delete_node = _yottadb.delete

--- Deletes a database variable tree (node and subnodes) or a node subtree.
-- @function kill
-- @invocation yottadb.kill('varname'[, {subsarray}][, ...])
-- @invocation yottadb.kill(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @example
-- -- include setup from example at yottadb.set()
-- ydb.get('^Population', {'USA'})
-- -- 325737000
-- ydb.get('^Population', {'USA', '17900802'})
-- -- 3929326
-- ydb.get('^Population', {'USA', '18000804'})
-- -- 5308483
-- ydb.kill('^Population', {'USA'})
-- ydb.data('^Population', {'USA'})
-- -- 0.0
function M.kill(varname, ...)
  return _yottadb.delete(varname, ..., true)
end

--- Deprecated and replaced by kill.
-- @function delete_tree
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @see kill
--- @deprecated v3.0
M.delete_tree = M.kill

--- Gets and returns the value of a database variable or node; or `nil` if the variable or node does not exist.
-- @function get
-- @invocation yottadb.get('varname'[, {subsarray}][, ...])
-- @invocation yottadb.get(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @return string value or `nil`
-- @example
-- -- include setup from example at yottadb.set()
-- ydb.get('^Population')
-- -- nil
-- ydb.get('^Population', {'Belgium'})
-- -- 1367000
-- ydb.get('$zgbldir')
-- -- /home/ydbuser/.yottadb/r1.34_x86_64/g/yottadb.gld
M.get = _yottadb.get

--- Increments the numeric value of a database variable or node.
-- Raises an error on overflow.
--
-- *Caution:* increment is *not* optional if `...` list of subscript is provided.
-- Otherwise incr() cannot tell whether last parameter is a subscript or an increment.
-- @function incr
-- @invocation yottadb.incr(varname[, {subs}][, increment=1])
-- @invocation yottadb.incr(varname[, {subs}], ..., increment=1)
-- @invocation yottadb.incr(cachearray[, increment=1])
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @param increment Number or string amount to increment by (default=1)
-- @return the new value
-- @example
-- ydb = require('yottadb')
-- ydb.get('num')
-- -- 4
-- ydb.incr('num', 3)
-- -- 7
-- ydb.incr('num')
-- -- 8
M.incr = _yottadb.incr

--- Releases all locks held and attempts to acquire all requested locks.
-- Returns after `timeout`, if specified.
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- Raises an error `yottadb.YDB_LOCK_TIMEOUT` if a lock could not be acquired.
-- @param[opt] nodes Table array of {varname[, subs]} elements or node objects that specify the lock names to lock.
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
-- @return 0 (always)
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
      assert_type(v, 'table', 1)
      local node = v
      if type(node) ~= 'userdata' then  node = cachearray_create(table.unpack(v))  end
      nodes_copy[i] = node
    end
  end
  _yottadb.lock(nodes_copy, timeout)
end

--- Attempts to acquire or increment a lock named varname[(subsarray)].
-- Returns after `timeout`, if specified.
-- Raises a `yottadb.YDB_LOCK_TIMEOUT` error if lock could not be acquired.
--
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- *Caution:* timeout is *not* optional if `...` list of subscripts is provided, but it may be `nil`.
-- Otherwise lock_incr cannot tell whether it is a subscript or a timeout.
-- @function lock_incr
-- @invocation yottadb.lock_incr(varname[, {subs}][, ...][, timeout=0])
-- @invocation yottadb.lock_incr(varname[, {subs}], ..., timeout=0)
-- @invocation yottadb.lock_incr(cachearray[, timeout=0])
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
--  Optional only if subscripts is a table.
-- @return 0 (always)
-- @see grab
-- @see lock_decr
M.lock_incr = _yottadb.lock_incr

--- Alias for lock_incr to acquire or increment a lock named varname[(subsarray)].
-- Returns after `timeout`, if specified.
-- Raises a `yottadb.YDB_LOCK_TIMEOUT` error if lock could not be acquired.
--
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- *Caution:* timeout is *not* optional if `...` list of subscripts is provided, but it may be `nil`.
-- Otherwise lock_incr cannot tell whether it is a subscript or a timeout.
-- @function grab
-- @invocation yottadb.grab(varname[, {subs}][, ...][, timeout=0])
-- @invocation yottadb.grab(varname[, {subs}], ..., timeout=0)
-- @invocation yottadb.grab(cachearray[, timeout=0])
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
--  Optional only if subscripts is a table.
-- @return 0 (always)
-- @see lock_incr
-- @see release
M.grab = M.lock_incr

--- Decrements a lock of the same name as varname[(subsarray)], releasing it if zero.
-- Releasing a lock cannot create an error unless the varname/subsarray names are invalid.
-- @function lock_decr
-- @invocation yottadb.lock_decr('varname'[, {subsarray}][, ...])
-- @invocation yottadb.lock_decr(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @return 0 (always)
-- @see release
-- @see lock_incr
M.lock_decr = _yottadb.lock_decr

--- Alias for lock_decr to decrement a lock of the same name as varname[(subsarray)], releasing it if zero.
-- Releasing a lock cannot create an error unless the varname/subsarray names are invalid.
-- @function release
-- @invocation yottadb.release('varname'[, {subsarray}][, ...])
-- @invocation yottadb.release(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @return 0 (always)
-- @see lock_decr
-- @see grab
M.release = M.lock_decr

--- Returns the full subscript list of the next node after a database variable or node.
-- A next node chain started from varname will eventually reach all nodes under that varname in order.
--
-- *Note:* `node:gettree()` or `node:subscripts()` may be a better way to iterate a node tree
-- @function node_next
-- @invocation yottadb.node_next('varname'[, {subsarray}][, ...])
-- @invocation yottadb.node_next(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @return list of subscripts for the node, or `nil` if there isn't a next node
-- @example
-- -- include setup from example at yottadb.set()
-- print(table.concat(ydb.node_next('^Population'), ', '))
-- -- Belgium
-- print(table.concat(ydb.node_next('^Population', {'Belgium'}), ', '))
-- -- Thailand
-- print(table.concat(ydb.node_next('^Population', {'Thailand'}), ', '))
-- -- USA
-- print(table.concat(ydb.node_next('^Population', {'USA'}), ', '))
-- -- USA, 17900802
-- print(table.concat(ydb.node_next('^Population', {'USA', '17900802'}), ', '))
-- -- USA, 18000804
-- @example
-- -- Note: The format used above to print the next node will give an error if there is no next node, i.e., the value returned is nil.
-- -- This case will have to be handled gracefully. The following code snippet is one way to handle nil as the return value:
--
-- local ydb = require('yottadb')
-- next = ydb.node_next('^Population', {'USA', '18000804'})
-- if next ~= nil then
--   print(table.concat(next, ', '))
-- else
--   print(next)
-- end
M.node_next = _yottadb.node_next

--- Returns the full subscript list of the previous node after a database variable or node.
-- A previous node chain started from varname will eventually reach all nodes under that varname in reverse order.
--
-- *Note:* `node:gettree()` or `node:subscripts()` may be a better way to iterate a node tree
-- @function node_previous
-- @invocation yottadb.node_previous('varname'[, {subsarray}][, ...])
-- @invocation yottadb.node_previous(cachearray)
-- @param varname String of the database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts to append after any elements in optional subsarray table
-- @return list of subscripts for the node, or `nil` if there isn't a previous node
-- @example
-- -- include setup from example at yottadb.set()
-- print(table.concat(ydb.node_previous('^Population', {'USA', '18000804'}), ', '))
-- -- USA, 17900802
-- print(table.concat(ydb.node_previous('^Population', {'USA', '17900802'}), ', '))
-- -- USA
-- print(table.concat(ydb.node_previous('^Population', {'USA'}), ', '))
-- -- Thailand
-- print(table.concat(ydb.node_previous('^Population', {'Thailand'}), ', '))
-- -- Belgium
--
-- @example -- Note: See the note on handling nil return values in node_next() which applies to node_previous() as well.
M.node_previous = _yottadb.node_previous

--- Sets the value of a database variable or node.
-- @function set
-- @invocation yottadb.set(varname[, {subs}][, ...], value)
-- @invocation yottadb.set(cachearray, value)
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @param value The value to assign to the node. If this is a number, it is converted to a string. If it is `nil`, the node's value, if any, is deleted.
-- @return `value`
-- @example
-- ydb = require('yottadb')
-- ydb.set('^Population', {'Belgium'}, 1367000)
-- ydb.set('^Population', {'Thailand'}, 8414000)
-- ydb.set('^Population', {'USA'}, 325737000)
-- ydb.set('^Population', {'USA', '17900802'}, 3929326)
-- ydb.set('^Population', {'USA', '18000804'}, 5308483)
M.set = _yottadb.set

--- Returns the next subscript for a database variable or node; or `nil` if there isn't one.
-- @function subscript_next
-- @invocation yottadb.subscript_next(varname[, {subsarray}][, ...])
-- @invocation yottadb.subscript_next(cachearray)
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @return string subscript name, or `nil` if there are no more subscripts
-- @example
-- -- include setup from example at yottadb.set()
-- ydb.subscript_next('^Population', {''})
-- -- Belgium
-- ydb.subscript_next('^Population', {'Belgium'})
-- -- Thailand
-- ydb.subscript_next('^Population', {'Thailand'})
-- -- USA
M.subscript_next = _yottadb.subscript_next

--- Returns the previous subscript for a database variable or node; or `nil` if there isn't one.
-- @function subscript_previous
-- @invocation yottadb.subscript_previous(varname[, {subsarray}][, ...])
-- @invocation yottadb.subscript_previous(cachearray)
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @return string subscript name, or `nil` if there are no previous subscripts
-- @example
-- -- include setup from example at yottadb.set()
-- ydb.subscript_previous('^Population', {'USA', ''})
-- -- 18000804
-- ydb.subscript_previous('^Population', {'USA', '18000804'})
-- -- 17900802
-- ydb.subscript_previous('^Population', {'USA', '17900802'})
-- -- nil
-- ydb.subscript_previous('^Population', {'USA'})
-- -- Thailand
M.subscript_previous = _yottadb.subscript_previous

--- Returns an iterator for iterating over database *sibling* subscripts starting from the node referenced by `varname` and `subarray`.
--
-- *Note:* this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
-- It operates differently than `node:subscipts()` which yields all subscripts that are *children* of the given node,
-- and which you may consider to be preferable.
-- @invocation for name in yottadb.subscripts(varname[, {subsarray}][, ...][, reverse]) do ... end
-- @invocation for name in yottadb.subscripts(cachearray[, ...][, reverse]) do ... end
-- @param varname of database node (this can also be replaced by cachearray)
-- @param[opt] subsarray Table of subscripts
-- @param[opt] ... List of subscripts or table subscripts
-- @param[opt] reverse Flag that indicates whether to iterate backwards.  Not optional when '...' is provided
-- @return iterator
function M.subscripts(varname, ...)
  local subsarray, reverse
  -- First do parameter checking
  if ... then
    if type(...)=='table' then
      subsarray, reverse = ...
    else
      -- Check & error if last parameter is nil (before turning into a table, which loses the last element)
      assert_type(select(-1, ...), _number_boolean, '<last>')
      subsarray = {...}
      reverse = table.remove(subsarray) -- pop
    end
  else
      subsarray = {}
  end

  -- Convert to mutable cachearray
  local cachearray = _yottadb.cachearray_create(varname, table.unpack(subsarray))  -- works even if varname is already a cachearray
  _yottadb.cachearray_setmetatable(cachearray, node)  -- make it a node type. Not strictly necessary since code below doesn't call node methods, but in case it does in future ...
  cachearray = _yottadb.cachearray_tomutable(cachearray)
  local actuator = reverse and _yottadb.subscript_previous or _yottadb.subscript_next
  local function iterator()
    local next_or_prev = actuator(cachearray)
    cachearray = _yottadb.cachearray_subst(cachearray, next_or_prev or '')
    return next_or_prev
  end
  return iterator, nil, ''  -- iterate using child from ''
end

--- Returns the zwrite-formatted version of the given string.
-- @function str2zwr
-- @param s String to format.
-- @return formatted string
-- @example
-- ydb=require('yottadb')
-- str='The quick brown dog\b\b\bfox jumps over the lazy fox\b\b\bdog.'
-- print(str)
-- -- The quick brown fox jumps over the lazy dog.
-- ydb.str2zwr(str)
-- -- "The quick brown dog"_$C(8,8,8)_"fox jumps over the lazy fox"_$C(8,8,8)_"dog."
M.str2zwr = _yottadb.str2zwr

--- Returns the string described by the given zwrite-formatted string.
-- @function zwr2str
-- @param s String in zwrite format.
-- @return string
-- @example
-- ydb=require('yottadb')
-- str1='The quick brown dog\b\b\bfox jumps over the lazy fox\b\b\bdog.'
-- zwr_str=ydb.str2zwr(str1)
-- print(zwr_str)
-- -- "The quick brown dog"_$C(8,8,8)_"fox jumps over the lazy fox"_$C(8,8,8)_"dog."
-- str2=ydb.zwr2str(zwr_str)
-- print(str2)
-- -- The quick brown fox jumps over the lazy dog.
-- str1==str2
-- -- true
M.zwr2str = _yottadb.zwr2str

-- The following 6 lines defines the 'High level functions' section to appear
-- before 'Transactions' in the docs. The blank lines in between are necessary:

--- @section end

--- Transactions
-- @section

--- Initiates a transaction (low level function).
-- Restarts are subject to `$ZMAXTPTIME` after which they cause error `%YDB-E-TPTIMEOUT`
-- @param[opt] id optional string transaction id. For special ids `BA` or `BATCH`, see [Transaction Processing](https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing).
-- @param[opt] varnames optional table of local M variable names to restore on transaction restart
-- (or `{'*'}` for all locals)
-- Restoration applies to rollback.
-- @param f Function to call. The transaction's affected globals are:
--
-- * Committed if the function returns nothing or `yottadb.YDB_OK`.
-- * Restarted if the function returns `yottadb.YDB_TP_RESTART` (`f` will be called again).
-- * Not committed if the function returns `yottadb.YDB_TP_ROLLBACK` or errors out.
-- @param[opt] ... arguments to pass to `f`
-- @see transaction
-- @example
-- local ydb = require('yottadb')
--
-- function transfer_to_savings(t)
--    local ok, e = pcall(ydb.incr, '^checking', -t)
--    if (ydb.get_error_code(e) == ydb.YDB_TP_RESTART) then
--       return ydb.YDB_TP_RESTART
--    end
--    if (not ok or tonumber(e)<0) then
--       return ydb.YDB_TP_ROLLBACK
--    end
--    local ok, e = pcall(ydb.incr, '^savings', t)
--    if (ydb.get_error_code(e) == ydb.YDB_TP_RESTART) then
--       return ydb.YDB_TP_RESTART
--    end
--    if (not ok) then
--       return ydb.YDB_TP_ROLLBACK
--    end
--    return ydb.YDB_OK
-- end
--
-- ydb.set('^checking', 200)
-- ydb.set('^savings', 85000)
--
-- print("Amount currently in checking account: $" .. ydb.get('^checking'))
-- print("Amount currently in savings account: $" .. ydb.get('^savings'))
--
-- print("Transferring $10 from checking to savings")
-- local ok, e = pcall(ydb.tp, '', {'*'}, transfer_to_savings, 10)
-- if (not e) then
--    print("Transfer successful")
-- elseif (ydb.get_error_code(e) == ydb.YDB_TP_ROLLBACK) then
--    print("Transfer not possible. Insufficient funds")
-- end
--
-- print("Amount in checking account: $" .. ydb.get('^checking'))
-- print("Amount in savings account: $" .. ydb.get('^savings'))
--
-- print("Transferring $1000 from checking to savings")
-- local ok, e = pcall(ydb.tp, '', {'*'}, transfer_to_savings, 1000)
-- if (not e) then
--    print("Transfer successful")
-- elseif (ydb.get_error_code(e) == ydb.YDB_TP_ROLLBACK) then
--    print("Transfer not possible. Insufficient funds")
-- end
--
-- print("Amount in checking account: $" .. ydb.get('^checking'))
-- print("Amount in savings account: $" .. ydb.get('^savings'))
-- @example
-- Output:
--   Amount currently in checking account: $200
--   Amount currently in savings account: $85000
--   Transferring $10 from checking to savings
--   Transfer successful
--   Amount in checking account: $190
--   Amount in savings account: $85010
--   Transferring $1000 from checking to savings
--   Transfer not possible. Insufficient funds
--   Amount in checking account: $190
--   Amount in savings account: $85010
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

--- Returns a high-level transaction-safe version of the given function.
-- It will be called within a YottaDB transaction and the database globals restored on error or `yottadb.trollback()`
-- @param[opt] id optional string transaction id. For special ids `BA` or `BATCH`, see [Transaction Processing](https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing).
-- @param[opt] varnames optional table of local M variable names to restore on transaction `trestart()`
-- (or `{'*'}` for all locals). Restoration applies to rollback.
-- @param f Function to call. The transaction's affected globals are:
--
-- * Committed if the function returns nothing or `yottadb.YDB_OK`.
-- * Restarted if the function returns `yottadb.YDB_TP_RESTART` (`f` will be called again).
-- Restarts are subject to `$ZMAXTPTIME` after which they cause error `%YDB-E-TPTIMEOUT`
-- * Not committed if the function returns `yottadb.YDB_TP_ROLLBACK` or errors out.
-- @return transaction-safe function.
-- @see tp
-- @example
-- Znode = ydb.node('^Ztest')
-- transact = ydb.transaction(function(end_func)
--   print("^Ztest starts as", Znode:get())
--   Znode:set('value')
--   end_func()
--   end)
--
-- transact(ydb.trollback)  -- perform a rollback after setting Znode
-- -- ^Ztest starts as	nil
-- -- YDB Error: 2147483645: YDB_TP_ROLLBACK
-- -- stack traceback:
-- --   [C]: in function '_yottadb.tp' ...
-- Znode:get()  -- see that the data didn't get set
-- -- nil
--
-- tries = 2
-- function trier()  tries=tries-1  if tries>0 then ydb.trestart() end  end
-- transact(trier)  -- restart with initial dbase state and try again
-- -- ^Ztest starts as	nil
-- -- ^Ztest starts as	nil
-- Znode:get()  -- check that the data got set after restart
-- -- value
--
-- Znode:set(nil)
-- transact(function() end)  -- end the transaction normally without restart
-- -- ^Ztest starts as	nil
-- Znode:get()  -- check that the data got set
-- -- value
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

--- Make the currently running transaction function rollback immediately with a YDB_TP_ROLLBACK error.
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
-- Raise any errors.
-- @param line is the text in the current line of the call-in file
-- @param ci_handle handle of call-in table
-- @return C name for the M routine
-- @return a function to invoke the M routine
-- @return or return `nil` if the line did not contain a function prototype
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

--- Import M routines as Lua functions specified in a ydb 'call-in' file. <br>
-- See example call-in file [arithmetic.ci](https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.ci)
-- and matching M file [arithmetic.m](https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.m).
-- @param Mprototypes A list of lines in the format of ydb 'call-in' files required by `ydb_ci()`.
-- If the string contains `:` it is considered to be the call-in specification itself;
-- otherwise it is treated as the filename of a call-in file to be opened and read.
-- @param debug When neither false nor nil, tell Lua not to delete the temporary preprocessed call-in table file it created.
-- The name of this file will be stored in the `__ci_filename` field of the returned table.
-- @return A table of functions analogous to a Lua module.
-- Each function in the table will call an M routine specified in `Mprototypes`.
-- @example
-- $ export ydb_routines=examples   # put arithmetic.m into ydb path
-- $ lua -lyottadb
-- arithmetic = yottadb.require('examples/arithmetic.ci')
-- arithmetic.add_verbose("Sum is:", 2, 3)
-- -- Sum is: 5
-- -- Sum is: 5
-- arithmetic.sub(5,7)
-- -- -2
function M.require(Mprototypes,debug)
  local routines = {}
  if not Mprototypes:find(':', 1, true) then
    -- read call-in file
    routines.__ci_filename_original = Mprototypes
    local f = assert(io.open(Mprototypes))
    Mprototypes = f:read('a')
    f:close()
  end

  -- now preprocess the call-in table to make it more suited to lua-yottadb
  -- first, declare a function that will be passed every string of types, for potential substitution
  local function type_replacer(before,types,after)
    local isretval = not types:find(':')  -- if we're replacing the retval, there is no ':' in types
    -- convert floats to doubles since Lua doesn't use floats. Avoids unexpected junk in the insignificant figures
    types = types:gsub('float', 'double')
    -- any non-pointer types that can't be used with ydb_call_variadic_plist_func(), convert to pointer types
    for _,typ in pairs{'ydb_double_t','ydb_int_t','double','int'} do
      types = types:gsub('(' .. typ .. '%s*)[*]*([,) ])', '%1*%2')
    end
    -- convert any non-pointer retvals (which are illegal) to pointer types
    if isretval and not types:find('void') then  types=types:gsub('([A-Za-z0-9_]+)[%s*]+', '%1* ')  end
    if ydb_release < 1.36 then
      -- make ydb <1.36 emulate 'buffer' type, even though it's not as good as string for output-only (O:) parameters
      types = types:gsub('ydb_buffer_t%s*%*', 'ydb_string_t*')
    end
    if ydb_release >= 1.36 then
      -- convert between buffer/string types for best efficiency (lets user use either one without thinking about it)
      types = types:gsub('IO%s*:%s*ydb_string_t%s*%*', 'IO:ydb_buffer_t*')  -- IO: params
      types = types:gsub('IO%s*:%s*string%s*%*', 'IO:ydb_buffer_t*')
      types = types:gsub('([^IO][IO])%s*:%s*ydb_buffer_t%s*%*', '%1:ydb_string_t*') -- I: or O: params
      -- always replace 'buffer' with 'string' in the retval as it is equivalent of an O: param
      if isretval then  types=types:gsub('ydb_buffer_t%s*%*', 'ydb_string_t*')  end
    end
    return before..types..after
  end
  -- replace things in parameters, i.e. between parentheses, and then replace things in retvals, i.e. immediately after first ':'
  -- note: `(\1?)` is my substitute for an empty capture since `()` is a special Lua code that returns the position in the string
  Mprototypes = Mprototypes:gsub('(\1?)(%([^\n]*%))(\1?)', type_replacer )
  Mprototypes = Mprototypes:gsub('^(%s*[A-Za-z0-9_]+%s*:%s*)([^%s*]+[%s*]+)(\1?)', type_replacer) -- first line's retval
  Mprototypes = Mprototypes:gsub('(\n%s*[A-Za-z0-9_]+%s*:%s*)([^%s*]+[%s*]+)(\1?)', type_replacer) -- other lines' retval
  -- remove preallocation specs for ydb which can only process them in call-out tables not call-in tables
  local ydb_prototypes = Mprototypes  -- take a copy for our own parser which requires preallocation specs
  Mprototypes = Mprototypes:gsub('%b[]', '')

  -- write call-in file and load into ydb
  local filename = os.tmpname()
  local f = assert(io.open(filename, 'w'), string.format("cannot open temporary call-in file %q", filename))
  assert(f:write(Mprototypes), string.format("cannot write to temporary call-in file %q", filename))
  f:close()
  local ci_handle = _yottadb.ci_tab_open(filename)
  if debug then  routines.__ci_filename = filename  end
  routines.__ci_table_handle = ci_handle

  -- process ci-table ourselves to get routine names and types to cast
  -- do this after ydb has handled it to let ydb catch any errors in the table
  local line_no = 0
  for line in ydb_prototypes:gmatch('([^\n]*)\n?') do
    line_no = line_no+1
    local ok, routine, func = pcall(parse_prototype, line, ci_handle)
    if routine then  routines[routine] = func end
  end
  if not debug then  os.remove(filename)  end  -- cleanup
  return routines
end

--- @section end


--- Node class operations
-- @section

--- Creates an object that represents a YottaDB node.
-- This node has all of the class methods defined below.
-- Calling the returned node with one or more string parameters returns a new node further subscripted by those strings.
-- Calling this on an existing node `yottadb.node(node)` creates an (immutable) copy of node.
--
-- *Notes:*
--
-- * Several standard Lua operators work on nodes. These are: `+` `-` `=` `pairs()` `tostring()`
-- * Although the syntax `node:method()` is pretty, be aware that it is slow. If you need speed, prefix the node method
-- with two underscores, `node:__method()`, which is equivalent, but 15x faster. 
-- The former is slow because in Lua, `node:method(...)` is syntactic sugar which expands to `node.method(node, ...)`,
-- causing lua-yottadb to create an intermediate node object `node.method`. It is only when this new object gets called
-- with `(node, ...)`, and the first parameter is of type `node`, that the `__call` metamethod detects it was supposed to
-- be a method access and invokes `node.__method()`, discarding the intermediate subnode object it created.
-- * Because the `__` prefix accesses *method* names (as above), it cannot access database subnode names starting with `__`.
-- Instead, use mynode('__nodename') to access a database node named `__nodename`.
-- * This `__` prefix handling also means that object method names that start with two underscores, like `__tostring`,
-- are only accessible with an *additional* `__` prefix; for example, `node:____tostring()`.
-- @param varname String variable name.
-- @param[opt] subsarray table of subscripts
-- @param[opt] ... list of subscripts to append after any elements in optional subsarray table
-- @param node `|key:` is an existing node or key to copy into a new object (you can turn a `key` type into a `node` type this way)
-- @usage yottadb.node('varname'[, {subsarray}][, ...])
-- yottadb.node(node|key[, {}][, ...])
-- yottadb.node('varname')('sub1', 'sub2')
-- yottadb.node('varname', 'sub1', 'sub2')
-- yottadb.node('varname', {'sub1', 'sub2'})
-- yottadb.node('varname').sub1.sub2
-- yottadb.node('varname')['sub1']['sub2']
-- @return node object with metatable `yottadb.node`
function M.node(varname, ...)
  local self
  if type(varname) == 'string' then
    self = _yottadb.cachearray_create(varname, ...)
    _yottadb.cachearray_setmetatable(self, node)  -- change to node type
  else
    assert(type(varname)=='userdata', "Parameter 1 must be varname (string) or a key/node object to create new node object from")
    self = _yottadb.cachearray_create(varname)  -- also makes it non-mutable
    _yottadb.cachearray_setmetatable(self, node)  -- change to node type
    local subs = select('#', ...)
    if subs>0 and type(...)=='table' then
      self = _yottadb.cachearray_append(self, table.unpack(...))
      if subs > 1 then
        subsarray = {...}
        table.remove(subsarray, 1)
        self = _yottadb.cachearray_append(self, table.unpack(subsarray))
      end
    else
      self = _yottadb.cachearray_append(self, ...)
    end
  end
  return self
end

--- Tests whether object is a node object or inherits from a node object.
-- @param object to test
-- @return boolean true or false
function M.isnode(object)
  if type(object) ~= 'userdata' then  return false  end
  local class = getmetatable(object)
  while class do
    if class == node then  return true  end
    class = rawget(class, '__superclass')
  end
  return false
end

--- @section end

--- Node class
-- @section

--- Get `node`'s value.
-- Equivalent to `node.__`, but 2.5x slower.
-- If node is subclassed, then `node.__` invokes the subclass's `node:__get()` if it exists.
-- @param[opt] default specify the value to return if the node has no data; if not supplied, `nil` is the default
-- @return value of the node
-- @see get
function node:get(default)  return _yottadb.get(self) or default  end

--- Set `node`'s value.
-- Equivalent to `node.__ = x`, but 4x slower.
-- If node is subclassed, then `node.__ = x` invokes the subclass's `node:__set(x)` if it exists.
-- @param value New value or `nil` to delete node
-- @return value
-- @see set
function node:set(value)  return _yottadb.set(self, value)  end

--- Delete database tree (node and subnodes) pointed to by node object.
-- @see node:kill
function node:kill()  return M.kill(self)  end

--- Deprecated and replaced by kill.
-- @function node:delete_tree
-- @see kill
--- @deprecated v3.0
node.delete_tree = node.kill

--- Increment `node`'s value.
-- @param[opt=1] increment Amount to increment by (negative to decrement)
-- @return the new value
-- @see incr
function node:incr(...)  assert_type(..., _string_number_nil, 1, ":incr")  return M.incr(self, ...)  end

--- Releases all locks held and attempts to acquire a lock matching only this node.
-- Returns after `timeout`, if specified.
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
-- @see lock
function node:lock(...)  assert_type(..., _number_nil, 1, ":lock")  return M.lock({self}, ...)  end

--- Attempts to acquire or increment a lock matching this node.
-- Returns after `timeout`, if specified.
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
-- @see lock_incr
-- @see node:grab
-- @see node:lock_decr
function node:lock_incr(...)  assert_type(..., _string_number_nil, 1, ":lock_incr")  return M.lock_incr(self, ...)  end

--- Alias for node:lock_incr to acquire or increment a lock matching this node.
-- Returns after `timeout`, if specified.
-- If timeout is not supplied or is `nil`, wait forever; timeout of zero means try only once.
-- @function node:grab
-- @param[opt] timeout Number timeout in seconds to wait for the lock.
-- @see grab
-- @see node:lock_incr
-- @see node:release
node.grab = node.lock_incr

--- Decrements a lock matching this node, releasing it if zero.
-- @see lock_decr
-- @see node:release
-- @see node:lock_incr
function node:lock_decr()  return M.lock_decr(self)  end

--- Alias for node:lock_decr to decrement a lock matching this node, releasing it if zero.
-- @function node:release
-- @see release
-- @see node:lock_decr
-- @see node:grab
node.release = node.lock_decr

--- Return iterator over the *child* subscript names of a node (in M terms, collate from "" to "").
-- Unlike `yottadb.subscripts()`, `node:subscripts()` returns all *child* subscripts, not subsequent *sibling* subscripts in the same level. <br>
-- Very slightly faster than node:__pairs() because it iterates subscript names without fetching the node value. <br>
-- Note that `subscripts()` order is guaranteed to equal the M collation sequence.
-- @param[opt] reverse set to true to iterate in reverse order
-- @example
-- ydb = require 'yottadb'
-- node = ydb.node('^myvar', 'subs1')
-- for subscript in node:subscripts() do  print subscript  end
-- @return iterator over *child* subscript names of a node, which returns a sequence of subscript name strings
-- @see node:__pairs
function node:subscripts(reverse)
  local actuator = reverse and _yottadb.subscript_previous or _yottadb.subscript_next
  local subnode = _yottadb.cachearray_append(self, '')
  subnode = _yottadb.cachearray_tomutable(subnode)
  local function iterator()
    local subscript = actuator(subnode)
    subnode = _yottadb.cachearray_subst(subnode, subscript or '')
    return subscript
  end
  return iterator, nil, ''  -- iterate using child from ''
end

-- Constant that may be passed to `node:settree()`
-- declare a unique flag value yottadb.DELETE to pass to settree to instruct deletion of a value
-- @see node:settree
M.DELETE = {}

--- Populate database from a table.
-- In its simplest form:
--    n = ydb.node('var')
--    n:settree({__='berwyn', weight=78, ['!@#$']='junk', appearance={__='handsome', eyes='blue', hair='blond'}, age=ydb.DELETE})
-- @param tbl The table to store into the database:
--
-- * Special field name `tbl.__` sets the value of the node itself, as opposed to a subnode.
-- * Set any table value to `yottadb.DELETE` to have `settree()` delete the value of the associated database node. You cannot delete the whole subtree.
-- @param[opt] filter Function of the form `function(node, key, value)` or `nil`
--
-- * If filter is `nil`, all values are set unfiltered.
-- * If filter is a function(node, key, value) it is invoked on every node
-- to allow it to cast/alter every key name and value.
-- * Filter must return the same or altered: key, value.
-- * Type errors can be handled (or ignored) using this function, too.
-- * If filter returns `yottadb.DELETE` as value, the key is deleted.
-- * If filter returns `nil` as key or value, `settree()` will simply not update the current database value.
-- @param[opt] _seen For internal use only (to prevent accidental duplicate sets: bad because order setting is not guaranteed).
-- @example
-- n = ydb.node('^oaks')
-- n:settree({__='treedata', {shadow=10,angle=30}, {shadow=13,angle=30}})
-- n:dump()
-- @example
-- -- outputs:
-- ^oaks="treedata"
-- ^oaks("1","angle")="30"
-- ^oaks("1","shadow")="10"
-- ^oaks("2","angle")="30"
-- ^oaks("2","shadow")="13"
function node:settree(tbl, filter, _seen)
  if not _seen then
    -- Check parameters first time through
    assert_type(tbl, 'table', 1, ":settree")
    assert_type(filter, _function_nil, 2, ":settree")
    _seen = {}
  end
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
--
-- *Notes:*
--
-- * special field name `__` in the returned table indicates the value of the node itself.
-- * Lua tables do not preserve the order YDB subtrees.
-- @param[opt] maxdepth Subscript depth to fetch. A value of nil fetches subscripts of arbitrary depth, i.e. all levels in the tree. A value of 1 fetches the first layer of subscript values only.
-- @param[opt] filter Either `nil` or a function matching the prototype `function(node, node_top_subscript_name, value, recurse, depth)`
--
-- * If filter is `nil`, all values are fetched unfiltered.
-- * If filter is a function it is invoked on every subscript
-- to allow it to cast/alter every value and recurse flag;
-- note that at node root (depth=0), subscript passed to filter is the empty string "".
-- * Filter may optionally return two items: `value` and `recurse`, which must either be the input parameters `value` and `recurse` or may be altered:
--    * If filter returns `value` then `gettree()` will store it in the table for that database subscript/value; or store nothing if `value=nil`.
--    * If filter returns `recurse=false`, it will prevent recursion deeper into that particular subscript. If it returns `nil`, it will use the original value of `recurse`.
-- @param[opt] _value For internal use only (to avoid duplicate value fetches, for speed).
-- @param[opt] _depth For internal use only (to record depth of recursion) and must start unspecified (nil).
-- @return Lua table containing data
-- @example
-- n = ydb.node('^oaks')
-- n:settree({__='treedata', {shadow=10,angle=30}, {shadow=13,angle=30}})
-- n:gettree(nil, print)
-- -- ^oaks		treedata	true	0
-- -- ^oaks(1)	1	nil	true	1
-- -- ^oaks(1,"angle")	angle	30	false	2
-- -- ^oaks(1,"shadow")	shadow	10	false	2
-- -- ^oaks(2)	2	nil	true	1
-- -- ^oaks(2,"angle")	angle	30	false	2
-- -- ^oaks(2,"shadow")	shadow	13	false	2
--
-- -- now fetch the tree into a Lua table
-- tbl = n:gettree()
-- @see settree
function node:gettree(maxdepth, filter, _value, _depth)
  if not _depth then  -- i.e. if this is the first time the function is called
    assert_type(maxdepth, _number_nil, 1, ":gettree")
    assert_type(filter, _function_nil, 2, ":gettree")
    _depth = _depth or 0
    maxdepth = maxdepth or 1/0  -- or infinity
    _value = self:__get()
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

--- Dump the specified node tree.
-- @param[opt=30] maxlines Maximum number of lines to output before stopping dump
-- @return dump as a string
function node:dump(maxlines)
  return M.dump(self, {}, maxlines)
end

--- Implement `pairs()` by iterating over the children of a given node.
-- At each child, yielding the triplet: subnode, subnode value (or `nil`), and subscript.
-- You can use either `pairs(node)` or `node:pairs()`.
-- If you need to iterate in reverse (or in Lua 5.1), use node:pairs(reverse) instead of pairs(node).
--
-- *Caution:* for the sake of speed, the iterator supplies a *mutable* node. This means it can
-- re-use the same node for each iteration by changing its last subscript, making it faster.
-- But if your loop needs to retain a reference to the node after loop iteration, it should create
-- an immutable copy of that node using `ydb.node(node)`.
-- Mutability can be tested for using `node:ismutable()`
--
-- *Notes:*
--
-- * `pairs()` order is guaranteed to equal the M collation sequence order
--   (even though `pairs()` order is not normally guaranteed for Lua tables).
--   This means that `pairs()` is a reasonable substitute for ipairs which is not implemented.
-- * This is very slightly slower than `node:subscripts()` which only iterates subscript names without
--   fetching the node value.
-- @function node:__pairs
-- @param[opt] reverse Boolean flag iterates in reverse if true
-- @example for subnode,value[,subscript] in pairs(node) do  subnode:incr(value)  end
-- -- to double the values of all subnodes of node
-- @return 3 values: `subnode_object`, `subnode_value_or_nil`, `subscript`
-- @see node:subscripts
function node:__pairs(reverse)
  local actuator = reverse and _yottadb.subscript_previous or _yottadb.subscript_next
  local subnode = _yottadb.cachearray_append(self, '')
  subnode = _yottadb.cachearray_tomutable(subnode)
  local function iterator()
    local subscript = actuator(subnode)
    subnode = _yottadb.cachearray_subst(subnode, subscript or '')
    if subscript==nil then return  nil  end
    local value = _yottadb.get(subnode)
    return subnode, value, subscript
  end
  return iterator, nil, ''  -- iterate using child from ''
end
node.pairs = node.__pairs

--- Not implemented: use `pairs(node)` or `node:__pairs()` instead.
-- See alternative usage below.
-- This is not implemented because
-- Lua >=5.3 implements ipairs via `__index()`.
-- This would mean that `__index()` would have to treat integer subscript lookup specially, so:
--
-- * Although `node['abc']`  => produces a new node so that `node.abc.def.ghi` works.
-- * `node[1]`  => would have to produce value `node(1).__` so ipairs() works. <br>
--   Since ipairs() will be little used anyway, the consequent inconsistency discourages implementation.
--
-- Alternatives using `pairs()` are as follows:
-- @function node:__ipairs
-- @example for k,v in pairs(node) do   if not tonumber(k) break end   <do_your_stuff with k,v>   end
-- -- this works since M sorts numbers first by default. The order may be changed by specifying a non-default collation on the database
-- @example for i=1,1/0 do   v=node[i].__  if not v break then   <do_your_stuff with k,v>   end
-- -- alternative that ensures integer keys

-- Creates and returns a new node with the given subscript(s) ... added.
-- If no subscripts supplied, return a copy of the node
-- @param ... string/number list of subscripts
function node:__call(...)
  if ... and type(...)=='userdata' then  -- 'userdata' is a fast way to test parameters are not strings to append
    -- This code is invoked when the user does node:method(x), which Lua translates to:
    --      node.method(node, x)
    -- Since we have redefined __index to create a subnode, the above first call index to create subnode node.method.
    -- Then Lua sees the (node, x) part of the command, which invokes `__call`:
    --      `node.__call(method_subnode, node, x)`
    -- where method_subnode gets mapped onto this function's `self`.
    -- Below we look up the name of method_subnode `self` to get the name of the method we are supposed to call.
    local method_name = _yottadb.cachearray_subscript(self, -1)
    local class = getmetatable(...)
    local method_found
    repeat
      method_found = class[method_name]
      class = class.__superclass
    until method_found or not class
    assert(method_found, string.format("could not find node method '%s' on node %s", method_name, ...))
    return method_found(...) -- first parameter of '...' is parent, as the method call will expect
  end
  return _yottadb.cachearray_append(self, ...)
end

-- Returns whether this node is equal to the given object.
-- This checks wither node A has the same varname and subscripts as node B:
--   equivalent to tostring(self)==tostring(other), but faster.
-- @param other Alternate node to compare self against
function node:__eq(other)
  if type(other) ~= 'userdata' then  return false  end
  local depth = _yottadb.cachearray_depth(self)
  if depth ~= _yottadb.cachearray_depth(other) then  return false  end
  for i=0, depth do
    if _yottadb.cachearray_subscript(self, i) ~= _yottadb.cachearray_subscript(other, i) then
      return false
    end
  end
  return true
end

-- @see incr
function node:__add(value)
  assert_type(value, _string_number, 1, ":add")
  node.incr(self, value)
  return self
end

-- @see incr
function node:__sub(value)
  assert_type(value, _string_number, 1, ":sub")
  node.incr(self, -value)
  return self
end

-- Returns the string representation of this node.
function node:__tostring()
  local subscripts, varname = _yottadb.cachearray_tostring(self)
  if subscripts == "" then  return varname  end
  return varname .. '(' .. subscripts .. ')'
end

-- Returns index `k` of the node
-- Search order for node attribute k:
--   node value when k=='__' -- this is a node property, not a method, so does not require invoking with ()
--   node method when k starts with '__' (k:__method() is the same as k:method() but 15x faster at ~200ns)
--   if nothing found, returns a new dbase subnode with subscript k
--   node:method() also works as a method as follows:
--      lua translates the ':' to node.method(self)
--      so first a subnode called node.method is created
--      and when invoked with parameter (self), `__call` checks whether the first parameter is self
--      and if so, invokes the method itself if self is a member of metatable 'node'
-- @param k Node attribute to look up
function node:__index(k)
  if k == '__' then  return _yottadb.get(self)  end  -- fast but only works if metatable is top-level superclass node, cf. subclass_index alternate
  local __end = '__\xff'
  if type(k)=='string' and k < __end and k >= '__' then  -- fastest way to check if k:startswith('__') -- with majority case (lowercase key values) falling through fastest
    return node[string.sub(k, 3)]  -- remove leading '__' to return node:method
  end
  return _yottadb.cachearray_append(self, k)
end

-- A generic version of `node:__index` for subclasses (slower, but works for subobject lookup)
local function subclass__index(self, k)
  if k == '__' then  return self:__get()  end  -- access subclass-overriden method if it exists
  local __end = '__\xff'
  if type(k)=='string' and k < __end and k >= '__' then  -- fastest way to check if k:startswith('__') -- with majority case (lowercase key values) falling through fastest
    return getmetatable(self)[string.sub(k, 3)]  -- remove leading '__' to return node:method
  end
  return _yottadb.cachearray_append(self, k)
end

-- Sets node's value if k='__'
-- It's tempting to implement db assignment node.subnode = 3
-- but that would not work consistently, e.g. node = 3 would set Lua local
function node:__newindex(k, v)
  if k == '__' then
    _yottadb.set(self, v)  -- fast but only works if metatable is top-level superclass node, cf. subclass_newindex alternate
  else
    error(string.format("Tried to set node object %s. Did you mean to set %s.__ instead?", self[k], self[k]), 2)
  end
end

-- A generic version of `node:__newindex` for subclasses (slower but works for setting subobjects)
local function subclass__newindex(self, k, v)
  if k == '__' then
    self:__set(v)  -- access subclass-overriden method if it exists
  else
    node.__newindex(self, k, v)  -- call original function to handle the identical error message
  end
end

--- Return raw representation of node's unique memory address.
-- @return string in hexadecimal format, starting with `0x`.
function node:__repr()  return rawtostring(self):match(' ([x%x]+)') or rawtostring(self)  end

-- Set up garbage collector for cachearrays when we're using our own implementation of lua_setuservalue()
if lua_version < 5.3 then
  node.__gc = _yottadb.cachearray_gc
end

--- @section end

--- Node class operations
-- @section

--- Create a new node class that inherits from the yottadb.node superclass.
-- The returned function will generate nodes of a new class (a new metatable). You may add or
-- override class methods by adding them to `new_metatable` either before or after calling inherit.
-- Any class method the user does not define in `new_metatable` will default to the class method of the superclass.
-- If desired, the new class may be further subclassed, also using `inherit`. Refer to the example below, and further
-- explanation in the README on [class inheritance](https://github.com/anet-be/lua-yottadb#class-inheritance).
-- @function M.inherit
-- @param node_func `yottadb.node` or a descendent that inherits from it using `inherit`
-- @param[opt] metatable to use for the new node class. Defaults to `{}`.
-- @return function that generates node of the new type
-- @return subclass metatable (modified)
-- @return superclass metatable used by the original node_func
-- @example
-- -- To average all data stored in a particular database node:
-- averaged_node, class, superclass = ydb.inherit(ydb.node)
-- function class:set(value)  sum=sum+value  writes=writes+1  return superclass.set(self, value)  end
--
-- -- Now use the new class
-- sum, writes = 0, 0
-- shoesize = averaged_node('shoesize')
-- shoesize:set(5)
-- shoesize:set(10)
-- shoesize.__ = 15  -- overriding set() also changes the behaviour of: .__ =
-- print('Average', sum/writes)
-- -- Average 10.0
function M.inherit(node_func, new_metatable)
  assert_type(node_func, 'function', 1)
  local super_object = node_func('tmp')  -- create an instance of the user's specified node() function to get its metatable
  assert(M.isnode(super_object), "inherit() arg #1 must be a function that produces an instance of yottadb.node or something inherited from it")
  local subclass = new_metatable or {}
  subclass.__superclass = getmetatable(super_object)
  subclass.__index = subclass.__index or subclass__index  -- don't use node.__index because it is only for super class (the sake of speed)
  subclass.__newindex = subclass.__newindex or subclass__newindex  -- don't use node.__newindex because it is only for super class (the sake of speed)
  -- Make heirs of node inherit all the __ methods of node except for those already in subclass.
  -- Note that I considered making __index auto-search through parent's methods rather than
  -- copying all the parent's methods. It would require setting the metatable's __index to the
  -- parent metatable. But this would mean it would have to look up even the __index method
  -- in every parent which is a speed-critical method. So it would be slower and more complicated.
  for k,v in pairs(node) do  subclass[k] = subclass[k] or v  end
  -- return a function that produces a node with above metatable
  local newfunc = function(...)
    local self = node_func(...)
    _yottadb.cachearray_setmetatable(self, subclass)  -- change to new class type
    return self
  end
  return newfunc, subclass, subclass.__superclass
end

-- @section end

--- Node class properties
-- @section

--- Fetch the varname of the node: the leftmost subscript.
function node:varname()  return _yottadb.cachearray_subscript(self, 0)  end
--- Fetch the name of the node: the rightmost subscript.
function node:name()  return _yottadb.cachearray_subscript(self, -1)  end
--- Fetch the depth of the node: how many subscripts it has.
-- @function node:depth
node.depth = _yottadb.cachearray_depth
--- Fetch the 'data' bitfield of the node that describes whether the node has a data value or subtrees.
-- @return
--   `yottadb.YDB_DATA_UNDEF` (no value or subtree) or <br>
--   `yottadb.YDB_DATA_VALUE_NODESC` (value, no subtree) or <br>
--   `yottadb.YDB_DATA_NOVALUE_DESC` (no value, subtree) or <br>
--   `yottadb.YDB_DATA_VALUE_DESC` (value and subtree)
-- @function node:data
node.data = _yottadb.data
--- Return true if the node has a value; otherwise false.
function node:has_value()  return node.data(self)%2 == 1  end
--- Return true if the node has a tree; otherwise false.
function node:has_tree()  return node.data(self)   >= 10  end
--- Return true if the node is mutable; otherwise false.
function node:ismutable()  return (_yottadb.cachearray_flags(self)%2) == 1  end
--- Return `node`'s subsarray of subscript strings as a table.
function node:subsarray()
  local subsarray = {}
  for i = 1, self:__depth() do  subsarray[i] = _yottadb.cachearray_subscript(self, i)  end
  return subsarray
end

-- ~~~ Deprecated object that represents a YDB node ~~~

--- Key class
-- @section

--- Creates an object that represents a YDB node; deprecated after v0.1. <br>
-- `key()` is a subclass of `node()` designed to implement deprecated
-- property names for backward compatibility, as follows:
--
-- * `name` (this node's subscript or variable name)
-- * `value` (this node's value in the YottaDB database)
-- * `data` (see `data()`)
-- * `has_value` (whether or not this node has a value)
-- * `has_tree` (whether or not this node has a subtree)
-- * `__varname` database variable name string -- for compatibility with a previous version
-- * `__subsarray` table array of database subscript name strings -- for compatibility with a previous version
--   and deprecated definitions of `key:subscript()`, `key:subscript_next()`, `key:subscript_previous()` <br>
-- @param varname String variable name.
-- @param[opt] subsarray list of subscripts or table subscripts
-- @return key object of the specified node with metatable `yottadb._key`
-- @see node
--- @deprecated v1.0
function M.key(...)
  assert_type(..., 'string', 1, "key")
  assert_type(select(2, ...), _table_nil, 2, "key")
  return _yottadb.cachearray_setmetatable(_yottadb.cachearray_create(...), key)  -- make it a key type
end

--- Deprecated object that represents a YDB node.
-- Key inherits all methods from node, plus deprecated (key-specific) method overrides
-- for backward compatibility, shown below.
-- @type key

-- @section end

-- Ldoc seems to require the following section name re-statement to prevent class being called "Class Key" in the docs
-- It also needs blank lines around it.

--- Key class
-- @section

-- Inherit node methods/properties
for k, v in pairs(node) do  key[k]=v  if string.sub(k,1,2)~='__' then key['__'..k]=v end  end

--- Properties of key object that are accessed with a dot.
-- These properties, listed below, are unlike object methods, which are accessed with a colon.
-- This kind of property access is for backward compatibility.
--
-- For example, access data property with: `key.data`
-- @table _property_
-- @field name equivalent to `node:name()`
-- @field data equivalent to `node:data()`
-- @field has_value equivalent to `node:has_value()`
-- @field has_tree equivalent to `node:has_tree()`
-- @field value equivalent to `node.__`
-- @field __varname database variable name string -- for compatibility with a previous version
-- @field __subsarray table array of database subscript name strings -- for compatibility with a previous version
--- @deprecated v1.0
key_properties = {
  name = key.name, -- equivalent to node::name()
  data = key.data, -- :name()
  has_value = key.has_value,
  has_tree = key.has_tree,
  value = key.get,
  __varname = key.varname, -- retained for backward compatibility
  __subsarray = key.subsarray,  -- retained for backward compatibility
}

local key_values = {}  -- Simulate node attribute storage using another table of tables since userdata can't store values

-- Returns indexes into the key
-- Search order for key attribute k:
--   self[k] (implemented first to simulate Lua's old-style key behaviour  -- finds self.attributes assigned to self such as __next_cachearray)
--   key_properties[k]
--   key[k] (i.e. look up in class named 'key' -- finds key.get, key.__call, etc.)
--   if nothing found, returns `nil`
-- @param k Node attribute to look up
--- @deprecated v1.0
function key:__index(k)
  local value_table = key_values[self]
  if value_table then
    local value = value_table[k]
    if value then  return value  end
  end
  local property = key_properties[k]
  if property then  return property(self)  end
  return key[k]
end

-- Sets dbase node value if k is 'value'; otherwise set self[k] = v
-- Differs from node.__newindex() as this can also set fields of self
--- @deprecated v1.0
function key:__newindex(k, v)
  if k == 'value' then
    key.set(self, v)
  else
    assert(not key_properties[k], 'read-only property')
    -- Simulate node attribute storage using another table of tables since userdata can't store values
    local value_table = key_values[self]
    if not value_table then  value_table = {}  key_values[self] = value_table  end
    value_table[k] = v
  end
end

-- ~~~ Deprecated functionality for M.key() as it's not Lua-esque: use pairs(key) instead ~~~

--- Deprecated way to delete database node value pointed to by node object.
-- Prefer `node:set(nil)`
-- @see kill, set
--- @deprecated v1.0
function key:delete_node() M.delete_node(self) end

--- Deprecated way to get next *sibling* subscript.
--
-- *Note:* this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
-- It operates differently than `node:subscripts()` which yields all subscripts that are *children* of the given node.
-- Deprecated because:
--
-- * It keeps dangerous state in the object, causing bugs when stale references attempt to access defunct state.
-- * It is more Lua-esque to iterate all subscripts in the node (think table) using `pairs()`.
-- * If sibling access becomes a common use-case, it should be reimplemented as an iterator.
-- @param[opt] reset If `true`, resets to the original subscript before any calls to `subscript_next()`
-- @param[opt] reverse If `true` then get previous instead of next
-- @see node:__pairs, subscript_previous
--- @deprecated v1.0
function key:subscript_next(reset, reverse)
  local actuator = reverse and M.subscript_previous or M.subscript_next
  if not self.__next_cachearray then
    self.__next_cachearray = self
    if self:depth()==0 then  self.__next_cachearray = _yottadb.cachearray_append(self, '')  end
    self.__next_cachearray = _yottadb.cachearray_tomutable(self.__next_cachearray)
    reset = true
  end
  if reset then _yottadb.cachearray_subst(self.__next_cachearray, '')  end
  local next_sub = actuator(self.__next_cachearray)
  if next_sub then  _yottadb.cachearray_subst(self.__next_cachearray, next_sub)  end
  return next_sub
end

--- Deprecated way to get previous *sibling* subscript.
-- See notes for `subscript_previous()`
-- @param[opt] reset If `true`, resets to the original subscript before any calls to `subscript_next()`
-- or `subscript_previous()`
-- @see node:__pairs, subscript_next
--- @deprecated v1.0
function key:subscript_previous(reset)
  return self:subscript_next(reset, true)
end

--- Deprecated way to get same-level subscripts from this node onward.
-- Deprecated because:
--
-- * `pairs()` is more Lua-esque.
-- * It was non-intuitive that `key:subscripts()` iterates only subsequent subscripts, not all child subscripts.
-- @param[opt] reverse When set to `true`, iterates in reverse
-- @see subscripts
--- @deprecated v1.0
function key:subscripts(...)
  local cachearray = self
  if self:depth() == 0 then
    cachearray = _yottadb.cachearray_append(self, '')
  end
  return M.subscripts(cachearray, ...)
end

--- @section end

-- ~~~ High level utility functions ~~~

--- High level functions
-- @section

--- Dump the specified node tree.
-- @param node Either a node object with `...` subscripts or glvn varname with `...` subsarray
-- @param[opt] ... Either a table or a list of subscripts to add to node
-- @param[opt=30] maxlines Maximum number of lines to output before stopping dump
-- @return dump as a string
-- @example ydb.dump(node, [...[, maxlines]])
-- @example ydb.dump('^MYVAR', 'people')
function M.dump(node, ...)
  -- check whether maxlines was supplied as last parameter
  local subs, maxlines
  if select('#',...)>0 and type(...)=='table' then  subs, maxlines = ...
  else  subs, maxlines = {...}, nil  end
  maxlines = maxlines or 30
  -- print node address if it is a userdata
  local output = {}
  local address = ''
  if M.isnode(node) then
    address = ' (cachearray ' .. node:____repr() .. ')'
  else
    node = M.node(node, subs)  -- make varname, subs into a node object
  end
  output[1] = tostring(node) .. address

  local too_many_lines_error = "Too many lines"
  local function print_func(node, _sub, val)
    if not val then  return  end
    table.insert(output, string.format('%s=%s', node, q_number(val) or string.format('%q',val)))
    assert(#output < maxlines, too_many_lines_error)
  end
  local ok, err = pcall(node.gettree, node, nil, print_func)
  if not ok then
    -- note: use of sub() is for lua5.1 which returns not err, but err with a prefix containing line number
    if err:sub(-#too_many_lines_error)==too_many_lines_error then
      table.insert(output, string.format("...etc.   -- stopped at %s lines; to show more use yottadb.dump(node, subscripts, maxlines)", maxlines))
    else  error(err .. ' in pcall above the stated line')  end
  end
  return table.concat(output, '\n')
end

-- Useful for debugging to check whether an object's metatable matches node superclass type
M._node = node
M._key = key
M._key_properties = key_properties

return M
