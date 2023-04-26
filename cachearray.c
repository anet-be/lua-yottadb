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

// Raw version of lua_getfield() -- almost negligibly slower than lua_getfield(), but much faster if field not found
#define lua_rawgetfield(L, index, fieldstr) \
  ( lua_pushstring(L, fieldstr), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )
#define lua_rawgetfieldbyindex(L, index, fieldindex) \
  ( lua_pushvalue(L, (fieldindex)), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )

// Update cachearray subscript pointers to match subsdata_string at addr
void _cachearray_updateaddr(cachearray_t *array, char *addr) {
  ydb_buffer_t *element = &array->varname;  // assumes array->subs[] come straight after array->varname
  int depth = array->depth;
  for (int i=0; i <= depth; i++) {
    element->buf_addr = addr;
    addr += element->len_used;
    element++;
  }
}

/// Underlying core of `cachearray_create()`, designed to call from C.
// For the sake of speed, this can be called from a C function that has pre-allocated cachearray_t.
// For example, pre-allocating it on the C stack is 20% (400ns) faster than `lua_newuserdata()`
// @param cachearray pointer to allocated memory to fit a maximum sized cachearray.
// If it is NULL, the function will allocate cachearray using lua_newuserdata()
// @return cachearray, subsdata_string -- see notes above -- cachearray returns lightuserdata if array is supplied on entry.
int _cachearray_create(lua_State *L, cachearray_t *array_maxsize) {
  int args = lua_gettop(L);
  if (lua_type(L, 1) != LUA_TSTRING)
    luaL_error(L, "Cannot generate cachearray: string expected at parameter #1 (varname) (got %s)", lua_typename(L, lua_type(L, 1)));

  // determine depth of cachearray to malloc
  int type_t1 = lua_type(L, 2);
  int depth = args - 1;
  int tlen = 0;
  if (type_t1 == LUA_TTABLE) {
    tlen = luaL_len(L, 2);
    depth = tlen + args - 2;
  }

  // init array -- leave some room to grow without realloc in case user creates subnodes
  cachearray_t *array = (cachearray_t *)array_maxsize;
  if (array)
    lua_pushlightuserdata(L, array);
  else
    array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
  array->depth = depth;
  array->alloc_size = depth+ARRAY_OVERALLOC;
  ydb_buffer_t *element = &array->varname;  // assumes array->subs[] come straight after array->varname

  luaL_Buffer b;
  luaL_buffinit(L, &b);
  int start = 0;  // starting length of buffer

  // Append varname
  lua_pushvalue(L, 1);
  luaL_addvalue(&b);
  // store length of subscript in cachearray
  int end = luaL_bufflen(&b);
  element->len_used = element->len_alloc = end-start;
  start = end;
  element++;

  // Append t1 if it is a table
  for (int i=1; i <= tlen; i++) {
    lua_geti(L, 2, i);
    if (luai_unlikely(!lua_isstring(L, -1)))
      luaL_error(L, "Cannot generate cachearray: string/number expected in parameter #2 table index %d (got %s)", i, lua_typename(L, lua_type(L, -1)));
    luaL_addvalue(&b);
    // store length of subscript in cachearray
    int end = luaL_bufflen(&b);
    element->len_used = element->len_alloc = end-start;
    start = end;
    element++;
  }

  // Append `...` list of strings
  for (int arg=2+(type_t1==LUA_TTABLE); arg<=args; arg++) {
    if (luai_unlikely(!lua_isstring(L, arg)))
      luaL_error(L, "Cannot generate cachearray: string/number expected at parameter #%d (got %s)", arg, lua_typename(L, lua_type(L, arg)));
    lua_pushvalue(L, arg);
    luaL_addvalue(&b);
    // store length of subscript in cachearray
    int end = luaL_bufflen(&b);
    element->len_used = element->len_alloc = end-start;
    start = end;
    element++;
  }
  luaL_pushresult(&b);

  // Update cachearray with final address of string
  char *addr = lua_tostring(L, -1);
  _cachearray_updateaddr(array, addr);

  // STACK: varname[, t1], ...], cachearray, cachestring
  lua_rotate(L, 1, 2);
  lua_pop(L, args);
  return 2;
}

/// Generate and return a C-style array of subscripts as a userdata.
// The resulting full userdata contains a C array which may be passed to raw `_yottadb()` functions as a subsarray. 
// Also return a string of concatenated subscripts which Lua must keep a reference to as it contains the text data
// that the cachearray points to.
// This function may be called by C -- the stack is correct at the end (doesn't depend on Lua's stack fixups)
// @function cachearray
// @usage _yottadb.cachearray(varname[, t1][, ...])
// @param varname is a string: the M glvn. (Note: If t1 is a cachearray, varname is ignored in favour of the one contained in t1)
// @param[opt] t1 is a subsarray table or cachearray to be copied
// @param[opt] ... a list of strings to be appended after t2.
// @return cachearray, subsdata_string -- see notes above
int cachearray_create(lua_State *L) {
  return _cachearray_create(L, NULL);
}

/// Generate a C-style cachearray of subscripts from a node, its parents, and their names.
// The resulting full userdata contains a C array which may be passed to raw `_yottadb()` functions as a subsarray. <br>
// Notes:
//
// * The resulting cachearray points to Lua strings without referencing them in Lua, so the
// node must keep a reference to them to prevent garbage-collection.
// These strings are kept in the node's `__name` field and the root node's `__parent` field (list of strings).
// For the same reason, the root node's `__parent` table must be a copy rather than a reference to
// a user-supplied table, and any number elements in it must be converted to strings when creating root node.
// * This function is designed to be recursive from C without using `lua_call()` to reset stack top,
// so it mustn't reference positive-numbered (absolute) stack indices which only refer to the first call's stack.
// @function cachearray
// @usage _yottadb.cachearray_generate(node[, apply])
// @param node is a database node object containing the following mandatory attributes:
//
// * `__parent` a reference to the parent node object or a table of subscript strings if has no parent.
// * `__name` of subscript at this node
// * `__depth` of this node (i.e. number of subscripts to arrive at this node)
// @param apply[opt] boolean whether to assign returned new cachearray to node's field `__cachearray`.
// This is a recursive field passed on to generation of parent nodes' cachearrays.
// It is an optional parameter only when called from Lua; not when recursed in C.
// @return cachearray as a full userdata object
int _cachearray(lua_State *L) {
  cachearray_t *array;
  ydb_buffer_t *element;
  size_t len;
  int depth;

  // Make sure there is an 'apply' parameter or stack references below don't work
  if (lua_gettop(L) < 2)
    lua_pushnil(L);

  // Return immediately if node has __cachearray. Must do this first to be fast: it is used often
  // STACK: node, apply
  if (lua_rawgetfield(L, -2, "__cachearray") == LUA_TUSERDATA) {
    // STACK: node, apply, __cachearray
    lua_copy(L, -1, -3);  // replace node with __cachearray
    lua_pop(L, 2); // pop apply, __cachearray
    return 1;
  }

  // Fetch parameter `apply`
  // STACK: node, apply, __cachearray(nil)
  bool apply = lua_toboolean(L, -2);
  lua_pop(L, 2);  // pop apply, __cachearray(nil)

  // Check __depth
  // STACK: node
  int depth_type = lua_rawgetfield(L, -1, "__depth");
  if (depth_type != LUA_TNUMBER || !lua_isinteger(L, -1))
    luaL_error(L, "Cannot generate cachearray: node object does not have an integer '__depth' field (got %s)", lua_typename(L, lua_type(L, -1)));
  depth = lua_tointeger(L, -1);
  lua_pop(L, 1); // pop __depth

  // Handle zero-depth nodes
  // STACK: node
  if (depth <= 0) {
    cachearray_t *array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
    array->alloc_size = depth+ARRAY_OVERALLOC;
    array->depth = 0;
    // Store varname in cachearray
    // STACK: node, cachearray
    if (lua_getfield(L, -2, "__varname") != LUA_TSTRING)
      luaL_error(L, "Cannot generate cachearray: node has invalid __varname (got %s expected string) at depth %d", lua_typename(L, lua_type(L, -1)), depth);
    array->varname.buf_addr = lua_tolstring(L, -1, &len);
    array->varname.len_used = array->varname.len_alloc = len;
    lua_pop(L, 1);  // pop varname
    // STACK: node, cachearray
    goto apply_cachearray;
  }
  // Does parent have __cachearray or is it the root node?
  // STACK: node
  if (lua_getfield(L, -1, "__parent") != LUA_TTABLE)
    luaL_error(L, "Cannot generate cachearray: node object does not have a table in field '__parent' at depth %d", depth);
  bool has_cachearray = lua_rawgetfield(L, -1, "__cachearray") == LUA_TUSERDATA;
  // STACK: node, __parent, parent.__cachearray
  if (!has_cachearray) {
    // Since __parent has no __cachearray, see if it is a node (i.e. has __depth)
    bool isnode = lua_getfield(L, -2, "__depth") == LUA_TNUMBER;
    lua_pop(L, 1); // pop __depth
    // STACK: node, __parent, parent.__cachearray
    if (isnode) {
      // Recurse() -- which returns parent_cachearray on stack
      lua_pop(L, 1); // old_cachearray(nil)
      // STACK: node, __parent
      lua_pushvalue(L, -1);
      lua_pushboolean(L, apply);
      // STACK: node, __parent, __parent, apply
      luaL_checkstack(L, LUA_MINSTACK, "Cannot generate cachearray: stack can't grow to recurse all parent subscripts");
      cachearray_create(L);
      has_cachearray = true;
      // STACK: node, __parent, parent.__cachearray
    }
  }

  if (has_cachearray) {
    // Does parent's cachearray have spare room?
    // STACK: node, __parent, parent.__cachearray
    array = lua_touserdata(L, -1);
    // If no room, or next slot already used, then copy parent.__cachearray, but with more space
    if (depth >= array->alloc_size || array->depth >= depth) {
      cachearray_t *newarray = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
      newarray->alloc_size = depth+ARRAY_OVERALLOC;
      // copy varname and subs from parent
      // STACK: node, __parent, parent.__cachearray, new_cachearray
      memcpy(&newarray->varname, &array->varname, sizeof(ydb_buffer_t)*(depth+1-1));  // copy depth +1(__varname) -1(__name)
      array = newarray;
      // STACK: node, __parent, parent.__cachearray, newarray
      lua_copy(L, -1, -3);
      lua_pop(L, 2);
      // STACK: node, newarray
    } else
      lua_remove(L, -2);
    // STACK: node, newarray

  } else { // no __cachearray, so __parent = {list_of_strings}
    // STACK: node, __parentlist, parent_cachearray
    lua_pop(L, 1);
    // Create array from list of strings in table at __parent (since there is no parent node)
    // STACK: node, __parentlist
    array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
    array->depth = depth;
    array->alloc_size = depth+ARRAY_OVERALLOC;
    // STACK: node, __parentlist, newarray
    element = &array->subs[0];
    for (int i=1; i<depth; i++) {
      lua_geti(L, -2, i); // put subscript onto the stack
      int type = lua_type(L, -1);
      if (type != LUA_TSTRING)  // do not replace with lua_isstring() because it also accepts numbers
        lua_getfield(L, -3, "__name"),
          luaL_error(L, "Node '%s' has malformed __parent: should be a node reference or a list of subscript strings (got %s at __parent[%d])",
            lua_tostring(L, -1), lua_typename(L, type), i);
      element->buf_addr = lua_tolstring(L, -1, &len);
      element->len_used = element->len_alloc = len;
      element++;
      lua_pop(L, 1); // pop subscript
    }
    // Apply __varname to new array
    lua_remove(L, -2);  // pop __parentlist
    // STACK: node, newarray
    if (lua_getfield(L, -2, "__varname") != LUA_TSTRING)
      luaL_error(L, "Cannot generate cachearray: node has invalid __varname (got %s expected string) at depth %d", lua_typename(L, lua_type(L, -1)), depth);
    array->varname.buf_addr = lua_tolstring(L, -1, &len);
    array->varname.len_used = array->varname.len_alloc = len;
    lua_pop(L, 1);  // pop __varname
    // STACK: node, newarray
  }

  // Append __name to cachearray
  // STACK: node, newarray
  array->depth = depth;
  element = &array->subs[depth-1];  // -1 converts from Lua index to C index
  if (lua_getfield(L, -2, "__name") != LUA_TSTRING)
    luaL_error(L, "Cannot generate cachearray: node has invalid __name (got %s expected string)", lua_typename(L, lua_type(L, -1)));
  element->buf_addr = lua_tolstring(L, -1, &len);
  element->len_used = element->len_alloc = len;
  // STACK: node, array, __name
  lua_pop(L, 1);

apply_cachearray:  // STACK: node, cachearray
  if (apply) {
    lua_pushstring(L, "__cachearray");
    lua_pushvalue(L, -2);
    // STACK: node, cachearray, "__cachearray", cachearray
    lua_rawset(L, -4);
  }
  // Must clean up the stack since this function is recursive in C
  lua_remove(L, -2);
  return 1;
}

// Create a mutable cachearray with changable subscripts -- intended for iteration.
// The only difference from a standard subscript is that free subscript space
// (per ARRAY_OVERALLOC) is not allocated in the cachearray.
// This forces child nodes to create new, immutable cachearrays.
// This is intended only for use by `cachearray_subst()` to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// The __mutable field should be set to true by the iterator as a warning to the user
// on any node that has a mutable cachearray.
// @usage _yottadb.cachearray_createmutable(...)
// @param ... parameters are passed directly into `cachearray_create()`
int cachearray_createmutable(lua_State *L) {
  // determine number of subscripts supplied
  int args = lua_gettop(L);
  int depth = args - 1;
  if (lua_type(L, 2) == LUA_TTABLE)
    depth = luaL_len(L, 2) + args - 2;

  cachearray_t *array = lua_newuserdata(L, sizeof(cachearray_t) + depth*sizeof(ydb_buffer_t));
  // pop cachearray so we can call _cachearray_create() with the stack it expects of cachearray_create()
  int ref = luaL_ref(L, LUA_REGISTRYINDEX);
  _cachearray_create(L, array);
  // STACK: cachearray(light_userdata), subsdata_string
  lua_rawgeti(L, LUA_REGISTRYINDEX, ref);  // restore full_userdata back onto stack
  lua_replace(L, -3);  // replace light_userdata with full_userdata
  luaL_unref(L, LUA_REGISTRYINDEX, ref);
  return 2;
}

// Substitute final subscript of cachearray with `string`.
// This is used only by node:subscripts() to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// The __mutable field should be set to true by the iterator as a warning to the user
// on any node that has a mutable cachearray.
// @usage _yottadb.cachearray_subst(cachearray, string)
// @param cachearray userdata
// @param string to store in array index
// @return new subsdata_string
int cachearray_subst(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_subst must be a cachearray userdata");
  int depth = array->depth;
  if (!depth)
    luaL_error(L, "Parameter #1 to cachearray_subst must be a cachearray with at least one subscript");
  int s1_len = array->subs[depth-1].buf_addr - array->varname.buf_addr;
  size_t s2_len;
  char * s2 = luaL_checklstring(L, 2, &s2_len);

  luaL_Buffer b;
  luaL_buffinit(L, &b);
  luaL_addlstring(&b, array->varname.buf_addr, s1_len);
  luaL_addlstring(&b, s2, s2_len);
  luaL_pushresult(&b);

  // Update cachearray with final address of string
  // STACK: cachearray, subscript_string, subsdata_string
  char *addr = lua_tostring(L, -1);
  array->subs[depth-1].len_used = array->subs[depth-1].len_alloc = s2_len;
  _cachearray_updateaddr(array, addr);
  // No need to tidy up stack as Lua does it
  //lua_replace(L, 1);
  //lua_pop(L, 1);
  return 1;
}

/// Return string of cachearray subscripts or empty string if no subscripts.
// Strings are quoted with %q. Numbers are quoted only if they differ from their string representation.
// @function cachearray_tostring
// @usage _yottadb.cachedump(cachearray[, depth])
// @param cachearray userdata created by _yottadb.cachearray()
// @param[opt] depth of subscripts to show (limits cachearray's inherent length)
// @return subscript_list, varname
int cachearray_tostring(lua_State *L) {
  bool isnum;

  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_tostring must be a cachearray userdata (got %s)", lua_typename(L, lua_type(L, 1)));
  int depth = array->depth;
  int args = lua_gettop(L);
  if (args > 1) depth = luaL_checkinteger(L, 2);
  if (depth < 0 || depth > array->depth)
    luaL_error(L, "Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-%d (got %d)", array->depth, depth);
  lua_pop(L, args-1); // pop [depth, ...]
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

/// @section end
