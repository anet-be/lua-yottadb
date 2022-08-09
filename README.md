# Overview

Lua bindings for YottaDB, sponsored by the [Library of UAntwerpen][].

Build the bindings by running `make ydb_dist=/path/to/YDB/install` where */path/to/YDB/install*
is the path to your installation of YottaDB that contains its header and shared library files.

Install the bindings by running `make install` or `sudo make install`, or copy the newly built
*_yottadb.so* and *yottadb.lua* files to somewhere in your Lua path. You can then use `local
yottadb = require('yottadb')` from your Lua scripts to communicate with YottaDB.  Then set up
your YDB environment as usual (i.e. source /path/to/YDB/install/ydb_env_set) before running
your Lua scripts.

Please see the documentation in *docs/* as well as the `test_module_*` tests in *tests/test.lua*
for examples of how to use these Lua bindings. These bindings were developed with reference to
YottaDB's Python bindings.

Note: these bindings are single-threaded and do not utilize YottaDB's multithreaded capabilities.

[Library of UAntwerpen]: http://www.uantwerpen.be/

## Requirements

* Lua 5.2 or greater. These bindings were built and tested with Lua 5.3. The *Makefile* assumes
  you have your Lua headers installed at */usr/include/lua5.3*. If your Lua headers are elsewhere,
  you can either modify *Makefile* or pass `CFLAGS=-I/path/to/your/lua` to `make`.
* YottaDB 1.34 or later.

## Sample Usage

    local yottadb = require('yottadb')

    -- Create key objects for conveniently accessing and manipulating database nodes.
    local key1 = yottadb.key('^hello')

    print(key1.name, key1.value) -- display current value of '^hello'
    key1.value = 'Hello World' -- set '^hello' to 'Hello World!'
    print(key1.name, key1.value)

    -- Add a 'cowboy' subscript to the global variable '^hello', creating a new key.
    local key2 = yottadb.key('^hello')('cowboy')
    key2.value = 'Howdy partner!' -- set '^hello('cowboy') to 'Howdy partner!'
    print(key2.name, key2.value)

    -- Add a second subscript to '^hello', creating a third key.
    local key3 = yottadb.key('^hello')('chinese')
    key3.value = '你好世界!' -- the value can be set to anything, including UTF-8
    print(key3.name, key3.value)

    for subscript in key1:subscripts() do -- loop through all subscripts of a key
      local sub_key = key1(subscript)
      print(sub_key.name, sub_key.value)
    end

    key1:delete_node() -- delete the value of '^hello', but not any of its child nodes

    print(key1.name, key1.value) -- no value is printed
    for subscript in key1:subscripts() do -- the values of the child node are still in the database
      local sub_key = key1(subscript)
      print(sub_key.name, sub_key.value)
    end

    key1.value = 'Hello World' -- reset the value of '^hello'
    print(key1.name, key1.value) -- prints the value
    key1:delete_tree() -- delete both the value at the '^hello' node and all of its children
    print(key1.name, key1.value) -- prints no value
    for subscript in key1:subscripts() do -- loop terminates immediately and displays no subscripts
      local sub_key = key1(subscript)
      print(sub_key, sub_key.value)
    end

    -- Database transactions are also available.
    local simple_transaction = yottadb.transaction(function(value)
      -- Set values directly with the set() function.
      yottadb.set('test1', value) -- set the local variable 'test1' to the given value
      yottadb.set('test2', value) -- set the local variable 'test2' to the given value
      local condition_a = false
      local condition_b = false
      if condition_a then
        -- When a yottadb.YDBTPRollback exception is raised YottaDB will rollback the transaction
        -- and then propagate the exception to the calling code.
        return yottadb.YDB_TP_ROLLBACK
      elseif condition_b then
        -- When a yottadb.YDBTPRestart exception is raised YottaDB will call the transaction again.
        -- Warning: This code is intentionally simplistic. An infinite loop will occur if
        --   yottadb.YDBTPRestart is continually raised
        return yottadb.YDB_TP_RESTART
      end
      return yottadb.YDB_OK -- success, transaction will be committed
    end)

    simple_transaction('test', db)
    print(db('test1'), db('test1').value)
    print(db('test2'), db('test2').value)

## Developer Notes

The following notes build and install a local copy of YottaDB to *YDB/install* in the current
working directory. The only admin privileges required are to change ownership of *gtmsecshr*
to root, which YottaDB requires to run. (Normally, YottaDB's install script requires admin
privileges.)

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
