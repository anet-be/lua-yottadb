-- ~~~ Make REPL display tables when you just type: table<Enter>

-- this file is copyright Berwyn Hoyt 2022, released under the MIT licence: https://opensource.org/licenses/MIT


table.dump = require('table_dump').dump

-- hook print()
local original_print = print
function print(...)
  if select('#', ...)~=1 or type(...) ~= 'table' then  return original_print(...)  end
  local first = ...
  original_print(...)
  original_print(table.dump(first, 30))
end

-- ~~~ YDB access

-- import ydb but provide a meaningful warning message if it fails to import
local success
success, ydb = pcall(require, 'yottadb')

if not success then
  print("startup.lua: cannot load yottadb module -- ydb functions will be unavailable; require 'yottadb' to debug")
  ydb=nil
else
  -- make REPL prompt also print dbase nodes
  -- hook print()
  local original_print = print
  function print(...)
    if select('#', ...)~=1 or getmetatable(...) ~= ydb._node then  return original_print(...)  end
    original_print(ydb.dump(..., {}, 30))
  end
end
