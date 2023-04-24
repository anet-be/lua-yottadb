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
// Assumes most uses will only dive into subscripts this deep below their starting point node (however deep that is)
// If users do go deeper, it all still works; it just creates an additional cachearray object for deeper nodes
#define ARRAY_OVERALLOC 5

// Raw version of lua_getfield() -- almost negligibly slower than lua_getfield(), but much faster if field not found
#define lua_rawgetfield(L, index, fieldstr) \
  ( lua_pushstring(L, fieldstr), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )
#define lua_rawgetfieldbyindex(L, index, fieldindex) \
  ( lua_pushvalue(L, (fieldindex)), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )

/// Generate a C-style cachearray of subscripts from a tables+list of subscripts.
// The resulting full userdata contains a C array which may be passed to raw `_yottadb()` functions as a subsarray. <br>
// Notes:
//
// * The resulting cachearray links to Lua strings without referencing them, so the caller MUST
// take care to ensure they are referenced elsewhere (e.g. in a Lua table) to prevent garbage-collection
// * For the same reason, numeric elements in the input are converted to strings to store in the cachearray
// and then also returned so that the caller can be sure to keep a table of them.
// * This function may be called by C -- the stack is correct at the end (doesn't depend on Lua's stack fixups)
// @function cachearray_fromtable
// @usage _yottadb.cachearray_fromtables(varname[, t1][, ...])
// @param varname is a string: the M glvn
// @param[opt] t1 is a subsarray table
// @param[opt] ... a list of strings (additional to optional t2).
// @return cachearray as a full userdata, followed by a list of strings of any numbers passed in -- see note 2 above.
int cachearray_fromtable(lua_State *L) {
  size_t len, depth=0;
  int args = lua_gettop(L);
  if (lua_type(L, 1) != LUA_TSTRING)
    luaL_error(L, "Cannot generate cachearray: string expected at parameter #1 (varname) (got %s)", lua_typename(L, lua_type(L, 1)));

  // determine depth of array to malloc
  int type_t1 = lua_type(L, 2);
  depth = args - 1;
  if (type_t1 == LUA_TTABLE)
    depth = luaL_len(L, 2) + args - 2;

  // init array -- leave some room to grow without realloc in case user creates subnodes
  cachearray_t *array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
  array->length = depth;
  array->alloc_length = depth+ARRAY_OVERALLOC;
  ydb_buffer_t *element = &array->subs[0];

  // store varname
  array->varname.buf_addr = lua_tolstring(L, 1, &len);
  array->varname.len_used = array->varname.len_alloc = len;

  // Append t1 if it is a table
  if (type_t1==LUA_TTABLE) {
    for (int i=1; i<=luaL_len(L, 2); i++) {
      lua_geti(L, 2, i); // put subscript onto the stack
      int type = lua_type(L, -1);
      char *buf = lua_tolstring(L, -1, &len);
      if (!buf)
        luaL_error(L, "Cannot generate cachearray: number/string expected at table element %d (got %s)", i, lua_typename(L, type));
      element->buf_addr = buf;
      element->len_used = element->len_alloc = len;
      element++;
      if (type == LUA_TSTRING)
        lua_pop(L, 1);  // leave string on stack to return only if it was converted from a number (see note in docs above)
    }
  }

  // Append `...` list of strings
  for (int i=2+(type_t1==LUA_TTABLE); i<=args; i++) {
    int type = lua_type(L, i);
    char *buf = lua_tolstring(L, i, &len);
    if (!buf)
      luaL_error(L, "Cannot generate cachearray: number/string expected in parameter #%d (got %s)", i, lua_typename(L, type));
    element->buf_addr = lua_tolstring(L, i, &len);
    element->len_used = element->len_alloc = len;
    element++;
    if (type == LUA_TNUMBER)
      lua_pushvalue(L, i);  // if it was converted from a number, duplicate it an leave it on the stack to return (see note in docs above)
  }
  // STACK: varname[, t1][, ...], cachearray, [list of numbers_to_strings...]
  lua_rotate(L, 1, -args);  // delete original args
  lua_pop(L, args);
  return lua_gettop(L);
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
int cachearray(lua_State *L) {
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
    array->alloc_length = depth+ARRAY_OVERALLOC;
    array->length = 0;
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
      cachearray(L);
      has_cachearray = true;
      // STACK: node, __parent, parent.__cachearray
    }
  }

  if (has_cachearray) {
    // Does parent's cachearray have spare room?
    // STACK: node, __parent, parent.__cachearray
    array = lua_touserdata(L, -1);
    // If no room, or next slot already used, then copy parent.__cachearray, but with more space
    if (depth >= array->alloc_length || array->length >= depth) {
      cachearray_t *newarray = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
      newarray->alloc_length = depth+ARRAY_OVERALLOC;
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
    array->length = depth;
    array->alloc_length = depth+ARRAY_OVERALLOC;
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
  array->length = depth;
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

// Replace existing element `index` of cachearray with `string`.
// This is used by node:subscripts() to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// The __mutable field should be set to true by the iterator on any node 
// that has a cachearray that will be changed after creation.
// @usage _yottadb.cachearray_replace(cachearray, index, string)
// @param cachearray userdata
// @param index into array (from 1 to length of array)
// @param string to store in array index
int cachearray_replace(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_replace must be a cachearray userdata");
  int index = luaL_checkinteger(L, 2) - 1;  // -1 converts Lua index to C index
  if (index < 0 || index >= array->length) {
    if (!array->length)
      luaL_error(L, "Parameter #1 to cachearray_replace must be a cachearray with at least one subscript");
    luaL_error(L, "Parameter #2 to cachearray_replace is %d but should be an index into cachearray between 1 and %d", index+1, array->length);
  }
  ydb_buffer_t *element = &array->subs[index];
  int type = lua_type(L, 3);
  if (type != LUA_TSTRING)
    luaL_error(L, "Parameter #3 to cachearray_replace must be a string (got %s)", lua_typename(L, type));

  size_t len;
  element->buf_addr = luaL_checklstring(L, 3, &len);
  element->len_used = element->len_alloc = len;
  return 0;
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
  int depth = array->length;
  int args = lua_gettop(L);
  if (args > 1) depth = luaL_checkinteger(L, 2);
  if (depth < 0 || depth > array->length)
    luaL_error(L, "Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-%d (got %d)", array->length, depth);
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
