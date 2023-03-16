# Overview

This project provides a shared library that lets the [Lua](https://lua.org/) language access a [YottaDB database](https://yottadb.com/) and the means to invoke M routines from within Lua. While this project is stand-alone, there is a closely related project called [MLua](https://github.com/anet-be/mlua) that goes in the other direction, allowing M software to invoke the Lua language. If you wish for both abilities, start with [MLua](https://github.com/anet-be/mlua) which is designed to incorporate lua-yottadb.

**License:** Unless otherwise stated, the software is licensed with the [GNU Affero GPL](https://opensource.org/licenses/AGPL-3.0), and the compat-5.3 files are licensed with the [MIT license](https://opensource.org/licenses/MIT).

## Intro by example

There is [full documentation here](https://htmlpreview.github.io/?https://github.com/anet-be/lua-yottadb/blob/master/docs/yottadb.html), but here are some examples to get you started.

Let's tinker with setting some database values in different ways:

```lua
> ydb = require 'yottadb'
> n = ydb.node('^hello')  -- create node object pointing to YottaDB global ^hello

> n:get()  -- get current value of the node in the database
nil
> n:set('Hello World')
> n:get()
Hello World

-- Equivalent ways to create a new subnode object pointing to an added 'cowboy' subscript
> n2 = ydb.node('^hello')('cowboy')
> n2 = ydb.node('^hello', 'cowboy')
> n2 = n('cowboy')
> n2 = n['cowboy']
> n2 = n.cowboy

> n2:set('Howdy partner!')  -- set ^hello('cowboy') to 'Howdy partner!'
> n2, n2:get()
^hello("cowboy")	Howdy partner!

> n2.ranches:set(3)  -- create subnode object ydb.node('^hello', 'cowboy', 'ranches') and set to 3
> n2.ranches._ = 3   -- same as :set() but 3x faster (ugly but direct access to value)

> n3 = n.chinese  -- add a second subscript to '^hello', creating a third object
> n3:set('你好世界!') -- value can be number or string, including UTF-8
> n3, n3:get()
hello("chinese")	你好世界!
```

We can also use other [methods of the node object](https://htmlpreview.github.io/?https://github.com/anet-be/lua-yottadb/blob/master/docs/yottadb.html#Class_node) like `incr() name() has_value() has_key() lock_incr()`:

```lua
> n2.ranches:incr(2)  -- increment
5
> n2:name()
cowboy
> n2.__name()  -- uglier but 15x faster access to node object methods
cowboy
```

(Note: lua-yottadb is able to distinguish n:method(n) from subnode creation n.method. See [details here](https://htmlpreview.github.io/?https://github.com/anet-be/lua-yottadb/blob/master/docs/yottadb.html#Class_node).)

Now, let's try `dump` to see what we've got so far:

```lua
> n:dump()
^hello="Hello World"
^hello("chinese")="你好世界!"
^hello("cowboy")="Howdy partner!"
^hello("cowboy","ranches")="5"
```

We can delete a node -- either its *value* or its entire *tree*:

```lua
> n:set(nil)  -- delete the value of '^hello', but not any of its child nodes
> n:get()
nil
> n:dump()  -- the values of the child node are still in the database
hello("chinese")="你好世界!!"
hello("cowboy")="Howdy partner!"

> n:delete_tree() -- delete both the value at the '^hello' node and all of its children
> n:dump()
nil
```

### Doing something useful

Let's use Lua to calculate the height of 3 oak trees, based on their shadow length and the angle of the sun. Method `settree()` is a handy way to enter literal data into the database from a Lua table constructor:

```lua
> trees = ydb.node('^oaks')  -- create node object pointing to YottaDB global ^oaks
> -- store initial data values into database subnodes ^oaks('1', 'shadow'), etc.
> trees:settree({{shadow=10, angle=30}, {shadow=13, angle=30}, {shadow=15, angle=45}})

> for index, oaktree in pairs(trees) do
     oaktree.height.__ = oaktree.shadow.__ * math.tan( math.rad(oaktree.angle.__) )
     print( string.format('Oak %s is %.1fm high', index, oaktree.height.__) )
  end
Oak 1 is 5.8m high
Oak 2 is 7.5m high
Oak 3 is 15.0m high
```

### Database transactions are also available:

```lua
> Znode = ydb.node('^Ztest')
> transact = ydb.transaction(function(end_func)
  print("^Ztest starts as", Znode:get())
  Znode:set('value')
  end_func()
  end)

> transact(ydb.trollback)  -- perform a rollback after setting Znode
^Ztest starts as	nil
YDB Error: 2147483645: YDB_TP_ROLLBACK
> Znode.get()  -- see that the data didn't get set
nil

> tries = 2
> function trier()  tries=tries-1  if tries>0 then ydb.trestart() end  end
> transact(trier)  -- restart with initial dbase state and try again
^Ztest starts as	nil
^Ztest starts as	nil
> Znode:get()  -- check that the data got set after restart
value

> Znode:set(nil)
> transact(function() end)  -- end the transaction normally without restart
^Ztest starts as	nil
> Znode:get()  -- check that the data got set
value
```

### Calling M from Lua

The Lua wrapper for M is designed for both speed and simple usage. The following calls M routines from [arithmetic.m](examples/arithmetic.m):

```lua
$ export ydb_routines=examples   # put arithmetic.m into ydb path
$ lua
> arithmetic = ydb.require('examples/arithmetic.ci')
> arithmetic.add_verbose("Sum is:", 2, 3)
Sum is: 5
Sum is: 5
> arithmetic.sub(5,7)
-2
```

Lua parameter types are converted to ydb types automatically according to the call-in table arithmetic.ci. If you need speed, avoid returning or outputting strings from M as they require the speed hit of memory allocation.

Note that the filename passed to ydb.require() may be either a call-in table filename or (if the string contains a `:`) a string specifying actual call-in routines. Review file `arithmetic.ci` and the [ydb manual](https://docs.yottadb.com/ProgrammersGuide/extrout.html#call-in-table). for details about call-in table specification.

### Development aids

You can enhance Lua to display database nodes or table contents when you type them at the Lua prompt. This project supplies a [`startup.lua`](examples/startup.lua) file to make this happen. To use it, simply set the environment variable:
 `export LUA_INIT=@path-to-lua-yottadb/examples/startup.lua`

Now Lua tables and database nodes display their contents when you type them at the Lua REPL prompt:

```lua
> t={test=5, subtable={x=10, y=20}}
> t
test: 5
subtable (table: 0x56494c7dd5b0):
  x: 10
  y: 20
> n=ydb.key('^oaks')
> n:settree({__='treedata', {shadow=10,angle=30}, {shadow=13,angle=30}})
> n
^oaks="treedata"
^oaks("1","angle")="30"
^oaks("1","shadow")="10"
^oaks("2","angle")="30"
^oaks("2","shadow")="13"
```

## Version History & Acknowledgements

Version history is documented in [changes.md](docs/changes.md).

[Mitchell](https://github.com/orbitalquark) is lua-yottadb's original author, basing it heavily on [YDBPython](https://gitlab.com/YottaDB/Lang/YDBPython). [Berwyn Hoyt](https://github.com/berwynhoyt) took over development to create version 1.0. It is sponsored by, and is copyright © 2022, [University of Antwerp Library](https://www.uantwerpen.be/en/library/).

## Installation

### Requirements

* YottaDB 1.34 or later.
* Lua 5.1 or greater. The Makefile will use your system's Lua version by default. To override this, run `make lua=/path/to/lua`.
  * Lua-yottadb has been built and tested with every major Lua version from 5.1 onward ([MLua](https://github.com/anet-be/mlua) does this with `make testall`)


**Note:** these bindings do not currently support multi-threaded applications ([more information here](https://github.com/anet-be/mlua#thread-safety)).

### Quickstart

If you do not already have it, install [YottaDB here](https://yottadb.com/product/get-started/). Then install lua-yottadb as follows:

```bash
git clone https://github.com/anet-be/lua-yottadb.git
cd lua-yottadb
make
sudo make install
```

### Detail

If more specifics are needed, build the bindings by running `make ydb_dist=/path/to/YDB/install` where */path/to/YDB/install* is the path to your installation of YottaDB that contains its header and shared library files.

Install the bindings by running `make install` or `sudo make install`, or copy the newly built
*_yottadb.so* and *yottadb.lua* files to somewhere in your Lua path. You can then use `local
yottadb = require('yottadb')` from your Lua scripts to communicate with YottaDB.  Then set up
your YDB environment as usual (i.e. source /path/to/YDB/install/ydb_env_set) before running
your Lua scripts.

The *Makefile* looks for Lua header files either in your compiler's default include path such
as /usr/local/include (the lua install default) or in */usr/include/luaX.Y*. Where *X.Y*
is the lua version installed on your system. If your Lua headers are elsewhere, run
`make lua_include=/path/to/your/lua/headers`.

### Example install of yottadb with minimal privileges

The following example builds and installs a local copy of YottaDB to *YDB/install* in the current
working directory. The only admin privileges required are to change ownership of *gtmsecshr*
to root, which YottaDB requires to run. (Normally, YottaDB's install script requires admin
privileges.)

```bash
# Install dependencies.
sudo apt-get install --no-install-recommends {libconfig,libelf,libgcrypt,libgpgme,libgpg-error,libssl}-dev
# Fetch YottaDB.
ydb_distrib="https://gitlab.com/api/v4/projects/7957109/repository/tags"
ydb_tmpdir='tmpdir'
mkdir $ydb_tmpdir
wget -P $ydb_tmpdir ${ydb_distrib} 2>&1 1>${ydb_tmpdir}/wget_latest.log
ydb_version=`sed 's/,/\n/g' ${ydb_tmpdir}/tags | grep -E "tag_name|.pro.tgz" | grep -B 1 ".pro.tgz" | grep "tag_name" | sort -r | head -1 | cut -d'"' -f6`
git clone --depth 1 --branch $ydb_version https://gitlab.com/YottaDB/DB/YDB.git
# Build YottaDB.
cd YDB
mkdir build
cd build/
cmake -D CMAKE_INSTALL_PREFIX:PATH=$PWD -D CMAKE_BUILD_TYPE=Debug ../
make -j4
make install
cd yottadb_r132
nano configure # replace 'root' with 'mitchell'
nano ydbinstall # replace 'root' with 'mitchell'
# Install YottaDB locally.
./ydbinstall --installdir /home/mitchell/code/lua/lua-yottadb/YDB/install --utf8 default --verbose --group mitchell --user mitchell --overwrite-existing
# may need to fix yottadb.pc
cd ../..
chmod ug+w install/ydb_env_set # change '. $ydb_tmp_env/out' to 'source $ydb_tmp_env/out'
sudo chown root.root install/gtmsecshr
sudo chmod a+s install/gtmsecshr

# Setup env.
source YDB/install/ydb_env_set

# Run tests with gdb.
ydb_gbldir=/tmp/lydb.gld gdb lua
b set
y
r -llydb tests/test.lua
```

