// Copyright 2021-2022 Mitchell. See LICENSE.

#include <assert.h>
#include <stdint.h> // intptr_t
#include <stdio.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

#include "yottadb.h"
#include "callins.h"

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

const char *LUA_YDB_ERR_PREFIX = "YDB Error: ";

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
int ydb_assert(lua_State *L, int code) {
  if (code == YDB_OK) return code;
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
  ydb_assert(L, status);
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
  ydb_assert(L, ydb_set_s(&varname, subs_used, subsarray, &value));
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
  ydb_assert(L, ydb_delete_s(&varname, subs_used, subsarray, deltype));
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
  ydb_assert(L, ydb_data_s(&varname, subs_used, subsarray, &ret_value));
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
  ydb_assert(L, ydb_lock_incr_s(timeout, &varname, subs_used, subsarray));
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
  ydb_assert(L, ydb_lock_decr_s(&varname, subs_used, subsarray));
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
  } else if (status != YDB_TP_RESTART) {
    ydb_assert(L, status);
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
  ydb_assert(L, status);
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
  ydb_assert(L, status);
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
  ydb_assert(L, status);
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
  ydb_assert(L, status);
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
  ydb_assert(L, status);
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
    YDB_COPY_STRING_TO_BUFFER(lua_tostring(L, -1), &varnames[i], unused);
    lua_pop(L, 1); // varname
  }
  ydb_assert(L, ydb_delete_excl_s(namecount, varnames));
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
  ydb_assert(L, status);
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
  ydb_assert(L, status);
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
  {"init", _ydb_init},
  #if LUA_VERSION_NUM < 502
    {"string_format", str_format},
    {"table_unpack", unpack},
  #endif
  #if LUA_VERSION_NUM < 503
    {"string_pack", str_pack},
  #endif
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
  {NULL, 0}
};

int luaopen__yottadb(lua_State *L) {
  luaL_newlib(L, yottadb_functions);
  for (const_Reg *c = &yottadb_constants[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_pushstring(L, LUA_YOTTADB_VERSION_STRING), lua_setfield(L, -2, "_VERSION");
  lua_createtable(L, 0, 20);
  for (const_Reg *c = &yottadb_types[0]; c->name; c++) {
    lua_pushinteger(L, c->value), lua_setfield(L, -2, c->name);
  }
  lua_setfield(L, -2, "YDB_CI_PARAM_TYPES");
  return 1;
}
