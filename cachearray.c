// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage C-cached subscript arrays for speed

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

// Debug macro to print a field `fieldstr` of the table on top the the lua_State `L`
#define PRINT_INDEX(L, index) \
  printf("stack[%d]=%s(%s)\n", (index), lua_tostring(L, (index)), lua_typename(L, lua_type(L, (index)))); \
  fflush(stdout);

#define PRINT_FIELD(L, index, fieldstr) \
  lua_getfield(L, (index), fieldstr); \
  printf(fieldstr "=%s(%s)\n", lua_tostring(L, -1), lua_typename(L, lua_type(L, -1))); \
  fflush(stdout); \
  lua_pop(L, 1);

// Raw version of lua_getfield() -- almost negligibly slower than lua_getfield() but much faster if field not found
#define lua_rawgetfield(L, index, fieldstr) \
  ( lua_pushstring(L, fieldstr), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )
#define lua_rawgetfieldbyindex(L, index, fieldindex) \
  ( lua_pushvalue(L, (fieldindex)), lua_rawget(L, ((index)<0)? ((index)-1): (index)) )

// Generate a C-style cachearray of subscripts from a tables/tables/list of subscripts
// _yottadb.cachearray_fromtables(varname, t1[, t2|...])
// The resulting full userdata contains a C array which may be passed to raw _yottadb() functions as a subsarray.
// Note: The resulting cachearray links to Lua strings without referencing them, so the caller
// must take care to ensure they are referenced elsewhere (e.g. in a Lua table) to prevent
// garbage-collection. For the same reason, all elements of t1 and t2 MUST be
// strings (not numbers) because any number converted to a string here would not be
// referenced elsewhere.
// @param varname is a string: the M glvn
// @param t1 is a subsarray table
// @param[opt] t2 a second subsarray table to append to the cachearray.
// Any cachearray in t2 will not be ignored
// @param[opt] ... a list of strings (alternative to t2).
// @return cachearray as a full userdata
int cachearray_fromtable(lua_State *L) {
  size_t len, len1, len2=0;
  int args = lua_gettop(L);
  if (lua_type(L, 1) != LUA_TSTRING)
    luaL_error(L, "Parameter #1 to cachearray_fromtable must be a string");
  if (!lua_istable(L, 2))
    luaL_error(L, "Parameter #2 to cachearray_fromtable must be a table");

  // determine depth of array to malloc
  len1 = luaL_len(L, 2);
  int type2 = lua_type(L, 3);
  if (type2 == LUA_TSTRING)
    len2 = args - 2;
  else if (type2 == LUA_TTABLE)
    len2 = luaL_len(L, 3);
  else if (type2 != LUA_TNONE)
    luaL_error(L, "Parameter #3 to cachearray_fromtable, if supplied, must be a table/string_list");

  // Checking the stack lets us push & then pop all subscripts in one function call
  int depth = len1+len2;
  luaL_checkstack(L, depth+1, "Lua stack in cachearray_fromtable() can't grow to fit M subscripts (less than 32)");

  // init array -- leave some room to grow without realloc in case user creates subnodes
  cachearray_t *array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVERALLOC)*sizeof(ydb_buffer_t));
  array->length = depth;
  array->alloc_length = depth+ARRAY_OVERALLOC;
  ydb_buffer_t *element = &array->subs[0];

  // store varname
  array->varname.buf_addr = lua_tolstring(L, 1, &len);
  array->varname.len_used = array->varname.len_alloc = len;

  // Append t1 and, if t2 is a table, also append t2 elements
  for (int arg=2; arg <= 2+(type2==LUA_TTABLE); arg++) {
    for (int i=1; i<=luaL_len(L, arg); i++) {
      lua_geti(L, arg, i); // put subscript onto the stack
      if (lua_type(L, -1) != LUA_TSTRING)  // do not replace with lua_isstring() which also accepts numbers
        luaL_error(L, "Parameter #%d to cachearray_fromtable, table element %d must be a string (got %s)", arg, i, lua_typename(L, lua_type(L, -1)));
      element->buf_addr = lua_tolstring(L, -1, &len);
      element->len_used = element->len_alloc = len;
      element++;
    }
  }

  // If t2 is not a table, append arg list elements
  if (type2 == LUA_TSTRING) {
    element->buf_addr = lua_tolstring(L, 3, &len);
    element->len_used = element->len_alloc = len;
    element++;
    for (int i=4; i<=args; i++) {
      if (lua_type(L, i) != LUA_TSTRING)  // do not replace with lua_isstring() which also accepts numbers
        luaL_error(L, "Parameter #%d to cachearray_fromtable must be a string (got %s)", i, lua_typename(L, lua_type(L, i)));
      element->buf_addr = lua_tolstring(L, i, &len);
      element->len_used = element->len_alloc = len;
      element++;
    }
    lua_pop(L, len1);
  } else
    lua_pop(L, depth);

  // tuck userdata underneath 2 parameters and pop them
  lua_copy(L, -1, 1);
  lua_pop(L, args);
  return 1;
}

// Generate a C-style cachearray of subscripts from a node, its parents, and their names
// _yottadb.cachearray_generate(node[, apply])
// The resulting full userdata contains a C array which may be passed to raw _yottadb() functions as a subsarray.
// Notes:
//
// * The resulting cachearray points to Lua strings without referencing them in Lua, so the
// node must keep a reference to them to prevent garbage-collection.
// For the same reason, all subscripts in the node MUST be strings (not numbers) because
// any number converted to a string here would not be referenced elsewhere.
// * This function is designed to be recursive from C without using lua_call() to reset stack top,
// so it mustn't reference positive-numbered (absolute) stack indices which only refer to the first call's stack.
// @function cachearray
// @param node is a database node object containing the following mandatory attributes:
//
// * `__parent` a reference to the parent node object or a table of subscript strings if has no parent.
// * `__name` of subscript at this node
// * `__depth` of this node (i.e. number of subscripts to arrive at this node)
// @param apply[opt] boolean whether to assign returned new cachearray to node's field __cachearray.
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
      memcpy(&newarray->subs[-1], &array->subs[-1], sizeof(ydb_buffer_t)*(depth));  // copy depth +1(__varname) -1(__name)
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
  lua_remove(L, -2);
  return 1;
}

// Replace existing element `index` of cachearray with `string`.
// _yottadb.cachearray_replace(cachearray, index, string)
// This is used by node:subscripts() to efficiently iterate subscripts
// without creating a new cachearray for every single iteration.
// The __mutable field should be set to true by the iterator on any node 
// that has a cachearray that will be changed after creation.
// @param cachearray userdata
// @param index into array (from 1 to length of array)
// @param string to store in array index
int cachearray_replace(lua_State *L) {
  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_replace must be a cachearray userdata");
  int index = luaL_checkinteger(L, 2) - 1;  // -1 converts Lua index to C index
  if (index < 0 || index >= array->length)
    luaL_error(L, "Parameter #2 to cachearray_replace must be an index into cachearray within the range 1-%d", array->length);
  ydb_buffer_t *element = &array->subs[index];
  int type = lua_type(L, 3);
  if (type != LUA_TSTRING)
    luaL_error(L, "Parameter #3 to cachearray_replace must be a string (got %s)", lua_typename(L, type));

  size_t len;
  element->buf_addr = luaL_checklstring(L, 3, &len);
  element->len_used = element->len_alloc = len;
  return 0;
}

// Return string of cachearray subscripts or empty string if no subscripts.
// Strings are quoted with %q. Numbers are quoted only if it differs from its string representation
// _yottadb.cachedump(cachearray[, depth])
// @param cachearray userdata created by _yottadb.cachearray()
// @param[opt] depth of subscripts to show (limits cachearray's inherent length)
// @return subscript_list, varname
int cachearray_tostring(lua_State *L) {
  bool isnum;

  cachearray_t *array = lua_touserdata(L, 1);
  if (!array)
    luaL_error(L, "Parameter #1 to cachearray_tostring must be a cachearray userdata");
  int depth = array->length;
  int args = lua_gettop(L);
  if (args > 1) depth = luaL_checkinteger(L, 2);
  if (depth < 0 || depth > array->length)
    luaL_error(L, "Parameter #2 to cachearray_tostring is not a valid node depth in the range 0-%d (got %d)", array->length, depth);
  lua_pop(L, args-1); // pop [depth, ...]
  if (depth == 0) {
    lua_pop(L, args);
    lua_pushstring(L, "");
    return 1;
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
  // STACK: cachearray, retval
  if (array->varname.buf_addr)
    lua_pushlstring(L, array->varname.buf_addr, array->varname.len_used);
  else
    lua_pushnil(L);
  // STACK: cachearray, retval, varname
  lua_remove(L, -3);
  return 2;
}
