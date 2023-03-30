#!/usr/bin/env lua
--[[ Test the speed of calling M routines using:
    perf stat lua mroutine_benchmarks.lua
]]

ydb = require 'yottadb'

ci_table = [=[
  ret: void ret^unittest()
  add: ydb_long_t* add^unittest(I:ydb_int_t, I:ydb_uint_t, I:ydb_long_t, I:ydb_ulong_t, I:ydb_int_t*, I:ydb_uint_t*, I:ydb_long_t*, I:ydb_ulong_t*)
]=]

ydb.set("$ZROUTINES", ". tests")
routines = ydb.require(ci_table)

local function time(code, count)
    task = load([[
        local start = os.clock()
        for i=1, ]] .. count .. [[ do ]] .. code .. [[ end
        return os.clock() - start
    ]])
    return task()
end

local function show(result, first, name)
    io.write(string.format("%0.2fus (%.1fx)\t%s\n", result, result/first, name))
end

ydb.init()
first = time('routines.ret()', 1000000)
show(first, first, "Empty M routine call+return with 0 params")
ydb.init(ydb.block_M_signals)
result = time('routines.ret()', 1000000)
show(result, first, "Empty M routine call+return with 0 params with signal blocking")
io.write('\n')

ydb.init()
first = time('routines.add(1,2,3,4,5,6,7,8)', 1000000)
show(first, first, "Empty M routine call+return with 8 params")
ydb.init(ydb.block_M_signals)
result = time('routines.add(1,2,3,4,5,6,7,8)', 1000000)
show(result, first, "Empty M routine call+return with 8 params with signal blocking")
