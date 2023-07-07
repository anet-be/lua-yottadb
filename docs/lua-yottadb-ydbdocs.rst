



+++++++++++++++++++++++++++++
Low level wrapper functions
+++++++++++++++++++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~
block_M_signals (bool)
~~~~~~~~~~~~~~~~~~~~~~~~

Block or unblock YDB signals for while M code is running.
This function is designed to be passed to yottadb.init() as the ``signal_blocker`` parameter.
Most signals (listed in ``BLOCKED_SIGNALS`` in callins.c) are blocked using sigprocmask()
but SIGLARM is not blocked; instead, sigaction() is used to set its SA_RESTART flag while
in Lua, and cleared while in M. This makes the OS automatically restart IO calls that are
interrupted by SIGALRM. The benefit of this over blocking is that the YDB SIGALRM
handler does actually run, allowing YDB to flush the database or IO as necessary without
your M code having to call the M command ``VIEW "FLUSH"``.

Note: this function does take time, as OS calls are slow. Using it will increase the M calling
overhead by about 1.4 microseconds: 2-5x the bare calling overhead (see ``make benchmarks``)
The call to init() already saves initial values of SIGALRM flags and Sigmask to reduce
OS calls and make it as fast as possible.



* ``bool``:
  true to block; false to unblock all YDB signals


:Returns:
    nothing





~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
data (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Return whether a node has a value or subtree.



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table


:Returns:
  #. 0: (node has neither value nor subtree)

  #. 1: node has value, not subtree

  #. 10: node has no value, but does have a subtree

  #. 11: node has both value and subtree




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb.set('^Population', {'Belgium'}, 1367000)
      ydb.set('^Population', {'Thailand'}, 8414000)
      ydb.set('^Population', {'USA'}, 325737000)
      ydb.set('^Population', {'USA', '17900802'}, 3929326)
      ydb.set('^Population', {'USA', '18000804'}, 5308483)

      ydb = require('yottadb')
      ydb.data('^Population')
      -- 10.0
      ydb.data('^Population', {'USA'})
      -- 11.0



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
delete_node (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deletes the value of a single database variable/node.



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table





:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.set('^Population', {'Belgium'}, 1367000)
      ydb.delete_node('^Population', {'Belgium'})
      ydb.get('^Population', {'Belgium'})
      -- nil



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
delete_tree (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deletes a database variable/node tree/subtree.



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table





:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.get('^Population', {'USA'})
      -- 325737000
      ydb.get('^Population', {'USA', '17900802'})
      -- 3929326
      ydb.get('^Population', {'USA', '18000804'})
      -- 5308483
      ydb.delete_tree('^Population', {'USA'})
      ydb.data('^Population', {'USA'})
      -- 0.0



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
get (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Gets and returns the value of a database variable/node, or ``nil`` if the variable/node does not exist.



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}


:Returns:
    string value or ``nil``




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.get('^Population')
      -- nil
      ydb.get('^Population', {'Belgium'})
      -- 1367000
      ydb.get('$zgbldir')
      -- /home/ydbuser/.yottadb/r1.34_x86_64/g/yottadb.gld



~~~~~~~~~~~~~~~~~~~~~~~~~~
get_error_code (message)
~~~~~~~~~~~~~~~~~~~~~~~~~~

Get the YDB error code (if any) contained in the given error message.



* ``message``:
  String error message.


:Returns:
  #. the YDB error code (if any) for the given error message,

  #. or ``nil`` if the message is not a YDB error.




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.get_error_code('YDB Error: -150374122: %YDB-E-ZGBLDIRACC, Cannot access global directory !AD!AD!AD.')
      -- -150374122



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
incr (varname[, subsarray][, ...], increment)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Increments the numeric value of a database variable/node.
Raises an error on overflow.
Caution: increment is *not* optional if ``...`` list of subscript is provided.
Otherwise incr() cannot tell whether last parameter is a subscript or an increment.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}

* ``increment``:
  Number or string amount to increment by (default=1)


:Returns:
    the new value




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.get('num')
      -- 4
      ydb.incr('num', 3)
      -- 7
      ydb.incr('num')
      -- 8



~~~~~~~~~~~~~~~~~~~~~~~~~
init ([signal_blocker])
~~~~~~~~~~~~~~~~~~~~~~~~~

Initialize ydb and set blocking of M signals.
If ``signal_blocker`` is specified, block M signals which could otherwise interrupt slow IO operations like reading from user/pipe.
Also read the notes on signals in the README.
Note: any calls to the YDB API also initialize YDB; any subsequent call here will set ``signal_blocker`` but not re-init YDB.
Assert any errors.



* ``signal_blocker``:
  (*optional*)
  specifies a Lua callback CFunction (e.g. ``yottadb.block_M_signals()``) which will be
  called with parameter false on entry to M, and with true on exit from M, so as to unblock YDB signals while M is in use.
  Setting ``signal_blocker`` to nil switches off signal blocking.
  Note: Changing this to support a generic Lua function as callback would be possible but slow, as it would require
  fetching the function pointer from a C closure, and using ``lua_call()``.


:Returns:
    nothing





~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock ([nodes[, timeout]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Releases all locks held and attempts to acquire all requested locks, waiting if requested.
Raises an error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.



* ``nodes``:
  (*optional*)
  Table array containing {varname[, subs]} or node objects that specify the lock names to lock.

* ``timeout``:
  (*optional*)
  Integer timeout in seconds to wait for the lock.


:Returns:
    0 (always)





~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock_decr (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Decrements a lock of the same name as {varname, subsarray}, releasing it if possible.
Releasing a lock cannot create an error unless the varname/subsarray names are invalid.



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table


:Returns:
    0 (always)





~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock_incr (varname[, subsarray[, ...[, timeout]]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Attempts to acquire or increment a lock of the same name as {varname, subsarray}, waiting if requested.
Raises a error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
Caution: timeout is *not* optional if ``...`` list of subscript is provided.
Otherwise lock_incr cannot tell whether it is a subscript or a timeout.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}

* ``timeout``:
  (*optional*)
  Integer timeout in seconds to wait for the lock.
  Optional only if subscripts is a table.


:Returns:
    0 (always)





~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node_next (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the full subscript list (think 'path') of the next node after a database variable/node.
A next node chain started from varname will eventually reach all nodes under that varname in order.

Note: ``node:gettree()`` or ``node:subscripts()`` may be a better way to iterate a node tree



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table


:Returns:
  #. 0 (always)

  #. list of subscripts for the node, or ``nil`` if there isn't a next node




:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      print(table.concat(ydb.node_next('^Population'), ', '))
      -- Belgium
      print(table.concat(ydb.node_next('^Population', {'Belgium'}), ', '))
      -- Thailand
      print(table.concat(ydb.node_next('^Population', {'Thailand'}), ', '))
      -- USA
      print(table.concat(ydb.node_next('^Population', {'USA'}), ', '))
      -- USA, 17900802
      print(table.concat(ydb.node_next('^Population', {'USA', '17900802'}), ', '))
      -- USA, 18000804


  .. code-block:: lua
    :dedent: 2
    :force:

      -- Note: The format used above to print the next node will give an error if there is no next node, i.e., the value returned is nil.
      -- This case will have to be handled gracefully. The following code snippet is one way to handle nil as the return value:

      local ydb = require('yottadb')
      next = ydb.node_next('^Population', {'USA', '18000804'})
      if next ~= nil then
        print(table.concat(next, ', '))
      else
        print(next)
      end



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node_previous (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the full subscript list (think 'path') of the previous node after a database variable/node.
A previous node chain started from varname will eventually reach all nodes under that varname in reverse order.

Note: ``node:gettree()`` or ``node:subscripts()`` may be a better way to iterate a node tree



* ``varname``:
  String of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts to append after any elements in optional subsarray table


:Returns:
  #. 0 (always)

  #. list of subscripts for the node, or ``nil`` if there isn't a previous node




:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      print(table.concat(ydb.node_previous('^Population', {'USA', '18000804'}), ', '))
      -- USA, 17900802
      print(table.concat(ydb.node_previous('^Population', {'USA', '17900802'}), ', '))
      -- USA
      print(table.concat(ydb.node_previous('^Population', {'USA'}), ', '))
      -- Thailand
      print(table.concat(ydb.node_previous('^Population', {'Thailand'}), ', '))
      -- Belgium


  .. code-block:: lua
    :dedent: 2
    :force:

      -- Note: See the note on handling nil return values in node_next() which applies to node_previous() as well.



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
set (varname[, subsarray][, ...], value)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Sets the value of a database variable/node.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}

* ``value``:
  String/number/nil value to set node to. If this is a number, it is converted to a string. If it is nil, the value is deleted.


:Returns:
    ``value``




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb = require('yottadb')
      ydb.set('^Population', {'Belgium'}, 1367000)
      ydb.set('^Population', {'Thailand'}, 8414000)
      ydb.set('^Population', {'USA'}, 325737000)
      ydb.set('^Population', {'USA', '17900802'}, 3929326)
      ydb.set('^Population', {'USA', '18000804'}, 5308483)



~~~~~~~~~~~~~
str2zwr (s)
~~~~~~~~~~~~~

Returns the zwrite-formatted version of the given string.



* ``s``:
  String to format.


:Returns:
    formatted string




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb=require('yottadb')
      str='The quick brown dog\b\b\bfox jumps over the lazy fox\b\b\bdog.'
      print(str)
      -- The quick brown fox jumps over the lazy dog.
      ydb.str2zwr(str)
      -- "The quick brown dog"_$C(8,8,8)_"fox jumps over the lazy fox"_$C(8,8,8)_"dog."



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
subscript_next (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the next subscript for a database variable/node, or ``nil`` if there isn't one.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}


:Returns:
    string subscript name, or ``nil`` if there are no more subscripts




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb=require('yottadb')
      ydb.subscript_next('^Population', {''})
      -- Belgium
      ydb.subscript_next('^Population', {'Belgium'})
      -- Thailand
      ydb.subscript_next('^Population', {'Thailand'})
      -- USA



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
subscript_previous (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the previous subscript for a database variable/node, or ``nil`` if there isn't one.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}


:Returns:
    string subscript name, or ``nil`` if there are no previous subscripts




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb=require('yottadb')
      ydb.subscript_previous('^Population', {'USA', ''})
      -- 18000804
      ydb.subscript_previous('^Population', {'USA', '18000804'})
      -- 17900802
      ydb.subscript_previous('^Population', {'USA', '17900802'})
      -- nil
      ydb.subscript_previous('^Population', {'USA'})
      -- Thailand



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
subscripts (varname[, subsarray[, ...[, reverse]]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns an iterator for iterating over database *sibling* subscripts starting from given varname(subs).
Note: this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
It operates differently than ``node:subscipts()`` which yields all subscripts that are *children* of the given node.
It has a kludgy implementation due to implementing so many input options as well as handling a
cachearray input (which is purely so that key:subscripts can call it).
As a result, it's not very efficient. But I don't anticipate it will get much use due to node:subscripts()
having a more intuitive outcome, in my opinion.



* ``varname``:
  of database node (this can also be replaced by cachearray)

* ``subsarray``:
  (*optional*)
  Table of {subscripts}

* ``...``:
  (*optional*)
  List of subscripts or table {subscripts}

* ``reverse``:
  (*optional*)
  Flag that indicates whether to iterate backwards.  Not optional when '...' is provided


:Returns:
    iterator





~~~~~~~~~~~~~~~~~~~~~~
ydb_eintr_handler ()
~~~~~~~~~~~~~~~~~~~~~~

Lua function to call ``ydb_eintr_handler()``.
If users wish to handle EINTR errors themselves, instead of blocking signals, they should call
``ydb_eintr_handler()`` when they get an EINTR error, before restarting the erroring OS system call.



:Returns:
    YDB_OK on success, and >0 on error (with message in ZSTATUS)





~~~~~~~~~~~~~
zwr2str (s)
~~~~~~~~~~~~~

Returns the string described by the given zwrite-formatted string.



* ``s``:
  String in zwrite format.


:Returns:
    string




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb=require('yottadb')
      str1='The quick brown dog\b\b\bfox jumps over the lazy fox\b\b\bdog.'
      zwr_str=ydb.str2zwr(str1)
      print(zwr_str)
      -- "The quick brown dog"_$C(8,8,8)_"fox jumps over the lazy fox"_$C(8,8,8)_"dog."
      str2=ydb.zwr2str(zwr_str)
      print(str2)
      -- The quick brown fox jumps over the lazy dog.
      str1==str2
      -- true



++++++++++++++
Transactions
++++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
tp ([id][, varnames], f[, ...])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Initiates a transaction (low level function).



* ``id``:
  (*optional*)
  optional string transaction id. For special ids ``BA`` or ``BATCH``, see `ydb docs here <https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing>`_.

* ``varnames``:
  (*optional*)
  optional table of local M variable names to restore on transaction restart
  (or ``{'*'}`` for all locals) -- restoration does apply to rollback

* ``f``:
  Function to call. The transaction's affected globals are:

 * committed if the function returns nothing or ``yottadb.YDB_OK``
 * restarted if the function returns ``yottadb.YDB_TP_RESTART`` (``f`` will be called again)
   Note: restarts are subject to ``$ZMAXTPTIME`` after which they cause error ``%YDB-E-TPTIMEOUT``
 * not committed if the function returns ``yottadb.YDB_TP_ROLLBACK`` or errors out.

* ``...``:
  (*optional*)
  arguments to pass to ``f``





:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      local ydb = require('yottadb')

      function transfer_to_savings(t)
         local ok, e = pcall(ydb.incr, '^checking', -t)
         if (ydb.get_error_code(e) == ydb.YDB_TP_RESTART) then
            return ydb.YDB_TP_RESTART
         end
         if (not ok or tonumber(e)<0) then
            return ydb.YDB_TP_ROLLBACK
         end
         local ok, e = pcall(ydb.incr, '^savings', t)
         if (ydb.get_error_code(e) == ydb.YDB_TP_RESTART) then
            return ydb.YDB_TP_RESTART
         end
         if (not ok) then
            return ydb.YDB_TP_ROLLBACK
         end
         return ydb.YDB_OK
      end

      ydb.set('^checking', 200)
      ydb.set('^savings', 85000)

      print("Amount currently in checking account: $" .. ydb.get('^checking'))
      print("Amount currently in savings account: $" .. ydb.get('^savings'))

      print("Transferring $10 from checking to savings")
      local ok, e = pcall(ydb.tp, '', {'*'}, transfer_to_savings, 10)
      if (not e) then
         print("Transfer successful")
      elseif (ydb.get_error_code(e) == ydb.YDB_TP_ROLLBACK) then
         print("Transfer not possible. Insufficient funds")
      end

      print("Amount in checking account: $" .. ydb.get('^checking'))
      print("Amount in savings account: $" .. ydb.get('^savings'))

      print("Transferring $1000 from checking to savings")
      local ok, e = pcall(ydb.tp, '', {'*'}, transfer_to_savings, 1000)
      if (not e) then
         print("Transfer successful")
      elseif (ydb.get_error_code(e) == ydb.YDB_TP_ROLLBACK) then
         print("Transfer not possible. Insufficient funds")
      end

      print("Amount in checking account: $" .. ydb.get('^checking'))
      print("Amount in savings account: $" .. ydb.get('^savings'))


  .. code-block:: lua
    :dedent: 2
    :force:

      Output:
        Amount currently in checking account: $200
        Amount currently in savings account: $85000
        Transferring $10 from checking to savings
        Transfer successful
        Amount in checking account: $190
        Amount in savings account: $85010
        Transferring $1000 from checking to savings
        Transfer not possible. Insufficient funds
        Amount in checking account: $190
        Amount in savings account: $85010



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
transaction ([id][, varnames], f)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns a high-level transaction-safed version of the given function.
It will be called within a yottadb transaction and the dbase globals restored on error or ``trollback()``



* ``id``:
  (*optional*)
  optional string transaction id. For special ids ``BA`` or ``BATCH``, see `ydb docs here <https://docs.yottadb.com/ProgrammersGuide/langfeat.html#transaction-processing>`_.

* ``varnames``:
  (*optional*)
  optional table of local M variable names to restore on transaction trestart()
  (or ``{'*'}`` for all locals) -- restoration does apply to rollback

* ``f``:
  Function to call. The transaction's affected globals are:

 * committed if the function returns nothing or ``yottadb.YDB_OK``
 * restarted if the function returns ``yottadb.YDB_TP_RESTART`` (``f`` will be called again)
   Note: restarts are subject to ``$ZMAXTPTIME`` after which they cause error ``%YDB-E-TPTIMEOUT``
 * not committed if the function returns ``yottadb.YDB_TP_ROLLBACK`` or errors out.


:Returns:
    transaction-safed function.




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      Znode = ydb.node('^Ztest')
      transact = ydb.transaction(function(end_func)
        print("^Ztest starts as", Znode:get())
        Znode:set('value')
        end_func()
        end)

      transact(ydb.trollback)  -- perform a rollback after setting Znode
      -- ^Ztest starts as	nil
      -- YDB Error: 2147483645: YDB_TP_ROLLBACK
      Znode.get()  -- see that the data didn't get set
      -- nil

      tries = 2
      function trier()  tries=tries-1  if tries>0 then ydb.trestart() end  end
      transact(trier)  -- restart with initial dbase state and try again
      -- ^Ztest starts as	nil
      -- ^Ztest starts as	nil
      Znode:get()  -- check that the data got set after restart
      -- value

      Znode:set(nil)
      transact(function() end)  -- end the transaction normally without restart
      -- ^Ztest starts as	nil
      Znode:get()  -- check that the data got set
      -- value



~~~~~~~~~~~~~
trestart ()
~~~~~~~~~~~~~

Make the currently running transaction function restart immediately.







~~~~~~~~~~~~~~
trollback ()
~~~~~~~~~~~~~~

Make the currently running transaction function rollback immediately and produce a rollback error.







++++++++++++++++++++++
High level functions
++++++++++++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
dump (node[, subsarray[, maxlines=30]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Dump the specified node and its children



* ``node``:
  Either a node object with ``...`` subscripts or glvn varname with ``...`` subsarray

* ``subsarray``:
  (*optional*)
  Table of subscripts to add to node -- valid only if the second parameter is a table

* ``maxlines``:
  (*default*: 30)
  Maximum number of lines to output before stopping dump


:Returns:
    dump as a string




:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      ydb.dump(node, {subsarray, ...}[, maxlines])


  .. code-block:: lua
    :dedent: 2
    :force:

      ydb.dump('^MYVAR', 'people')



~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:dump ([maxlines=30])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Dump the specified node and its children



* ``maxlines``:
  (*default*: 30)
  Maximum number of lines to output before stopping dump


:Returns:
    dump as a string





~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:gettree ([maxdepth[, filter[, _value[, _depth]]]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Fetch database node and subtree and return a Lua table of it.
But be aware that order is not preserved by Lua tables.

Note: special field name ``__`` in the returned table indicates the value of the node itself.



* ``maxdepth``:
  (*optional*)
  subscript depth to fetch (nil=infinite; 1 fetches first layer of subscript's values only)

* ``filter``:
  (*optional*)
  ``function(node, node_top_subscript_name, value, recurse, depth)`` or nil

 * if filter is nil, all values are fetched unfiltered
 * if filter is a function it is invoked on every subscript
   to allow it to cast/alter every value and recurse flag;
   note that at node root (depth=0), subscript passed to filter is the empty string ""
 * filter may optionally return two items: ``value``, ``recurse`` -- copies of the input parameters, optionally altered:
    * if filter returns ``value`` then gettree will store it in the table for that database subscript/value; or store nothing if ``value=nil``
    * if filter returns ``recurse=false``, it will prevent recursion deeper into that particular subscript; if ``nil``, it will use the original value of recurse

* ``_value``:
  (*optional*)
  is for internal use only (to avoid duplicate value fetches, for speed)

* ``_depth``:
  (*optional*)
  is for internal use only (to record depth of recursion) and must start unspecified (nil)


:Returns:
    Lua table containing data




:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      tbl = node:gettree()


  .. code-block:: lua
    :dedent: 2
    :force:

      node:gettree(nil, print) end)
       -- prints details of every node in the tree



~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:settree (tbl[, filter[, _seen]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Populate database from a table.
In its simplest form:
::

    node:settree({__='berwyn', weight=78, ['!@#$']='junk', appearance={__='handsome', eyes='blue', hair='blond'}, age=yottadb.DELETE})



* ``tbl``:
  is the table to store into the database:

 * special field name ``__`` sets the value of the node itself, as opposed to a subnode
 * assign special value ``yottadb.DELETE`` to a node to delete the value of the node. You cannot delete the whole subtree

* ``filter``:
  (*optional*)
  optional function(node, key, value) or nil

 * if filter is nil, all values are set unfiltered
 * if filter is a function(node, key, value) it is invoked on every node
   to allow it to cast/alter every key name and value
 * filter must return the same or altered: key, value
 * type errors can be handled (or ignored) using this function, too.
 * if filter returns yottadb.DELETE as value, the key is deleted
 * if filter returns nil as key or value, settree will simply not update the current database value

* ``_seen``:
  (*optional*)
  is for internal use only (to prevent accidental duplicate sets: bad because order setting is not guaranteed)





:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      n=ydb.node('^oaks')
      n:settree({__='treedata', {shadow=10,angle=30}, {shadow=13,angle=30}})
      n:dump()


  .. code-block:: lua
    :dedent: 2
    :force:

      -- outputs:
      ^oaks="treedata"
      ^oaks("1","angle")="30"
      ^oaks("1","shadow")="10"
      ^oaks("2","angle")="30"
      ^oaks("2","shadow")="13"



~~~~~~~~~~~~~~~~~~~~~~~
require (Mprototypes)
~~~~~~~~~~~~~~~~~~~~~~~

Import Mumps routines as Lua functions specified in ydb 'call-in' file.

See example call-in file `arithmetic.ci <https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.ci>`_
and matching M file `arithmetic.m <https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.m>`_



* ``Mprototypes``:
  is a list of lines in the format of ydb 'callin' files per ydb_ci().
  If the string contains ``:`` it is considered to be the call-in specification itself;
  otherwise it is treated as the filename of a call-in file to be opened and read.


:Returns:
    A table of functions analogous to a Lua module.
    Each function in the table will call an M routine specified in ``Mprototypes``.




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      $ export ydb_routines=examples   # put arithmetic.m (below) into ydb path
      $ lua
      arithmetic = yottadb.require('examples/arithmetic.ci')
      arithmetic.add_verbose("Sum is:", 2, 3)
      -- Sum is: 5
      -- Sum is: 5
      arithmetic.sub(5,7)
      -- -2



++++++++++++
Class node
++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node (varname[, subsarray][, ...], node)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Creates object that represents a YottaDB node.
This node has all of the class methods defined below.
Calling the returned node with one or more string parameters returns a new node further subscripted by those strings.
Calling this on an existing node ``yottadb.node(node)`` creates an (immutable) copy of node.

 **Note1:** Although the syntax ``node:method()`` is pretty, be aware that it is slow. If you are concerned
   about speed, use ``node:__method()`` instead, which is equivalent but 15x faster.
   This is because Lua expands ``node:method()`` to ``node.method(node)``, so lua-yottadb creates
   an intermediate object of database subnode ``node.method``, thinking it is is a database subnode access.
   Then, when this object gets called with ``()``, lua-yottadb discovers that its first parameter is of type ``node`` --
   at which point it finally knows invoke ``node.__method()`` instead of treating it as a database subnode access.

 **Note2:** Because lua-yottadb's underlying method access is with the ``__`` prefix, database node names
   starting with two underscores are not accessable using dot notation: instead use mynode('__nodename') to
   access a database node named ``__nodename``. In addition, Lua object methods starting with two underscores,
   like ``__tostring``, are only accessible with an *additional* ``__`` prefix, for example, ``node:____tostring()``.

 **Note3:** Several standard Lua operators work on nodes. These are: ``+ - = pairs() tostring()``



* ``varname``:
  String variable name.

* ``subsarray``:
  (*optional*)
  table of {subscripts}

* ``...``:
  (*optional*)
  list of subscripts to append after any elements in optional subsarray table

* ``node``:
  ``|key:`` is an existing node or key to copy into a new object (you can turn a ``key`` type into a ``node`` type this way)


:Returns:
    node object with metatable yottadb.node




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      yottadb.node('varname'[, {subsarray}][, ...])
      yottadb.node(node|key[, {}][, ...])
      yottadb.node('varname')('sub1', 'sub2')
      yottadb.node('varname', 'sub1', 'sub2')
      yottadb.node('varname', {'sub1', 'sub2'})
      yottadb.node('varname').sub1.sub2
      yottadb.node('varname')['sub1']['sub2']



~~~~~~~~~~~~~~~~~~
node:__ipairs ()
~~~~~~~~~~~~~~~~~~

Not implemented - use ``pairs(node)`` or ``node:__pairs()`` instead.
See alternative usage below.
The reason this is not implemented is that since
Lua >=5.3 implements ipairs via ``__index()``.
This would mean that ``__index()`` would have to treat integer subscript lookup specially, so:

 * although ``node['abc']``  => produces a new node so that ``node.abc.def.ghi`` works
 * ``node[1]``  => would have to produce value ``node(1).__`` so ipairs() works

   Since ipairs() will be little used anyway, the consequent inconsistency discourages implementation.

Alternatives using pairs() are as follows:






:Examples:

  .. code-block:: lua
    :dedent: 2
    :force:

      for k,v in pairs(node) do   if not tonumber(k) break end   <do_your_stuff with k,v>   end
       -- this works since standard M order is numbers first -- unless your db specified another collation


  .. code-block:: lua
    :dedent: 2
    :force:

      for i=1,1/0 do   v=node[i].__  if not v break then   <do_your_stuff with k,v>   end
       -- alternative that ensures integer keys



~~~~~~~~~~~~~~~~~~~~~~~~~~
node:__pairs ([reverse])
~~~~~~~~~~~~~~~~~~~~~~~~~~

Makes pairs() work - iterate over the child (subnode, subnode_value, subscript) of given node.
You can use either ``pairs(node)`` or ``node:pairs()``.
If you need to iterate in reverse (or in Lua 5.1), use node:pairs(reverse) instead of pairs(node).

*Caution:* for the sake of speed, the iterator supplies a *mutable* node. This means it can
re-use the same node for each iteration by changing its last subscript, making it faster.
But if your loop needs to retain a reference to the node after loop iteration, it should create
an immutable copy of that node using ``ydb.node(node)``.
Mutability can be tested for using node:ismutable()

Notes:

 * pairs() order is guaranteed to equal the M collation sequence order
   (even though pairs() order is not normally guaranteed for Lua tables).
   This means that pairs() is a reasonable substitute for ipairs which is not implemented.
 * this is very slightly slower than node:subscripts() which only iterates subscript names without
   fetching the node value.



* ``reverse``:
  (*optional*)
  Boolean flag iterates in reverse if true


:Returns:
    subnode, subnode_value_or_nil, subscript




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      for subnode,value[,subscript] in pairs(node) do ...
       -- where subnode is a node/key object.



~~~~~~~~~~~~~~~~~~~~~
node:delete_tree ()
~~~~~~~~~~~~~~~~~~~~~

Delete database tree pointed to by node object







~~~~~~~~~~~~~~~~~~~~~~
node:get ([default])
~~~~~~~~~~~~~~~~~~~~~~

Get node's value.
Equivalent to (but 2.5x slower than) ``node.__``



* ``default``:
  (*optional*)
  return value if the node has no data; if not supplied, nil is the default


:Returns:
    value of the node





~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:incr ([increment=1])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Increment node's value



* ``increment``:
  (*default*: 1)
  Amount to increment by (negative to decrement)


:Returns:
    the new value





~~~~~~~~~~~~~~~~~~~~~~~
node:lock ([timeout])
~~~~~~~~~~~~~~~~~~~~~~~

Releases all locks held and attempts to acquire a lock matching this node, waiting if requested.



* ``timeout``:
  (*optional*)
  Integer timeout in seconds to wait for the lock.






~~~~~~~~~~~~~~~~~~~
node:lock_decr ()
~~~~~~~~~~~~~~~~~~~

Decrements a lock matching this node, releasing it if possible.







~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:lock_incr ([timeout])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Attempts to acquire or increment a lock matching this node, waiting if requested.



* ``timeout``:
  (*optional*)
  Integer timeout in seconds to wait for the lock.






~~~~~~~~~~~~~~~~~~
node:set (value)
~~~~~~~~~~~~~~~~~~

Set node's value.
Equivalent to (but 4x slower than) ``node.__ = x``



* ``value``:
  New value or nil to delete node






~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:subscripts ([reverse])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Return iterator over the *child* subscript names of a node (in M terms, collate from "" to "").
Unlike ``yottadb.subscripts()``, ``node:subscripts()`` returns all *child* subscripts, not subsequent *sibling* subscripts in the same level.

Very slightly faster than node:__pairs() because it iterates subscript names without fetching the node value.

Note that subscripts() order is guaranteed to equal the M collation sequence.



* ``reverse``:
  (*optional*)
  set to true to iterate in reverse order


:Returns:
    iterator over *child* subscript names of a node, returning a sequence of subscript name strings




:Example:

  .. code-block:: lua
    :dedent: 2
    :force:

      for subscript in node:subscripts() do ...



+++++++++++++++++
Node properties
+++++++++++++++++




~~~~~~~~~~~~~~
node:data ()
~~~~~~~~~~~~~~

Fetch the 'data' flags of the node @see data







~~~~~~~~~~~~~~~
node:depth ()
~~~~~~~~~~~~~~~

Fetch the depth of the node, i.e.  how many subscripts it has







~~~~~~~~~~~~~~~~~~
node:has_tree ()
~~~~~~~~~~~~~~~~~~

Return true if the node has a tree; otherwise false







~~~~~~~~~~~~~~~~~~~
node:has_value ()
~~~~~~~~~~~~~~~~~~~

Return true if the node has a value; otherwise false







~~~~~~~~~~~~~~~~~~~
node:ismutable ()
~~~~~~~~~~~~~~~~~~~

Return true if the node is mutable; otherwise false







~~~~~~~~~~~~~~
node:name ()
~~~~~~~~~~~~~~

Fetch the name of the node, i.e.  the rightmost subscript







~~~~~~~~~~~~~~~~~~~
node:subsarray ()
~~~~~~~~~~~~~~~~~~~

Return node's subsarray of subscript strings as a table







~~~~~~~~~~~~~~~~~
node:varname ()
~~~~~~~~~~~~~~~~~

Fetch the varname of the node, i.e.  the leftmost subscript







+++++++++++
Class key
+++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key (varname[, subsarray])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Creates deprecated object that represents a YDB node.
``key()`` is a subclass of ``node()`` designed to implement deprecated
property names for backward compatibility, as follows:

 * ``name`` (this node's subscript or variable name)
 * ``value`` (this node's value in the YottaDB database)
 * ``data`` (see data())
 * ``has_value`` (whether or not this node has a value)
 * ``has_tree`` (whether or not this node has a subtree)
 * ``__varname`` database variable name string -- for compatibility with a previous version
 * ``__subsarray`` table array of database subscript name strings -- for compatibility with a previous version
   and deprecated definitions of ``key:subscript()``, ``key:subscript_next()``, ``key:subscript_previous()``.




* ``varname``:
  String variable name.

* ``subsarray``:
  (*optional*)
  list of subscripts or table {subscripts}


:Returns:
    key object of the specified node with metatable yottadb._key





~~~~~~~~~~~~~~~~
key._property_
~~~~~~~~~~~~~~~~

Properties of key object that are accessed with a dot.
These properties, listed below, are unlike object methods, which are accessed with a colon.
This kind of property access is for backward compatibility.

For example, access data property with: ``key.data``



* ``name``:
  equivalent to ``node:name()``

* ``data``:
  equivalent to ``node:data()``

* ``has_value``:
  equivalent to ``node:has_value()``

* ``has_tree``:
  equivalent to ``node:has_tree()``

* ``value``:
  equivalent to ``node.__``

* ``__varname``:
  database variable name string -- for compatibility with a previous version

* ``__subsarray``:
  table array of database subscript name strings -- for compatibility with a previous version






~~~~~~~~~~~~~~~~~~~~
key:delete_node ()
~~~~~~~~~~~~~~~~~~~~

Deprecated way to delete database node value pointed to by node object.  Prefer node:set(nil)







~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key:subscript_next ([reset[, reverse]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deprecated way to get next *sibling* subscript.
Note: this starts from the given location and gives the next *sibling* subscript in the M collation sequence.
It operates differently than ``node:subscipts()`` which yields all subscripts that are *children* of the given node.
Deprecated because:

 * it keeps dangerous state in the object: causes bugs where old references to it think it's still original
 * it is more Lua-esque to iterate all subscripts in the node (think table) using pairs()
 * if sibling access becomes a common use-case, it should be reimplemented as an iterator.



* ``reset``:
  (*optional*)
  If ``true``, resets to the original subscript before any calls to subscript_next()

* ``reverse``:
  (*optional*)
  If ``true`` then get previous instead of next
  or subscript_previous()






~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key:subscript_previous ([reset])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deprecated way to get previous *sibling* subscript.
See notes for subscript_previous()



* ``reset``:
  (*optional*)
  If ``true``, resets to the original subscript before any calls to subscript_next()
  or subscript_previous()






~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key:subscripts ([reverse])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deprecated way to get same-level subscripts from this node onward.
Deprecated because:

 * pairs() is more Lua-esque
 * it was is non-intuitive that k:subscripts() iterates only subsequent subscripts, not all child subscripts



* ``reverse``:
  (*optional*)
  boolean






