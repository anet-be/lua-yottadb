-- Benchmarking different kinds of object access
-- "Deferred lookup" (~1.5x longer than "Standard"),
--    is what we would need to oust __ fields from nodes (db subnode namespace)
-- "Subnode creation/lookup (~8x longer) than "Standard"),
--    is what we would need to make node:method() work by
--    creating an intermediate throw-away node
load = rawget(_G, 'loadstring') or load -- Lua 5.1-5.2 hack

do
  local first = nil
  local function runbenchmark(name, code, count, ob)
    local f = load([[
        local count,ob = ...
        local clock = os.clock
        local start = clock()
        for i=1,count do ]] .. code .. [[ end
        return clock() - start
    ]])
    local result = f(count, ob)
    if not first then first = result end
    io.write(string.format("%0.2f (%.1fx)\t%s\n", result, result/first, name))
  end

  local nameof = {}
  local codeof = {}
  local tests  = {}
  function addbenchmark(name, code, ob)
    nameof[ob] = name
    codeof[ob] = code
    tests[#tests+1] = ob
  end
  function runbenchmarks(count)
    for _,ob in ipairs(tests) do
      runbenchmark(nameof[ob], codeof[ob], count, ob)
    end
  end
end

function makeob1()
  local self = {data = 0}
  function self:test()  self.data = self.data + 1  end
  return self
end
addbenchmark("Standard", "ob:test()", makeob1())

function makeob_1()
  local self = {}
  local alt = {[self] = {data = 0}}
  function self:test()  local a = alt[self] a.data = a.data + 1  end
  return self
end
addbenchmark("Deferred lookup", "ob:test()", makeob_1())

local ob2mt = {}
ob2mt.__call = function(self, ...)
  self._parent.data = self._parent.data + 1
end
ob2mt.__index = function(self, k)
  return setmetatable({_parent=self, _name=k}, ob2mt)
end
function ob2mt:test()  self.data = self.data + 1  end
function makeob_2()
  return setmetatable({data = 0}, ob2mt)
end
addbenchmark("Subnode creation/lookup", "ob:test()", makeob_2())

local ob2mt = {}
ob2mt.__index = ob2mt
function ob2mt:test()  self.data = self.data + 1  end
function makeob2()
  return setmetatable({data = 0}, ob2mt)
end
addbenchmark("Standard (metatable)", "ob:test()", makeob2())

function makeob3() 
  local self = {data = 0};
  function self.test()  self.data = self.data + 1 end
  return self
end
addbenchmark("Object using closures (PiL 16.4)", "ob.test()", makeob3())

function makeob4()
  local public = {}
  local data = 0
  function public.test()  data = data + 1 end
  function public.getdata()  return data end
  function public.setdata(d)  data = d end
  return public
end
addbenchmark("Object using closures (noself)", "ob.test()", makeob4())

addbenchmark("Direct Access", "ob.data = ob.data + 1", makeob1())
addbenchmark("Local Variable", "ob = ob + 1", 0)

runbenchmarks(select(1,...) or 100000000)
