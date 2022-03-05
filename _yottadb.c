//

#include <assert.h>
#include <stdint.h> // intptr_t
#include <stdio.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

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

// Raises a Lua error with error object {code = X, message = Y} where X is the YDB error code
// and Y is the message reported by YDB.
static int error(lua_State *L, int code) {
  lua_newtable(L);
  lua_pushnumber(L, code), lua_setfield(L, -2, "code");
  char message[2048]; // docs say 2048 is a safe size
  ydb_zstatus(message, 2048);
  lua_pushstring(L, message), lua_setfield(L, -2, "message");
  lua_error(L);
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
  YDB_STRING_TO_BUFFER(luaL_optstring(L, !lua_isstring(L, 2) ? 3 : 2, ""), &value);
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
//   _yottadb.YDB_DATA_VALUE_NODESC (value and subtree)
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
  lua_pushnumber(L, ret_value);
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
  int status;
  if (lua_pcall(L, n - 1, 1, 0) != LUA_OK) {
    if (lua_type(L, -1) == LUA_TTABLE) {
      status = (lua_getfield(L, -1, "code"), lua_tointeger(L, -1));
      lua_pop(L, 1);
    } else {
      lua_pushvalue(L, -1), lua_setfield(L, LUA_REGISTRYINDEX, "_yottadb_lua_error");
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
// varnames: optional table of varnames to restore on transaction restart
// f: Lua function to call (can have nested _yottadb.tp() calls for nested transactions)
//   If f returns nothing or _yottadb.YDB_OK, the transaction is committed.
//   If f returns _yottadb.YDB_TP_RESTART or _yottadb.YDB_TP_ROLLBACK, the transaction is
//     restarted (f will be called again) or not committed, respectively.
//   If f errors, the transaction is not committed and the error propagated up the stack.
// ...: optional arguments to pass to f
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
  void **args = malloc((1 + num_args) * sizeof(void *)); // include num_args itself
  int arg_i = 0;
  args[arg_i++] = (void *)(uintptr_t)num_args;
  args[arg_i++] = (void *)timeout;
  args[arg_i++] = (void *)(uintptr_t)num_keys;
  ydb_key_t keys[num_keys];
  for (int i = 0; i < num_keys; i++) {
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
    args[arg_i++] = (void *)&keys[i].varname;
    args[arg_i++] = (void *)(uintptr_t)keys[i].subs_used;
    args[arg_i++] = (void *)keys[i].subsarray;
  }
  int status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_lock_s, (uintptr_t)args);
  for (int i = 0; i < num_keys; i++) {
    YDB_FREE_BUFFER(&keys[i].varname);
    for (int j = 0; j < keys[i].subs_used; j++) {
      YDB_FREE_BUFFER(&keys[i].subsarray[j]);
    }
  }
  free(args);
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
// _yottadb.incr(varname[, subs][, increment='1'])
// varname: string
// subs: optional table of subscripts
// increment: string amount to increment by (should be a canonical number)
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
  {NULL, NULL}
};

typedef struct const_Reg {
  const char *name;
  int value;
} const_Reg;

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
  {NULL, 0}
};

int luaopen__yottadb(lua_State *L) {
  luaL_newlib(L, yottadb_functions);
  for (const_Reg *c = &yottadb_constants[0]; c->name; c++) {
    lua_pushnumber(L, c->value), lua_setfield(L, -2, c->name);
  }
  return 1;
}
