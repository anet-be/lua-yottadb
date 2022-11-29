// Copyright 2021-2022 Mitchell. See LICENSE.

#include <assert.h>
#include <stdint.h> // intptr_t
#include <stdio.h>
#include <strings.h>
#include <stdbool.h>

#include <libyottadb.h>
#include <lua.h>

// Enable build against Lua older than 5.3
#include "compat-5.3.h"

#include <lauxlib.h>
#include "_yottadb.h"

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

typedef struct const_Reg {
  const char *name;
  int value;
} const_Reg;

#define YDB_REALLOC_BUFFER(BUFFERP) { \
  int len_used = (BUFFERP)->len_used; \
  YDB_FREE_BUFFER(BUFFERP); \
  YDB_MALLOC_BUFFER(BUFFERP, len_used); \
}

// Determines the key's varname and number of subs (if any).
// Assumes the Lua stack starts with the key.
static void get_key_info(lua_State *L, ydb_buffer_t *varname, int *subs_used) {
  YDB_STRING_TO_BUFFER(luaL_checkstring(L, 1), varname);
  *subs_used = (lua_gettop(L) > 1 && lua_istable(L, 2)) ? luaL_len(L, 2) : 0;
}

// Assumes subs table is second argument on Lua stack and subsarray is same length.
static void get_subs(lua_State *L, int subs_used, ydb_buffer_t *subsarray) {
  RECORD_STACK_TOP(L);
  for (int i = 0; i < subs_used; i++) {
    lua_geti(L, 2, i + 1);
    YDB_STRING_TO_BUFFER(luaL_checkstring(L, -1), &subsarray[i]);
    lua_pop(L, 1);
  }
  ASSERT_STACK_TOP(L);
}

static const char *LUA_YDB_ERR_PREFIX = "YDB Error: ";

// Returns an error message to match the supplied YDB error code
// _yottadb.message(code)
static int message(lua_State *L) {
  ydb_buffer_t buf;
  char *msg;

  int code = luaL_checkinteger(L, -1);
  lua_pop(L, 1);
  YDB_MALLOC_BUFFER(&buf, 2049); // docs say 2048 is a safe size
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
static int error(lua_State *L, int code) {
  lua_pushinteger(L, code);
  message(L);
  lua_error(L);
  return 0;
}

// Call ydb_init()
// Return YDB_OK on success, and >0 on error (with message in ZSTATUS)
// If users wish to set their own signal handlers for signals not used by YDB
// they may do so after caling ydb_init() -- which sets ydb's signal handlers
static int _ydb_init(lua_State *L) {
  lua_pushinteger(L, ydb_init());
  return 1;
}

// Gets the value of a variable/node.
// Raises an error if variable/node does not exist.
// _yottadb.get(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: string
static int get(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_get_s(&varname, subs_used, subsarray, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_value);
    status = ydb_get_s(&varname, subs_used, subsarray, &ret_value);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  }
  YDB_FREE_BUFFER(&ret_value);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Sets the value of a variable/node.
// Raises an error of no such intrinsic variable exists.
// _yottadb.set(varname[, subs], value)
// varname: string
// subs: optional table of subscripts
// value: string or number convertible to string
static int set(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  ydb_buffer_t value;
  size_t length;
  value.buf_addr = luaL_optlstring(L, !lua_isstring(L, 2) ? 3 : 2, "", &length);
  value.len_used = value.len_alloc = (unsigned int)length;
  int status = ydb_set_s(&varname, subs_used, subsarray, &value);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

// Deletes a node or tree of nodes.
// _yottadb.delete(varname[, subs][, type=_yottadb.YDB_DEL_NODE])
// varname: string
// subs: optional table of subscripts
// type: _yottadb.YDB_DEL_NODE or _yottadb.YDB_DEL_TREE
static int delete(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  int deltype = luaL_optinteger(L, lua_type(L, 2) != LUA_TNUMBER ? 3 : 2, YDB_DEL_NODE);
  int status = ydb_delete_s(&varname, subs_used, subsarray, deltype);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

// Returns information about a variable/node (except intrinsic variables).
// _yottadb.data(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: _yottadb.YDB_DATA_UNDEF (no value or subtree) or
//   _yottadb.YDB_DATA_VALUE_NODESC (value, no subtree) or
//   _yottadb.YDB_DATA_NOVALUE_DESC (no value, subtree) or
//   _yottadb.YDB_DATA_VALUE_DESC (value and subtree)
static int data(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  unsigned int ret_value;
  int status = ydb_data_s(&varname, subs_used, subsarray, &ret_value);
  if (status != YDB_OK) {
    error(L, status);
  }
  lua_pushinteger(L, ret_value);
  return 1;
}

// Attempts to acquire or increment a lock on a variable/node, waiting if requested.
// Raises an error if a lock could not be acquired.
// _yottadb.lock_incr(varname[, subs][, timeout=0])
// varname: string
// subs: optional table of subscripts
// timeout: optional timeout in seconds to wait for lock
static int lock_incr(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  unsigned long long timeout = luaL_optnumber(L, lua_type(L, 2) != LUA_TNUMBER ? 3 : 2, 0) * 1000000000;
  int status = ydb_lock_incr_s(timeout, &varname, subs_used, subsarray);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

// Decrements a lock on a variable/node, releasing it if possible.
// _yottadb.lock_decr(varname[, subs])
// varname: string
// subs: optional table of subscripts
static int lock_decr(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  int status = ydb_lock_decr_s(&varname, subs_used, subsarray);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

typedef struct tpfnparm_t {
  lua_State *L;
  int ref;
} tpfnparm_t;

// Invokes the Lua transaction function passed to _yottadb.tp().
static int tpfn(void *tpfnparm) {
  lua_State *L = ((tpfnparm_t *)tpfnparm)->L;
  RECORD_STACK_TOP(L);
  int ref = ((tpfnparm_t *)tpfnparm)->ref;
  lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
  int top = lua_gettop(L), n = luaL_len(L, top);
  luaL_checkstack(L, n, "too many callback args");
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
      lua_pushvalue(L, -1), lua_setfield(L, LUA_REGISTRYINDEX, "_yottadb_lua_error"); // TODO: this is not thread-safe. It should be returned using luaL_ref()
      status = LUA_YDB_ERR;
    }
  } else if (lua_isnil(L, -1)) {
    status = YDB_OK;
  } else if (lua_isnumber(L, -1)) {
    status = lua_tointeger(L, -1);
  } else {
    status = YDB_ERR_TPCALLBACKINVRETVAL;
  }
  lua_pop(L, 2); // retval and ref
  ASSERT_STACK_TOP(L);
  return status;
}

// Initiates a transaction.
// _yottadb.tp([transid,] [varnames,] f[, ...])
// transid: optional string transaction id
// varnames: optional table of local M varnames to restore on transaction restart
//   (or {'*'} for all locals) -- restoration does apply to rollback
// f: Lua function to call (can have nested _yottadb.tp() calls for nested transactions)
//   If f returns nothing or _yottadb.YDB_OK, the transaction's affected globals are committed.
//   If f returns _yottadb.YDB_TP_RESTART or _yottadb.YDB_TP_ROLLBACK, the transaction is
//     restarted (f will be called again) or not committed, respectively.
//   If f errors, the transaction is not committed and the error propagated up the stack.
// ...: optional arguments to pass to f
//   Note: restarts are subject to $ZMAXTPTIME after which they cause error %YDB-E-TPTIMEOUT
static int tp(lua_State *L) {
  const char *transid = lua_isstring(L, 1) ? lua_tostring(L, 1) : "";
  int npos = lua_isstring(L, 1) ? 2 : 1;
  int namecount = lua_istable(L, npos) ? luaL_len(L, npos) : 0;
  ydb_buffer_t varnames[namecount];
  if (lua_istable(L, npos)) {
    for (int i = 0; i < namecount; i++) {
      luaL_argcheck(L, lua_geti(L, npos, i + 1) == LUA_TSTRING, npos, "varnames must be strings"), lua_pop(L, 1);
    }
    for (int i = 0; i < namecount; i++) {
      lua_geti(L, npos, i + 1);
      YDB_MALLOC_BUFFER(&varnames[i], luaL_len(L, -1));
      int unused;
      YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &varnames[i], unused);
      lua_pop(L, 1); // varname
    }
    npos++;
  }
  luaL_argcheck(L, lua_isfunction(L, npos), npos, "function expected"); // TODO: memory leak for varnames
  lua_createtable(L, lua_gettop(L), 0);
  for (int i = npos; i < lua_gettop(L); i++) {
    lua_pushvalue(L, i), lua_seti(L, -2, luaL_len(L, -2) + 1);
  }
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);
  tpfnparm_t *tpfnparm = malloc(sizeof(tpfnparm_t));
  tpfnparm->L = L, tpfnparm->ref = ref;
  int status = ydb_tp_s(tpfn, (void *)tpfnparm, transid, namecount, varnames);
  luaL_unref(L, LUA_REGISTRYINDEX, ref);
  free(tpfnparm);
  for (int i = 0; i < namecount; i++) {
    YDB_FREE_BUFFER(&varnames[i]);
  }
  if (status == LUA_YDB_ERR) {
    lua_getfield(L, LUA_REGISTRYINDEX, "_yottadb_lua_error");
    lua_error(L);
  } else if (status != YDB_OK && status != YDB_TP_RESTART) {
    error(L, status);
  }
  return 0;
}

// Returns the next subscript for a variable/node.
// Raises an error of there are no more subscripts.
// _yottadb.subscript_next(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: string
static int subscript_next(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_subscript_next_s(&varname, subs_used, subsarray, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_value);
    status = ydb_subscript_next_s(&varname, subs_used, subsarray, &ret_value);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  }
  YDB_FREE_BUFFER(&ret_value);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Returns the previous subscript for a variable/node.
// Raises an error of there are not previous subscripts.
// _yottadb.subscript_previous(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: string
static int subscript_previous(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_subscript_previous_s(&varname, subs_used, subsarray, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_value);
    status = ydb_subscript_previous_s(&varname, subs_used, subsarray, &ret_value);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  }
  YDB_FREE_BUFFER(&ret_value);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Returns the next node for a variable/node.
// Raises an error if there are no more nodes.
// _yottadb.node_next(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: table of subscripts for the node
static int node_next(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  int ret_subs_alloc = LUA_YDB_SUBSIZ, ret_subs_used = 0;
  ydb_buffer_t *ret_subsarray = malloc(ret_subs_alloc * sizeof(ydb_buffer_t));
  for (int i = 0; i < ret_subs_alloc; i++) {
    YDB_MALLOC_BUFFER(&ret_subsarray[i], LUA_YDB_BUFSIZ);
  }
  int status = ydb_node_next_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  if (status == YDB_ERR_INSUFFSUBS) {
    ret_subsarray = realloc(ret_subsarray, ret_subs_used * sizeof(ydb_buffer_t));
    for (int i = ret_subs_alloc; i < ret_subs_used; i++) {
      YDB_MALLOC_BUFFER(&ret_subsarray[i], LUA_YDB_BUFSIZ);
    }
    ret_subs_alloc = ret_subs_used;
    status = ydb_node_next_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  while (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_subsarray[ret_subs_used]);
    ret_subs_used = ret_subs_alloc;
    status = ydb_node_next_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  if (status == YDB_OK) {
    lua_createtable(L, ret_subs_used, 0);
    for (int i = 0; i < ret_subs_used; i++) {
      lua_pushlstring(L, ret_subsarray[i].buf_addr, ret_subsarray[i].len_used);
      lua_seti(L, -2, i + 1);
    }
  }
  for (int i = 0; i < ret_subs_alloc; i++) {
    YDB_FREE_BUFFER(&ret_subsarray[i]);
  }
  free(ret_subsarray);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Returns the previous node for a variable/node.
// Raises an error if there are no previous nodes.
// _yottadb.node_previous(varname[, subs])
// varname: string
// subs: optional table of subscripts
// return: table of subscripts for the node
static int node_previous(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  int ret_subs_alloc = LUA_YDB_SUBSIZ, ret_subs_used = 0;
  ydb_buffer_t *ret_subsarray = malloc(ret_subs_alloc * sizeof(ydb_buffer_t));
  for (int i = 0; i < ret_subs_alloc; i++) {
    YDB_MALLOC_BUFFER(&ret_subsarray[i], LUA_YDB_BUFSIZ);
  }
  int status = ydb_node_previous_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  if (status == YDB_ERR_INSUFFSUBS) {
    ret_subsarray = realloc(ret_subsarray, ret_subs_used * sizeof(ydb_buffer_t));
    for (int i = ret_subs_alloc; i < ret_subs_used; i++) {
      YDB_MALLOC_BUFFER(&ret_subsarray[i], LUA_YDB_BUFSIZ);
    }
    ret_subs_alloc = ret_subs_used;
    status = ydb_node_previous_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  while (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_subsarray[ret_subs_used]);
    ret_subs_used = ret_subs_alloc;
    status = ydb_node_previous_s(&varname, subs_used, subsarray, &ret_subs_used, ret_subsarray);
  }
  if (status == YDB_OK) {
    lua_createtable(L, ret_subs_used, 0);
    for (int i = 0; i < ret_subs_used; i++) {
      lua_pushlstring(L, ret_subsarray[i].buf_addr, ret_subsarray[i].len_used);
      lua_seti(L, -2, i + 1);
    }
  }
  for (int i = 0; i < ret_subs_alloc; i++) {
    YDB_FREE_BUFFER(&ret_subsarray[i]);
  }
  free(ret_subsarray);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

typedef struct ydb_key_t {
  ydb_buffer_t varname;
  int subs_used;
  ydb_buffer_t *subsarray;
} ydb_key_t;

// Releases all locks held and attempts to acquire all requested locks, waiting if requested.
// Raises an error if a lock could not be acquired.
// _yottadb.lock([keys[, timeout=0]])
// keys: optional table of {varname[, subs]} variable/nodes to lock
// timeout: optional timeout in seconds to wait for lock
static int lock(lua_State *L) {
  int num_keys = 0;
  if (lua_gettop(L) > 0) luaL_argcheck(L, lua_istable(L, 1), 1, "table of keys expected");
  if (lua_istable(L, 1)) {
    num_keys = luaL_len(L, 1);
    for (int i = 1; i <= num_keys; i++) {
      luaL_argcheck(L, lua_geti(L, 1, i) == LUA_TTABLE, 1, "table of keys expected");
      luaL_argcheck(L, lua_geti(L, -1, 1) == LUA_TSTRING, 1, "varnames must be strings"), lua_pop(L, 1);
      if (luaL_len(L, -1) > 1) {
        luaL_argcheck(L, lua_geti(L, -1, 2) == LUA_TTABLE, 1, "subs must be tables");
        for (int j = 1; j <= luaL_len(L, -1); j++) {
          luaL_argcheck(L, lua_geti(L, -1, j) == LUA_TSTRING, 1, "subs must be strings"), lua_pop(L, 1);
        }
        lua_pop(L, 1); // subs
      }
      lua_pop(L, 1); // key
    }
  }
  unsigned long long timeout = luaL_optnumber(L, 2, 0) * 1000000000;
  int num_args = 2 + (num_keys * 3); // timeout, num_keys, {varname, subs_used, subsarray}*
  gparam_list params;
  params.n = num_args;
  int arg_i = 0;
  params.arg[arg_i++] = (void *)timeout;
  params.arg[arg_i++] = (void *)(uintptr_t)num_keys;
  ydb_key_t keys[num_keys];
  for (int i = 0; i < num_keys && i < MAX_ACTUALS; i++) {
    lua_geti(L, 1, i + 1);
    lua_geti(L, -1, 1);
    YDB_MALLOC_BUFFER(&keys[i].varname, luaL_len(L, -1));
    int unused;
    YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &keys[i].varname, unused);
    lua_pop(L, 1); // varname
    if (luaL_len(L, -1) > 1) {
      lua_geti(L, -1, 2);
      keys[i].subs_used = luaL_len(L, -1);
      keys[i].subsarray = malloc(keys[i].subs_used * sizeof(ydb_buffer_t));
      for (int j = 0; j < keys[i].subs_used; j++) {
        lua_geti(L, -1, j + 1);
        YDB_MALLOC_BUFFER(&keys[i].subsarray[j], luaL_len(L, -1));
        YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &keys[i].subsarray[j], unused);
        lua_pop(L, 1); // sub
      }
      lua_pop(L, 1); // subs
    } else {
      keys[i].subs_used = 0;
      keys[i].subsarray = NULL;
    }
    lua_pop(L, 1); // key
    params.arg[arg_i++] = (void *)&keys[i].varname;
    params.arg[arg_i++] = (void *)(uintptr_t)keys[i].subs_used;
    params.arg[arg_i++] = (void *)keys[i].subsarray;
  }
  int status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_lock_s, &params);
  for (int i = 0; i < num_keys; i++) {
    YDB_FREE_BUFFER(&keys[i].varname);
    for (int j = 0; j < keys[i].subs_used; j++) {
      YDB_FREE_BUFFER(&keys[i].subsarray[j]);
    }
  }
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

// Deletes trees of all local variables except the given ones.
// _yottadb.delete_excl(varnames)
// varnames: table of variable names to exclude (no subscripts)
static int delete_excl(lua_State *L) {
  luaL_argcheck(L, lua_istable(L, 1), 1, "table of varnames expected");
  int namecount = luaL_len(L, 1);
  for (int i = 0; i < namecount; i++) {
    luaL_argcheck(L, lua_geti(L, 1, i + 1) == LUA_TSTRING, 1, "varnames must be strings"), lua_pop(L, 1);
  }
  ydb_buffer_t varnames[namecount];
  for (int i = 0; i < namecount; i++) {
    lua_geti(L, 1, i + 1);
    YDB_MALLOC_BUFFER(&varnames[i], luaL_len(L, -1));
    int unused;
    YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &varnames[i], unused);
    lua_pop(L, 1); // varname
  }
  int status = ydb_delete_excl_s(namecount, varnames);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 0;
}

// Increments the numeric value of a variable/node.
// Raises an error on overflow.
// _yottadb.incr(varname[, subs][, increment=n])
// varname: string
// subs: optional table of subscripts
// increment: amount to increment by = number, or string-of-a-canonical-number, default=1
static int incr(lua_State *L) {
  ydb_buffer_t varname;
  int subs_used;
  get_key_info(L, &varname, &subs_used);
  ydb_buffer_t subsarray[subs_used];
  get_subs(L, subs_used, subsarray);
  ydb_buffer_t increment;
  YDB_STRING_TO_BUFFER(luaL_optstring(L, !lua_isstring(L, 2) ? 3 : 2, ""), &increment);
  ydb_buffer_t ret_value;
  YDB_MALLOC_BUFFER(&ret_value, LUA_YDB_BUFSIZ);
  int status = ydb_incr_s(&varname, subs_used, subsarray, &increment, &ret_value);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&ret_value);
    status = ydb_incr_s(&varname, subs_used, subsarray, &increment, &ret_value);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, ret_value.buf_addr, ret_value.len_used);
  }
  YDB_FREE_BUFFER(&ret_value);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Returns the zwrite-formatted version of the given string.
// _yottadb.str2zwr(s)
// s: string
// return: zwrite-formatted string
static int str2zwr(lua_State *L) {
  ydb_buffer_t str;
  YDB_STRING_TO_BUFFER(luaL_checkstring(L, 1), &str);
  str.len_alloc = str.len_used = luaL_len(L, 1); // in case of NUL bytes
  ydb_buffer_t zwr;
  YDB_MALLOC_BUFFER(&zwr, LUA_YDB_BUFSIZ);
  int status = ydb_str2zwr_s(&str, &zwr);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&zwr);
    status = ydb_str2zwr_s(&str, &zwr);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, zwr.buf_addr, zwr.len_used);
  }
  YDB_FREE_BUFFER(&zwr);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}

// Returns the string described by the given zwrite-formatted string.
// _yottadb.zwr2str(s)
// s: zwrite-formatted string
// return: string
static int zwr2str(lua_State *L) {
  ydb_buffer_t zwr;
  YDB_STRING_TO_BUFFER(luaL_checkstring(L, 1), &zwr);
  ydb_buffer_t str;
  YDB_MALLOC_BUFFER(&str, LUA_YDB_BUFSIZ);
  int status = ydb_zwr2str_s(&zwr, &str);
  if (status == YDB_ERR_INVSTRLEN) {
    YDB_REALLOC_BUFFER(&str);
    status = ydb_zwr2str_s(&zwr, &str);
  }
  if (status == YDB_OK) {
    lua_pushlstring(L, str.buf_addr, str.len_used);
  }
  YDB_FREE_BUFFER(&str);
  if (status != YDB_OK) {
    error(L, status);
  }
  return 1;
}


// ~~~ Manage YDB callins ~~~

// Open a call-in table using ydb_ci_tab_open()
// _yottadb.ci_tab_open(ci_table_filename)
// return: integer handle to call-in table
static int ci_tab_open(lua_State *L) {
  uintptr_t ci_handle;
  ydb_ci_tab_open(luaL_checkstring(L, 1), &ci_handle);
  lua_pop(L, 1);
  lua_pushinteger(L, ci_handle);
  return 1;
}

// Make enum that expresses a bitfield for speedy category lookup when processing
// order of bits is also important for YDB_TYPE_ISINTEGRAL to work
#define _YDB_TYPE_ISUNSIGNED 0x01  /* unsigned must be bit1 for enum sequential types to work */
#define _YDB_TYPE_IS32BIT    0x02  /* not set for LONG types which are build-dependent in YDB */
#define _YDB_TYPE_IS64BIT    0x04  /* not set for LONG types which are build-dependent in YDB */
#define _YDB_TYPE_ISPTR      0x08
#define _YDB_TYPE_ISREAL     0x10  /* float or double */
#define _YDB_TYPE_ISSTR      0x80  /* Note: for string types, other bits have different: to distinguish string types */

enum ydb_types {
  YDB_LONG_T  = 0, YDB_ULONG_T,
  YDB_INT_T   = _YDB_TYPE_IS32BIT, YDB_UINT_T,
  YDB_INT64_T = _YDB_TYPE_IS64BIT, YDB_UINT64_T,
  YDB_FLOAT_T = _YDB_TYPE_ISREAL+_YDB_TYPE_IS32BIT,
  YDB_DOUBLE_T= _YDB_TYPE_ISREAL+_YDB_TYPE_IS64BIT,
  YDB_LONG_T_PTR  = _YDB_TYPE_ISPTR, YDB_ULONG_T,
  YDB_INT_T_PTR   = _YDB_TYPE_ISPTR+_YDB_TYPE_IS32BIT, YDB_UINT_T,
  YDB_INT64_T_PTR = _YDB_TYPE_ISPTR+_YDB_TYPE_IS64BIT, YDB_UINT64_T,
  YDB_FLOAT_T_PTR = _YDB_TYPE_ISPTR+_YDB_TYPE_ISREAL+_YDB_TYPE_IS32BIT,
  YDB_DOUBLE_T_PTR= _YDB_TYPE_ISPTR+_YDB_TYPE_ISREAL+_YDB_TYPE_IS64BIT,
  YDB_CHAR_T_PTR  = _YDB_TYPE_ISSTR+_YDB_TYPE_ISPTR, YDB_STRING_T_PTR, YDB_BUFFER_T_PTR,
  VOID=0xff
};

// Make table of constants for export to Lua
static const const_Reg yottadb_types[] = {
  {"ydb_long_t", YDB_LONG_T}, {"ydb_ulong_t", YDB_ULONG_T},
  {"ydb_int_t", YDB_INT_T}, {"ydb_uint_t", YDB_UINT_T},
  {"ydb_int64_t", YDB_INT64_T}, {"ydb_uint64_t", YDB_UINT64_T},
  {"ydb_float_t", YDB_FLOAT_T}, {"ydb_double_t", YDB_DOUBLE_T},
  {"ydb_long_t*", YDB_LONG_T_PTR}, {"ydb_ulong_t*", YDB_ULONG_T_PTR},
  {"ydb_int_t*", YDB_INT_T_PTR}, {"ydb_uint_t*", YDB_UINT_T_PTR},
  {"ydb_int64_t*", YDB_INT64_T_PTR}, {"ydb_uint64_t*", YDB_UINT64_T_PTR},
  {"ydb_float_t*", YDB_FLOAT_T_PTR}, {"ydb_double_t*", YDB_DOUBLE_T_PTR},
  {"ydb_char_t*", YDB_CHAR_T_PTR},
  {"ydb_string_t*", YDB_STRING_T_PTR},
  {"ydb_buffer_t*", YDB_BUFFER_T_PTR},
  {"void", VOID},
  {NULL, 0},
};

#define YDB_TYPE_ISSTR(type) (((type)&_YDB_TYPE_ISSTR) != 0)
// The following macros assume the type is already know to be not VOID and not string type
#define YDB_TYPE_ISPTR(type) (((type)&_YDB_TYPE_ISPTR) != 0)
#define YDB_TYPE_ISREAL(type) (((type)&_YDB_TYPE_ISREAL) != 0)
#define YDB_TYPE_IS64BIT(type) (((type)&_YDB_TYPE_IS64BIT) != 0)
#define YDB_TYPE_IS32BIT(type) (((type)&_YDB_TYPE_IS32BIT) != 0)
#define YDB_TYPE_ISUNSIGNED(type) (((type)&_YDB_TYPE_ISUNSIGNED) != 0)
#define YDB_TYPE_ISINTEGRAL(type) ((type) < _YDB_TYPE_ISREAL)

// Let Lua know the order of enums -- keeps it the same between C and Lua versions
#define _AUX(...) #__VA_ARGS__
#define _STRINGIFY(x) _AUX(x)
static char YDB_CI_PARAM_TYPES[] = _STRINGIFY(PARAM_TYPE_NAMES);

typedef union ydb_param_union {
  ydb_int_t int_n;
  ydb_uint_t uint_n;
  ydb_long_t long_n;
  ydb_ulong_t ulong_n;
  ydb_float_t float_n;

  intptr_t* any_ptr; // for storing pointer to any pointer type
  ydb_int_t* int_ptr;
  ydb_uint_t* uint_ptr;
  ydb_long_t* long_ptr;
  ydb_ulong_t* ulong_ptr;
  ydb_float_t* float_ptr;
  ydb_double_t* double_ptr;

  ydb_char_t* char_ptr;
  ydb_string_t* string_ptr;
  ydb_buffer_t* buffer_ptr; // Note: only works from YDB r1.36 onward

  #if UINTPTR_MAX == 0xffffffffffffffff
    // ydb_double_t doesn't fit in (void*) on 32-bit builds. Instead, use pointer type ydb_double_t*
    ydb_double_t double_n;
    // int64 types do not exist on 32-bit builds
    ydb_int64_t int64_n;
    ydb_uint64_t uint64_n;
    ydb_int64_t* int64_ptr;
    ydb_uint64_t* uint64_ptr;
  #endif
} ydb_param;

static_assert( sizeof(ydb_param) == sizeof(void*),
  "Not all ydb_ci parameters will fit into ydb's gparam_list array. "
  "Need to revise either ydb or lua-yottadb code. Or don't use the offending parameter types."
);

// type of parameter list passed to ydb_call_variadic_plist_func()
typedef struct {
	intptr_t n;				/* Count of parameter/arguments -- must be same type as in YDB's gparam_list */
	ydb_param arg[MAX_GPARAM_LIST_ARGS];	/* Parameter/argument array */
} gparam_list_alltypes;

// struct to house every kind of ydb string
typedef struct {
  typedef union {
    ydb_string_t string;
    ydb_buffer_t buffer;
  } type;
  char **data;  // the actual string
} blob_alltypes;

// specify type and IO of call-in parameter from call-in table
// (specify __packed__ since these structs are packed end-to-end into a Lua string -- may not be necessary since they're all chars)
typedef struct {
  size_t preallocation; // amount of string space to preallocate -- first for alignment reasons
  char type;  // index into enum ydb_types
  char input, output;  // 1 char boolean flags
} type_spec;

// Manage metadata for ci()
//   specifically, hold param data for each param and malloc pointers that need to be freed
// -- for internal use
// For the sake of speed, init M in pre-allocated space rather than using malloc because stack is
//   much faster. Thus, for minimal functions that don't return strings, malloc is not needed at all.
// Functions defined as inline for speed.
typedef struct {
	int n;				    // count of mallocs stored so far
	void **malloc;    // array of malloc'ed handles - one for each param
  ydb_param *data;  // array of ydb_param space - one for each param
} metadata;
// Allocate metadata structure for 'n' params
// Metadata is used, to store param data and mallocs (for subsequent freeing)
// Allocate on the stack for speed (hence need to use a macro)
// Invoke with: metadata M* = create_metadata(n)
#define create_metadata(n) \
  NULL; \
  ydb_param param_space[(n)]; \
  void *malloc_space[(n)]; \
  metadata __M = {0, param_space, malloc_space}; \
  M = &__M; /* ptr makes it same for user as if we made non-macro version */
static inline void *add_malloc(metadata *M, size_t size) {
  return (*M->malloc)[M->n++] = malloc(size);
}
// Free each pointer in an array of malloc'ed pointers unless it is NULL
// ensure the first element is freed last because it contains the malloc structure itself
static inline void free_mallocs(metadata *M) {
  for (int i = M->n-1; i >= 0; i--) free((*M->malloc)[i]);
}
// Return pointer to metadata for parameter n
static inline ydb_param *get_metadata(M, int n) {
  return &(*M->data)[n];
}

// Cast Lua parameter at Lua stack index argi to ydb type type->type
// Store any malloc'ed data in metadata struct M
// On error, free all mallocs tracked in M and raise a Lua error
// Note: this is inner loop param processing, so limit cast_2ydb() args to 4 for speedy register params
ydb_param cast_2ydb(lua_State *L, int argi, type_spec *ydb_type, metadata *M) {
  char *expected;  // expected type for error message
  ydb_param param;
  int isint;
  bool success;
  char type = ydb_type->type;
  char isinput = ydb_type->input;
  char isoutput = ydb_type->output;

  // Use IF statement -- faster than SWITCH (even if table lookup) due to pipelining (untested)
  if (YDB_TYPE_ISSTR(type)) {
    // first handle all string types (number types later)
    size_t preallocation = ydb_type->preallocation;
    if (!preallocation) preallocation=YDB_MAX_STR;
    size_t length;
    char *s = strcpy(param.char_ptr, lua_tolstring(L, argi, &length))
    if (length > preallocation) length = preallocation; // prevent writing past preallocation
    if (!s) { expected="string"; goto type_error; }
    if (type == YDB_CHAR_T_PTR) {
      // handle ydb_char_t* type
      if (isoutput) {
        // TODO: could check here whether YDB avoids overwriting string of strlen(input_string) -- maybe we don't need to malloc preallocation, and maybe we need to fill an input string with junk to the preallocation
        param.char_ptr = add_malloc(M, preallocation+1); // +1 for null safety-terminator
        if (isinput) {
          memcpy(param.char_ptr, s, length); // also copy Lua's NUL safety-terminator
          param.char_ptr[length] = '\0';  // make sure it's null-terminated somewhere
        } else
          param.char_ptr[0] = '\0'; // make it a blank string to start with if it's not an input
      } else {
        param.char_ptr = s;
      }
    } else if (type == YDB_STRING_T_PTR) {
      // handle ydb_string_t* type
      if (isoutput) {
        // TODO: check by trial whether YDB avoids overwriting string of strlen(input_string) -- maybe we don't need to malloc preallocation
        blob_alltypes *blob = add_malloc(M, preallocation+sizeof(blob_alltypes));
        param.string_ptr = &blob->type;
        param.string_ptr.address = &blob->data;
        param.string_ptr.length = preallocation;
        if (isinput)
          memcpy(param.string_ptr.address, s, length);
      } else {
        blob_alltypes *blob = add_malloc(M, sizeof(blob_alltypes));
        param.string_ptr = &blob->type;
        param.string_ptr.address = s;
        param.string_ptr.length = length;
      }
    } else (type == YDB_BUFFER_T_PTR) {
      // handle ydb_buffer_t* type
      if (isoutput) {
        blob_alltypes *blob = add_malloc(M, preallocation+sizeof(blob_alltypes));
        param.buffer_ptr = &blob->type;
        param.buffer_ptr.buf_addr = &blob->data;
        param.buffer_ptr.len_alloc = preallocation;
        param.buffer_ptr.len_used = 0;
        if (isinput) {
          memcpy(param.buffer_ptr.buf_addr, s, length);
          param.buffer_ptr.len_used = length;
        }
      } else {
        blob_alltypes *blob = add_malloc(M, sizeof(blob_alltypes));
        param.buffer_ptr = &blob->type;
        param.buffer_ptr.buf_addr = s;
        param.buffer_ptr.len_alloc = length;
        param.buffer_ptr.len_used = length;
      }
    } else {
        free_mallocs(M);
        luaL_error("Invalid type id %d supplied in M routine call-in specification", type);
    }

  } else {
    // now handle number types
    if (isinput) {
      if (YDB_TYPE_ISINTEGRAL(type)) {
        // handle long and int64
        param.long_n = lua_tointegerx(L, argi, &success);
        if (!success) { expected="integer"; goto type_error; }
        if (YDB_TYPE_IS32BIT(type))
          // handle int32 (ydb_int_t is specifically 32-bits)
          param.int_n = param.long_n; // cast in case we're running big-endian
      } else if (YDB_TYPE_ISREAL(type) {
        param.double_n = lua_tonumberx(L, argi, &success);
        if (!success) { expected="number"; goto type_error; }
        if (type == YDB_FLOAT_T)
          param.float_n = param.double_n; // cast
      }
    } else
      param.long_n = 0;
    if (YDB_TYPE_ISPTR(type) {
      // If it's a pointer type, store the actual data in M->data, then make param point to it
      M->data[argi] = param;
      param.any_ptr = &M->data[argi];
    }
  }

  // TODO: confirm in assembler output that compiler returns an efficient single 64-bit value for param
  return param;
type_error:
  free_mallocs(M);
  luaL_typeerror(L, argi, expected);
}

// Cast retval/output param from ydb_type to a Lua type and push onto the Lua stack as a return value.
// Only called for output types
// There are no errors
// Note: this is inner loop param processing, so limit cast_2lua() args to 4 for speedy register params
void cast_2lua(lua_State *L, ydb_param *param, type_spec *ydb_type) {
  char type = ydb_type->type;

  // Use IF statement -- faster than SWITCH (even if table lookup) due to pipelining (untested)
  if (YDB_TYPE_ISSTR(type)) {
    // first handle all string types (number types later)
    if (type == YDB_CHAR_T_PTR)
      lua_pushstring(L, param->char_ptr);
    else if (type == YDB_STRING_T_PTR)
      lua_pushlstring(L, param->string_ptr->address, param->string_ptr->length);
    else (type == YDB_BUFFER_T_PTR)
      lua_pushlstring(L, param->buffer_ptr->buf_addr, param->buffer_ptr->len_used);

  } else {
    // now handle number types
    if (YDB_TYPE_ISINTEGRAL(type)) {
      if (YDB_TYPE_IS32BIT(type))  // handle int32 (ydb_int_t is specifically 32-bits)
        lua_pushinteger(L, *param->int_ptr);
      else
        lua_pushinteger(L, *param->long_ptr);
    } else if (YDB_TYPE_ISREAL(type) {
      if (type == YDB_FLOAT_T_PTR)
        lua_pushnumber(L, *param->float_ptr);
      else
        lua_pushnumber(L, *param->double_ptr);
    }
  }
}


// Call an M routine using ydb_ci()
// Note: this function is intended to be called by a wrapper in yottadb.lua rather than by the user
//    (so validity of type_list array is not checked)
// _yottadb.ci(ci_handle, routine_name, type_list[, param1][, param2][, ...])
// Call M routine routine_name which was specified in call-in table ci_handle, cf. ci_tab_open()
// @param type_list is a Lua string containing an array of type_spec[] specifying for ret_val and each parameter per the call-in table
//    (so the number of type_spec array elements must equal (1+n) where n is the number of parameters in the call-in file)
// @param<n> must list the parameters specified specified in the call-in table
//    each parameter is converted from its Lua type to the correct C type (e.g. ydb_int_t*) before calling the M routine
//    an error results if the number of parameters does not match the number specified in the call-in table
//    if too few parameters are supplied, an error results
//    if too many parameters are supplied, they are ignored (typical Lua behaviour)
// return: function's return value (unless ret_type='void') followed by any params listed as outputs (O or IO) in the call-in table
//    returned values are all converted from the call-in table type to Lua types
// NOTE: This is designed for speed, which means it does no mallocs unless it has to return strings
//    (because mallocs take ~50 CPU cycles each, according to google)
static int ci(lua_State *L) {
  uintptr_t old_handle, ci_handle = luaL_checkinteger(L, 1);
  char *routine_name = luaL_checkstring(L, 2);

  size_t type_list_len;
  char *type_string = lua_tolstring(L, 3, &type_list_len);
  type_spec *type_list = (type_spec *)type_string;
  type_spec *types_end = (type_spec*)(type_string + type_list_len);
  bool has_retval = type_list->type != VOID;
  if (!has_retval) type_list++; // Don't need the first type any more if its type is VOID

  gparam_list_alltypes out_arg; // list of args to send to ydb_ci()
  int in_args = lua_gettop(L);
  out_arg.n = (intptr_t) = types_end - type_list + 1; // +1 for routine_name
  if ((in_args-2+has_retval) < out_arg.n)
    luaL_error(L, "not enough parameters to match M routine call-in specification");

  // Allocate space to store a free-pointer and other metadata for each in_arg where needed
  // Note: after this, must not error out without first calling free_mallocs(M)
  metadata *M = create_metadata(in_args+1);

  int argi=0;  // output argument index
  out_arg.arg[argi++].char_ptr = routine_name;
  type_spec *typeptr = type_list;
  for (; typeptr<types_end; typeptr++, argi++) {
    out_arg.arg[argi] = cast_2ydb(L, argi+3-has_retval, typeptr, M);
  }

  // Set new ci_table
  int status = ydb_ci_tab_switch(ci_handle, &old_handle);
  if (status != YDB_OK) { free_mallocs(M); error(L, status); }

  // Call the M routine
  fflush(stdout); // Avoid mingled stdout; ydb routine also needs to flush with (U $P) after it outputs
  // Note: ydb function ydb_call_variadic_plist_func() assumes all parameters passed are sizeof(void*)
  // which works, luckily, because gcc pads even 32-bit ydb_int_t to 64-bits
  status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_ci, (gparam_list*)&out_arg);

  // Restore ci_table
  int status2 = ydb_ci_tab_switch(old_handle, &ci_handle);
  if (status == YDB_OK) status=status2; // report the first error
  if (status != YDB_OK) { free_mallocs(M); error(L, status); }
  lua_pop(L, in_args); // pop all args

  // Push return values
  int nreturns = 0;
  type_spec *typeptr = type_list;
  for (argi=1;  typeptr<types_end;  typeptr++, argi++) {
    if (!typeptr->output) continue;
    cast_2lua(L, &out_arg[argi], typeptr);
    nreturns++;
  }

  free_mallocs(M);
  return nreturns;
}

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
  {"ci", ci},
  {"init", _ydb_init},
  {NULL, NULL}
};

static const const_Reg yottadb_constants[] = {
  {"YDB_ERR_GVUNDEF", YDB_ERR_GVUNDEF},
  {"YDB_ERR_LVUNDEF", YDB_ERR_LVUNDEF},
  {"YDB_MAX_STR", YDB_MAX_STR},
  {"YDB_DEL_NODE", YDB_DEL_NODE},
  {"YDB_DEL_TREE", YDB_DEL_TREE},
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
  {"DIR_NONE", DIR_NONE},
  {"DIR_IN", DIR_IN},
  {"DIR_OUT", DIR_OUT},
  {"DIR_BOTH", DIR_BOTH};
  {NULL, 0}
};

int luaopen__yottadb(lua_State *L) {
  luaL_newlib(L, yottadb_functions);
  for (const_Reg *c = &yottadb_constants[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_pushstring(L, LUA_YOTTADB_VERSION_STRING), lua_setfield(L, -2, "_VERSION");
  lua_createtable(L, 0, sizeof(yottadb_types)/sizeof(const_Reg));
  for (const_Reg *c = &yottadb_types[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_setfield(L, -2, "YDB_CI_PARAM_TYPES");
  return 1;
}
