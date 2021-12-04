--

local _yottadb = require('_yottadb')
local cwd = arg[0]:match('^.+/')
local gbldir = os.getenv('ydb_gbldir')
local gbldat = gbldir:gsub('[^.]+$', 'dat')

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
  {{'^test7', {'sub1\x80',}}, 'test7value'},
  -- Test subscripts with non-UTF-8 data
  {{'^test7', {'sub2\x80', 'sub7'}}, 'test7sub2value'},
  {{'^test7', {'sub3\x80', 'sub7'}}, 'test7sub3value'},
  {{'^test7', {'sub4\x80', 'sub7'}}, 'test7sub4value'},
}

local function setup()
  os.remove(gbldir)
  os.remove(gbldat)
  os.execute(string.format('%s/createdb.sh %s %s', cwd, os.getenv('ydb_dist'), gbldat))
end

local has_simple_data = false
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
  os.remove(gbldir)
  os.remove(gbldat)
end

function skip(f)
  if #arg > 0 then return end -- do not skip manually specified tests
  for k, v in pairs(_G) do
    if v == f then _G['skip_' .. k], _G[k] = v, nil end
  end
end

function test_get()
  simple_data()
  assert(_yottadb.get('^test1') == 'test1value')
  assert(_yottadb.get('^test2', {'sub1'}) == 'test2value')
  assert(_yottadb.get('^test3') == 'test3value1')
  assert(_yottadb.get('^test3', {'sub1'}) == 'test3value2')
  assert(_yottadb.get('^test3', {'sub1', 'sub2'}) == 'test3value3')

  -- Error handling.
  local gvns = {{'^testerror'}, {'^testerror', {'sub1'}}}
  for i = 1, #gvns do
    local ok, e = pcall(_yottadb.get, table.unpack(gvns[i]))
    assert(not ok)
    assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  end
  local lvns = {{'testerror'}, {'testerror', {'sub1'}}}
  for i = 1, #lvns do
    local ok, e = pcall(_yottadb.get, table.unpack(lvns[i]))
    assert(not ok)
    assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
  end

  -- Handling of large values.
  _yottadb.set('testlong', string.rep('a', _yottadb.YDB_MAX_STR))
  assert(_yottadb.get('testlong') == string.rep('a', _yottadb.YDB_MAX_STR))
end

function test_set()
  _yottadb.set('test4', 'test4value')
  assert(_yottadb.get('test4') == 'test4value')
  _yottadb.set('test6', {'sub1'}, 'test6value')
  assert(_yottadb.get('test6', {'sub1'}) == 'test6value')

  -- Unicode/i18n value.
  _yottadb.set('testchinese', '你好世界')
  assert(_yottadb.get('testchinese') == '你好世界')
end

function test_delete()
  _yottadb.set('test8', 'test8value')
  assert(_yottadb.get('test8') == 'test8value')
  _yottadb.delete('test8')
  local ok, e = pcall(_yottadb.get, 'test8')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)

  _yottadb.set('test10', {'sub1'}, 'test10value')
  assert(_yottadb.get('test10', {'sub1'}) == 'test10value')
  _yottadb.delete('test10', {'sub1'})
  ok, e = pcall(_yottadb.get, 'test10', {'sub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)

  -- Delete tree.
  _yottadb.set('test12', 'test12 node value')
  _yottadb.set('test12', {'sub1'}, 'test12 subnode value')
  assert(_yottadb.get('test12') == 'test12 node value')
  assert(_yottadb.get('test12', {'sub1'}) == 'test12 subnode value')
  _yottadb.delete('test12', _yottadb.YDB_DEL_TREE)
  ok, e = pcall(_yottadb.get, 'test12')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
  ok, e = pcall(_yottadb.get, 'test12', {'sub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)

  _yottadb.set('test11', {'sub1'}, 'test11value')
  assert(_yottadb.get('test11', {'sub1'}) == 'test11value')
  _yottadb.delete('test11', {'sub1'}, _yottadb.YDB_DEL_NODE)
  ok, e = pcall(_yottadb.get, 'test11', {'sub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
end

function test_data()
  simple_data()
  assert(_yottadb.data('^nodata') == _yottadb.YDB_DATA_UNDEF)
  assert(_yottadb.data('^test1') == _yottadb.YDB_DATA_VALUE_NODESC)
  assert(_yottadb.data('^test2') == _yottadb.YDB_DATA_NOVALUE_DESC)
  assert(_yottadb.data('^test2', {'sub1'}) == _yottadb.YDB_DATA_VALUE_NODESC)
  assert(_yottadb.data('^test3') == _yottadb.YDB_DATA_VALUE_DESC)
  assert(_yottadb.data('^test3', {'sub1'}) == _yottadb.YDB_DATA_VALUE_DESC)
  assert(_yottadb.data('^test3', {'sub1', 'sub2'}) == _yottadb.YDB_DATA_VALUE_NODESC)
end

-- Note: for some reason, this test must be run first to pass.
function test__lock_incr()
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
  os.execute('tests/lock.sh "^test1"')
  os.execute('sleep 0.1')
  local t1 = os.time()
  local ok, e = pcall(_yottadb.lock_incr, '^test1', 1)
  assert(not ok)
  assert(e.code == _yottadb.YDB_LOCK_TIMEOUT)
  local t2 = os.time()
  assert(t2 - t1 >= 1)
  -- Varname and subscript
  os.execute('tests/lock.sh "^test2" "sub1"')
  os.execute('sleep 0.1')
  t1 = os.time()
  ok, e = pcall(_yottadb.lock_incr, '^test2', {'sub1'}, 1)
  assert(not ok)
  assert(e.code == _yottadb.YDB_LOCK_TIMEOUT)
  t2 = os.time()
  assert(t2 - t1 >= 1)
  os.execute('sleep 1')

  -- No timeout.
  os.execute('tests/lock.sh "^test2" "sub1"')
  os.execute('sleep 2')
  local t1 = os.clock()
  _yottadb.lock_incr('^test2', {'sub1'})
  local t2 = os.clock()
  assert(t2 - t1 < 0.1)

  -- Test blocking other.
  local keys = {
    {'^test1'},
    {'^test2', {'sub1'}},
    {'^test2', {'sub1', 'sub2'}}
  }
  _yottadb.lock(keys)
  for i = 1, #keys do
    local cmd = string.format('tests/lock.lua "%s" %s', keys[i][1], table.concat(keys[i][2] or {}, ' '))
    local _, _, status = os.execute(cmd)
    assert(status == 1)
  end
  _yottadb.lock() -- release all locks
  for i = 1, #keys do
    local cmd = string.format('tests/lock.lua "%s" %s', keys[i][1], table.concat(keys[i][2] or {}, ' '))
    local _, _, status = os.execute(cmd)
    assert(status == 0)
  end

  -- Test lock being blocked.
  os.execute('tests/lock.sh "^test1"')
  os.execute('sleep 0.1')
  local ok, e = pcall(_yottadb.lock, {{"^test1"}})
  assert(not ok)
  assert(e.code == _yottadb.YDB_LOCK_TIMEOUT)
end
--skip(test__lock_incr) -- for speed

local function tp_set(varname, subs, value, retval)
  _yottadb.set(varname, subs, value)
  if retval then return retval end
end

function test_tp_return_YDB_OK()
  local key = {'^tptests', {'test_tp_return_YDB_OK'}}
  local value = 'return YDB_OK'
  _yottadb.delete(table.unpack(key))
  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)
  _yottadb.tp(tp_set, key[1], key[2], value)
  assert(_yottadb.get(table.unpack(key)) == value)
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

  assert(_yottadb.get(table.unpack(key1)) == value1)
  assert(_yottadb.get(table.unpack(key2)) == value2)
  _yottadb.delete('^tptests', _yottadb.YDB_DEL_TREE)
end

function test_tp_return_YDB_TP_ROLLBACK()
  local key, value = {'^tptests', {'test_tp_return_YDB_TP_ROLLBACK'}}, 'return YDB_TP_ROLLBACK'
  _yottadb.delete(table.unpack(key))
  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, tp_set, key[1], key[2], value, _yottadb.YDB_TP_ROLLBACK)
  assert(not ok)
  assert(e.code == _yottadb.YDB_TP_ROLLBACK)

  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_return_YDB_TP_ROLLBACK()
  local key1 = {'^tptests', {'test_tp_nested_return_YDB_TP_ROLLBACK', 'outer'}}
  local value1 = 'return YDB_TP_ROLLBACK'
  local key2 = {'^tptests', {'test_tp_nested_return_YDB_TP_ROLLBACK', 'nested'}}
  local value2 = 'nested return YDB_TP_ROLLBACK'
  _yottadb.delete(table.unpack(key1))
  _yottadb.delete(table.unpack(key2))
  assert(_yottadb.data(table.unpack(key1)) == _yottadb.YDB_DATA_UNDEF)
  assert(_yottadb.data(table.unpack(key2)) == _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, function()
    tp_set(key1[1], key1[2], value1)
    _yottadb.tp(tp_set, key2[1], key2[2], value2, _yottadb.YDB_TP_ROLLBACK)
  end)
  assert(not ok)
  assert(e.code == _yottadb.YDB_TP_ROLLBACK)

  assert(_yottadb.data(table.unpack(key1)) == _yottadb.YDB_DATA_UNDEF)
  assert(_yottadb.data(table.unpack(key2)) == _yottadb.YDB_DATA_UNDEF)
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

  local ok, e = pcall(_yottadb.get, table.unpack(key1))
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  assert(_yottadb.get(table.unpack(key2)) == value)
  assert(tonumber(_yottadb.get(table.unpack(tracker))) == 1)

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

  local ok, e = pcall(_yottadb.get, table.unpack(key1_1))
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  assert(tonumber(_yottadb.get(table.unpack(tracker1))) == 1)
  ok, e = pcall(_yottadb.get, table.unpack(key2_1))
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  assert(_yottadb.get(table.unpack(key2_2)) == value2)

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

  assert(_yottadb.get(table.unpack(key)) == '1')
  local ok, e = pcall(_yottadb.get, table.unpack(tracker))
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_return_YDB_ERR_TPTIMEOUT()
  local key = {'^tptests', {'test_tp_return_YDB_ERR_TPTIMEOUT'}}
  local value = 'return YDB_ERR_TPTIMEOUT'
  _yottadb.delete(table.unpack(key))
  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, tp_set, key[1], key[2], value, _yottadb.YDB_ERR_TPTIMEOUT)
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_TPTIMEOUT)

  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)
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
  assert(e.code == _yottadb.YDB_ERR_TPTIMEOUT)

  assert(_yottadb.data(table.unpack(key1)) == _yottadb.YDB_DATA_UNDEF)
  assert(_yottadb.data(table.unpack(key2)) == _yottadb.YDB_DATA_UNDEF)
  _yottadb.delete(key1[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_raise_error()
  local key = {'^tptests', 'test_tp_raise_error'}
  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, _yottadb.get, key[1], key[2])
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  _yottadb.delete(key[1], _yottadb.YDB_DEL_TREE)
end

function test_tp_nested_raise_error()
  local key = {'^tptests', {'test_tp_nested_raise_error'}}
  assert(_yottadb.data(table.unpack(key)) == _yottadb.YDB_DATA_UNDEF)

  local ok, e = pcall(_yottadb.tp, function()
    _yottadb.tp(_yottadb.get, key[1], key[2])
  end)
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_GVUNDEF)
  _yottadb.delete('^tptests', _yottadb.YDB_DEL_TREE)
end

function test_tp_raise_lua_error()
  local ok, e = pcall(_yottadb.tp, error, 'lua error')
  assert(not ok)
  assert(e == 'lua error')
end

function test_tp_nested_raise_lua_error()
  local ok, e = pcall(_yottadb.tp, function()
    _yottadb.tp(error, 'lua error')
  end)
  assert(not ok)
  assert(e == 'lua error')
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
    assert(_yottadb.get(table.unpack(key)) == value(i))
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
  assert(tonumber(_yottadb.get('^account', {account1, 'balance'})) == balance1 - amount)
  assert(tonumber(_yottadb.get('^account', {account2, 'balance'})) == balance2 + amount)

  -- Test rollback.
  balance1 = balance1 - amount
  balance2 = balance2 + amount
  amount = balance1 + 1 -- would overdraft
  local ok, e = pcall(_yottadb.tp, transfer, account1, account2, amount)
  assert(not ok)
  assert(e.code == _yottadb.YDB_TP_ROLLBACK)
  assert(tonumber(_yottadb.get('^account', {account1, 'balance'})) == balance1)
  assert(tonumber(_yottadb.get('^account', {account2, 'balance'})) == balance2)

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
  assert(_yottadb.get('resetattempt') == '2')
  assert(_yottadb.get('resetvalue') == '1')
  _yottadb.delete('resetattempt')
  _yottadb.delete('resetvalue')
end

function test_subscript_next()
  simple_data()
  assert(_yottadb.subscript_next('^%') == '^Test5')
  assert(_yottadb.subscript_next('^a') == '^test1')
  assert(_yottadb.subscript_next('^test1') == '^test2')
  assert(_yottadb.subscript_next('^test2') == '^test3')
  assert(_yottadb.subscript_next('^test3') == '^test4')
  local ok, e = pcall(_yottadb.subscript_next, '^test7')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)

  assert(_yottadb.subscript_next('^test4', {''}) == 'sub1')
  assert(_yottadb.subscript_next('^test4', {'sub1'}) == 'sub2')
  assert(_yottadb.subscript_next('^test4', {'sub2'}) == 'sub3')
  ok, e = pcall(_yottadb.subscript_next, '^test4', {'sub3'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)

  assert(_yottadb.subscript_next('^test4', {'sub1', ''}) == 'subsub1')
  assert(_yottadb.subscript_next('^test4', {'sub1', 'subsub1'}) == 'subsub2')
  assert(_yottadb.subscript_next('^test4', {'sub1', 'subsub2'}) == 'subsub3')
  ok, e = pcall(_yottadb.subscript_next, '^test4', {'sub3', 'subsub3'})
    assert(not ok)
    assert(e.code == _yottadb.YDB_ERR_NODEEND)

  -- Test subscripts that include a non-UTF8 character
  assert(_yottadb.subscript_next('^test7', {''}) == 'sub1\x80')
  assert(_yottadb.subscript_next('^test7', {'sub1\x80'}) == 'sub2\x80')
  assert(_yottadb.subscript_next('^test7', {'sub2\x80'}) == 'sub3\x80')
  assert(_yottadb.subscript_next('^test7', {'sub3\x80'}) == 'sub4\x80')
  ok, e = pcall(_yottadb.subscript_next, '^test7', {'sub4\x80'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)
end

function test_subscript_next_long()
  _yottadb.set('testLongSubscript', {string.rep('a', _yottadb.YDB_MAX_STR)}, 'toolong')
  assert(_yottadb.subscript_next('testLongSubscript', {''}) == string.rep('a', _yottadb.YDB_MAX_STR))
end

function test_subscript_next_i18n()
  _yottadb.set('testi18n', {'中文'}, 'chinese')
  assert(_yottadb.subscript_next('testi18n', {''}) == '中文')
end

function test_subscript_previous()
  simple_data()
  assert(_yottadb.subscript_previous('^z') == '^test7')
  assert(_yottadb.subscript_previous('^a') == '^Test5')
  assert(_yottadb.subscript_previous('^test1') == '^Test5')
  assert(_yottadb.subscript_previous('^test2') == '^test1')
  assert(_yottadb.subscript_previous('^test3') == '^test2')
  assert(_yottadb.subscript_previous('^test4') == '^test3')
  local ok, e = pcall(_yottadb.subscript_previous, '^Test5')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)

  assert(_yottadb.subscript_previous('^test4', {''}) == 'sub3')
  assert(_yottadb.subscript_previous('^test4', {'sub2'}) == 'sub1')
  assert(_yottadb.subscript_previous('^test4', {'sub3'}) == 'sub2')
  local ok, e = pcall(_yottadb.subscript_previous, '^test4', {'sub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)

  assert(_yottadb.subscript_previous('^test4', {'sub1', ''}) == 'subsub3')
  assert(_yottadb.subscript_previous('^test4', {'sub1', 'subsub2'}) == 'subsub1')
  assert(_yottadb.subscript_previous('^test4', {'sub1', 'subsub3'}) == 'subsub2')
  local ok, e = pcall(_yottadb.subscript_previous, '^test4', {'sub3', 'subsub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)
end

function test_subscript_previous_long()
  _yottadb.set('testLongSubscript', {string.rep('a', _yottadb.YDB_MAX_STR)}, 'toolong')
  assert(_yottadb.subscript_previous('testLongSubscript', {''}) == string.rep('a', _yottadb.YDB_MAX_STR))
end

function test_node_next()
  simple_data()
  assert(_yottadb.node_next('^test3')[1] == 'sub1')
  local node = _yottadb.node_next('^test3', {'sub1'})
  assert(#node == 2)
  assert(node[1] == 'sub1')
  assert(node[2] == 'sub2')
  local ok, e = pcall(_yottadb.node_next, '^test3', {'sub1', 'sub2'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)
  node = _yottadb.node_next('^test6')
  assert(#node == 2)
  assert(node[1] == 'sub6')
  assert(node[2] == 'subsub6')
end

function test_node_next_many_subscripts()
  local subs = {'sub1', 'sub2', 'sub3', 'sub4', 'sub5', 'sub6'}
  _yottadb.set('testmanysubscripts', subs, '123')
  local node = _yottadb.node_next('testmanysubscripts')
  assert(#node == #subs)
  for i = 1, #subs do assert(node[i] == subs[i]) end
end

function test_node_next_long_subscripts()
  _yottadb.set('testlong', {string.rep('a', 1025), string.rep('a', 1026)}, '123')
  local node = _yottadb.node_next('testlong')
  assert(#node == 2)
  assert(node[1] == string.rep('a', 1025))
  assert(node[2] == string.rep('a', 1026))
end

function test_node_previous()
  simple_data()
  local ok, e = pcall(_yottadb.node_prev, '^test3')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NODEEND)
  local node = _yottadb.node_prev('^test3', {'sub1'})
  assert(#node == 0)
  node = _yottadb.node_prev('^test3', {'sub1', 'sub2'})
  assert(#node == 1)
  assert(node[1] == 'sub1')
end

function test_node_previous_long_subscripts()
  local a1025 = string.rep('a', 1025)
  local a1026 = string.rep('a', 1026)
  _yottadb.set('testlong', {a1025, a1026}, '123')
  _yottadb.set('testlong', {a1025, a1026, 'a'}, '123')
  local node = _yottadb.node_prev('testlong', {a1025, a1026, 'a'})
  assert(#node == 2)
  assert(node[1] == a1025)
  assert(node[2] == a1026)
end

function test_delete_excl()
  _yottadb.set('testdeleteexcl1', '1')
  _yottadb.set('testdeleteexcl2', {'sub1'}, '2')
  _yottadb.set('testdeleteexclexception', {'sub1'}, '3')
  _yottadb.delete_excl({'testdeleteexclexception'})
  local ok, e = pcall(_yottadb.get, 'testdeleteexcl1')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
  ok, e = pcall(_yottadb.get, 'testdeleteexcl2', {'sub1'})
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_LVUNDEF)
  assert(_yottadb.get('testdeleteexclexception', {'sub1'}) == '3')
end

-- Initial, increment, result.
local increment_tests = {
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
  {'1', 999999999999999998, string.rep('9', 18)}, -- 18 significant digits
  {'0', 999999999999999999, string.rep('9', 18)}, -- 18 significant digits
  {'-1', -999999999999999998, '-' .. string.rep('9', 18)}, -- 18 significant digits
  {'0', -999999999999999999, '-' .. string.rep('9', 18)}, -- 18 significant digits
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

local increment_keys = {
  {'testincrparametrized'},
  {'^testincrparametrized'},
  {'^testincrparametrized', {'sub1'}},
  {'testincrparametrized', {'sub1'}},
}

local function number_to_string(number)
  return type(number) ~= 'string' and tostring(number):upper():gsub('%+', '') or number
end

function test_incr()
  for i = 1, #increment_keys do
    local key = increment_keys[i]
    print('test_incr:', key[1], table.concat(key[2] or {}, ' '))
    for j = 1, #increment_tests do
      local t = increment_tests[j]
      local initial, increment, result = t[1], t[2], t[3]
      print('test_incr:', initial, increment, result)
      if not (i == 1 and j == 1) then setup() end
      local args = {table.unpack(key)}
      args[#args + 1] = initial
      _yottadb.set(table.unpack(args))
      args[#args] = number_to_string(increment)
      local retval = _yottadb.incr(table.unpack(args))
      assert(retval == result)
      assert(_yottadb.get(table.unpack(key)) == result)
      args[#args] = _yottadb.YDB_DEL_TREE
      _yottadb.delete(table.unpack(args))
      teardown()
    end
  end
end

function test_incr_errors()
  _yottadb.set('testincrparametrized', '0')
  local ok, e = pcall(_yottadb.incr, 'testincrparametrized', '1E47')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NUMOFLOW)
  ok, e = pcall(_yottadb.incr, 'testincrparametrized', '-1E47')
  assert(not ok)
  assert(e.code == _yottadb.YDB_ERR_NUMOFLOW)
end

-- Input, output1, output2.
local str2zwr_tests = {
  {"X\0ABC", '"X"_$C(0)_"ABC"', '"X"_$C(0)_"ABC"'},
  {
    "你好世界",
    '"\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8"_$C{150}_"\xe7"_$C{149,140}',
    '"\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96\xe7\x95\x8c"',
  },
}

function test_str2zwr()
  for i = 1, #str2zwr_tests do
    local t = str2zwr_tests[i]
    local input, output1, output2 = t[1], t[2], t[3]
    print('test_str2zwr:', input, output1, output2)
    assert(_yottadb.str2zwr(input) == (os.getenv('ydb_chset') == 'UTF-8' and output2 or output1))
  end
end

function test_zwr2str()
  for i = 1, #str2zwr_tests do
    local t = str2zwr_tests[i]
    local input, output = t[3], t[1]
    print('test_zwr2str:', input, output)
    assert(_yottadb.zwr2str(input) == output)
  end
end

-- Run tests.
print('Starting test suite.')
local tests = {}
local skipped = 0
if #arg == 0 then
  for k, v in pairs(_G) do
    if k:find('^test_') and type(v) == 'function' then tests[#tests + 1] = k end
    if k:find('^skip_') and type(v) == 'function' then skipped = skipped + 1 end
  end
else
  for i = 1, #arg do
    if type(_G[arg[i]]) == 'function' then
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
for i = 1, #tests do
  print(string.format('Running %s.', tests[i]))
  setup()
  local ok, e = xpcall(_G[tests[i]], function(e)
    print(string.format('Failed!\n%s', debug.traceback(type(e) == 'string' and e or e.message, 3)))
    failed = failed + 1
  end)
  if ok then teardown() end
end
print(string.format('%d/%d tests passed (%d skipped)', #tests - failed, #tests, skipped))
os.exit(failed == 0 and 0 or 1)
