-- ~~~ Make REPL display tables when you just type: table<Enter>

-- this file is public domain

M = {}

-- Return a recursive dump table (or iterator) `tbl`, with indentation
--   Return as both a string (first) and a table of lines (second).
--   The table version can be useful for sorting and comparison.
-- `maxlines` (optional) defaults to 30 unless specified
-- 'maxdepth' (optional) defaults to infinite
-- `as_table` (optional) flag=true returns the result as a table of lines instead of a string
-- `_indent` (optional) is for internal use only (sets the initial level of indentation)
-- `_seen` (optional) is for internal use only (prevents infinite recursion)
-- `_output` (optional) is for internal use only (table of collected output strings)
-- I could also consider alternative table dump formats at http://lua-users.org/wiki/TableSerialization
function M.dump(tbl, maxlines, maxdepth, as_table, _indent, _seen, _output)
  if not tbl then  return "usage: table.dump(<table>, [maxlines], [maxdepth])"  end
  maxlines = maxlines or 1/0  -- infinite
  _indent = _indent or 0
  _seen = _seen or {}
  _output = _output or {}
  maxdepth = maxdepth or 1/0 -- infinite
  if _indent >= maxdepth then  return  end
  if type(tbl)=='function' then tbl=list(tbl) end
  for k, v in pairs(tbl) do
    if #_output >= maxlines then  break  end
    local formatting = string.rep("  ", _indent) .. tostring(k)
    if type(v) == "table" then
      if _seen[v] then
        table.insert(_output, formatting .. ' <' .. tostring(v) .. ' (above)>')
      else
        _seen[v] = true
        table.insert(_output, formatting .. ' (' .. tostring(v) .. '):')
        M.dump(v, maxlines, maxdepth, as_table, _indent+1, _seen, _output)
      end
    elseif type(v) == 'function' then
      local funcinfo = debug.getinfo(v, 'nS')
      local line = (funcinfo.linedefined == -1) and '' or (' line ' .. funcinfo.linedefined)
      table.insert(_output, formatting .. ': <function ' .. tostring(funcinfo.name) .. ' from ' .. funcinfo.source .. line .. '>')
    else
      table.insert(_output, formatting .. ': ' .. string.format('%q', v))
    end
  end
  if _indent==0 then
    if #_output >= maxlines then
      table.insert(_output, string.format("...etc.   -- stopped at %s lines; to show more use table.dump(<table>, [maxlines], [maxdepth])", maxlines))
    end
    if as_table then  return _output  end
    return table.concat(_output, '\n')
  end
end

table.dump = M.dump

-- hook print()
local original_print = print
function print(...)
  if select('#', ...)~=1 or type(...) ~= 'table' then  return original_print(...)  end
  original_print(...)
  original_print(M.dump(..., 30))
end

-- ~~~ YDB access

-- import ydb but provide a meaningful warning message if it fails to import
local success
success, ydb = pcall(require, 'yottadb')

if not success then
  -- write any warning to stderr instead of stdout lest it clobber Lua being used to generate output
  io.stderr:write(ydb.."\n")
  io.stderr:write("startup.lua: cannot load yottadb module -- ydb functions will be unavailable\n")
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

return M
