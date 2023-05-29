/// Manage C-cached subscript arrays for speed.
// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// @module yottadb.c

/// Cachearray functions
// @section

#include <stdio.h>
#include <stdbool.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

#include "yottadb.h"
#include "cachearray.h"

// Number of extra items to allocate in cachearray.
// This prevents having to create a new userdata for every single subnode
// Assumes most uses will only dive into subscripts this much deeper than their starting point node
// If users do go deeper, it all still works; it just has to create a new cachearray
#define ARRAY_OVERALLOC 5

#define NO_PARENT LUA_REGISTRYINDEX

// Allocate cachearray of `size` and set its metatable to the same as the cachearray at parent_index.
// @param size of space to allocate for cachearray
// @param parent_index is the index of the cachearray whose metatable will be inherited -- specify
// special value NO_PARENT to apply no metatable
// @return new_cachearray and on Lua stack
static cachearray_t *cachearray_new(lua_State *L, int size, int parent_index) {
  cachearray_t *array = lua_newuserdata(L, size);
  array->flags = 0;  // default
  if (parent_index != NO_PARENT && lua_getmetatable(L, parent_index) != 0)
    lua_setmetatable(L, -2);
  return array;
}

/// Set metatable for a cachearray since Lua itself can't set userdata metatables.
// This is the same as debug.setmetatable(cachearray, mt) but production apps are not supposed to use the debug library.
// @function cachearray_setmetatable
// @usage _yottadb.cachearray_setmetatable(cachearray, metatable)
// @param cachearray to set
// @param metatable to use
// @return cachearray
int cachearray_setmetatable(lua_State *L) {
  if (lua_type(L, 1) != LUA_TUSERDATA)
    luaL_error(L, "parameter #1 must be a cachearray (got %s)", lua_typename(L, lua_type(L, 1)));
  lua_setmetatable(L, -2);
  return 1;
}

// Update cachearray subscript pointers to match subsdata_string at addr
static void _cachearray_updateaddr(cachearray_t *array, char *subsdata) {
  ydb_buffer_t *element = &array->varname;  // assumes array->subs[] come straight after array->varname
  // unsigned comparison is important below to handle when we get junk data in depth
  int depth = (unsigned)array->depth_used > (unsigned)array->depth_alloc? array->depth_alloc: array->depth_used;
  do {
    element->buf_addr = subsdata;
    subsdata += element->len_used;
    element++;
  } while (depth--);
}

// Reallocate (expand space of) cachearray at stack location `index` and replace it with a new one in the same stack index.
// @param index of Lua stack where cachearray resides
// @param new_depth is the required depth in the new cachearray (ARRAY_OVERALLOC will be added to this)
// @param new_subslen is the required subsdata_string length (ARRAY_OVERALLOC*YDB_TYPICAL_SUBLEN will be added)
// @param **subsdata points to where to copy subsdata_string from, and where to store the address of the new subsdata_string
// @return a cachearray which has metatable matching the registry entry "cachearray"
static cachearray_t *_cachearray_realloc(lua_State *L, int index, int new_depth, int new_subslen, char **subsdata) {
  cachearray_t *array = lua_touserdata(L, index);
  array = array->dereference;
  int depth_alloc2 = new_depth + ARRAY_OVERALLOC;
  int arraysize2 = depth_alloc2 * sizeof(ydb_buffer_t);
  int subsdata_alloc2 = new_subslen + (ARRAY_OVERALLOC*YDB_TYPICAL_SUBLEN);
  int allocsize = sizeof(cachearray_t) + arraysize2 + subsdata_alloc2;

  cachearray_t *newarray = cachearray_new(L, allocsize, index);
  newarray->dereference = newarray;  // point to itself (i.e. it's not dereferenced)
  newarray->depth = new_depth;
  newarray->subsdata_alloc = subsdata_alloc2;
  newarray->depth_alloc = depth_alloc2;
  char *new_subsdata = get_subsdata(newarray);  // must set ->subsdata_alloc first

  int copydepth = 1 + array->depth_alloc<new_depth? array->depth_alloc: new_depth; // 1+ for varname
  int copysize = sizeof(cachearray_t) - offsetof(cachearray_t,depth_used) + copydepth*sizeof(ydb_buffer_t);
  memcpy(&newarray->depth_used, &array->depth_used, copysize);

  copysize = array->subsdata_alloc < new_subslen? array->subsdata_alloc: new_subslen;
  memcpy(new_subsdata, *subsdata, copysize);

  // Set up array sizes before update
  newarray->subsdata_alloc = subsdata_alloc2;
  newarray->depth_alloc = depth_alloc2;
  _cachearray_updateaddr(newarray, new_subsdata);
  *subsdata = new_subsdata;
  // STACK: <original_stack, ...>, new_cachearray
  lua_replace(L, index-(index<0)); // sub this cachearray onto the stack instead of the original one.
  return newarray;
}

// Underlying core of `cachearray_create()`, designed to call from C.
// Create cachearray from varname and subscripts on the Lua stack: varname[, t1][, ...]
// This function may be called by C -- the stack is correct at the end (doesn't depend on Lua's stack fixups).
// For the sake of speed, the caller can pre-allocate `cachearray_t_maxsize` on its stack
// (in which case the returned cachearray will only be valid while inside that C function).
// For example, pre-allocating it on the C stack is 20% (400ns) faster than `lua_newuserdata()`
// @param array_prealloc is a pointer to allocated memory that fits a maximum sized cachearray.
// If it is NULL, the function will allocate cachearray itself, using `lua_newuserdata()`.
// @return cachearray_t* -- lightuserdata if array is supplied in C parameter; otherwise full userdata with metatable matching the registry entry "cachearray"
// @return cachearray on Lua stack
cachearray_t *_cachearray_create(lua_State *L, cachearray_t_maxsize *array_prealloc) {
  int args = lua_gettop(L);
  if (lua_type(L, 1) != LUA_TSTRING)
    luaL_error(L, "Cannot generate cachearray: string expected at parameter #1 (varname) (got %s)", lua_typename(L, lua_type(L, 1)));

  // Determine depth of cachearray to malloc
  int type_t1 = lua_type(L, 2);
  int depth = args - 1;
  int tlen = 0;
  if (type_t1 == LUA_TTABLE) {
    tlen = luaL_len(L, 2);
    depth = tlen + args - 2;
  }
  if (depth > YDB_MAX_SUBS)
    luaL_error(L, "Cannot generate cachearray: maximum %d number of subscripts exceeded (got %d)", YDB_MAX_SUBS, depth);

  // Init array -- leave some room to grow without realloc in case user creates subnodes
  cachearray_t *array;
  // Allocate temporary array on stack for speed
  char _tmp_array[sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t) + YDB_LARGE_SUBSLEN];
  if (array_prealloc) {
    array = (cachearray_t *)array_prealloc;
    array->subsdata_alloc = member_size(cachearray_t_maxsize, _subsdata);
    array->depth_alloc = member_len(cachearray_t_maxsize, subs);
  } else {
    array = (cachearray_t *)_tmp_array;
    array->subsdata_alloc = YDB_LARGE_SUBSLEN;
    array->depth_alloc = depth+ARRAY_OVERALLOC;
  }
  array->dereference = array;  // point to itself (i.e. it's not dereferenced)
  // Push cachearray on the Lua stack -- we will realloc it later if necessary
  lua_pushlightuserdata(L, array);

  char *subsdata = get_subsdata(array);
  int subslen = 0;
  int sub = 0;  // assumes array->subs[] come straight after array->varname

  // Append t1 if it is a table
  char *string;
  size_t len;
  int i = 1;
  for (int arg=1; arg <= args; arg++) {
    if (type_t1==LUA_TTABLE && arg==2) {
      if (i > tlen) continue;
      lua_geti(L, 2, i++);
      arg--;
    } else
      lua_pushvalue(L, arg);
    // Fetch string from top of stack
    string = lua_tolstring(L, -1, &len);
    if (!string)
      luaL_error(L, "Cannot generate cachearray: string/number expected in parameter #%d (got %s)", arg, lua_typename(L, lua_type(L, -1)));
    // Reallocate array if necessary
    if (subslen+(int)len > array->subsdata_alloc)
      array = _cachearray_realloc(L, -2, depth, subslen+len, &subsdata);
    memcpy(subsdata+subslen, string, len);
    lua_pop(L, 1);  // pop appended string

    ydb_buffer_t *element = &array->varname + sub;
    element->buf_addr = subsdata+subslen;
    element->len_used = element->len_alloc = len;
    subslen += len;
    sub++;
  }
  array->depth_used = depth;

  if (array == (cachearray_t *)_tmp_array)
    array = _cachearray_realloc(L, -1, depth, subslen, &subsdata);
  array->depth = depth;

  // STACK: varname[, t1], ...], cachearray
  lua_rotate(L, 1, 1);
  lua_pop(L, args);

  // The following is intentional, so switch off the warning
  // We're not returning a local variable's address: we checked for that in the IF statement above
  #pragma GCC diagnostic push
  #pragma GCC diagnostic ignored "-Wreturn-local-addr"
  return (cachearray_t*)(void*)array;
  #pragma GCC diagnostic pop
}

/// Generate and return a C-style array of subscripts as a userdata.
// The resulting full userdata contains a cached C array of varname and subscripts which may be passed
// to raw `_yottadb()` functions as a speedy subsarray.
// Returned cachearray is always immutable (copied from a mutable one if necessary)
// @function cachearray_create
// @usage _yottadb.cachearray_create(varname[, t1][, ...])
// @usage _yottadb.cachearray_create(cachearray[, ...])
// @param varname string (M glvn) or cachearray
// @param[opt] t1 Table of subscripts (may only be supplied if varname is a string)
// @param[opt] ... a list of strings to be appended to the cachearray after t1.
// @return cachearray
int cachearray_create(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (array) {
    int depth = array->depth;
    array = array->dereference;
    // if it's a mutable cachearray
    if (array->flags & MUTABLE_BIT) {
      if (depth < 0 || depth > array->depth_used)
        luaL_error(L, "Cannot copy cachearray: it has a corrupt depth (%d) must be between 0 and cachearray end %d", depth, array->depth_used);
      // Reallocate (i.e. copy) array using same depth and subsdata
      char *subsdata = get_subsdata(array);
      int subslen = get_subslen(array, depth, subsdata);
      array = _cachearray_realloc(L, 1, depth, subslen, &subsdata);
    }
    if (lua_gettop(L) > 1)  // see whether there are args to append
      cachearray_append(L);  // _append takes the same stack as _create
  } else {
    array = _cachearray_create(L, NULL);
  }
  return 1;
}

#if LUA_VERSION_NUM > 501
  #define my_setuservalue(L, index) lua_setuservalue((L), (index))
  #define my_getuservalue(L, index) lua_getuservalue((L), (index))
#else
  static int UVtable_ref = LUA_NOREF;

  // Version of `lua_setuservalue()`, implemented to work with any value type even on Lua versions <= 5.1
  // Pops a value from the stack and sets it as the new value associated to the userdata at the given index.
  // Value can be any Lua type.
  // Should work on any Lua version, but tested on Lua 5.1
  static void my_setuservalue(lua_State *L, int index) {
    // Create a uservalue table (with a metatable whose __mode="k" for weak keys)
    if (UVtable_ref == LUA_NOREF) {
      // create UVtable
      lua_createtable(L, 0, 1);
      // create metatable for UVtable
      lua_createtable(L, 0, 1);
      // set t.__mode = "k"
      lua_pushstring(L, "k");
      lua_setfield(L, -2, "__mode");
      // STACK: UVtable, metatable
      // set metatable of UVtable
      lua_setmetatable(L, -2);
      UVtable_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    // STACK: uservalue
    lua_rawgeti(L, LUA_REGISTRYINDEX, UVtable_ref);
    // STACK: uservalue, uvtable
    lua_pushvalue(L, index-(index<0));
    // STACK: uservalue, uvtable, userdata
    lua_pushvalue(L, -3);
    // STACK: uservalue, uvtable, userdata, uservalue
    lua_rawset(L, -3);  // sets: uvtable[userdata] = uservalue
    // STACK: uservalue, uvtable
    lua_pop(L, 2);
  }

  // Version of `lua_getuservalue()`, implemented to work with any value type even on Lua versions <= 5.1
  // Pushes onto the stack the Lua value associated with the userdata at the given index. Value can be any Lua type.
  // Should work on any Lua version, but tested on Lua 5.1
  static int my_getuservalue(lua_State *L, int index) {
    if (UVtable_ref == LUA_NOREF) {
      lua_pushnil(L);
      return LUA_TNIL;
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, UVtable_ref);
    // STACK: uvtable
    lua_pushvalue(L, index-(index<0));
    // STACK: uvtable, userdata
    lua_rawget(L, -2);
    // STACK: uvtable, uservalue
    lua_replace(L, -2);
    return lua_type(L, -1);
  }

  // Garbage-collect cachearray -- only for use in Lua <= 5.1 as later Luas allow uservalues to be userdata, so we don't need this
  // @function cachearray_gc
  // @usage node.__gc = _yottadb.cachearray_gc
  // @param cachearray is an existing cachearray created by cachearray_create()
  int cachearray_gc(lua_State *L) {
    cachearray_t *array = lua_touserdata(L, 1);
    if (!array || array == array->dereference)  // only dereferenced arrays have uservalues
      // This return of UVtable is for debugging garbage collection:
      return lua_rawgeti(L, LUA_REGISTRYINDEX, UVtable_ref), 1;
    lua_pushnil(L);
    my_setuservalue(L, -2);
    lua_pop(L, 1);
    return 0;
  }
#endif

// Create a new deferred version of the cachearray at `index` and replace the one at index with the new one.
// @return new cachearray
static cachearray_t *_cachearray_deferred(lua_State *L, int index) {
  cachearray_t *parent = lua_touserdata(L, index);
  if (!parent)
    luaL_error(L, "_cachearray_deferred() parameter #1 must be a cachearray (got %s)", lua_typename(L, lua_type(L, index)));
  cachearray_t *array = cachearray_new(L, sizeof(cachearray_dereferenced), index);
  array->dereference = parent->dereference;
  array->depth = parent->depth;
  array->flags = parent->flags;
  // Make sure new cachearray Lua-references the parent to prevent its premature garbage collection
  // STACK: <original_stack, ...>, new_cachearray
  if (parent == parent->dereference)
    lua_pushvalue(L, index-(index<0));  // copy parent to top of stack
  else
    my_getuservalue(L, index-(index<0)); // point Lua to the actual original to avoid garbage collection chain buildup
  // STACK: <original_stack, ...>, new_cachearray, original_cachearray
  my_setuservalue(L, -2);
  // STACK: <original_stack, ...>, new_cachearray
  lua_replace(L, index-(index<0));
  return array;
}

/// Append subscripts to an existing cachearray, creating a copy if it is full at this depth.
// Append string list '...' to cachearray. If cachearray is full then copy the cachearray
// with free space for the appendage.
// Note: Function may be called by C as it tidies up its Lua stack itself.
// @function cachearray_append
// @usage _yottadb.cachearray_append(cachearray[, ...])
// @param cachearray is an existing cachearray created by cachearray_create()
// @param[opt] ... a list of strings to be appended
// @return cachearray (the same or new)
int cachearray_append(lua_State *L) {
  ydb_buffer_t *element;
  int args = lua_gettop(L);
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Cannot append to cachearray: cachearray expected at parameter #1 (got %s)", lua_typename(L, lua_type(L, 1)));
  int depth = array->depth;
  array = array->dereference;
  cachearray_t *original_array = array;
  if (depth < 0 || depth > array->depth_used)
    luaL_error(L, "Cannot append to cachearray: has corrupt depth (%d) must be between 0 and cachearray end %d", depth, array->depth_used);
  // Determine depth of cachearray required (depth2)
  int additions = args - 1;
  int depth2 = depth + additions;  // newdepth
  if (depth2 > YDB_MAX_SUBS)
    luaL_error(L, "Cannot append to cachearray: %d would exceed maximum number of subscripts (%d)", depth2, YDB_MAX_SUBS);

  // Append subscripts to array and subsdata_string
  char *subsdata = get_subsdata(array);
  int subslen = get_subslen(array, depth, subsdata);
  for (int arg=2; arg <= args; arg++) {
    size_t len;
    char *string = lua_tolstring(L, arg, &len);
    if (!string)
      luaL_error(L, "Cannot append subscript to cachearray: string/number expected at parameter #%d (got %s)", arg, lua_typename(L, lua_type(L, arg)));
    // if appending will overfill or clobber or an existing array element, allocate a new cachearray
    if ( (array->flags&MUTABLE_BIT) != 0
      || subslen+(int)len > array->subsdata_alloc
      || depth >= array->depth_alloc
      || (array->depth_used > depth  // if array is full, and strings don't already match:
          && (len != array->subs[depth].len_used || memcmp(string, array->subs[depth].buf_addr, len) != 0)) ) {
      // re-allocate userdata now that we know more about actual string lengths required
      int args_left = args-arg;
      array = _cachearray_realloc(L, 1, depth2, subslen+len + args_left*YDB_TYPICAL_SUBLEN, &subsdata);
    }
    // Copy string into subsdata. No need to check max len as we allocated maximum possible
    memcpy(subsdata+subslen, string, len);

    element = &array->subs[depth];
    element->buf_addr = subsdata+subslen;
    element->len_used = element->len_alloc = len;
    subslen += len;
    depth++;
  }
  array->depth_used = depth2;
  // If we're still using the original cachearray, create a new cachearray object that defers to it, except with a different depth
  if (array == original_array && depth2 != original_array->depth)
    array = _cachearray_deferred(L, 1);
  array->depth = depth2;
  // STACK: cachearray[, ...]
  lua_pop(L, additions);
  return 1;
}

/// Make copy of cachearray that is mutable (having changable subscripts) -- intended for iteration.
// Allows `cachearray_subst()` to be used on the cachearray to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// Forces `cachearray_append()` to create child nodes that are copies rather than re-using this cachearray.
// The user can detect whether a node is mutable (could change) using the node's `__mutable()` method.
// @function cachearray_tomutable
// @usage _yottadb.cachearray_tomutable(cachearray)
// @param cachearray userdata created by `cachearray_create()
// @return new cachearray
int cachearray_tomutable(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_subst must be a cachearray userdata");
  int depth = array->depth;
  array = array->dereference;
  // Reallocate array
  char *subsdata = get_subsdata(array);
  int subslen = get_subslen(array, depth, subsdata);
  array = _cachearray_realloc(L, 1, depth, subslen, &subsdata);
  array->flags |= MUTABLE_BIT;
  return 1;
}

/// Return cachearray flags field
// @function cachearray_flags
// @usage _yottadb.cachearray_flags(cachearray)
// @param cachearray userdata
// @return bitfield `flags` (see cachearray.h for bit defines)
int cachearray_flags(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_flags must be a cachearray userdata");
  int flags = array->flags;
  lua_pop(L, 1);
  lua_pushinteger(L, flags);
  return 1;
}

/// Substitute final subscript of given mutable cachearray with `string`.
// The supplied cachearray must be the product of `cachearray_tomutable()`.
// This is used only by node:subscripts() to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// The user can detect whether a node is mutable using the node's `__mutable()` method.
// @function cachearray_subs
// @usage _yottadb.cachearray_subst(cachearray, string)
// @param cachearray
// @param string to store in the topmost array index (at depth)
// @return cachearray (which could be a new mutable one if it could not hold the new subscript size)
int cachearray_subst(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_subst must be a cachearray");
  int depth = array->depth;
  array = array->dereference;
  if ((array->flags&MUTABLE_BIT) == 0 || depth != array->depth_used)  // depth should always = depth_used in a mutable array, but double-check
    luaL_error(L, "Parameter #1 to cachearray_subst must be a *mutable* cachearray");
  char *subsdata = get_subsdata(array);
  int subslen = (&array->varname+depth)->buf_addr - subsdata;
  size_t len;
  char *string = luaL_checklstring(L, 2, &len);
  if (subslen+(int)len > array->subsdata_alloc) {
    array = _cachearray_realloc(L, 1, depth, subslen+len, &subsdata);
    array->flags |= MUTABLE_BIT;
  }
  memcpy((&array->varname+depth)->buf_addr, string, len);
  (&array->varname+depth)->len_used = (&array->varname+depth)->len_alloc = len;
  lua_pop(L, 1);  // pop string
  return 1;
}

/// Return string of cachearray subscripts or empty string if no subscripts.
// Strings are quoted with %q. Numbers are quoted only if they differ from their string representation.
// @function cachearray_tostring
// @usage _yottadb.cachearray_tostring(cachearray[, depth])
// @param cachearray userdata created by _yottadb.cachearray_create()
// @param[opt] depth of subscripts to show (limits cachearray's inherent length)
// @return subscript_list, varname
int cachearray_tostring(lua_State *L) {
  bool isnum;

  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_tostring must be a cachearray userdata (got %s)", lua_typename(L, lua_type(L, 1)));
  int depth = array->depth;
  array = array->dereference;
  int args = lua_gettop(L);
  if (args > 1) depth = luaL_checkinteger(L, 2);
  if (depth < 0 || depth > array->depth_used)
    luaL_error(L, "Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-%d (got %d)", array->depth_used, depth);
  lua_pop(L, args-1); // pop all except cachearray
  // STACK: cachearray
  if (depth == 0) {
    lua_pushstring(L, "");
    goto push_varname;
  }
  ydb_buffer_t *element = &array->subs[0];

  // push string.format
  lua_getglobal(L, "string");
  lua_getfield(L, -1, "format");
  lua_remove(L, -2);  // remove string; leaving string.format()
  // STACK: cachearray, string.format()
  luaL_checkstack(L, depth*2+4, "Lua stack can't grow to fit all cachearray subscript (and separator) strings in cachearray_tostring()");
  for (int len=depth; len--;) {
    lua_pushlstring(L, element->buf_addr, element->len_used);
    lua_pushinteger(L, lua_tointeger(L, -1));
    lua_tostring(L, -1);
    isnum = lua_compare(L, -1, -2, LUA_OPEQ);
    lua_pop(L, 2);  // pop string1, string2
    // invoke: string.format(isnum and "%s" or "%q", <subscript>)
    lua_pushvalue(L, 2);  // push string.format()
    lua_pushstring(L, isnum? "%s": "%q");
    lua_pushlstring(L, element->buf_addr, element->len_used);
    lua_call(L, 2, 1);
    lua_pushstring(L, ",");
    element++;
  }
  lua_pop(L, 1); // remove final comma
  lua_concat(L, depth*2-1);
  // STACK: cachearray, string.format(), retval
  lua_remove(L, -2);
push_varname:
  // STACK: cachearray, retval
  if (array->varname.buf_addr)
    lua_pushlstring(L, array->varname.buf_addr, array->varname.len_used);
  else
    lua_pushnil(L);
  // STACK: cachearray, retval, varname
  lua_remove(L, -3);
  return 2;
}

/// Return the depth of the cachearray.
// @function cachearray_depth
// @usage _yottadb.cachearray_depth(cachearray)
// @param cachearray userdata created by _yottadb.cachearray_create()
// @return depth of cachearray
int cachearray_depth(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_depth() must be a cachearray userdata (got %s)", lua_typename(L, lua_type(L, 1)));
  int depth = array->depth;
  lua_pop(L, 1);  // pop cachearray
  lua_pushinteger(L, depth);
  return 1;
}

/// Return the cachearray subscript at the specified depth.
// @function cachearray_subscript
// @usage _yottadb.cachearray_subscript(cachearray, depth)
// @param depth integer of subscript to return (0 returns the varname; -n counts back from the last subscript)
// @return subscript string
int cachearray_subscript(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_depth() must be a cachearray userdata (got %s)", lua_typename(L, lua_type(L, 1)));
  int inherent_depth = array->depth;
  array = array->dereference;
  int depth = luaL_checkinteger(L, 2);
  if (depth < 0) depth = inherent_depth + 1 + depth;  // -n starts from the last subscript
  if (depth > inherent_depth)
    luaL_error(L, "Parameter #2 to cachearray_depth (%d) must be an integer in range 0 to positive or negative cachearray depth (%d)", depth, inherent_depth);

  ydb_buffer_t *element = &array->varname + depth;
  lua_pushlstring(L, element->buf_addr, element->len_used);
  // No need to clean up stack: Lua does it
  // lua_replace(L, 1); lua_pop(L, 1)
  return 1;
}

/// @section end
