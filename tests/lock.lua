#!/usr/bin/env lua
-- Test helper for locking keys in a separate process.

local _yottadb = require('_yottadb')
local ok, e = pcall(_yottadb.lock_incr, arg[1], {arg[2]})
if ok then
  print('Locked')
elseif tonumber(e:match('^YDB Error: (%d+)')) == _yottadb.YDB_LOCK_TIMEOUT then
  print('Not locked')
  os.exit(1)
else
  print('Lock Error: ' .. e)
  os.exit(2)
end
os.execute('sleep 1.5')
_yottadb.lock_decr(arg[1], {arg[2]})
print('Lock released')
