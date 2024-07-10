#!/usr/bin/env lua
-- Test helper to hold a lock varname[(subscript)] for 0.5 seconds in a separate process.
-- Print whether it could be locked on first try; exiting immediately if not.
--   Usage: lock.lua <varname> [<subscript>]

local _yottadb = require('_yottadb')
local ok, e = pcall(_yottadb.lock_incr, arg[1], {arg[2]}, 0)
if ok then
  print('Locked')
elseif tonumber(e:match('^YDB Error: (%d+)')) == _yottadb.YDB_LOCK_TIMEOUT then
  print('Not locked')
  os.exit(1)
else
  print('Lock Error: ' .. e)
  os.exit(2)
end
os.execute('sleep 0.5')
_yottadb.lock_decr(arg[1], {arg[2]})
print('Lock released')
