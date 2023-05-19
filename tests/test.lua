-- Copyright 2021-2022 Mitchell. See LICENSE.

require('tests.strict')

local table_dump = require('examples.startup')
local _yottadb = require('_yottadb')
local yottadb = require('yottadb')
local lua_version = tonumber( string.match(_VERSION, " ([0-9]+[.][0-9]+)") )
local ydb_release = tonumber( string.match(_yottadb.get('$ZYRELEASE'), "[A-Za-z]+ r([0-9]+[.][0-9]+)") )

local lua_exec = 'lua'
local i=0  while arg[i] do lua_exec = arg[i]  i=i-1  end

local cwd = arg[0]:match('^.+/') or '.'
local gbldir_prefix = (os.getenv('TMPDIR') or '/tmp') .. '/lua-yottadb-'

local SIMPLE_DATA = {
  {{'^Test5', {}}, 'test5value'},
  {{'^test1', {}}, 'test1value'},
  {{'^test2', {'sub1',}}, 'test2value'},
  {{'^test3', {}}, 'test3value1'},
  {{'^test3', {'sub1',}}, 'test3value2'},
  {{'^test3', {'sub1', 'sub2'}}, 'test3value3'},
  {{'^test4', {}}, 'test4'},
  {{'^test4', {'sub1',}}, 'test4sub1'},
  {{'^test4', {'sub1', 'subsub1'}}, 'test4sub1subsub1'},
  {{'^test4', {'sub1', 'subsub2'}}, 'test4sub1subsub2'},
  {{'^test4', {'sub1', 'subsub3'}}, 'test4sub1subsub3'},
  {{'^test4', {'sub2',}}, 'test4sub2'},
  {{'^test4', {'sub2', 'subsub1'}}, 'test4sub2subsub1'},
  {{'^test4', {'sub2', 'subsub2'}}, 'test4sub2subsub2'},
  {{'^test4', {'sub2', 'subsub3'}}, 'test4sub2subsub3'},
  {{'^test4', {'sub3',}}, 'test4sub3'},
  {{'^test4', {'sub3', 'subsub1'}}, 'test4sub3subsub1'},
  {{'^test4', {'sub3', 'subsub2'}}, 'test4sub3subsub2'},
  {{'^test4', {'sub3', 'subsub3'}}, 'test4sub3subsub3'},
  {{'^test6', {'sub6', 'subsub6'}}, 'test6value'},
  {{'^test7', {'sub1\128',}}, 'test7value'},
  -- Test subscripts with non-UTF-8 data
  {{'^test7', {'sub2\128', 'sub7'}}, 'test7sub2value'},
  {{'^test7', {'sub3\128', 'sub7'}}, 'test7sub3value'},
  {{'^test7', {'sub4\128', 'sub7'}}, 'test7sub4value'},
}

-- Remove database temporary directories
local function cleanup()
  os.execute(string.format('bash -c "rm -f %s*.gld %s*.dat*"', gbldir_prefix, gbldir_prefix))
end

-- Execute shell command with the environment settings we need
local Zgbldir   -- our current database file
local function env_execute(command)
  local env = string.format('ydb_gbldir="%s"', Zgbldir)
  command = 'env '..env..' '..command
  if lua_version <= 5.1 then
    -- simulate behaviour of os.execute in later Lua versions
    return true, 'exit', os.execute(command)/256
  end
  local ok, typ, result = os.execute(command)
  assert(typ ~= 'signal', string.format("Signal %s interrupted process: %s", result, command))
  return ok, typ, result
end

-- Run shell command in the background (using bash &)
-- Beware that you must not use single quotes in the supplied string
local function background_execute(command)
  return env_execute("bash -c '"..command.." &'")
end

-- Create database in temporary directories using GDE
-- unique_name specifies a filename suffix for the global directory and datafile
local function setup(unique_name)
  local gbldir = gbldir_prefix .. unique_name .. '.gld'
  local gbldat = gbldir_prefix .. unique_name .. '.dat'
  -- verify that these files do not yet exist
  for _, fname in ipairs({gbldir, gbldat}) do
    local f, msg = io.open(fname, 'r')
    if f then f:close() end
    assert(not f, string.format("File already exists trying to create database %s. Run 'gde help overview' for details", fname))
  end
  Zgbldir=gbldir
  local command = string.format('bash -c "%s/createdb.sh %s %s 2>/dev/null >/dev/null"', cwd, os.getenv('ydb_dist'), gbldat)
  local ok = env_execute(command)
  assert(ok, string.format("Failed to create database %s with command:\n  %s", Zgbldir, command))
  yottadb.set('$ZGBLDIR', Zgbldir)
  _yottadb.delete_excl({})  -- make sure all locals are deleted before each test
end

local has_simple_data = false
-- Inserts SIMPLE_DATA into the YDB database for the test that calls this function.
local function simple_data()
  for i = 1, #SIMPLE_DATA do
    local key, value = SIMPLE_DATA[i][1], SIMPLE_DATA[i][2]
    _yottadb.set(key[1], key[2], value)
  end
  has_simple_data = true
end

local function teardown()
  if has_simple_data then
    for i = 1, #SIMPLE_DATA do
      local key = SIMPLE_DATA[i][1]
      _yottadb.delete(key[1], key[2], _yottadb.YDB_DEL_TREE)
    end
    has_simple_data = false
  end
end

-- Skips the given test when running the test suite.
local function skip(f)
  if #arg > 0 then return end -- do not skip manually specified tests
  local skip = {}
  for k, v in pairs(_G) do if v == f then skip[#skip + 1] = k end end
  for _, name in ipairs(skip) do _G['skip_' .. name], _G[name] = f, nil end
end

local function validate_varname_inputs(f, skip_invalid)
  local function val() if f==_yottadb.set then  return 'val'  end end
  local ok, e = pcall(f, true, val)
  assert(not ok)
  assert(e:find('expected'))

  ok, e = pcall(f, string.rep('b', _yottadb.YDB_MAX_IDENT + 1), val())
  assert(not ok)
  assert(e:find("name length exceeds"))

  if f == _yottadb.get then
    _yottadb.set(string.rep('b', _yottadb.YDB_MAX_IDENT), 'val')
  end
  ok, e = pcall(f, string.rep('b', _yottadb.YDB_MAX_IDENT), val())
  assert(ok)

  if not skip_invalid then
    ok, e = pcall(f, '\128', val())
    assert(not ok)
    asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_INVVARNAME)
  end
end

local function validate_subsarray_inputs(f)
  local function val() if f==_yottadb.set then  return 'val'  end end
  local subs = {}
  for i = 1, _yottadb.YDB_MAX_SUBS do subs[i] = 'b' end
  if f == _yottadb.get then _yottadb.set('test', subs, 'val') end -- avoid YDB_ERR_LVUNDEF
  local ok, e = pcall(f, 'test', subs, val())
  assert(ok)

  subs[#subs + 1] = 'b'
  ok, e = pcall(f, 'test', subs, val())
  assert(not ok)
  assert(e:find("number of subscripts exceeded"))

  ok, e = pcall(f, 'test', {true}, val())
  assert(not ok)
  assert(e:find('expected'))

  if f == _yottadb.get then
    _yottadb.set('test', {string.rep('b', _yottadb.YDB_MAX_IDENT)}, 'val') -- avoid YDB_ERR_LVUNDEF
  end
  ok, e = pcall(f, 'test', {string.rep('b', _yottadb.YDB_MAX_IDENT)}, val())
  -- Note: subscripts for lock functions are shorter, so ignore those errors.
  assert(ok or yottadb.get_error_code(e) == _yottadb.YDB_ERR_LOCKSUB2LONG)
end

function asserteq(value1, value2)
  if value1 ~= value2 then
    error(string.format("%s <> %s", value1, value2), 2)
  end
end

function test_get()
  simple_data()
  asserteq(_yottadb.get('^test1'), 'test1value')
  asserteq(_yottadb.get('^test2', {'sub1'}), 'test2value')
  asserteq(_yottadb.get('^test3'), 'test3value1')
  asserteq(_yottadb.get('^test3', {'sub1'}), 'test3value2')
  asserteq(_yottadb.get('^test3', {'sub1', 'sub2'}), 'test3value3')
  asserteq(yottadb.get('^test3', 'sub1', 'sub2'), 'test3value3')

  -- Error handling.
  local gvns = {{'^testerror'}, {'^testerror', {'sub1'}}}
  for i = 1, #gvns do
    asserteq(_yottadb.get(table.unpack(gvns[i])), nil)
  end
  local lvns = {{'testerror'}, {'testerror', {'sub1'}}}
  for i = 1, #lvns do
    asserteq(_yottadb.get(table.unpack(lvns[i])), nil)
  end

  -- Handling of large values.
  _yottadb.set('testlong', string.rep('a', _yottadb.YDB_MAX_STR))
  asserteq(_yottadb.get('testlong'), string.rep('a', _yottadb.YDB_MAX_STR))

  -- Validate inputs.
  validate_varname_inputs(_yottadb.get)
  validate_subsarray_inputs(_yottadb.get)
end

function test_set()
  _yottadb.set('test4', 'test4value')
  asserteq(_yottadb.get('test4'), 'test4value')
  _yottadb.set('test6', {'sub1'}, 'test6value')
  asserteq(_yottadb.get('test6', {'sub1'}), 'test6value')
  yottadb.set('test6', 'sub1', 'test7value')
  asserteq(_yottadb.get('test6', {'sub1'}), 'test7value')

  -- Unicode/i18n value.
  _yottadb.set('testchinese', '你好世界')
  asserteq(_yottadb.get('testchinese'), '你好世界')

  -- strings with NULs
  local name, value = 'testnulstring', 'testnul\0string'
  _yottadb.set(name, value)
  asserteq(_yottadb.get(name), value)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.set)
  validate_subsarray_inputs(_yottadb.set)

  local ok, e = pcall(_yottadb.set, 'test', {'b'}, true)
  assert(not ok)
  assert(e:find('string expected'))

  ok, e = pcall(_yottadb.set, 'test', {'b'}, string.rep('b', _yottadb.YDB_MAX_STR))
  assert(ok)

  ok, e = pcall(_yottadb.set, 'test', {'b'}, string.rep('b', _yottadb.YDB_MAX_STR + 1))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_INVSTRLEN)
end

function test_delete()
  _yottadb.set('test8', 'test8value')
  asserteq(_yottadb.get('test8'), 'test8value')
  _yottadb.delete('test8')
  asserteq(_yottadb.get('test8'), nil)

  _yottadb.set('test10', {'sub1'}, 'test10value')
  asserteq(_yottadb.get('test10', {'sub1'}), 'test10value')
  _yottadb.delete('test10', {'sub1'})
  asserteq(_yottadb.get('test10', {'sub1'}), nil)

  -- test deleting a root node value by setting it to nil
  _yottadb.set('test10', 'test10value')
  asserteq(_yottadb.get('test10'), 'test10value')
  yottadb.set('test10', nil)
  asserteq(_yottadb.get('test10'), nil)
  -- test deleting subnode value by setting it to nil
  _yottadb.set('test10', {'sub1'}, 'test10value')
  asserteq(_yottadb.get('test10', {'sub1'}), 'test10value')
  yottadb.set('test10', {'sub1'}, nil)  -- Note: testing delete functionality of yottadb.set(), not _yottadb.set()
  asserteq(_yottadb.get('test10', {'sub1'}), nil)
  -- test deleting subnode-list value by setting it to nil
  _yottadb.set('test10', {'sub1'}, 'test10value')
  asserteq(_yottadb.get('test10', {'sub1'}), 'test10value')
  yottadb.set('test10', 'sub1', nil)
  asserteq(_yottadb.get('test10', {'sub1'}), nil)

  -- Delete tree.
  _yottadb.set('test12', 'test12 node value')
  _yottadb.set('test12', {'sub1'}, 'test12 subnode value')
  asserteq(_yottadb.get('test12'), 'test12 node value')
  asserteq(_yottadb.get('test12', {'sub1'}), 'test12 subnode value')
  _yottadb.delete('test12', _yottadb.YDB_DEL_TREE)
  asserteq(_yottadb.get('test12'), nil)
  asserteq(_yottadb.get('test12', {'sub1'}), nil)

  _yottadb.set('test11', {'sub1'}, 'test11value')
  asserteq(_yottadb.get('test11', {'sub1'}), 'test11value')
  _yottadb.delete('test11', {'sub1'}, _yottadb.YDB_DEL_NODE)
  asserteq(_yottadb.get('test11', {'sub1'}), nil)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.delete)
  validate_subsarray_inputs(_yottadb.delete)

  _yottadb.delete('test', {'b'}, nil)
end

function test_delete_excl()
  yottadb.set('test1', 'abc')
  _yottadb.delete_excl({})  -- delete all locals
  assert(yottadb.get('test1') ~= 'abc')
end

function test_data()
  simple_data()
  asserteq(_yottadb.data('^nodata'), _yottadb.YDB_DATA_UNDEF)
  asserteq(_yottadb.data('^test1'), _yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(_yottadb.data('^test2'), _yottadb.YDB_DATA_NOVALUE_DESC)
  asserteq(_yottadb.data('^test2', {'sub1'}), _yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(_yottadb.data('^test3'), _yottadb.YDB_DATA_VALUE_DESC)
  asserteq(_yottadb.data('^test3', {'sub1'}), _yottadb.YDB_DATA_VALUE_DESC)
  asserteq(_yottadb.data('^test3', {'sub1', 'sub2'}), _yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(yottadb.data('^test3', 'sub1', 'sub2'), _yottadb.YDB_DATA_VALUE_NODESC)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.data)
  validate_subsarray_inputs(_yottadb.data)
end

-- Note: for some reason, this test must be run first to pass.
function test_lock_incr()
  -- Varname only.
  local t1 = os.clock()
  _yottadb.lock_incr('test1')
  local t2 = os.clock()
  assert(t2 - t1 < 0.1)
  _yottadb.lock_decr('test1')

  -- Varname and subscript.
  t1 = os.clock()
  _yottadb.lock_incr('test2', {'sub1'})
  t2 = os.clock()
  assert(t2 - t1 < 0.1)
  _yottadb.lock_decr('test2', {'sub1'})

  -- Timeout, varname only.
  background_execute(lua_exec .. ' tests/lock.lua "^test1"')
  os.execute('sleep 0.1')
  local t1 = os.time()
  local ok, e = pcall(_yottadb.lock_incr, '^test1', 1)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_LOCK_TIMEOUT)
  local t2 = os.time()
  assert(t2 - t1 >= 1)
  -- Varname and subscript
  background_execute(lua_exec .. ' tests/lock.lua "^test2" "sub1"')
  os.execute('sleep 0.1')
  t1 = os.time()
  ok, e = pcall(_yottadb.lock_incr, '^test2', {'sub1'}, 1)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_LOCK_TIMEOUT)
  t2 = os.time()
  assert(t2 - t1 >= 1)
  os.execute('sleep 1')

  -- No timeout.
  background_execute(lua_exec .. ' tests/lock.lua "^test2" "sub1"')
  os.execute('sleep 2')
  local t1 = os.clock()
  _yottadb.lock_incr('^test2', {'sub1'})
  local t2 = os.clock()
  assert(t2 - t1 < 0.1)

  -- Test blocking other.
  local nodes_text = {
    {'^test1'},
    {'^test2', {'sub1'}},
    {'^test2', {'sub1', 'sub2'}}
  }
  local nodes = {
    {_yottadb.cachearray_create('^test1')},
    {_yottadb.cachearray_create('^test2', {'sub1'})},
    {_yottadb.cachearray_create('^test2', {'sub1', 'sub2'})}
  }
  _yottadb.lock(nodes)
  for i = 1, #nodes do
    local cmd = string.format('%s tests/lock.lua "%s" %s', lua_exec, nodes_text[i][1], table.concat(nodes_text[i][2] or {}, ' '))
    local _1, _2, status = env_execute(cmd)
    asserteq(status, 1)
  end
  _yottadb.lock() -- release all locks
  for i = 1, #nodes do
    local cmd = string.format('%s tests/lock.lua "%s" %s', lua_exec, nodes_text[i][1], table.concat(nodes_text[i][2] or {}, ' '))
    local _, _, status = env_execute(cmd)
    asserteq(status, 0)
  end

  -- Test lock being blocked.
  background_execute(lua_exec .. ' tests/lock.lua "^test1"')
  os.execute('sleep 0.1')
  local ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create("^test1")}})
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_LOCK_TIMEOUT)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.lock_incr)
  validate_subsarray_inputs(_yottadb.lock_incr)

  ok, e = pcall(_yottadb.lock_incr, 'test', {'b'}, true)
  assert(not ok)
  assert(e:find('number expected'))
end
--skip(test_lock_incr) -- for speed

function test_lock()
  -- Validate inputs.
  local ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create('\128')}})
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_INVVARNAME)
  ok, e = pcall(_yottadb.lock, true)
  assert(not ok)
  assert(e:find('table of') and e:find('node specifiers expected'))

  ok, e = pcall(_yottadb.lock, {true})
  assert(not ok)
  assert(e:find('table of') and e:find('node specifiers expected'))

  ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create(string.rep('a', _yottadb.YDB_MAX_IDENT))}})
  assert(ok)

  ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create(string.rep('a', _yottadb.YDB_MAX_IDENT + 1))}})
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_VARNAME2LONG)

  ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create('test'), true}})
  assert(not ok)
  assert(e:find('element 2 must be an integer'))

  local subsarray = {}
  for i = 1, _yottadb.YDB_MAX_SUBS do subsarray[i] = 'test' .. i end
  ok, e = pcall(_yottadb.lock, {{_yottadb.cachearray_create('test', subsarray)}})
  assert(ok)
end

local function test_lock_decr()
  validate_varname_inputs(_yottadb.lock_decr)
  validate_subsarray_inputs(_yottadb.lock_decr)
end

-- This function simulates the operation of an obsolete version of _yottadb.get()
-- which raised an error if the variable was not found instead of returning nil.
-- Its purpose is to use in the transaction tests below, which were designed for
-- the old version
local function test_get(...)
  local retval = _yottadb.get(...)
  if retval == nil then
    error(_yottadb.message(_yottadb.YDB_ERR_GVUNDEF))
  end
end

local function tp_set(varname, subs, value, retval)
  _yottadb.set(varname, subs, value)
  if retval then return retval end
end

function test_tp_return_YDB_OK()
  local key = {'^tptests', {'test_tp_return_YDB_OK'}}
  local value = 'return YDB_OK'
  _yottadb.delete(table.unpack(key))
  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)
  _yottadb.tp(tp_set, key[1], key[2], value)
  asserteq(_yottadb.get(table.unpack(key)), value)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_return_YDB_OK()
  local key1 = {'^tptests', {'test_tp_nested_return_YDB_OK', 'outer'}}
  local value1 = 'return_YDB_OK'
  local key2 = {'^tptests', {'test_tp_nested_return_YDB_OK', 'nested'}}
  local value2 = 'nested return_YDB_OK'

  _yottadb.tp(function()
    tp_set(key1[1], key1[2], value1)
    _yottadb.tp(tp_set, key2[1], key2[2], value2)
  end)

  asserteq(_yottadb.get(table.unpack(key1)), value1)
  asserteq(_yottadb.get(table.unpack(key2)), value2)
  _yottadb.delete('^tptests', _yottadb.YDB_DEL_TREE)
end

function test_tp_return_YDB_TP_ROLLBACK()
  local key, value = {'^tptests', {'test_tp_return_YDB_TP_ROLLBACK'}}, 'return YDB_TP_ROLLBACK'
  _yottadb.delete(table.unpack(key))
  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, tp_set, key[1], key[2], value, _yottadb.YDB_TP_ROLLBACK)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_TP_ROLLBACK)

  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_return_YDB_TP_ROLLBACK()
  local key1 = {'^tptests', {'test_tp_nested_return_YDB_TP_ROLLBACK', 'outer'}}
  local value1 = 'return YDB_TP_ROLLBACK'
  local key2 = {'^tptests', {'test_tp_nested_return_YDB_TP_ROLLBACK', 'nested'}}
  local value2 = 'nested return YDB_TP_ROLLBACK'
  _yottadb.delete(table.unpack(key1))
  _yottadb.delete(table.unpack(key2))
  asserteq(_yottadb.data(table.unpack(key1)), _yottadb.YDB_DATA_UNDEF)
  asserteq(_yottadb.data(table.unpack(key2)), _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, function()
    tp_set(key1[1], key1[2], value1)
    _yottadb.tp(tp_set, key2[1], key2[2], value2, _yottadb.YDB_TP_ROLLBACK)
  end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_TP_ROLLBACK)

  asserteq(_yottadb.data(table.unpack(key1)), _yottadb.YDB_DATA_UNDEF)
  asserteq(_yottadb.data(table.unpack(key2)), _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key1[1], _yottadb.YDB_DEL_TREE)
end

local function tp_conditional_set(key1, key2, value, tracker)
  if _yottadb.data(table.unpack(tracker)) == _yottadb.YDB_DATA_UNDEF then
    _yottadb.set(key1[1], key1[2], value)
    _yottadb.incr(table.unpack(tracker))
    return _yottadb.YDB_TP_RESTART
  else
    _yottadb.set(key2[1], key2[2], value)
  end
end

function test_tp_return_YDB_TP_RESTART()
  local key1 = {'^tptests', {'test_tp_return_YDB_TP_RESTART', 'key1'}}
  _yottadb.delete(table.unpack(key1))
  local key2 = {'^tptests', {'test_tp_return_YDB_TP_RESTART', 'key2'}}
  _yottadb.delete(table.unpack(key2))
  local value = 'restart once'
  local tracker = {'tptests', {'test_tp_return_YDB_TP_RESTART', 'reset count'}}

  _yottadb.tp(tp_conditional_set, key1, key2, value, tracker)

  local ok, e = pcall(test_get, table.unpack(key1))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF)
  asserteq(_yottadb.get(table.unpack(key2)), value)
  asserteq(tonumber(_yottadb.get(table.unpack(tracker))), 1)

  _yottadb.delete(key1[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_return_YDB_TP_RESTART()
  local key1_1 = {'^tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'outer', 'key1'}}
  _yottadb.delete(table.unpack(key1_1))
  local key1_2 = {'^tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'outer', 'key2'}}
  _yottadb.delete(table.unpack(key1_2))
  local value1 = 'outer restart once'
  local tracker1 = {'tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'outer reset count'}}

  local key2_1 = {'^tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'inner', 'key1'}}
  _yottadb.delete(table.unpack(key2_1))
  local key2_2 = {'^tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'inner', 'key2'}}
  _yottadb.delete(table.unpack(key2_2))
  local value2 = 'inner restart once'
  local tracker2 = {'tptests', {'test_tp_nested_return_YDB_TP_RESTART', 'inner reset count'}}

  _yottadb.tp(function()
    local status = tp_conditional_set(key1_1, key1_2, value1, tracker1)
    _yottadb.tp(tp_conditional_set, key2_1, key2_2, value2, tracker2)
    return status -- TODO: _yottadb.tp_restart() to throw error that can be caught and bubbled up?
  end)

  local ok, e = pcall(test_get, table.unpack(key1_1))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF)
  asserteq(tonumber(_yottadb.get(table.unpack(tracker1))), 1)
  ok, e = pcall(test_get, table.unpack(key2_1))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF)
  asserteq(_yottadb.get(table.unpack(key2_2)), value2)

  _yottadb.delete(table.unpack(key1_1))
  _yottadb.delete(table.unpack(key1_2))
  _yottadb.delete(table.unpack(tracker1))
  _yottadb.delete(table.unpack(key2_1))
  _yottadb.delete(table.unpack(key2_2))
  _yottadb.delete(table.unpack(tracker2))
  _yottadb.delete(key1_1[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_return_YDB_TP_RESTART_reset_all()
  local key = {'^tptests', {'test_tp_return_YDB_TP_RESTART_reset_all', 'resetvalue'}}
  local tracker = {'tptests', {'test_tp_return_YDB_TP_RESTART_reset_all', 'resetcount'}}
  _yottadb.delete(table.unpack(key))

  local timeout = os.time() + 1

  _yottadb.tp({'*'}, function()
    _yottadb.incr(key[1], key[2])
    if os.time() < timeout then return _yottadb.YDB_TP_RESTART end
    os.execute('sleep 0.1')
  end)

  asserteq(_yottadb.get(table.unpack(key)), '1')
  local ok, e = pcall(test_get, table.unpack(tracker))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF) -- GVUNDEF instead of LVUNDEF used here: a kludge for test_get()
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_return_YDB_ERR_TPTIMEOUT()
  local key = {'^tptests', {'test_tp_return_YDB_ERR_TPTIMEOUT'}}
  local value = 'return YDB_ERR_TPTIMEOUT'
  _yottadb.delete(table.unpack(key))
  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, tp_set, key[1], key[2], value, _yottadb.YDB_ERR_TPTIMEOUT)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_TPTIMEOUT)

  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_return_YDB_ERR_TPTIMEOUT()
  local key1 = {'^tptests', {'test_tp_nested_return_YDB_ERR_TPTIMEOUT', 'outer'}}
  local value1 = 'return YDB_ERR_TPTIMEOUT'
  local key2 = {'^tptests', {'test_tp_nested_return_YDB_ERR_TPTIMEOUT', 'nested'}}
  local value2 = 'nested return YDB_ERR_TPTIMEOUT'

  local ok, e = pcall(_yottadb.tp, function()
    local status = tp_set(key1[1], key1[2], value1, _yottadb.YDB_ERR_TPTIMEOUT)
    _yottadb.tp(tp_set, key2[1], key2[2], value2, _yottadb.YDB_ERR_TPTIMEOUT)
    return status
  end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_TPTIMEOUT)

  asserteq(_yottadb.data(table.unpack(key1)), _yottadb.YDB_DATA_UNDEF)
  asserteq(_yottadb.data(table.unpack(key2)), _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key1[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_raise_error()
  local key = {'^tptests', 'test_tp_raise_error'}
  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, test_get, key[1], key[2])
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_raise_error()
  local key = {'^tptests', {'test_tp_nested_raise_error'}}
  asserteq(_yottadb.data(table.unpack(key)), _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, function()
    _yottadb.tp(test_get, key[1], key[2])
  end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_GVUNDEF)
  _yottadb.delete('^tptests', _yottadb.YDB_DEL_TREE)
end

function test_tp_raise_lua_error()
  local ok, e = pcall(_yottadb.tp, error, 'lua error')
  assert(not ok)
  asserteq(e, 'lua error')
end

function test_tp_nested_raise_lua_error()
  local ok, e = pcall(_yottadb.tp, function()
    _yottadb.tp(error, 'lua error')
  end)
  assert(not ok)
  asserteq(e, 'lua error')
end

local YDB_MAX_TP_DEPTH = 126 -- max nested transactions
function test_tp_return_YDB_OK_to_depth()
  local function key(i)
    return {'^tptests', {'test_tp_return_YDB_OK_to_depth' .. i, 'level' .. i}}
  end
  local function value(i)
    return string.format('level%i returns YDB_OK', i)
  end

  local function recursive_tp(i)
    if not i then i = 1 end
    local key = key(i)
    _yottadb.set(key[1], key[2], value(i))
    if i < YDB_MAX_TP_DEPTH then _yottadb.tp(recursive_tp, i + 1) end
  end
  _yottadb.tp(recursive_tp)

  for i = 1, YDB_MAX_TP_DEPTH do
    local key = key(i)
    asserteq(_yottadb.get(table.unpack(key)), value(i))
    _yottadb.delete(table.unpack(key))
  end
  _yottadb.delete('^tptests', _yottadb.YDB_DEL_TREE)
end

function test_tp_bank_transfer()
  local account1 = 'acc#1234'
  local account2 = 'acc#5678'
  local balance1 = 1234
  local balance2 = 5678
  _yottadb.set('^account', {account1, 'balance'}, balance1)
  _yottadb.set('^account', {account2, 'balance'}, balance2)

  local function transfer(from, to, amount)
    local from_balance = tonumber(_yottadb.get('^account', {from, 'balance'}))
    local to_balance = tonumber(_yottadb.get('^account', {to, 'balance'}))
    _yottadb.set('^account', {from, 'balance'}, from_balance - amount)
    _yottadb.set('^account', {to, 'balance'}, to_balance + amount)
    local new_from_balance = tonumber(_yottadb.get('^account', {from, 'balance'}))
    if new_from_balance < 0 then return _yottadb.YDB_TP_ROLLBACK end
  end

  local amount = balance1 - 1
  _yottadb.tp(transfer, account1, account2, amount)
  asserteq(tonumber(_yottadb.get('^account', {account1, 'balance'})), balance1 - amount)
  asserteq(tonumber(_yottadb.get('^account', {account2, 'balance'})), balance2 + amount)

  -- Test rollback.
  balance1 = balance1 - amount
  balance2 = balance2 + amount
  amount = balance1 + 1 -- would overdraft
  local ok, e = pcall(_yottadb.tp, transfer, account1, account2, amount)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_TP_ROLLBACK)
  asserteq(tonumber(_yottadb.get('^account', {account1, 'balance'})), balance1)
  asserteq(tonumber(_yottadb.get('^account', {account2, 'balance'})), balance2)

  _yottadb.delete('^account', _yottadb.YDB_DEL_TREE)
end

function test_tp_reset_some()
  _yottadb.set('resetattempt', '0')
  _yottadb.set('resetvalue', '0')
  local timeout = os.time() + 1
  _yottadb.tp({'resetvalue'}, function()
    _yottadb.incr('resetattempt', '1')
    _yottadb.incr('resetvalue', 1)
    if not (_yottadb.get('resetattempt') == '2' or os.time() >= timeout) then
      os.execute('sleep 0.1')
      return _yottadb.YDB_TP_RESTART
    end
  end)
  asserteq(_yottadb.get('resetattempt'), '2')
  asserteq(_yottadb.get('resetvalue'), '1')
  _yottadb.delete('resetattempt')
  _yottadb.delete('resetvalue')
end

function test_tp()
  -- Validate inputs.
  local ok, e = pcall(_yottadb.tp, true)
  assert(not ok)
  assert(e:find('function expected'))

  ok, e = pcall(_yottadb.tp, function() return true end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_TPCALLBACKINVRETVAL)

  local function simple_transaction() return _yottadb.YDB_OK end

  ok, e = pcall(_yottadb.tp, {true}, simple_transaction)
  assert(not ok)
  assert(e:find('varnames must be strings'))

  local varnames = {}
  for i = 1, _yottadb.YDB_MAX_NAMES do varnames[i] = 'test' .. i end
  ok, e = pcall(_yottadb.tp, varnames, simple_transaction)
  assert(ok)

  varnames[#varnames + 1] = 'test' .. (#varnames + 1)
  ok, e = pcall(_yottadb.tp, varnames, simple_transaction)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_NAMECOUNT2HI)

  ok, e = pcall(_yottadb.tp, {string.rep('b', _yottadb.YDB_MAX_IDENT)}, simple_transaction)
  assert(ok)

  ok, e = pcall(_yottadb.tp, {string.rep('b', _yottadb.YDB_MAX_IDENT + 1)}, simple_transaction)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_VARNAME2LONG)
end

function test_subscript_next()
  simple_data()
  asserteq(_yottadb.subscript_next('^%'), '^Test5')
  asserteq(_yottadb.subscript_next('^a'), '^test1')
  asserteq(_yottadb.subscript_next('^test1'), '^test2')
  asserteq(_yottadb.subscript_next('^test2'), '^test3')
  asserteq(_yottadb.subscript_next('^test3'), '^test4')
  asserteq(_yottadb.subscript_next('^test7'), nil)

  asserteq(_yottadb.subscript_next('^test4', {''}), 'sub1')
  asserteq(_yottadb.subscript_next('^test4', {'sub1'}), 'sub2')
  asserteq(_yottadb.subscript_next('^test4', {'sub2'}), 'sub3')
  asserteq(_yottadb.subscript_next('^test4', {'sub3'}), nil)

  asserteq(_yottadb.subscript_next('^test4', {'sub1', ''}), 'subsub1')
  asserteq(_yottadb.subscript_next('^test4', {'sub1', 'subsub1'}), 'subsub2')
  asserteq(_yottadb.subscript_next('^test4', {'sub1', 'subsub2'}), 'subsub3')
  asserteq(_yottadb.subscript_next('^test4', {'sub3', 'subsub3'}), nil)

  -- Test subscripts that include a non-UTF8 character
  asserteq(_yottadb.subscript_next('^test7', {''}), 'sub1\128')
  asserteq(_yottadb.subscript_next('^test7', {'sub1\128'}), 'sub2\128')
  asserteq(_yottadb.subscript_next('^test7', {'sub2\128'}), 'sub3\128')
  asserteq(_yottadb.subscript_next('^test7', {'sub3\128'}), 'sub4\128')
  asserteq(_yottadb.subscript_next('^test7', {'sub4\128'}), nil)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.subscript_next)
  validate_subsarray_inputs(_yottadb.subscript_next)
end

function test_subscript_next_long()
  _yottadb.set('testLongSubscript', {string.rep('a', _yottadb.YDB_MAX_STR)}, 'toolong')
  asserteq(_yottadb.subscript_next('testLongSubscript', {''}), string.rep('a', _yottadb.YDB_MAX_STR))
end

function test_subscript_next_i18n()
  _yottadb.set('testi18n', {'中文'}, 'chinese')
  asserteq(_yottadb.subscript_next('testi18n', {''}), '中文')
end

function test_subscript_previous()
  simple_data()
  asserteq(_yottadb.subscript_previous('^z'), '^test7')
  asserteq(_yottadb.subscript_previous('^a'), '^Test5')
  asserteq(_yottadb.subscript_previous('^test1'), '^Test5')
  asserteq(_yottadb.subscript_previous('^test2'), '^test1')
  asserteq(_yottadb.subscript_previous('^test3'), '^test2')
  asserteq(_yottadb.subscript_previous('^test4'), '^test3')
  asserteq(_yottadb.subscript_previous('^Test5'), nil)

  asserteq(_yottadb.subscript_previous('^test4', {''}), 'sub3')
  asserteq(_yottadb.subscript_previous('^test4', {'sub2'}), 'sub1')
  asserteq(_yottadb.subscript_previous('^test4', {'sub3'}), 'sub2')
  asserteq(_yottadb.subscript_previous('^test4', {'sub1'}), nil)

  asserteq(_yottadb.subscript_previous('^test4', {'sub1', ''}), 'subsub3')
  asserteq(_yottadb.subscript_previous('^test4', {'sub1', 'subsub2'}), 'subsub1')
  asserteq(_yottadb.subscript_previous('^test4', {'sub1', 'subsub3'}), 'subsub2')
  asserteq(_yottadb.subscript_previous('^test4', {'sub3', 'subsub1'}), nil)

  -- Validate inputs.
  validate_varname_inputs(_yottadb.subscript_previous)
  validate_subsarray_inputs(_yottadb.subscript_previous)
end

function test_subscript_previous_long()
  _yottadb.set('testLongSubscript', {string.rep('a', _yottadb.YDB_MAX_STR)}, 'toolong')
  asserteq(_yottadb.subscript_previous('testLongSubscript', {''}), string.rep('a', _yottadb.YDB_MAX_STR))
end

function test_node_next()
  simple_data()
  asserteq(_yottadb.node_next('^test3')[1], 'sub1')
  local node = _yottadb.node_next('^test3', {'sub1'})
  asserteq(#node, 2)
  asserteq(node[1], 'sub1')
  asserteq(node[2], 'sub2')
  asserteq(_yottadb.node_next('^test3', {'sub1', 'sub2'}), nil)
  node = _yottadb.node_next('^test6')
  asserteq(#node, 2)
  asserteq(node[1], 'sub6')
  asserteq(node[2], 'subsub6')

  -- Validate inputs.
  validate_varname_inputs(_yottadb.node_next)
  validate_subsarray_inputs(_yottadb.node_next)
end

function test_node_next_many_subscripts()
  local subs = {'sub1', 'sub2', 'sub3', 'sub4', 'sub5', 'sub6'}
  _yottadb.set('testmanysubscripts', subs, '123')
  local node = _yottadb.node_next('testmanysubscripts')
  asserteq(#node, #subs)
  for i = 1, #subs do asserteq(node[i], subs[i]) end
end

function test_node_next_long_subscripts()
  _yottadb.set('testlong', {string.rep('a', 1025), string.rep('a', 1026)}, '123')
  local node = _yottadb.node_next('testlong')
  asserteq(#node, 2)
  asserteq(node[1], string.rep('a', 1025))
  asserteq(node[2], string.rep('a', 1026))
end

function test_node_previous()
  simple_data()
  asserteq(_yottadb.node_previous('^test3'), nil)
  local node = _yottadb.node_previous('^test3', {'sub1'})
  asserteq(#node, 0)
  node = _yottadb.node_previous('^test3', {'sub1', 'sub2'})
  asserteq(#node, 1)
  asserteq(node[1], 'sub1')

  -- Validate inputs.
  validate_varname_inputs(_yottadb.node_previous)
  validate_subsarray_inputs(_yottadb.node_previous)
end

function test_node_previous_long_subscripts()
  local a1025 = string.rep('a', 1025)
  local a1026 = string.rep('a', 1026)
  _yottadb.set('testlong', {a1025, a1026}, '123')
  _yottadb.set('testlong', {a1025, a1026, 'a'}, '123')
  local node = _yottadb.node_previous('testlong', {a1025, a1026, 'a'})
  asserteq(#node, 2)
  asserteq(node[1], a1025)
  asserteq(node[2], a1026)
end

function test_delete_excl()
  _yottadb.set('testdeleteexcl1', '1')
  _yottadb.set('testdeleteexcl2', {'sub1'}, '2')
  _yottadb.set('testdeleteexclexception', {'sub1'}, '3')
  _yottadb.delete_excl({'testdeleteexclexception'})
  asserteq(_yottadb.get('testdeleteexcl1'), nil)
  asserteq(_yottadb.get('testdeleteexcl2', {'sub1'}), nil)
  asserteq(_yottadb.get('testdeleteexclexception', {'sub1'}), '3')

  -- Validate inputs.
  local ok, e = pcall(_yottadb.delete_excl, true)
  assert(not ok)
  assert(e:find('table of varnames expected'))

  ok, e = pcall(_yottadb.delete_excl, {true})
  assert(not ok)
  assert(e:find('varnames must be strings'))

  local names = {}
  for i = 1, _yottadb.YDB_MAX_NAMES do names[i] = 'test' .. i end
  ok, e = pcall(_yottadb.delete_excl, names)
  assert(ok)

  names[#names + 1] = 'test' .. (#names + 1)
  ok, e = pcall(_yottadb.delete_excl, names)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_NAMECOUNT2HI)

  ok, e = pcall(_yottadb.delete_excl, {string.rep('b', _yottadb.YDB_MAX_IDENT)})
  assert(ok)

  ok, e = pcall(_yottadb.delete_excl, {string.rep('b', _yottadb.YDB_MAX_IDENT + 1)})
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_VARNAME2LONG)
end

-- Initial, increment, result.
local increment_tests_all = {  -- tests for all Lua versions
  -- string input tests
  {'0', '1', '1'},
  {'0', '1E1', '10'},
  {'0', '1E16', '1' .. string.rep('0', 16)},
  {'0', string.rep('9', 6), string.rep('9', 6)},
  {'0', string.rep('9', 7) .. 'E0', string.rep('9', 7)},
  {'0', string.rep('9', 6) .. 'E1', string.rep('9', 6) .. '0'},
  {'0', string.rep('9', 18) .. 'E0', string.rep('9', 18)},
  {'9999998', '1', string.rep('9', 7)},
  {'999999999999999998', '1', string.rep('9', 18)},
  {'999999999999888888', '111111', string.rep('9', 18)},
  {'999999999998888888', '1111111', string.rep('9', 18)},
  {'999999999990000000', '9999999', string.rep('9', 18)},
  {'1', '-1234567', '-1234566'},
  {'0', '1234567E40', '1234567' .. string.rep('0', 40)},
  {'0', '1234567E-43', '.' .. string.rep('0', 36) .. '1234567'},
  {'0', '123456789123456789E-43', '.' .. string.rep('0', 25) .. '123456789123456789'},
  {'0', '123456789123456789E29', '123456789123456789' .. string.rep('0', 29)},
  {'0', '1234567', '1234567'},
  {'0', '-1234567', '-1234567'},
  {'0', '100.0001', '100.0001'},
  {'0', '1' .. string.rep('0', 6), '1' .. string.rep('0', 6)},
  {'0', string.rep('1', 7), string.rep('1', 7)},
  {'0', string.rep('9', 7), string.rep('9', 7)},
  {'0', string.rep('9', 6) .. '0', string.rep('9', 6) .. '0'},
  {'0', '100.001', '100.001'},
  {'1', '100.0001', '101.0001'},
  {'1', string.rep('9', 18), '1' .. string.rep('0', 18)},
  {'0', '-1234567E0', '-1234567'},
  {'1', string.rep('9', 6) .. '8', string.rep('9', 7)},
  {'1', string.rep('9', 6) .. '0', string.rep('9', 6) .. '1'},
  {'0', '1E-43', '.' .. string.rep('0', 42) .. '1'},
  {'0', '.1E47', '1' .. string.rep('0', 46)}, -- max magnitude
  {'0', '-.1E47', '-1' .. string.rep('0', 46)}, -- max magnitude
  {'0', '1E-43', '.' .. string.rep('0', 42) .. '1'}, -- min magnitude
  {'0', '-1E-43', '-.' .. string.rep('0', 42) .. '1'}, -- min magnitude
  -- int input tests
  {'0', 1, '1'},
  {'0', 10, '10'},
  {'9999998', 1, string.rep('9', 7)},
  {'999999999999999998', 1, string.rep('9', 18)},
  {'999999999999888888', 111111, string.rep('9', 18)},
  {'999999999998888888', 1111111, string.rep('9', 18)},
  {'999999999990000000', 9999999, string.rep('9', 18)},
  {'1', -1234567, '-1234566'},
  {'0', 10000000000000000000000000000000000000000000000, '1' .. string.rep('0', 46)}, -- max int magnitude
  {'0', -10000000000000000000000000000000000000000000000, '-1' .. string.rep('0', 46)}, -- max int magnitude
  -- float input tests
  {'0', 1.0, '1'},
  {'0', 0.1, '.1'},
  {'0', 1e1, '10'},
  {'0', 1e16, '1' .. string.rep('0', 16)},
  {'0', 1e-43, '.' .. string.rep('0', 42) .. '1'}, -- max float magnitude
  {'0', -1e-43, '-.' .. string.rep('0', 42) .. '1'}, -- max float magnitude
  {'0', 0.1e47, '1' .. string.rep('0', 46)}, -- min float magnitude
  {'0', -0.1e47, '-1' .. string.rep('0', 46)}, -- min float magnitude
}

local increment_tests_5_3 = { -- tests for Lua >=5.3
  {'1', 999999999999999998, string.rep('9', 18)}, -- 18 significant digits
  {'0', 999999999999999999, string.rep('9', 18)}, -- 18 significant digits
  {'-1', -999999999999999998, '-' .. string.rep('9', 18)}, -- 18 significant digits
  {'0', -999999999999999999, '-' .. string.rep('9', 18)}, -- 18 significant digits
}

local increment_keys = {
  {'testincrparametrized'},
  {'^testincrparametrized'},
  {'^testincrparametrized', {'sub1'}},
  {'testincrparametrized', {'sub1'}},
}

local function number_to_string(number)
  return type(number) ~= 'string' and tostring(number):upper():gsub('%+', '') or number
end

function _test_incr(increment_tests, name)
  for i = 1, #increment_keys do
    local key = increment_keys[i]
    for j = 1, #increment_tests do
      setup('test_incr_' .. name .. tostring(i) .. '_' .. tostring(j))
      local t = increment_tests[j]
      local initial, increment, result = t[1], t[2], t[3]
      local args = {table.unpack(key)}
      args[#args + 1] = initial
      _yottadb.set(table.unpack(args))
      args[#args] = number_to_string(increment)
      local retval = _yottadb.incr(table.unpack(args))
      asserteq(retval, result)
      asserteq(_yottadb.get(table.unpack(key)), result)
      args[#args] = _yottadb.YDB_DEL_TREE
      _yottadb.delete(table.unpack(args))
      teardown()
    end
  end

  -- Validate inputs.
  validate_varname_inputs(_yottadb.incr)
  validate_subsarray_inputs(_yottadb.incr)

  local ok, e = pcall(_yottadb.incr, 'test', {'b'}, true)
  assert(not ok)
  assert(e:find('string expected'))

  ok, e = pcall(_yottadb.incr, 'test', {'b'}, string.rep('1', _yottadb.YDB_MAX_STR + 1))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_NUMOFLOW)
end

function test_incr()
  _test_incr(increment_tests_all, 'all')
  if lua_version >= 5.3 then
    _test_incr(increment_tests_5_3, '5.3')
  end
end

function test_incr_errors()
  _yottadb.set('testincrparametrized', '0')
  local ok, e = pcall(_yottadb.incr, 'testincrparametrized', '1E47')
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_NUMOFLOW)
  ok, e = pcall(_yottadb.incr, 'testincrparametrized', '-1E47')
  assert(not ok)
  asserteq(yottadb.get_error_code(e), _yottadb.YDB_ERR_NUMOFLOW)
end

-- Input, output1, output2.
local str2zwr_tests = {
  {"X\0ABC", '"X"_$C(0)_"ABC"', '"X"_$C(0)_"ABC"'},
  {
    "你好世界",
    '"\228\189\160\229\165\189\228\184"_$C(150)_"\231"_$C(149,140)',
    '"\228\189\160\229\165\189\228\184\150\231\149\140"',
  },
}

function test_str2zwr()
  for i = 1, #str2zwr_tests do
    local t = str2zwr_tests[i]
    local input, output1, output2 = t[1], t[2], t[3]
    asserteq(_yottadb.str2zwr(input), (os.getenv('ydb_chset') == 'UTF-8' and output2 or output1))
  end

  -- Validate inputs.
  local ok, e = pcall(_yottadb.str2zwr, true)
  assert(not ok)
  assert(e:find('string expected'))

  ok, e = pcall(_yottadb.str2zwr, string.rep('b', _yottadb.YDB_MAX_STR - 2)) -- return is quoted
  assert(ok)

  ok, e = pcall(_yottadb.str2zwr, string.rep('b', _yottadb.YDB_MAX_STR - 1))
  assert(not ok)
  assert(yottadb.get_error_code(e) ~= _yottadb.YDB_OK)
end

function test_zwr2str()
  for i = 1, #str2zwr_tests do
    local t = str2zwr_tests[i]
    local input, output = t[3], t[1]
    asserteq(_yottadb.zwr2str(input), output)
  end

  -- Validate inputs.
  local ok, e = pcall(_yottadb.zwr2str, true)
  assert(not ok)
  assert(e:find('string expected'))

  ok, e = pcall(_yottadb.zwr2str, string.rep('b', _yottadb.YDB_MAX_STR))
  assert(ok)

  --ok, e = pcall(_yottadb.zwr2str, string.rep('b', _yottadb.YDB_MAX_STR + 1))
  --assert(ok)
  --assert(yottadb.get_error_code(e) ~= _yottadb.YDB_OK)
end

function test_get_error_code()
  -- if user is using strict.lua, allow the following pcall to work without creating an error
  local mt = getmetatable(_G)
  setmetatable(_G, nil)
  -- capture error code
  local ok, e = pcall(f_does_not_exist)
  assert(not ok)
  local code = yottadb.get_error_code(e)
  asserteq(code, nil)
  -- restore _G metatable
  setmetatable(_G, mt)
end

function test_module_node_next()
  simple_data()
  local node_subs = yottadb.node_next('^test3')
  asserteq(table.concat(node_subs), 'sub1')
  node_subs = yottadb.node_next('^test3', {'sub1'})
  asserteq(table.concat(node_subs), table.concat({'sub1', 'sub2'}))
  node_subs = yottadb.node_next('^test3', {'sub1', 'sub2'})
  assert(not node_subs)
  node_subs = yottadb.node_next('^test6')
  asserteq(table.concat(node_subs), table.concat({'sub6', 'subsub6'}))

  local all_subs = {}
  for i = 1, 5 do
    all_subs[#all_subs + 1] = 'sub' .. i
    yottadb.set('mylocal', all_subs, 'val' .. i)
  end
  node_subs = yottadb.node_next('mylocal')
  local num_subs = 1
  asserteq(table.concat(node_subs), 'sub1')
  while true do
    num_subs = num_subs + 1
    node_subs = yottadb.node_next('mylocal', node_subs)
    if not node_subs then break end
    assert(table.concat(all_subs):find(table.concat(node_subs), 1, true)) -- is subset
    asserteq(#node_subs, num_subs)
  end
end

function test_module_node_previous()
  simple_data()
  local node_subs = yottadb.node_previous('^test3')
  assert(not node_subs)
  node_subs = yottadb.node_previous('^test3', {'sub1'})
  asserteq(#node_subs, 0)
  node_subs = yottadb.node_previous('^test3', {'sub1', 'sub2'})
  asserteq(table.concat(node_subs), 'sub1')

  local all_subs = {}
  for i = 1, 5 do
    all_subs[#all_subs + 1] = 'sub' .. i
    yottadb.set('mylocal', all_subs, 'val' .. i)
  end
  node_subs = yottadb.node_previous('mylocal', all_subs)
  local num_subs = 4
  asserteq(table.concat(node_subs), table.concat({'sub1', 'sub2', 'sub3', 'sub4'}))
  while true do
    num_subs = num_subs - 1
    node_subs = yottadb.node_previous('mylocal', node_subs)
    if not node_subs then break end
    assert(table.concat(all_subs):find(table.concat(node_subs))) -- is subset
    asserteq(#node_subs, num_subs)
  end
end

function test_module_subscript_next()
  simple_data()
  asserteq(yottadb.subscript_next('^test1'), '^test2')
  asserteq(yottadb.subscript_next('^test2'), '^test3')
  asserteq(yottadb.subscript_next('^test3'), '^test4')
  assert(not yottadb.subscript_next('^test7'))

  local subscript = yottadb.subscript_next('^test4', {''})
  local count = 1
  asserteq(subscript, 'sub' .. count)
  while true do
    count = count + 1
    subscript = yottadb.subscript_next('^test4', {subscript})
    if not subscript then break end
    asserteq(subscript, 'sub' .. count)
  end

  asserteq(yottadb.subscript_next('^test4', {'sub1', ''}), 'subsub1')
  asserteq(yottadb.subscript_next('^test4', {'sub1', 'subsub1'}), 'subsub2')
  asserteq(yottadb.subscript_next('^test4', {'sub1', 'subsub2'}), 'subsub3')
  assert(not yottadb.subscript_next('^test4', {'sub3', 'subsub3'}))

  asserteq(yottadb.subscript_next('^test7', {''}), 'sub1\128')
  asserteq(yottadb.subscript_next('^test7', {'sub1\128'}), 'sub2\128')
  asserteq(yottadb.subscript_next('^test7', {'sub2\128'}), 'sub3\128')
  asserteq(yottadb.subscript_next('^test7', {'sub3\128'}), 'sub4\128')
  assert(not yottadb.subscript_next('^test7', {'sub4\128'}))
end

function test_module_subscript_previous()
  simple_data()
  asserteq(yottadb.subscript_previous('^test1'), '^Test5')
  asserteq(yottadb.subscript_previous('^test2'), '^test1')
  asserteq(yottadb.subscript_previous('^test3'), '^test2')
  asserteq(yottadb.subscript_previous('^test4'), '^test3')
  assert(not yottadb.subscript_previous('^Test5'))

  local subscript = yottadb.subscript_previous('^test4', {''})
  local count = 3
  asserteq(subscript, 'sub' .. count)
  while true do
    count = count - 1
    subscript = yottadb.subscript_previous('^test4', {subscript})
    if not subscript then break end
    asserteq(subscript, 'sub' .. count)
  end

  asserteq(yottadb.subscript_previous('^test4', {'sub1', ''}), 'subsub3')
  asserteq(yottadb.subscript_previous('^test4', {'sub1', 'subsub2'}), 'subsub1')
  asserteq(yottadb.subscript_previous('^test4', {'sub1', 'subsub3'}), 'subsub2')
  assert(not yottadb.subscript_previous('^test4', {'sub3', 'subsub1'}))

  asserteq(yottadb.subscript_previous('^test7', {''}), 'sub4\128')
  asserteq(yottadb.subscript_previous('^test7', {'sub4\128'}), 'sub3\128')
  asserteq(yottadb.subscript_previous('^test7', {'sub3\128'}), 'sub2\128')
  asserteq(yottadb.subscript_previous('^test7', {'sub2\128'}), 'sub1\128')
  assert(not yottadb.subscript_previous('^test7', {'sub1\128'}))
end

function test_module_subscripts()
  simple_data()
  local subs = {'sub1', 'sub2', 'sub3'}

  local i = 1
  for subscript in yottadb.subscripts('^test4', {''}) do
    asserteq(subscript, subs[i])
    i = i + 1
  end

  i = 2
  for subscript in yottadb.subscripts('^test4', {'sub1'}) do
    asserteq(subscript, subs[i])
    i = i + 1
  end

  local rsubs = {}
  for i = 1, #subs do rsubs[i] = subs[#subs + 1 - i] end

  i = 1
  for subscript in yottadb.subscripts('^test4', {''}, true) do
    asserteq(subscript, rsubs[i])
    i = i + 1
  end

  i = 2
  for subscript in yottadb.subscripts('^test4', {'sub3'}, true) do
    asserteq(subscript, rsubs[i])
    i = i + 1
  end

  local varnames = {'^Test5', '^test1', '^test2', '^test3', '^test4', '^test6', '^test7'}
  i = 1
  for subscript in yottadb.subscripts('^%') do
    asserteq(subscript, varnames[i])
    i = i + 1
  end
  asserteq(#varnames, i - 1)

  local rvarnames = {}
  for i = 1, #varnames do rvarnames[i] = varnames[#varnames + 1 - i] end

  i = 1
  for subscript in yottadb.subscripts('^z', true) do
    asserteq(subscript, rvarnames[i])
    i = i + 1
  end
  asserteq(#rvarnames, i - 1)

  local ok, e = pcall(yottadb.subscripts(string.rep('a', yottadb.YDB_MAX_IDENT + 1)))
  assert(not ok)
  assert(e:find("name length exceeds"))

  ok, e = pcall(yottadb.subscripts('\128'))
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)
end

function test_module_lock()
  -- Validate inputs.
  local ok, e = pcall(yottadb.lock, true)
  assert(not ok)
  assert(e:find('table') and e:find('number') and e:find('nil') and e:find(' expected'))

  ok, e = pcall(yottadb.lock, {true})
  assert(not ok)
  assert(e:find('table expected'))
end

function test_key()
  local tostr = _yottadb.cachearray_tostring
  simple_data()

  local key = yottadb.key('^test1')
  asserteq(key.__varname, '^test1')
  asserteq(key.__depth, 0)
  asserteq(key.name, '^test1')
  asserteq(key.value, 'test1value')

  key = yottadb.key('^test2')('sub1')
  asserteq(key.__varname, '^test2')
  asserteq(#key.__subsarray, 1)
  asserteq(key.__subsarray[1], 'sub1')
  asserteq(key.name, 'sub1')
  asserteq(key.value, 'test2value')
  asserteq(key, yottadb.key('^test2')('sub1'))

  key = yottadb.key('test3local')('sub1')
  key.value = 'smoketest3local'
  asserteq(rawget(key, 'value'), nil)
  asserteq(key.value, 'smoketest3local')

  key = yottadb.key('^nonexistent')
  asserteq(key.value, nil)
  key = yottadb.key('nonexistent')
  asserteq(key.value, nil)

  key = yottadb.key('localincr')
  asserteq(key:incr(), '1')
  asserteq(key:incr(-1), '0')
  asserteq(key:incr('2'), '2')
  asserteq(key:incr('testeroni'), '2') -- unchanged
  local ok, e = pcall(key.incr, key, true)
  assert(not ok)
  assert(e:find('string') and e:find('number') and e:find('nil') and e:find(' expected'))

  key = yottadb.key('testeroni')('sub1')
  local key_copy = yottadb.key('testeroni')('sub1')
  local key2 = yottadb.key('testeroni')('sub2')
  asserteq(key, key_copy)
  assert(key ~= key2)

  key = yottadb.key('iadd')
  key = key + 1
  asserteq(tonumber(key.value), 1)
  key = key - 1
  asserteq(tonumber(key.value), 0)
  key = key + '2'
  asserteq(tonumber(key.value), 2)
  key = key - '3'
  asserteq(tonumber(key.value), -1)
  key = key + 0.5
  asserteq(tonumber(key.value), -0.5)
  key = key - -1.5
  asserteq(tonumber(key.value), 1)
  key = key + 'testeroni'
  asserteq(tonumber(key.value), 1) -- unchanged
  ok, e = pcall(function() key = key + {} end)
  assert(not ok)
  assert(e:find('string') and e:find('number') and e:find(' expected'))

  -- Validate input.
  ok, e = pcall(yottadb.key, 1)
  assert(not ok)
  assert(e:find('string expected'))
  ok, e = pcall(yottadb.key, '^test1', 'not a key object')
  assert(not ok)
  assert(e:find('table') and e:find('nil') and e:find(' expected'))
  -- TODO: error subscripting ISV
  -- TODO: error creating more than YDB_MAX_SUBS subscripts

  -- String output.
  asserteq(tostring(yottadb.key('test')), 'test')
  asserteq(tostring(yottadb.key('test')('sub1')), 'test("sub1")')
  asserteq(tostring(yottadb.key('test')('sub1')('sub2')), 'test("sub1","sub2")')

  -- Get values.
  asserteq(yottadb.key('^test1').value, 'test1value')
  asserteq(yottadb.key('^test2')('sub1').value, 'test2value')
  asserteq(yottadb.key('^test3').value, 'test3value1')
  asserteq(yottadb.key('^test3')('sub1').value, 'test3value2')
  asserteq(yottadb.key('^test3')('sub1')('sub2').value, 'test3value3')

  -- Subsarray.
  asserteq(#yottadb.key('^test3').__subsarray, 0)
  local subsarray = yottadb.key('^test3')('sub1').__subsarray
  asserteq(#subsarray, 1)
  asserteq(subsarray[1], 'sub1')
  local subsarray = yottadb.key('^test3')('sub1')('sub2').__subsarray
  asserteq(#subsarray, 2)
  asserteq(subsarray[1], 'sub1')
  asserteq(subsarray[2], 'sub2')
  for subscript in yottadb.key('^test3'):subscripts() do end -- confirm no error

  -- Varname.
  asserteq(yottadb.key('^test3').__varname, '^test3')
  asserteq(yottadb.key('^test3')('sub1').__varname, '^test3')
  asserteq(yottadb.key('^test3')('sub1')('sub2').__varname, '^test3')

  -- Data.
  asserteq(yottadb.key('nodata').data, yottadb.YDB_DATA_UNDEF)
  asserteq(yottadb.key('^test1').data, yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(yottadb.key('^test2').data, yottadb.YDB_DATA_NOVALUE_DESC)
  asserteq(yottadb.key('^test2')('sub1').data, yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(yottadb.key('^test3').data, yottadb.YDB_DATA_VALUE_DESC)
  asserteq(yottadb.key('^test3')('sub1').data, yottadb.YDB_DATA_VALUE_DESC)
  asserteq(yottadb.key('^test3')('sub1')('sub2').data, yottadb.YDB_DATA_VALUE_NODESC)
  ok, e = pcall(function() return yottadb.key('\128').data end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Has value.
  assert(not yottadb.key('nodata').has_value)
  assert(yottadb.key('^test1').has_value)
  assert(not yottadb.key('^test2').has_value)
  assert(yottadb.key('^test2')('sub1').has_value)
  assert(yottadb.key('^test3').has_value)
  assert(yottadb.key('^test3')('sub1').has_value)
  assert(yottadb.key('^test3')('sub1')('sub2').has_value)
  ok, e = pcall(function() return yottadb.key('\128').has_value end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Has tree.
  assert(not yottadb.key('nodata').has_tree)
  assert(not yottadb.key('^test1').has_tree)
  assert(yottadb.key('^test2').has_tree)
  assert(not yottadb.key('^test2')('sub1').has_tree)
  assert(yottadb.key('^test3').has_tree)
  assert(yottadb.key('^test3')('sub1').has_tree)
  assert(not yottadb.key('^test3')('sub1')('sub2').has_tree)
  ok, e = pcall(function() return yottadb.key('\128').has_tree end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Subscript next.
  key = yottadb.key('testsubsnext')
  key('sub1').value = '1'
  key('sub2').value = '2'
  key('sub3').value = '3'
  key('sub4').value = '4'
  asserteq(key:subscript_next(), 'sub1')
  asserteq(key:subscript_next(), 'sub2')
  asserteq(key:subscript_next(), 'sub3')
  asserteq(key:subscript_next(), 'sub4')
  assert(not key:subscript_next())
  asserteq(key:subscript_next(true), 'sub1')
  asserteq(key:subscript_next(), 'sub2')
  asserteq(key:subscript_next(), 'sub3')
  asserteq(key:subscript_next(), 'sub4')
  ok, e = pcall(function() yottadb.key('^\128'):subscript_next() end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Subscript previous.
  key = yottadb.key('testsubsprev')
  key('sub1').value = '1'
  key('sub2').value = '2'
  key('sub3').value = '3'
  key('sub4').value = '4'
  asserteq(key:subscript_previous(), 'sub4')
  asserteq(key:subscript_previous(), 'sub3')
  asserteq(key:subscript_next(), 'sub4') -- confirm capatibility with subscript_next
  asserteq(key:subscript_previous(), 'sub3')
  asserteq(key:subscript_previous(), 'sub2')
  asserteq(key:subscript_previous(), 'sub1')
  assert(not key:subscript_previous())
  asserteq(key:subscript_previous(true), 'sub4')
  asserteq(key:subscript_previous(), 'sub3')
  asserteq(key:subscript_previous(), 'sub2')
  asserteq(key:subscript_previous(), 'sub1')
  ok, e = pcall(function() yottadb.key('^\128'):subscript_previous() end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)
end

function test_key_set()
  local testkey = yottadb.key('test4')
  testkey.value = 'test4value'
  asserteq(testkey:get(), 'test4value')

  testkey = yottadb.key('test5')('sub1')
  testkey:set('test5value')
  asserteq(testkey.value, 'test5value')
  asserteq(yottadb.key('test5')('sub1').value, 'test5value')
end

function test_key_delete()
  local testkey = yottadb.key('test6')
  local subkey = testkey('sub1')
  testkey.value = 'test6value'
  subkey.value = 'test6 subvalue'
  asserteq(testkey:get(), 'test6value')
  asserteq(subkey:get(), 'test6 subvalue')
  testkey:delete_node()
  assert(not testkey.value)
  asserteq(subkey:get(), 'test6 subvalue')

  testkey = yottadb.key('test7')
  subkey = testkey('sub1')
  testkey.value = 'test7value'
  subkey.value = 'test7 subvalue'
  subkey:delete_tree()
  asserteq(testkey:get(), 'test7value')
  assert(not subkey.value)
  subkey.value = 'test7 subvalue'
  asserteq(testkey:get(), 'test7value')
  asserteq(subkey:get(), 'test7 subvalue')
  testkey:delete_tree()
  assert(not testkey.value)
  assert(not subkey.value)
  asserteq(testkey.data, 0)
end

function test_key_lock()
  local key = yottadb.key('test1')('sub1')('sub2')
  local t1 = os.clock()
  key:lock_incr()
  local t2 = os.clock()
  assert(t2 - t1 < 0.1)
  key:lock_decr()
end

function test_integer_subscripts()
  local node = yottadb.node('test20')(1)('abc')(2)
  asserteq(node, yottadb.node('test20')('1')('abc')('2'))
  yottadb.set('test20', {2}, 'asdf')
  asserteq(yottadb.get('test20', {'2'}), 'asdf')
end

function test_node_features()
  local node = yottadb.node('test21', {'abc', 'def'})
  asserteq(node, yottadb.node('test21').abc.def)

  node = yottadb.node('test20', 1, 'abc', 2)
  asserteq(node, yottadb.node('test20', '1', 'abc', '2'))
  asserteq(node, yottadb.node('test20')(1)('abc')(2))
end

function test_node()
  simple_data()

  local node = yottadb.node('^test1')
  asserteq(node:__varname(), '^test1')
  asserteq(#node:__subsarray(), 0)
  asserteq(node:name(), '^test1')
  asserteq(node:get(), 'test1value')
  asserteq(node:__get(), 'test1value')

  node = yottadb.node('^test2', 'sub1')
  asserteq(node:__varname(), '^test2')
  asserteq(#node:__subsarray(), 1)
  asserteq(node:__subsarray()[1], 'sub1')
  asserteq(node:name(), 'sub1')
  asserteq(node:get(), 'test2value')
  asserteq(node, yottadb.node('^test2')('sub1'))

  node = yottadb.node(node, 'sub2') -- append subscript to existing node
  asserteq(#node:__subsarray(), 2)
  asserteq(tostring(node), '^test2("sub1","sub2")')
  local newnode = yottadb.node(node)  -- make sure new node re-uses the same cachearray
  assert(node.__cachearray == newnode.__cachearray)
  rawset(node, '__mutable', true)
  local newnode = yottadb.node(node)
  assert(node == newnode)  -- varname/subscripts should be the same
  assert(node.__cachearray ~= newnode.__cachearray)  -- make sure we get new immutable copy of cachearray

  -- Ensure node does not respond to the old key properties
  node = yottadb.node('^test2', 'sub1')
  asserteq(node.varname, node('varname'))
  asserteq(#node.subsarray, 0)
  asserteq(node.name, node('name'))
  asserteq(node.value, node('value'))
  asserteq(node, yottadb.node('^test2').sub1)

  node = yottadb.node('test3local', 'sub1')
  asserteq(node:get('test'), 'test')
  node.__ = 'smoketest3local'
  asserteq(rawget(node, '_'), nil)
  asserteq(node:get(), 'smoketest3local')

  node = yottadb.node('test3local', 'sub1')
  node.__ = 'smoketest4local'
  asserteq(rawget(node, '_'), nil)

  node = yottadb.node('^nonexistent')
  asserteq(node:get(), nil)
  node = yottadb.node('nonexistent')
  asserteq(node:get(), nil)

  node = yottadb.node('nodeincr')
  asserteq(node:incr(), '1')
  asserteq(node:incr(-1), '0')
  asserteq(node:incr('2'), '2')
  asserteq(node:incr('testeroni'), '2') -- unchanged
  local ok, e = pcall(node.incr, node, true)
  assert(not ok, e)
  assert(e:find('string') and e:find('number') and e:find('nil') and e:find(' expected'))

  node = yottadb.node('testeroni', 'sub1')
  local node_copy = yottadb.node('testeroni').sub1
  local node2 = yottadb.node('testeroni').sub2
  asserteq(node, node_copy)
  assert(node ~= node2)

  node = yottadb.node('iaddnode')
  node = node + 1
  asserteq(tonumber(node.__), 1)
  node = node - 1
  asserteq(tonumber(node.__), 0)
  node = node + '2'
  asserteq(tonumber(node.__), 2)
  node = node - '3'
  asserteq(tonumber(node.__), -1)
  node = node + 0.5
  asserteq(tonumber(node.__), -0.5)
  node = node - -1.5
  asserteq(tonumber(node.__), 1)
  node = node + 'testeroni'
  asserteq(tonumber(node.__), 1) -- unchanged
  ok, e = pcall(function() node = node + {} end)
  assert(not ok)
  assert(e:find('string') and e:find('number') and e:find(' expected'))

  -- Validate input.
  ok, e = pcall(yottadb.node, 1)
  assert(not ok)
  assert(e:find('attempt to index') and e:find('a number value'))
  -- TODO: error subscripting ISV
  -- TODO: error creating more than YDB_MAX_SUBS subscripts

  -- String output.
  asserteq(tostring(yottadb.node('test')), 'test')
  asserteq(tostring(yottadb.node('test', 'sub1')), 'test("sub1")')
  asserteq(tostring(yottadb.node('test')('sub1')('sub2')), 'test("sub1","sub2")')

  -- Get values.
  asserteq(yottadb.node('^test1').__, 'test1value')
  asserteq(yottadb.node('^test2', 'sub1').__, 'test2value')
  asserteq(yottadb.node('^test3').__, 'test3value1')
  asserteq(yottadb.node('^test3', 'sub1').__, 'test3value2')
  asserteq(yottadb.node('^test3', 'sub1', 'sub2').__, 'test3value3')

  -- Subsarray.
  asserteq(#yottadb.node('^test3'):__subsarray(), 0)
  local subsarray = yottadb.node('^test3').sub1:__subsarray()
  asserteq(#subsarray, 1)
  asserteq(subsarray[1], 'sub1')
  local subsarray = yottadb.node('^test3', 'sub1', 'sub2'):__subsarray()
  asserteq(#subsarray, 2)
  asserteq(subsarray[1], 'sub1')
  asserteq(subsarray[2], 'sub2')

  -- Varname.
  asserteq(yottadb.node('^test3'):varname(), '^test3')
  asserteq(yottadb.node('^test3', 'sub1'):__varname(), '^test3')
  asserteq(yottadb.node('^test3', 'sub1', 'sub2'):__varname(), '^test3')

  -- Data.
  asserteq(yottadb.node('nodata'):data(), yottadb.YDB_DATA_UNDEF)
  asserteq(yottadb.node('^test1'):data(), yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(yottadb.node('^test2'):data(), yottadb.YDB_DATA_NOVALUE_DESC)
  asserteq(yottadb.node('^test2', 'sub1'):data(), yottadb.YDB_DATA_VALUE_NODESC)
  asserteq(yottadb.node('^test3'):data(), yottadb.YDB_DATA_VALUE_DESC)
  asserteq(yottadb.node('^test3','sub1'):data(), yottadb.YDB_DATA_VALUE_DESC)
  asserteq(yottadb.node('^test3','sub1','sub2'):data(), yottadb.YDB_DATA_VALUE_NODESC)
  ok, e = pcall(function() return yottadb.node('\128'):data() end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Has value.
  assert(not yottadb.node('nodata'):has_value())
  assert(yottadb.node('^test1'):has_value())
  assert(not yottadb.node('^test2'):has_value())
  assert(yottadb.node('^test2','sub1'):has_value())
  assert(yottadb.node('^test3'):has_value())
  assert(yottadb.node('^test3','sub1'):has_value())
  assert(yottadb.node('^test3','sub1','sub2'):has_value())
  ok, e = pcall(function() return yottadb.node('\128'):has_value() end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)

  -- Has tree.
  assert(not yottadb.node('nodata'):has_tree())
  assert(not yottadb.node('^test1'):has_tree())
  assert(yottadb.node('^test2'):has_tree())
  assert(not yottadb.node('^test2','sub1'):has_tree())
  assert(yottadb.node('^test3'):has_tree())
  assert(yottadb.node('^test3','sub1'):has_tree())
  assert(not yottadb.node('^test3','sub1','sub2'):has_tree())
  ok, e = pcall(function() return yottadb.node('\128'):has_tree() end)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)
end

function test_node_set()
  local testnode = yottadb.node('test4')
  testnode.__ = 'test4value'
  asserteq(testnode:get(), 'test4value')

  testnode = yottadb.node('test5','sub1')
  testnode:set('test5value')
  asserteq(testnode.__, 'test5value')
  asserteq(yottadb.node('test5','sub1').__, 'test5value')
end

function test_node_delete()
  local testnode = yottadb.node('test6')
  local subnode = testnode('sub1')
  testnode.__ = 'test6value'
  subnode.__ = 'test6 subvalue'
  asserteq(testnode:get(), 'test6value')
  asserteq(subnode:get(), 'test6 subvalue')
  testnode.__ = nil
  assert(not testnode.__)
  asserteq(subnode:get(), 'test6 subvalue')

  testnode = yottadb.node('test7')
  subnode = testnode('sub1')
  testnode.__ = 'test7value'
  subnode.__ = 'test7 subvalue'
  asserteq(testnode:get(), 'test7value')
  asserteq(subnode:get(), 'test7 subvalue')
  testnode:delete_tree()
  assert(not testnode.__)
  assert(not subnode.__)
  asserteq(testnode:data(), 0)
end

function test_node_lock()
  local node = yottadb.node('testlock').sub1
  local command = lua_exec .. [[ -e "yottadb=require'yottadb' pcall(yottadb.lock_incr, 'testlock', 'sub1', 1)"]]
  local start, diff
  -- lock and make sure a subprocess can't access it
  node:lock_incr()
  start = os.time()
  env_execute(command)
  diff = os.difftime(os.time(), start)
  assert(diff >= 1)
  -- unlock and test again
  node:lock_decr()
  start = os.time()
  env_execute(command)
  diff = os.difftime(os.time(), start)
  if not (diff < 3) then  print("difftime=" .. diff)  end  -- help debugging next time since this is an occasional error
  assert(diff < 3)
end

function test_module_transactions()
  -- Simple transaction.
  local simple_transaction = yottadb.transaction(function(key1, value1, key2, value2, n)
    key1:set(value1)
    key2:set(value2)
    if n == 1 then
      yottadb.get('\128') -- trigger an error
    elseif n == 2 then
      local ok, e = pcall(yottadb.get, '\128')
      return assert(yottadb.get_error_code(e)) -- return a recognized error code
    else
      -- Returning nothing will return YDB_OK.
    end
  end)
  local key1, value1 = yottadb.key('^TransactionTests')('test1')('key1'), 'v1'
  local key2, value2 = yottadb.key('^TransactionTests')('test1')('key2'), 'v2'
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  -- YDB error.
  local ok, e = pcall(simple_transaction, key1, value1, key2, value2, 1)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  -- Handled and returned YDB error code.
  ok, e = pcall(simple_transaction, key1, value1, key2, value2, 2)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_ERR_INVVARNAME)
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  -- No error.
  simple_transaction(key1, value1, key2, value2, 3)
  asserteq(key1.value, value1)
  asserteq(key2.value, value2)

  yottadb.delete_tree('^TransactionTests', {'test1'})

  -- Rollback.
  local simple_rollback_transaction = yottadb.transaction(function(key1, value1, key2, value2, n)
    key1:set(value1)
    key2:set(value2)
    return yottadb.YDB_TP_ROLLBACK
  end)
  key1 = yottadb.key('^TransactionTests')('test2')('key1')
  key2 = yottadb.key('^TransactionTests')('test2')('key2')
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(simple_rollback_transaction, key1, value1, key2, value2)
  assert(not ok)
  asserteq(yottadb.get_error_code(e), yottadb.YDB_TP_ROLLBACK)
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  yottadb.delete_tree('^TransactionTests', {'test2'})

  -- Restart.
  local simple_restart_transaction = yottadb.transaction(function(key1, value1, key2, value2, trackerkey)
    if trackerkey.data == yottadb.YDB_DATA_UNDEF then
      key1:set(value1)
      trackerkey:set('1')
      return yottadb.YDB_TP_RESTART
    else
      key2:set(value2)
    end
  end)
  key1 = yottadb.key('^TransactionTests')('test3')('key1')
  key2 = yottadb.key('^TransactionTests')('test3')('key2')
  local trackerkey = yottadb.key('TransactionTests')('test3')('restart tracker')
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)
  asserteq(trackerkey.data, yottadb.YDB_DATA_UNDEF)

  simple_restart_transaction(key1, value1, key2, value2, trackerkey)
  assert(not key1.value)
  asserteq(key2.value, value2)
  asserteq(trackerkey.value, '1')

  yottadb.delete_tree('^TransactionTests', {'test3'})
  trackerkey:delete_tree()

  -- Nested.
  local nested_set_transaction = yottadb.transaction(function(...) yottadb.set(...) end)
  local simple_nested_transaction = yottadb.transaction(function(key1, value1, key2, value2)
    key1:set(value1)
    nested_set_transaction(key2.__varname, key2.__subsarray, value2)
  end)
  key1 = yottadb.key('^TransactionTests')('test4')('key1')
  key2 = yottadb.key('^TransactionTests')('test4')('key2')
  asserteq(key1.data, yottadb.YDB_DATA_UNDEF)
  asserteq(key2.data, yottadb.YDB_DATA_UNDEF)

  simple_nested_transaction(key1, value1, key2, value2)
  asserteq(key1.value, value1)
  asserteq(key2.value, value2)
  yottadb.delete_tree('^TransactionTests', {'test4'})
end

function test_pairs()
  local pairs = pairs
  -- Lua 5.1 does not support __pairs() metamethod so reference it explicitly
  if lua_version <= 5.1 then  pairs = yottadb._node.__pairs return  end
  simple_data()
  
  local test4 = yottadb.node('^test4')
  local subs = {}
  local i = 0  for subnode,value,k in pairs(test4) do  subs[k] = value  i = i+1  end
  asserteq(i, 3)
  asserteq(subs['sub1'], 'test4sub1')
  asserteq(subs['sub2'], 'test4sub2')
  asserteq(subs['sub3'], 'test4sub3')
  subs = {}
  i = 0  for subnode,value,k in pairs(test4.sub2) do  subs[k] = value  i = i+1  end
  asserteq(i, 3)
  asserteq(subs['subsub1'], 'test4sub2subsub1')
  asserteq(subs['subsub2'], 'test4sub2subsub2')
  asserteq(subs['subsub3'], 'test4sub2subsub3')
  -- check order of pairs:
  local keys = {}
  i = 0  for subnode,value,k in pairs(test4) do  keys[#keys+1] = k  i = i+1  end
  asserteq(i, 3)
  asserteq(keys[1], 'sub1')
  asserteq(keys[2], 'sub2')
  asserteq(keys[3], 'sub3')
  keys = {}
  i = 0  for subnode,value,k in test4:__pairs(true) do  keys[#keys+1] = k  i = i+1  end
  asserteq(i, 3)
  asserteq(keys[1], 'sub3')
  asserteq(keys[2], 'sub2')
  asserteq(keys[3], 'sub1')
  i = 0  for subnode,value,k in pairs(test4.sub2.test4sub2) do  i = i+1  end
  asserteq(i, 0)
  -- test pairs on a local var 'testPairsTest' that has no value
  local local_node = yottadb.node('testPairsTest')
  local_node.subfield.__ = 'junk'
  i = 0  for subnode,value,k in pairs(local_node) do  i = i+1 end
  asserteq(i, 1)
  i = 0  for subnode,value,k in pairs(local_node.subfield) do  i = i+1 end
  asserteq(i, 0)
end

local inserted_tree = {__='berwyn', [0]='null', [-1]='negative', weight=78, ['!@#$']='junk', appearance={__='handsome', eyes='blue', hair='blond'}, age=yottadb.delete}

local expected_tree_dump = [=[
test("sub1")="berwyn"
test("sub1",-1)="negative"
test("sub1",0)="null"
test("sub1","!@#$")="junk"
test("sub1","appearance")="handsome"
test("sub1","appearance","eyes")="blue"
test("sub1","appearance","hair")="blond"
test("sub1","weight")=78]=]

local expected_table_dump = [=[
  __: "handsome"
  eyes: "blue"
  hair: "blond"
!@#$: "junk"
-1: "negative"
0: "null"
__: "berwyn"
appearance (table: 0x...):
weight: "78"]=]

local expected_level0_table_dump = [=[
!@#$: "junk"
-1: "negative"
0: "null"
__: "berwyn"
appearance: "handsome"
weight: "78"]=]

function test_settree()
  -- check that an inserted_tree creates the correct node dump
  local node = yottadb.node('test', 'sub1')
  node:settree(inserted_tree)
  local tree_dump = yottadb.dump('test', 'sub1')
  asserteq(tree_dump, expected_tree_dump)
  
  -- check that a fetched table creates the correct table dump
  local t = node:gettree()
  local actual_table_dump = table_dump.dump(t, nil, nil, true)
  table.sort(actual_table_dump)
  local table_formatted = table.concat(actual_table_dump, '\n'):gsub('table: 0x%x*', 'table: 0x...')
  asserteq(table_formatted, expected_table_dump)

  -- check that get_tree() maxdepth param works
  t = node:gettree(0)
  actual_table_dump = table_dump.dump(t, nil, nil, true)
  table.sort(actual_table_dump)
  table_formatted = table.concat(actual_table_dump, '\n'):gsub('table: 0x%x*', 'table: 0x...')
  asserteq(table_formatted, expected_level0_table_dump)

  -- check that get_tree() filter param works
  local function filter(node, key, value, recurse, depth)  if key=='appearance' then value,recurse='ugly',false end  return value, recurse  end
  t = node:gettree(nil, filter)
  actual_table_dump = table_dump.dump(t, nil, nil, true)
  table.sort(actual_table_dump)
  table_formatted = table.concat(actual_table_dump, '\n'):gsub('table: 0x%x*', 'table: 0x...')
  asserteq(table_formatted, expected_level0_table_dump:gsub('handsome','ugly'))

  -- check that set_tree() filter param works
  local function filter(node, key, value)  if key=='nogarble' then key,value='_nogarble','fixed' end  return key, value  end
  node = yottadb.node('test', 'sub1')
  inserted_tree['!@#$'] = yottadb.DELETE    -- test that delete function works
  inserted_tree['nogarble'] = '!@#$'
  node:settree(inserted_tree, filter)
  local tree_dump2 = yottadb.dump('test', 'sub1')
  local expected_tree_dump2 = expected_tree_dump:gsub('%!%@%#%$', '_nogarble'):gsub('junk', 'fixed')
  asserteq(tree_dump2, expected_tree_dump2)
end

ci_table1 = [=[
  add: ydb_long_t* add^unittest(I:ydb_int_t, I:ydb_uint_t, I:ydb_long_t, I:ydb_ulong_t, I:ydb_int_t*, I:ydb_uint_t*, I:ydb_long_t*, I:ydb_ulong_t*)
  add_floats: ydb_long_t* add^unittest(I:ydb_int_t, I:ydb_uint_t, I:ydb_long_t, I:ydb_ulong_t, I:ydb_int_t*, I:ydb_uint_t*, I:ydb_float_t*, I:ydb_double_t*)
  ret_float: ydb_double_t* add^unittest(I:ydb_int_t, I:ydb_uint_t, I:ydb_long_t, I:ydb_ulong_t, I:ydb_int_t*, I:ydb_uint_t*, I:ydb_float_t*, IO:ydb_double_t*)
  concat1: ydb_string_t* concat^unittest(I:ydb_char_t*, I:ydb_string_t*, IO:ydb_char_t*, O:ydb_char_t*)
  concat2: ydb_string_t* concat^unittest(I:ydb_char_t*, I:ydb_string_t*, IO:ydb_char_t*, O:ydb_string_t*)
  concat3: ydb_string_t* concat^unittest(I:ydb_char_t*, I:ydb_string_t*, IO:ydb_string_t*, O:ydb_string_t*)
  concat4: ydb_buffer_t* concat^unittest(I:ydb_char_t*, I:ydb_buffer_t*, IO:ydb_buffer_t*, O:ydb_buffer_t*)
]=]

function test_callin()
  yottadb.set("$ZROUTINES", "tests")
  local table1 = yottadb.require(ci_table1)
  asserteq(table1.add(1,2,3,4,5,6,7,8), 36)
  asserteq(table1.add(1,2147483648,3,4,5,6,7,8), 1+2147483648+3+4+5+6+7+8)
  assert(not pcall(table1.add, 2147483648,2,3,4,5,6,7,8))
  assert(not pcall(table1.add, 1,-1,3,4,5,6,7,8))

  asserteq(table1.add_floats(1,2,3,4,5,6,7.6,8.6), 37)
  local out1, out2 = table1.ret_float(1,2,3,4,5,6,7.6,8.6)
  asserteq(out1,1+2+3+4+5+6+7.6+8.6)  asserteq(out2, 8.6)

  local alphabet = 'abcdefghijklmnopqrstuvwxyz'
  local concat = 'a\0b\0c'
  local out1, out2, out3 = table1.concat1('a','b','c', '')
  asserteq(out1, concat)  asserteq(out2, alphabet)  asserteq(out3, 'a')
  out1, out2, out3 = table1.concat2('a','b','c', '')
  asserteq(out1, concat)  asserteq(out2, alphabet)  asserteq(out3, concat)

  local expected = {true, concat, alphabet, concat}
  -- Quirk of these versions is that IO ydb_string_t* can only return max of the length of IO input.
  if ydb_release >= 1.26 and ydb_release < 1.36 then  expected = {false, _yottadb.message(_yottadb.YDB_ERR_INVSTRLEN)}  end

  local results = {pcall(table1.concat3, 'a','b','c', '')}
  asserteq(results[1], expected[1])  asserteq(results[2], expected[2])  asserteq(results[3], expected[3])  asserteq(results[4], expected[4])
  local results = {pcall(table1.concat4, 'a','b','c', '')}
  asserteq(results[1], expected[1])  asserteq(results[2], expected[2])  asserteq(results[3], expected[3])  asserteq(results[4], expected[4])
end

function test_deprecated_readme()
  -- Create key objects for conveniently accessing and manipulating database nodes.
  local key1 = yottadb.key('^hello')
  asserteq(key1.name, '^hello')
  assert(not key1.value)
  key1.value = 'Hello World' -- set '^hello' to 'Hello World!'
  asserteq(key1.value, 'Hello World')

  -- Add a 'cowboy' subscript to the global variable '^hello', creating a new key.
  local key2 = yottadb.key('^hello')('cowboy')
  key2.value = 'Howdy partner!' -- set '^hello('cowboy') to 'Howdy partner!'
  asserteq(key2.name, 'cowboy')
  asserteq(key2.value, 'Howdy partner!')

  -- Add a second subscript to '^hello', creating a third key.
  local key3 = yottadb.key('^hello')('chinese')
  key3.value = '你好世界!' -- the value can be set to anything, including UTF-8
  asserteq(key3.name, 'chinese')
  asserteq(key3.value, '你好世界!')

  assert(key1:subscripts()() ~= nil)
  local values = {[key2.name] = key2.value, [key3.name] = key3.value}

  for subscript in key1:subscripts() do -- loop through all subscripts of a key
    local sub_key = key1(subscript)
    asserteq(sub_key.name, subscript)
    asserteq(sub_key.value, values[subscript])
  end

  key1:delete_node() -- delete the value of '^hello', but not any of its child nodes

  assert(not key1.value)

  for subscript in key1:subscripts() do -- the values of the child node are still in the database
    local sub_key = key1(subscript)
    asserteq(sub_key.name, subscript)
    asserteq(sub_key.value, values[subscript])
  end

  key1.value = 'Hello World' -- reset the value of '^hello'
  asserteq(key1.value, 'Hello World')
  key1:delete_tree() -- delete both the value at the '^hello' node and all of its children
  assert(not key1.value)
  assert(not key1:subscripts()())
end

function test_signals()
  -- get PID
  local f=assert(io.open('/proc/self/stat'), 'Cannot open /proc/self/stat')
  local pid=assert(f:read('*n'), 'Cannot read PID from /proc/self/stat')
  f:close()

  -- Define function to open a pipe and read it all into a string
  local function capture(cmd)
    local f=assert(io.popen(cmd))
    local s=assert(f:read('*a'))
    f:close()
    return s
  end

  -- Define shell (sh) commands to send ourselves different signals
  local cmd1 = "kill -s CONT "..pid.." && sleep 0.1 && echo -n Complete 2>/dev/null"
  local cmd2 = "kill -s ALRM "..pid.." && sleep 0.1 && echo -n Complete 2>/dev/null"

  --first send ourselves a signal while Lua is doing slow IO
  --make sure Lua returns early without block_M_signals enabled
  local ok, e = pcall(capture, cmd1)
  assert(not ok and e:find('Interrupted system call'))
  local ok, e = pcall(capture, cmd2)
  assert(not ok and e:find('Interrupted system call'))

  -- Now do the same with M signals blocked -- it should complete the who task properly
  yottadb.init(_yottadb.block_M_signals)
  local ok, e = pcall(capture, cmd1)
  assert(ok)  asserteq(e, 'Complete')
  local ok, e = pcall(capture, cmd2)
  assert(ok)  asserteq(e, 'Complete')

  -- check that init(nil) switches blocking back off
  yottadb.init(nil)
  local ok, e = pcall(capture, cmd1)
  assert(not ok and e:find('Interrupted system call'))
  local ok, e = pcall(capture, cmd2)
  assert(not ok and e:find('Interrupted system call'))
end

function test_cachearray()
  local ok, e, node, cachearray, depth, newarray, expected, varname, subs

  local cache_create = _yottadb.cachearray_create
  local cache_tomutable = _yottadb.cachearray_tomutable
  local cache_subst = _yottadb.cachearray_subst
  local cache_append = _yottadb.cachearray_append
  local cache_tostring = _yottadb.cachearray_tostring

  cachearray = cache_create('var')
  subs, varname = cache_tostring(cachearray)
  asserteq(varname, 'var')  asserteq(subs, '')

  cachearray = cache_create('var2', {'person', '3', 'male', 'asian'})
  subs, varname = cache_tostring(cachearray)
  asserteq(varname, 'var2')  asserteq(subs, '"person",3,"male","asian"')

  cachearray = cache_create('var', 'person', '3', '4', '5')
  asserteq(cache_tostring(cachearray), '"person",3,4,5')

  cachearray = cache_create('var', {'person','3'}, 'male')
  asserteq(cache_tostring(cachearray), '"person",3,"male"')
  asserteq(cache_tostring(cachearray,2), '"person",3')
  asserteq(cache_tostring(cachearray,1), '"person"')
  asserteq(cache_tostring(cachearray,0), '')
  ok, e = pcall(cache_tostring, cachearray, -1)
  assert(not ok)  asserteq(e, 'Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-3 (got -1)')
  ok, e = pcall(cache_tostring, cachearray, 4)
  assert(not ok)  asserteq(e, 'Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-3 (got 4)')

  -- Check that generating a new cachearray looks the same but is a different object
  -- Assume that ARRAY_OVERALLOC is 5 in array.c
  -- This means that if you append more than 5 subscripts, it will have to allocate a new cachearray
  cachearray = cache_create('var', {'person','3'}, 'male')
  newarray, depth = cache_append(cachearray,3,1,2,3,4,5)
  asserteq(depth, 8)
  assert(cachearray == newarray)  -- should be same cachearray until ARRAY_OVERALLOC exceded
  newarray, depth = cache_append(cachearray,8,6)
  asserteq(depth, 9)
  assert(cachearray ~= newarray)
  asserteq(cache_tostring(newarray), '"person",3,"male",1,2,3,4,5,6')
  -- Make sure we can append to a node shallower than the cachearray's depth
  cachearray, depth = cache_append(newarray,2,'male',1,2)
  asserteq(depth, 5)
  asserteq(cachearray, newarray)  -- should be the same since we used identical subscripts
  asserteq(cache_tostring(cachearray), '"person",3,"male",1,2')
  cachearray, depth = cache_append(newarray,2,'female',1)
  asserteq(depth, 4)
  asserteq(cache_tostring(cachearray), '"person",3,"female",1')
  assert(newarray ~= cachearray)  -- should be different since we change a subscript

  subs = {'person','3','male','4','5','6','7','8','9','10','11','12','13','14','15','16','17','18','19', '20'}
  cachearray = cache_create('var', subs)
  collectgarbage()  -- catch allocation problems such as the one fixed in commit 4bed5e6
  expected = '"person",3,"male",4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20'
  asserteq(cache_tostring(cachearray), expected)

  subs = {'person', 'male'}
  cachearray = cache_tomutable(cache_create('var', subs))
  asserteq(cache_tostring(cachearray), '"person","male"')
  local cachearray2 = cache_subst(cachearray, 'female')
  asserteq(cache_tostring(cachearray2), '"person","female"')
  assert(cachearray == cachearray2)
  local bigsub = string.rep('b', 1000)  -- make new subscript big enough to force reallocation of cachearray
  cachearray2 = cache_subst(cachearray, bigsub)
  asserteq(cache_tostring(cachearray2), '"person","' .. bigsub .. '"')
  assert(cachearray ~= cachearray2)
  local cachearray3
  cachearray3, depth = cache_append(cachearray2, 2, 'sub3')
  asserteq(depth, 3)
  asserteq(cache_tostring(cachearray3), '"person","' .. bigsub .. '","sub3"')
  assert(cachearray2 ~= cachearray3)  -- make sure child of a *reallocated* mutable cachearray is still non-extendable

  -- Validate inputs.
  validate_subsarray_inputs(_yottadb.cachearray_create, true)
end

-- Run tests.
print('Starting test suite.')
local tests = {}
local skipped = 0
if #arg == 0 then
  for k, v in pairs(_G) do
    if k:find('^test_') and type(v) == 'function' then tests[#tests + 1] = k end
    if k:find('^skip_') and type(v) == 'function' then print("Skipping "..k:sub(6)..".") skipped = skipped + 1 end
  end
else
  for i = 1, #arg do
    if type(rawget(_G, arg[i])) == 'function' then
      tests[#tests + 1] = arg[i]
    else
      for k, v in pairs(_G) do
        if k:find('^' .. arg[i]) and type(v) == 'function' then
          tests[#tests + 1] = k
        end
      end
    end
  end
end
table.sort(tests)
local failed = 0
cleanup()
setup('test')   -- in case I remove subsequent setups for debugging, make sure there is at least one
for i = 1, #tests do
  print(string.format('Running %s.', tests[i]))
  setup(tests[i])
  local ok, e = xpcall(_G[tests[i]], function(e)
    print(string.format('Failed!\n%s', debug.traceback(type(e) == 'string' and e or e.message, 3)))
    failed = failed + 1
  end)
  teardown()
end
cleanup()
print(string.format('%d/%d tests passed (%d skipped)', #tests - failed, #tests, skipped))
os.exit(failed == 0 and 0 or 1)
