/// Private yottadb funtions. These are not part of the public API and may change.
// Copyright 2021-2022, Mitchell; Copyright 2022-2023, Berwyn Hoyt. See LICENSE.
// @module yottadb.c

#include <assert.h>
#include <stdint.h> // intptr_t
#include <stdio.h>
#include <stdbool.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

#include "yottadb.h"
#include "callins.h"
#include "cachearray.h"

#ifndef NDEBUG
#define RECORD_STACK_TOP(l) int orig_stack_top = lua_gettop(l);
#define ASSERT_STACK_TOP(l) assert(lua_gettop(l) == orig_stack_top)
#else
#define RECORD_STACK_TOP(l) (void)0
#define ASSERT_STACK_TOP(l) (void)0
#endif

static const int LUA_YDB_BUFSIZ = 128;
static const int LUA_YDB_SUBSIZ = 16;
static const int LUA_YDB_ERR = -200000000; // arbitrary

int unused; // used as junk dumping space

// Define safe malloc routines that exit with error on failure, rather than unpredictably continuing
// see related definitions in yottadb.h
int _memory_error(size_t size, int line, char *file) {
  fprintf(stderr, "Out of memory allocating %zi bytes (line %d in %s)\n", size, line, file);
  fflush(stderr);													\
  fflush(stdout);													\
  exit(1);
  return 0;
}


// Fetch subscripts into supplied variables; assume Lua stack contains: (varname[, {subs}, ...]) or: (cachearray)
// Any new cachearray is allocated on the C stack to be faster than lua_newuserdata(),
// but be aware that this will expire as soon as the function returns.
#define getsubs(L,_subs_used,_varname,_subsarray) \
  cachearray_t *___cachearray = lua_touserdata(L, 1); \
  cachearray_t_maxsize ___cachearray_; \
  if (!___cachearray) \
    ___cachearray = _cachearray_create(L, &___cachearray_); \
  _subs_used = ___cachearray->depth; \
  ___cachearray = ___cachearray->dereference; \
  _varname = &___cachearray->varname; \
  _subsarray = &___cachearray->subs[0];

const char *LUA_YDB_ERR_PREFIX = "YDB Error: ";

// Returns an error message to match the supplied YDB error code
// @usage _yottadb.message(code)
// @param code is the YDB error code
static int message(lua_State *L) {
  ydb_buffer_t buf;
  char *msg;

  int code = luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  YDB_MALLOC_BUFFER_SAFE(&buf, 2049); // docs say 2048 is a safe size
  // Decode the special return values that come with libyottadb's C interface
  if (code == YDB_LOCK_TIMEOUT)
    msg = "YDB_LOCK_TIMEOUT";
  else if (code == YDB_TP_ROLLBACK)
    msg = "YDB_TP_ROLLBACK";
  else if (code == YDB_TP_RESTART)
    msg = "YDB_TP_RESTART";
  else if (code == YDB_NOTOK)
    msg = "YDB_NOTOK";
  else {
    ydb_message(code, &buf);
    msg = buf.buf_addr;
    buf.buf_addr[buf.len_used] = '\0';
    if (!msg[0]) msg = "Unknown system error";
  }
  lua_pushfstring(L, "%s%d: %s", LUA_YDB_ERR_PREFIX, code, msg);
  YDB_FREE_BUFFER(&buf);
  return 1;
}

// Raises a Lua error with the YDB error code supplied
int ydb_assert(lua_State *L, int code) {
  if (code == YDB_OK) return code;
  lua_pushinteger(L, code);
  message(L);
  lua_error(L);
  return 0;
}

// Lua function to call `ydb_eintr_handler()`.
// If users wish to handle EINTR errors themselves, instead of blocking signals, they should call
// `ydb_eintr_handler()` when they get an EINTR error, before restarting the erroring OS system call.
// @return `YDB_OK` on success, and >0 on error (with message in ZSTATUS)
// @see block_M_signals
static int _ydb_eintr_handler(lua_State *L) {
  lua_pushinteger(L, ydb_eintr_handler());
  return 1;
}


/// Gets the value of a variable/node or nil if it has no data.
// @function get
// @usage _yottadb.get(varname[, {subs} | ...]),  or:
// @usage _yottadb.get(cachearray)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... is a list of subscripts
// @return string or nil if node has no data
static int get(lua_State *L) {
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER_SAFE(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_get_s(varname, subs_used, subsarray, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&ret_value);
    status = ydb_get_s(varname, subs_used, subsarray, &ret_value);
  }
  if (status == YDB_OK)
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  else if (status == YDB_ERR_GVUNDEF || status == YDB_ERR_LVUNDEF)
    { lua_pushnil(L); status = YDB_OK; }
  YDB_FREE_BUFFER(&ret_value);
  ydb_assert(L, status);
  return 1;
}

/// Deletes a node or tree of nodes.
// `_yottadb.YDB_DEL_xxxx` are boolean constants and must be supplied as actual boolean
// (not merely convertable to boolean), so that delete() can distinguish them from subscripts.
// Note: `_yottadb.YDB_DEL_xxxx` values differ from the values in `libyottadb.h`, but they work the same.
// Specifying type=nil or not supplied is the same as _yottadb.YDB_DEL_NODE
// @function delete
// @usage _yottadb.delete(varname[, {subs} | ...][, type=_yottadb.YDB_DEL_xxxx])
// @usage _yottadb.delete(cachearray[, type=_yottadb.YDB_DEL_xxxx])
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... list of subscripts
// @param type `_yottadb.YDB_DEL_NODE` or `_yottadb.YDB_DEL_TREE`
static int delete(lua_State *L) {
  int deltype = YDB_DEL_NODE;
  int type = lua_type(L, -1);
  if (type == LUA_TBOOLEAN || type == LUA_TNIL) {
    if (lua_toboolean(L, -1))
      deltype = YDB_DEL_TREE;
    lua_pop(L, 1);  // pop type
  }
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_assert(L, ydb_delete_s(varname, subs_used, subsarray, deltype));
  return 0;
}

/// Sets the value of a variable/node.
// Raises an error of no such intrinsic variable exists.
// if value = nil then perform delete(node) instead
// @function set
// @usage _yottadb.set(varname[, {subs} | ...], value),  or:
// @usage _yottadb.set(cachearray, value)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... is a list of subscripts
// @param value string or number convertible to string
// @return value
static int set(lua_State *L) {
  if (lua_gettop(L) && lua_type(L, -1) == LUA_TNIL)
    return delete(L), lua_pushnil(L), 1;
  // pop `value` off stack before calling getsubs
  ydb_buffer_t value;
  size_t length;
  value.buf_addr = luaL_checklstring(L, -1, &length);
  value.len_used = value.len_alloc = (unsigned int)length;
  // pop string `value` so we can call getsubs, but keep reference to it so it is valid until ydb_set_s() is complete
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  int status = ydb_set_s(varname, subs_used, subsarray, &value);
  lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ref);
  ydb_assert(L, status);
  return 1;
}

/// Returns information about a variable/node (except intrinsic variables).
// @function data
// @usage _yottadb.data(varname[, {subs | ...}]),  or:
// @usage _yottadb.data(cachearray)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... list of subscripts
// @param[opt] ... list of subscripts
// @return `_yottadb.YDB_DATA_UNDEF` (no value or subtree) or
//   `_yottadb.YDB_DATA_VALUE_NODESC` (value, no subtree) or
//   `_yottadb.YDB_DATA_NOVALUE_DESC` (no value, subtree) or
//   `_yottadb.YDB_DATA_VALUE_DESC` (value and subtree)
static int data(lua_State *L) {
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  unsigned int ret_value;
  ydb_assert(L, ydb_data_s(varname, subs_used, subsarray, &ret_value));
  lua_pushinteger(L, ret_value);
  return 1;
}

/// Attempts to acquire or increment a lock on a variable/node, waiting if requested.
// Raises an error if a lock could not be acquired.
// Caution: timeout is *not* optional if `...` list of subscript is provided.
// Otherwise lock_incr cannot tell whether it is a subscript or a timeout.
// @function lock_incr
// @usage _yottadb.lock_incr(varname[, {subs}][, timeout=0])
// @usage _yottadb.lock_incr(varname[, ...], timeout)
// @usage _yottadb.lock_incr(cachearray[, timeout=0])
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... list of subscripts
// @param[opt] timeout timeout in seconds to wait for lock
static int lock_incr(lua_State *L) {
  int argpos=-1;
  if (lua_gettop(L) < 2 || lua_type(L, 1)==LUA_TUSERDATA)
    argpos = 2;
  else
    if (lua_type(L, 2)==LUA_TTABLE)
      argpos = 3;
  unsigned long long timeout_nsec = luaL_optnumber(L, argpos, 0) * 1000000000;
  lua_settop(L, argpos-1);  // pop timeout if it was supplied

  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_assert(L, ydb_lock_incr_s(timeout_nsec, varname, subs_used, subsarray));
  return 0;
}

/// Decrements a lock on a variable/node, releasing it if possible.
// @function lock_decr
// @usage _yottadb.lock_decr(varname[, {subs} | ...]),  or:
// @usage _yottadb.lock_decr(cachearray)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... list of subscripts
static int lock_decr(lua_State *L) {
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_assert(L, ydb_lock_decr_s(varname, subs_used, subsarray));
  return 0;
}

typedef struct tpfnparm_t {
  lua_State *L;
  int ref;  // ref to registry table used to store parameters that are passed to lua function invoked by tpfn()
} tpfnparm_t;

// Invokes the Lua transaction function passed to `_yottadb.tp()`.
// @function tpfn
static int tpfn(void *tpfnparm) {
  lua_State *L = ((tpfnparm_t *)tpfnparm)->L;
  RECORD_STACK_TOP(L);
  int ref = ((tpfnparm_t *)tpfnparm)->ref;
  lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
  int top = lua_gettop(L), n = luaL_len(L, top);
  luaL_checkstack(L, n, "too many callback args -- cannot expand Lua stack to fit them");
  for (int i = 1; i <= n; i++) {
    lua_geti(L, top, i);
  }
  int status, nargs=n-1, nresults=1, msg_handler=0;
  if (lua_pcall(L, nargs, nresults, msg_handler) != LUA_OK) {
    char *s = strstr(lua_tostring(L, -1), LUA_YDB_ERR_PREFIX);
    char *endp;
    if (s) {
      s += strlen(LUA_YDB_ERR_PREFIX);
      status = strtol(s, &endp, 10);
    }
    if (!s || endp == s) {
      // STACK: ref_table, retval
      lua_pushvalue(L, -1);
      // STACK: ref_table, retval, retval
      lua_setfield(L, -3, "_yottadb_lua_error");
      status = LUA_YDB_ERR;
    }
  } else if (lua_isnil(L, -1)) {
    status = YDB_OK;
  } else if (lua_isnumber(L, -1)) {
    status = lua_tointeger(L, -1);
  } else {
    status = YDB_ERR_TPCALLBACKINVRETVAL;
  }
  lua_pop(L, 2); // retval and ref_table
  ASSERT_STACK_TOP(L);
  return status;
}

/// Initiates a transaction.
//   Note: restarts are subject to $ZMAXTPTIME after which they cause error `%YDB-E-TPTIMEOUT`
// @function tp
// @usage _yottadb.tp([transid,] [varnames,] f[, ...])
// @param[opt] transid string transaction id
// @param[opt] varnames table of local M varnames to restore on transaction restart
//   (or {'*'} for all locals) -- restoration does apply to rollback
// @param f Lua function to call (can have nested `_yottadb.tp()` calls for nested transactions).
//
//  * If f returns nothing or `_yottadb.YDB_OK`, the transaction's affected globals are committed.
//  * If f returns `_yottadb.YDB_TP_RESTART` or `_yottadb.YDB_TP_ROLLBACK`, the transaction is
//     restarted (f will be called again) or not committed, respectively.
//  * If f errors, the transaction is not committed and the error propagated up the stack.
// @param[opt] ... arguments to pass to f
static int tp(lua_State *L) {
  const char *transid = lua_isstring(L, 1) ? lua_tostring(L, 1) : "";
  int npos = lua_isstring(L, 1) ? 2 : 1;
  char table_given = lua_istable(L, npos);
  int namecount = table_given ? luaL_len(L, npos) : 0;
  ydb_buffer_t varnames[namecount];
  luaL_argcheck(L, lua_isfunction(L, npos+table_given), npos+table_given, "function expected");
  if (table_given) {
    for (int i = 0; i < namecount; i++) {
      luaL_argcheck(L, lua_geti(L, npos, i + 1) == LUA_TSTRING, npos, "varnames must be strings"), lua_pop(L, 1);
    }
    for (int i = 0; i < namecount; i++) {
      lua_geti(L, npos, i + 1);
      YDB_MALLOC_BUFFER_SAFE(&varnames[i], luaL_len(L, -1));
      YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &varnames[i], unused);
      lua_pop(L, 1); // varname
    }
    npos++;
  }
  lua_createtable(L, lua_gettop(L), 0);
  for (int i = npos; i < lua_gettop(L); i++) {
    lua_pushvalue(L, i), lua_seti(L, -2, luaL_len(L, -2) + 1);
  }
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);  // store ref_table containing parameters to pass to Lua callback function
  tpfnparm_t *tpfnparm = MALLOC_SAFE(sizeof(tpfnparm_t));
  tpfnparm->L = L, tpfnparm->ref = ref;
  int status = ydb_tp_s(tpfn, (void *)tpfnparm, transid, namecount, varnames);
  free(tpfnparm);
  for (int i = 0; i < namecount; i++) {
    YDB_FREE_BUFFER(&varnames[i]);
  }
  if (status == LUA_YDB_ERR) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);  // get ref_table cont
    lua_getfield(L, -1, "_yottadb_lua_error");
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
    lua_error(L);
  } else if (status != YDB_TP_RESTART) {
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
    ydb_assert(L, status);
  }
  return 0;
}

typedef int (*subscript_actuator_t) (const ydb_buffer_t *varname, int subs_used, const ydb_buffer_t *subsarray, ydb_buffer_t *ret_value);
// Underlying function for subscript next or previous
static int subscript_nexter(lua_State *L, subscript_actuator_t actuator) {
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER_SAFE(&ret_value, LUA_YDB_BUFSIZ);
  int status = actuator(varname, subs_used, subsarray, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&ret_value);
    status = actuator(varname, subs_used, subsarray, &ret_value);
  }
  if (status == YDB_OK)
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  YDB_FREE_BUFFER(&ret_value);
  if (status == YDB_ERR_NODEEND)
    lua_pushnil(L);
  else
    ydb_assert(L, status);
  return 1;
}

/// Returns the next subscript for a variable/node.
// @function subscript_next
// @usage _yottadb.subscript_next(varname[, {subs} | ...]),  or:
// @usage _yottadb.subscript_next(cachearray)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... is a list of subscripts
// @return: string or nil if there are no more subscripts
static int subscript_next(lua_State *L) {
  return subscript_nexter(L, ydb_subscript_next_s);
}

/// Returns the previous subscript for a variable/node.
// @function subscript_previous
// @usage _yottadb.subscript_previous(varname[, {subs} | ...]),  or:
// @usage _yottadb.subscript_previous(cachearray)
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... is a list of subscripts
// @return string or nil if there are not any previous subscripts
static int subscript_previous(lua_State *L) {
  return subscript_nexter(L, ydb_subscript_previous_s);
}

typedef int (*node_actuator_t) (const ydb_buffer_t *varname, int subs_used, const ydb_buffer_t *subsarray, int *ret_subs_used, ydb_buffer_t *ret_subsarray);
// Underlying function for node next or previous
static int node_nexter(lua_State *L, node_actuator_t actuator) {
  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  int ret_subs_alloc = LUA_YDB_SUBSIZ, ret_subs_used = 0;
  ydb_buffer_t *ret_subsarray = MALLOC_SAFE(ret_subs_alloc * sizeof(ydb_buffer_t));
  for (int i = 0; i < ret_subs_alloc; i++)
    YDB_MALLOC_BUFFER_SAFE(&ret_subsarray[i], LUA_YDB_BUFSIZ);
  int status = actuator(varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  if (status == YDB_ERR_INSUFFSUBS) {
    ret_subsarray = REALLOC_SAFE(ret_subsarray, ret_subs_used * sizeof(ydb_buffer_t));
    for (int i = ret_subs_alloc; i < ret_subs_used; i++)
      YDB_MALLOC_BUFFER_SAFE(&ret_subsarray[i], LUA_YDB_BUFSIZ);
    ret_subs_alloc = ret_subs_used;
    status = actuator(varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  while (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&ret_subsarray[ret_subs_used]);
    ret_subs_used = ret_subs_alloc;
    status = actuator(varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  if (status == YDB_OK) {
    lua_createtable(L, ret_subs_used, 0);
    for (int i = 0; i < ret_subs_used; i++) {
      lua_pushlstring(L, ret_subsarray[i].buf_addr, ret_subsarray[i].len_used);
      lua_seti(L, -2, i + 1);
    }
  }
  for (int i = 0; i < ret_subs_alloc; i++)
    YDB_FREE_BUFFER(&ret_subsarray[i]);
  free(ret_subsarray);
  if (status == YDB_ERR_NODEEND)
    lua_pushnil(L);
  else
    ydb_assert(L, status);
  return 1;
}

/// Returns the full subscript table of the next node after a variable/node.
// A next node chain started from varname will eventually reach all nodes under that varname in order.
// @function node_next
// @usage _yottadb.node_next(varname[, {subs} | ...])
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] ... is a list of subscripts
// @return table of subscripts for the node or nil if there are no next nodes
static int node_next(lua_State *L) {
  return node_nexter(L, ydb_node_next_s);
}

/// Returns the full subscript table of the node prior to a variable/node.
// A previous node chain started from varname will eventually reach all nodes under that varname in reverse order.
// @function node_previous
// @usage _yottadb.node_previous(varname[, {subs}])
// @param varname string
// @param[opt] subs table of subscripts
// @return table of subscripts for the node or nil if there are no previous nodes
static int node_previous(lua_State *L) {
  return node_nexter(L, ydb_node_previous_s);
}

/// Releases all locks held and attempts to acquire all requested locks, waiting if requested.
// Raises an error if a lock could not be acquired.
// @function lock
// @usage _yottadb.lock([{node_specifiers}[, timeout=0]])
// @param[opt] {node_specifiers} table of cachearrays of variables/nodes to lock
// @param[opt] timeout timeout in seconds to wait for lock
static int lock(lua_State *L) {
  int num_nodes = 0;
  int istable = lua_istable(L, 1);
  if (lua_gettop(L) > 0) luaL_argcheck(L, istable, 1, "table of {cachearray, cachearray, ...} node specifiers expected in parameter #1");
  if (istable) {
    num_nodes = luaL_len(L, 1);
    for (int i = 1; i <= num_nodes; i++) {
      luaL_argcheck(L, lua_geti(L, 1, i) == LUA_TUSERDATA, 1, "node specifiers in parameter #1 must all be cachearrays");
      lua_pop(L, 1); // pop cachearray
    }
  }
  unsigned long long timeout = luaL_optnumber(L, 2, 0) * 1000000000;
  int num_args = 2 + (num_nodes * 3); // timeout, num_nodes, [varname, subs_used, subsarray]*n
  gparam_list params;
  params.n = num_args;
  int arg_i = 0;
  params.arg[arg_i++] = (void *)timeout;
  params.arg[arg_i++] = (void *)(uintptr_t)num_nodes;
  for (int i = 0; i < num_nodes && i < MAX_ACTUALS; i++) {
    lua_geti(L, 1, i + 1);
    cachearray_t *array = lua_touserdata(L, -1);
    int depth = array->depth;
    lua_pop(L, 1);  // pop cachearray
    array = array->dereference;
    params.arg[arg_i++] = (void *)&array->varname;
    params.arg[arg_i++] = (void *)(uintptr_t)depth;
    params.arg[arg_i++] = (void *)array->subs;
  }
  int status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_lock_s, &params);
  ydb_assert(L, status);
  return 0;
}

/// Deletes trees of all local variables except the given ones.
// @function delete_excl
// @usage _yottadb.delete_excl(varnames)
// @param varnames table of variable names to exclude (no subscripts)
static int delete_excl(lua_State *L) {
  luaL_argcheck(L, lua_istable(L, 1), 1, "table of varnames expected");
  int namecount = luaL_len(L, 1);
  for (int i = 0; i < namecount; i++) {
    luaL_argcheck(L, lua_geti(L, 1, i + 1) == LUA_TSTRING, 1, "varnames must be strings"), lua_pop(L, 1);
  }
  ydb_buffer_t varnames[namecount];
  for (int i = 0; i < namecount; i++) {
    lua_geti(L, 1, i + 1);
    YDB_MALLOC_BUFFER_SAFE(&varnames[i], luaL_len(L, -1));
    YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &varnames[i], unused);
    lua_pop(L, 1); // varname
  }
  ydb_assert(L, ydb_delete_excl_s(namecount, varnames));
  return 0;
}

/// Increments the numeric value of a variable/node.
// Raises an error on overflow.
// Caution: increment is *not* optional if `...` list of subscript is provided.
// Otherwise incr cannot tell whether last parameter is a subscript or an increment.
// @function incr
// @usage _yottadb.incr(varname[, {subs}][, increment=1])
// @usage _yottadb.incr(varname[, ...], increment=n)
// @usage _yottadb.incr(cachearray[, increment=1])
// @param varname string
// @param[opt] subs table of subscripts
// @param[opt] increment amount to increment by = number, or string-of-a-canonical-number, default=1
static int incr(lua_State *L) {
  int args = lua_gettop(L);
  int argpos=-1;
  if (args < 2 || lua_type(L, 1)==LUA_TUSERDATA)
    argpos = 2;
  else
    if (lua_type(L, 2)==LUA_TTABLE)
      argpos = 3;
  ydb_buffer_t increment;
  YDB_STRING_TO_BUFFER(luaL_optstring(L, argpos, ""), &increment);
  // pop string `value` so we can call getsubs, but keep reference to it so it is valid until ydb_incr_s() is complete
  int ref = LUA_NOREF;
  if (args >= argpos)
    ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int subs_used;
  ydb_buffer_t *varname, *subsarray;
  getsubs(L, subs_used, varname, subsarray);

  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER_SAFE(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_incr_s(varname, subs_used, subsarray, &increment, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&ret_value);
    status = ydb_incr_s(varname, subs_used, subsarray, &increment, &ret_value);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  }
  YDB_FREE_BUFFER(&ret_value);
  luaL_unref(L, LUA_REGISTRYINDEX, ref);
  ydb_assert(L, status);
  return 1;
}

/// Returns the zwrite-formatted version of the given string.
// @function str2zwr
// @usage _yottadb.str2zwr(s)
// @param s string
// @return zwrite-formatted string
static int str2zwr(lua_State *L) {
  ydb_buffer_t str;
  YDB_STRING_TO_BUFFER(luaL_checkstring(L, 1), &str);
  str.len_alloc = str.len_used = luaL_len(L, 1); // in case of NUL bytes
  ydb_buffer_t zwr;
  YDB_MALLOC_BUFFER_SAFE(&zwr, LUA_YDB_BUFSIZ);
  int status = ydb_str2zwr_s(&str, &zwr);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&zwr);
    status = ydb_str2zwr_s(&str, &zwr);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, zwr.buf_addr, zwr.len_used);
  }
  YDB_FREE_BUFFER(&zwr);
  ydb_assert(L, status);
  return 1;
}

/// Returns the string described by the given zwrite-formatted string.
// @function zwr2str
// @usage _yottadb.zwr2str(s)
// @param s zwrite-formatted string
// @return string
static int zwr2str(lua_State *L) {
  ydb_buffer_t zwr;
  YDB_STRING_TO_BUFFER(luaL_checkstring(L, 1), &zwr);
  ydb_buffer_t str;
  YDB_MALLOC_BUFFER_SAFE(&str, LUA_YDB_BUFSIZ);
  int status = ydb_zwr2str_s(&zwr, &str);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER_SAFE(&str);
    status = ydb_zwr2str_s(&zwr, &str);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, str.buf_addr, str.len_used);
  }
  YDB_FREE_BUFFER(&str);
  ydb_assert(L, status);
  return 1;
}


#if LUA_VERSION_NUM < 503
  #define ltablib_c  /* required to make lprefix.h include stuff needed for ltablib_c */
  #include "compat-5.3/lstrlib.c"
  #include "compat-5.3/ltablib.c"
#endif

static const luaL_Reg yottadb_functions[] = {
  {"get", get},
  {"set", set},
  {"delete", delete},
  {"data", data},
  {"lock_incr", lock_incr},
  {"lock_decr", lock_decr},
  {"tp", tp},
  {"subscript_next", subscript_next},
  {"subscript_previous", subscript_previous},
  {"node_next", node_next},
  {"node_previous", node_previous},
  {"lock", lock},
  {"delete_excl", delete_excl},
  {"incr", incr},
  {"str2zwr", str2zwr},
  {"zwr2str", zwr2str},
  {"message", message},
  {"ci_tab_open", ci_tab_open},
  {"cip", cip},
  {"register_routine", register_routine},
  {"block_M_signals", block_M_signals},
  {"init", init},
  {"ydb_eintr_handler", _ydb_eintr_handler},
  {"cachearray_create", cachearray_create},
  {"cachearray_setmetatable", cachearray_setmetatable},
  {"cachearray_tomutable", cachearray_tomutable},
  {"cachearray_subst", cachearray_subst},
  {"cachearray_flags", cachearray_flags},
  {"cachearray_append", cachearray_append},
  {"cachearray_tostring", cachearray_tostring},
  {"cachearray_depth", cachearray_depth},
  {"cachearray_subscript", cachearray_subscript},
  #if LUA_VERSION_NUM < 503
    {"string_pack", str_pack},
    {"cachearray_gc", cachearray_gc},
  #endif
  #if LUA_VERSION_NUM < 502
    {"string_format", str_format},
    {"table_unpack", unpack},
  #endif
  {NULL, NULL}
};

static const const_Reg yottadb_constants[] = {
  {"YDB_ERR_GVUNDEF", YDB_ERR_GVUNDEF},
  {"YDB_ERR_LVUNDEF", YDB_ERR_LVUNDEF},
  {"YDB_MAX_STR", YDB_MAX_STR},
  {"YDB_DATA_UNDEF", 0},
  {"YDB_DATA_VALUE_NODESC", 1},
  {"YDB_DATA_NOVALUE_DESC", 10},
  {"YDB_DATA_VALUE_DESC", 11},
  {"YDB_LOCK_TIMEOUT", YDB_LOCK_TIMEOUT},
  {"YDB_OK", YDB_OK},
  {"YDB_TP_ROLLBACK", YDB_TP_ROLLBACK},
  {"YDB_TP_RESTART", YDB_TP_RESTART},
  {"YDB_ERR_TPTIMEOUT", YDB_ERR_TPTIMEOUT},
  {"YDB_ERR_NODEEND", YDB_ERR_NODEEND},
  {"YDB_ERR_NUMOFLOW", YDB_ERR_NUMOFLOW},
  {"YDB_MAX_IDENT", YDB_MAX_IDENT},
  {"YDB_ERR_VARNAME2LONG", YDB_ERR_VARNAME2LONG},
  {"YDB_ERR_INVVARNAME", YDB_ERR_INVVARNAME},
  {"YDB_MAX_SUBS", YDB_MAX_SUBS},
  {"YDB_ERR_MAXNRSUBSCRIPTS", YDB_ERR_MAXNRSUBSCRIPTS},
  {"YDB_ERR_LOCKSUB2LONG", YDB_ERR_LOCKSUB2LONG},
  {"YDB_MAX_NAMES", YDB_MAX_NAMES},
  {"YDB_ERR_NAMECOUNT2HI", YDB_ERR_NAMECOUNT2HI},
  {"YDB_ERR_INVSTRLEN", YDB_ERR_INVSTRLEN},
  {"YDB_ERR_TPCALLBACKINVRETVAL", YDB_ERR_TPCALLBACKINVRETVAL},
  {NULL, 0}
};

int luaopen__yottadb(lua_State *L) {
  luaL_newlibtable(L, yottadb_functions);
  // Push upvalues used by module
  int top = lua_gettop(L);
  // Push any needed upvalues here, e.g.: cachearray_pushupvalues(L);
  luaL_setfuncs(L, yottadb_functions, lua_gettop(L)-top);

  for (const_Reg *c = &yottadb_constants[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_pushboolean(L, true), lua_setfield(L, -2, "YDB_DEL_TREE");  // these 2 values are changed from libyottadb.h so delete()
  lua_pushboolean(L, false), lua_setfield(L, -2, "YDB_DEL_NODE");  // can detect their type is not string/number. No API change.
  lua_pushstring(L, LUA_YOTTADB_VERSION_STRING), lua_setfield(L, -2, "_VERSION");
  lua_createtable(L, 0, (sizeof(yottadb_types)/sizeof(const_Reg))-1);
  for (const_Reg *c = &yottadb_types[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_setfield(L, -2, "YDB_CI_PARAM_TYPES");
  return 1;
}
