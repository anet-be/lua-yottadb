


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

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
data (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Return whether a node has a value or subtree.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
delete_node (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deletes the value of a single database variable/node.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
delete_tree (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deletes a database variable/node tree/subtree.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
get (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Gets and returns the value of a database variable/node, or ``nil`` if the variable/node does not exist.

~~~~~~~~~~~~~~~~~~~~~~~~~~
get_error_code (message)
~~~~~~~~~~~~~~~~~~~~~~~~~~

Get the YDB error code (if any) contained in the given error message.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
incr (varname[, subsarray][, ...], increment)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Increments the numeric value of a database variable/node.
Raises an error on overflow.
Caution: increment is *not* optional if ``...`` list of subscript is provided.
Otherwise incr() cannot tell whether last parameter is a subscript or an increment.

~~~~~~~~~~~~~~~~~~~~~~~~~
init ([signal_blocker])
~~~~~~~~~~~~~~~~~~~~~~~~~

Initialize ydb and set blocking of M signals.
If ``signal_blocker`` is specified, block M signals which could otherwise interrupt slow IO operations like reading from user/pipe.
Also read the notes on signals in the README.
Note: any calls to the YDB API also initialize YDB; any subsequent call here will set ``signal_blocker`` but not re-init YDB.
Assert any errors.

~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock ([nodes[, timeout]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Releases all locks held and attempts to acquire all requested locks, waiting if requested.
Raises an error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock_decr (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Decrements a lock of the same name as {varname, subsarray}, releasing it if possible.
Releasing a lock cannot create an error unless the varname/subsarray names are invalid.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
lock_incr (varname[, subsarray[, ...[, timeout]]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Attempts to acquire or increment a lock of the same name as {varname, subsarray}, waiting if requested.
Raises a error yottadb.YDB_LOCK_TIMEOUT if a lock could not be acquired.
Caution: timeout is *not* optional if ``...`` list of subscript is provided.
Otherwise lock_incr cannot tell whether it is a subscript or a timeout.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node_next (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the full subscript list (think 'path') of the next node after a database variable/node.
A next node chain started from varname will eventually reach all nodes under that varname in order.

Note: ``node:gettree()`` may be a better way to iterate a node tree (see comment on ``yottadb.nodes()``)

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node_previous (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the full subscript list (think 'path') of the previous node after a database variable/node.
A previous node chain started from varname will eventually reach all nodes under that varname in reverse order.

Note: ``node:gettree()`` may be a better way to iterate a node tree (see comment on ``yottadb.nodes()``)

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
set (varname[, subsarray][, ...], value)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Sets the value of a database variable/node.

~~~~~~~~~~~~~
str2zwr (s)
~~~~~~~~~~~~~

Returns the zwrite-formatted version of the given string.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
subscript_next (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the next subscript for a database variable/node, or ``nil`` if there isn't one.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
subscript_previous (varname[, subsarray[, ...]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns the previous subscript for a database variable/node, or ``nil`` if there isn't one.

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

~~~~~~~~~~~~~~~~~~~~~~
ydb_eintr_handler ()
~~~~~~~~~~~~~~~~~~~~~~

Lua function to call ``ydb_eintr_handler()``.
If users wish to handle EINTR errors themselves, instead of blocking signals, they should call
``ydb_eintr_handler()`` when they get an EINTR error, before restarting the erroring OS system call.

~~~~~~~~~~~~~
zwr2str (s)
~~~~~~~~~~~~~

Returns the string described by the given zwrite-formatted string.

++++++++++++++
Transactions
++++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
tp ([id][, varnames], f[, ...])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Initiates a transaction (low level function).

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
transaction ([id][, varnames], f)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Returns a high-level transaction-safed version of the given function.
It will be called within a yottadb transaction and the dbase globals restored on error or ``trollback()``

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

~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:dump ([maxlines=30])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Dump the specified node and its children

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:gettree ([maxdepth[, filter[, _value[, _depth]]]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Fetch database node and subtree and return a Lua table of it.
But be aware that order is not preserved by Lua tables.

Note: special field name ``__`` in the returned table indicates the value of the node itself.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:settree (tbl[, filter[, _seen]])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Populate database from a table.
In its simplest form:
::

    node:settree({__='berwyn', weight=78, ['!@#$']='junk', appearance={__='handsome', eyes='blue', hair='blond'}, age=yottadb.DELETE})

~~~~~~~~~~~~~~~~~~~~~~~
require (Mprototypes)
~~~~~~~~~~~~~~~~~~~~~~~

Import Mumps routines as Lua functions specified in ydb 'call-in' file.

See example call-in file `arithmetic.ci <https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.ci>`_
and matching M file `arithmetic.m <https://github.com/anet-be/lua-yottadb/blob/master/examples/arithmetic.m>`_

++++++++++++
Class node
++++++++++++




~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node (varname[, subsarray][, ...], node)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Creates and returns a new YottaDB node object.
This node has all of the class methods defined below.
Calling the returned node with one or more string parameters returns a new node further subscripted by those strings.
Calling this on an existing node ``yottadb.node(node)`` creates an (immutable) copy of node.

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

~~~~~~~~~~~~~~~~~~~~~
node:delete_tree ()
~~~~~~~~~~~~~~~~~~~~~

Delete database tree pointed to by node object

~~~~~~~~~~~~~~~~~~~~~~
node:get ([default])
~~~~~~~~~~~~~~~~~~~~~~

Get node's value.
Equivalent to (but 2.5x slower than) ``node.__``

~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:incr ([increment=1])
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Increment node's value

~~~~~~~~~~~~~~~~~~~~~~~
node:lock ([timeout])
~~~~~~~~~~~~~~~~~~~~~~~

Releases all locks held and attempts to acquire a lock matching this node, waiting if requested.

~~~~~~~~~~~~~~~~~~~
node:lock_decr ()
~~~~~~~~~~~~~~~~~~~

Decrements a lock matching this node, releasing it if possible.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:lock_incr ([timeout])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Attempts to acquire or increment a lock matching this node, waiting if requested.

~~~~~~~~~~~~~~~~~~
node:set (value)
~~~~~~~~~~~~~~~~~~

Set node's value.
Equivalent to (but 4x slower than) ``node.__ = x``

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
node:subscripts ([reverse])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Return iterator over the *child* subscript names of a node (in M terms, collate from "" to "").
Unlike ``yottadb.subscripts()``, ``node:subscripts()`` returns all *child* subscripts, not subsequent *sibling* subscripts in the same level.

Very slightly faster than node:__pairs() because it iterates subscript names without fetching the node value.

Note that subscripts() order is guaranteed to equal the M collation sequence.

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


~~~~~~~~~~~~~~~~
key._property_
~~~~~~~~~~~~~~~~

Properties of key object that are accessed with a dot.
These properties, listed below, are unlike object methods, which are accessed with a colon.
This kind of property access is for backward compatibility.

For example, access data property with: ``key.data``

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

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key:subscript_previous ([reset])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deprecated way to get previous *sibling* subscript.
See notes for subscript_previous()

~~~~~~~~~~~~~~~~~~~~~~~~~~~~
key:subscripts ([reverse])
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Deprecated way to get same-level subscripts from this node onward.
Deprecated because:

 * pairs() is more Lua-esque
 * it was is non-intuitive that k:subscripts() iterates only subsequent subscripts, not all child subscripts

