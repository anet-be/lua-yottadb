# Lua-yottadb Syntax Upgrade Proposal

MLua uses lua-yottadb for its ydb-lua bindings, under the covers. This is as it should be, since lua-yottadb implements the Lua interface specified in the ydb [Multi-language Programmer's Guide](https://docs.yottadb.com/MultiLangProgGuide/luaprogram.html). However, that specification (taken from the Python bindings) could be made more Lua-esque and additional developer visibility tools provided.

One of the MLua requirements is to implement an efficient but Lua-esque data exchange mechanism between Lua and ydb. I believe this can be done with meta-methods to overload getter, setter, and other functions of Lua tables. Lua tables are remarkably similar in structure to ydb globals. It seems possible to make this backward compatible.

This is a proposal to make ydb globals act more like Lua tables, when in Lua. It will retain the binary-format efficiency of lua-yottadb by lazily populating table entries. The current syntax is non-intuitive in several respects, and somewhat long-winded, resulting in reduced code clarity that discourages the developer. Below is an example.

Let's use Lua to calculate the height of 3 oak trees based on their shadow length and the angle of the sun. First let's see the data in Mumps code:

```lua
set ^oaks(1,"shadow")=10,^("angle")=30
set ^oaks(2,"shadow")=13,^("angle")=30
set ^oaks(3,"shadow")=15,^("angle")=45
```

## Problem

Now, let's calculate with the old syntax:

```lua
oakkey = ydb.key('^oaks')
for sub in oakkey:subscripts() do
    oaktree=oakkey(sub)
    height = oaktree('shadow').value * math.tan( math.rad(oaktree('angle').value) )
    print(string.format('Oak %s is %.1fm high', sub, height))
    oaktree('height').value = height  -- save back into ydb
end
```

The problems are that:

1. It is long-winded: oakkey has to be created explicitly, to avoid repeated effort every access.
2. Iterating string subscripts (`sub`) takes an extra lookup line: `oaktree=oakkey(sub)` but iterating dbase objects would be more intuitive.
3. Explicit access to .value fields feels like unnecessary noise.

## Proposal

In the proposed solution, the code above becomes:

```lua
for index, oaktree in pairs(ydb.node('^oaks')) do
    oaktree.height._ = oaktree.shadow() * math.tan( math.rad(oaktree.angle()) )
    print(string.format('Oak %s is %.1fm high', index, oaktree.height()))
end
```

Essentially, the database table `oaks` can now be accessed more like a regular table in Lua -- with either dot .notation or bracket[notation], and the use of the Lua standard pairs() iterators. Yet this new syntax retains the underlying efficiency of the database because table values are still only populated when they're needed, and they remain in binary format.

## Solution - what's new

The proposal has now been implemented and you run the code above and use several other idioms, show below.

<table>
<thead>
  <tr>
    <th></th>
    <th>Old Syntax</th>
    <th>New Syntax</th>
    <th>Old Syntax<br />still valid?</th>
  </tr>
</thead>
<tbody>
  <tr>
    <td>Node object<br />renamed</td>
      <td><pre lang="lua">k = ydb.key('^oaks')</pre></td>
    <td><pre lang="lua">n = ydb.node('^oaks')</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Duplicate/cast<br />object</td>
    <td><pre lang="lua">newk = ydb.key(k.varname, k.subsarray)</pre></td>
    <td><pre lang="lua">n = ydb.node(k)</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Initialize db data</td>
      <td><pre lang="lua">
k.value = 'treedata'
k('1')('shadow').value = 10
k('1')('angle').value=30
k('2')('shadow').value = 13
k('2')('angle').value=30
k('3')('shadow').value = 15
k('3')('angle').value=45<pre></td>
    <td><pre lang="lua">
n:_settree({ _='treedata',
  {shadow=10,angle=30},
  {shadow=13,angle=30},
  {shadow=15,angle=45}})
</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Integer subscripts</td>
    <td><pre lang="lua">k1 = k('1')</pre></td>
    <td><pre lang="lua">n1 = (1)</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Subscripts lists</td>
    <td><pre lang="lua">
k('1')('angle')('subangle')
ydb.lock_incr(varname, {'sub1', 'sub2'}, 3)
</pre></td>
    <td><pre lang="lua">
n(1, 'angle', 'subangle')
ydb.lock_incr(varname, 'sub1', 'sub2', 3)
</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Dot notation<br />Index notation</td>
    <td><pre lang="lua">k1('angle')('subangle','1')</pre></td>
    <td><pre lang="lua">n1.angle.subangle[1]</pre></td>
    <td>yes</td>
  </tr>
  <tr>
    <td>Iterate subscripts</td>
    <td><pre lang="lua">
for subname in key:subscripts() do
  subscript = key(subname)
  ...
</pre></td>
    <td><pre lang="lua">
for subname, subscript in pairs(key) do
  ...
</pre></td>
    <td>with fixes</td>
  </tr>
  <tr>
    <td>Visibility</td>
    <td><pre lang="lua"></pre></td>
    <td><pre lang="lua">
ydb.dump('^oaks', sub1)
ydb.dump(n, sub1)
</pre></td>
    <td>--</td>
  </tr>
  <tr>
    <td>Property set</td>
    <td><pre lang="lua">k1('angle').value = 3</pre></td>
    <td><pre lang="lua">
n1.angle:set(3)  OR
n1.angle._ = 3  (4x faster)
</pre></td>
    <td>no</td>
  </tr>
  <tr>
    <td>Property get</td>
    <td><pre lang="lua">angle = k1('angle').value</pre></td>
    <td><pre lang="lua">
angle = n1.angle:get() OR
angle = n1.angle:get(default) OR
angle = n1.angle._  (2.5x faster)
</pre></td>
    <td>no</td>
  </tr>
  <tr>
    <td>Method run</td>
    <td><pre lang="lua">k1:incr()</pre></td>
    <td><pre lang="lua">
n1:name()  OR
n1:__name()  (15x faster)
</pre></td>
    <td>yes</td>
  </tr>
</tbody>
</table>


#### Additional visibility tools

These are supplied in a sample `startup.lua` to enhance the Lua prompt:

``` lua
-- Node dump at Lua prompt
> n
^oaks
^oaks="treedata"
^oaks("1","angle")="30"
^oaks("1","shadow")="10"
^oaks("2","angle")="30"
^oaks("2","shadow")="13"
^oaks("3","angle")="45"
^oaks("3","shadow")="15"

-- Table dump at Lua prompt
> t={name='triangle', sides={3,4},
    hypotenuse=5}
> t
table: 0x561bf4a64390
hypotenuse: 5
name: pythagoras
sides (table: 0x561bf4a643d0):
  1: 3
  2: 4
```

### Details of the changes

The breakdown of changes needed to implement this solution includes the following:

1. Done: use new syntax with new `node` object rather than `key` object (more standard name for M nodes anyway).
2. Done: subscripts may now be not only strings but also integers, automatically converted to strings like ydb does. 
   - integer only, since floats will cause problems with significant figures and possibly rounding, for example:
     - YDB> s test(5/3)=9 zwr test
       test(1.66666666666666666)=9
     - Lua> ydb.set('test', {tostring(5/3)}, 9) print(ydb.dump('test'))
       test("1.6666666666667")="9"
   - works in Lua < 5.3 as number is treated as an integer if tostring(number) has no decimal point; this maintains source compatibility between Lua versions.
3. Done: make node accept dot notation `node.subscript1.subscript2` -- this set syntax limitations on subscript name content which means the more general `()` syntax must also be retained.
4. Skip: tempting to allow `node.subnode = 3`, but that would not work consistently, e.g. node = 3 would set Lua local
5. Done: create more terse ways of getting/setting dbase node.value:
   - Done: node._: good for `node._ = 3` since `node = 3` would set lua local `node` rather than dbase value.
   - Omit: access node.subscript.value by referencing `node.subscript` or node[subscript] -- but it would only work when there is no node.subscript.sub_subscript in the dbase (in which case it returns new node(subscript). This makes pretty code but turns out to be dangerous because if sub_subscripts are later added to the dbase, code accessing the node.subscript value will stop working. Plus, it only works on node.subscript not on node.
   - Omit: Could make unary operators access the node.value: ~node (lua>=5.3), #node (lua>=5.2), -node (lua>=5.0). This would be pretty, but are not the usual usage of these operators.
6. Done: Rename node properties to become methods: `.value, .get, .data` become `:get(), :data()`, etc., so they don't clobber common dbase subscript names. (The :method() is distinguished from .method() by the fact that in Lua it supplies self as the first parameter -- thanks, Alain)
7. Done: Allow multiple subscripts as parameter lists or as a table in the follows new situations:
   - Done: `node(sub1, sub2, ...)` or `node({sub1, sub2})`
   - Done: make ydb.node(glvn, sub1, sub2, ...) to become equivalent to ydb.node(glvn, {sub1, sub2, ...})
   - Done: ydb.get(glvn, sub1, sub2, ...) to become equivalent to ydb.get(glvn, {sub1, sub2, ...})
   - Done: ydb.set(glvn, sub1, sub2, ..., value) to become equivalent to ydb.set(glvn, {sub1, sub2, ...}, value) for the sake of consistency with get() and node()
8. 
9. Done: make `pairs()` work as expected
   - Also made iterator node:subscripts() work differently than key.subscripts(). The old one started at the current subscript and produced *sibling* subscripts at the same level until the end of the collation. The new one iterates all *child* subscripts of the specified node. I'm not sure whether the old one was intended or a bug, but the new one makes much more sense to me: to iterate over a whole node's children.

10. Skip: making nodes act like specific integer-indexed Lua list-type tables because it would generate inefficient db code; also unlikely to be used:

   - Considered making ipairs() work using `__index()` from Lua 5.2 but later Lua versions implement `ipairs()` by invoking `__index()`.  So that would require making node index by an *integer* to act differently than indexing a node by a *string* as follows:

     - `node['abc']`  => produces a new node so that `node.abc.def.ghi` works
     - but `node[1]`  => would have to produce value `note(1).value` for ipairs() to work
       This integer/string distinction can easily be done, but creates an unexpected syntax inconsistency.

     Instead, use pairs() with numeric subscripts or a numeric `for` as follows:

     - `for k,v in pairs(node) do   if not tonumber(k) break end   <do_your_stuff with k,v>   end`
     - `for i=1,1/0 do   v=node[i]()  if not v break then   <do_your_stuff with k,v>   end`

   - Decided not to define Lua `#` operator, which counts only sequential numeric nodes and is mostly used in Lua to append to a table (t[#t+1] = n). Its use seems unlikely since ipairs() is not implemented, and there is also no way ydb-way to make it efficient. It's use does not match a typical M way of structuring arrays.

   - The consequence of the above is that standard Lua list functions (that use tables as integer-indexed lists) do not work. Specifically: `table.concat, table.insert, table.move, table.pack, table.remove, table.sort`

11. Done: populate a ydb database global using Lua table constructors: `oaktree:settree( {shadow=5, angle=30} )`
12. Done: add ability to cast a key to a node: key(node) and node(key)
13. Done: Additional programmer usage improvements:
    - Done: Improve ydb.dump and add it to the standard library
    - Done: Make Lua table and db node display contents when typed at the Lua prompt -- implemented in startup.lua and table_dump.lua
14. In another PR: Ability for Lua to call an M function using ydb_cip() and call-in table registration
    - decided not to add M-style invocation format `get(''$$routine^module")` until it is more clearly useful.


## Future - Efficiency

Key and node objects in lua-yottadb are inefficient for two main reasons that require attention in the future. Each time a node object or a subnode object is created:

1. The subscript array is copied three times: twice in Lua (into `node:__subsarray` and `node.__next_subsarray`) and once by every C function that uses the node. These could instead be cached in single C array.
2. Each subscript in the subscript array is checked for type validity twice: once by the node creator and once by the C function that uses the node.

These overheads are repeated for every subnode, so `node.sub1.sub2.sub3` repeats all the above 4 times (once for each dot). These improvements are relatively low-hanging fruit, but will be postponed until feedback on the new syntax is received and the syntax solidified.

