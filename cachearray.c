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
#define ARRAY_OVER_ALLOC 5

typedef struct cachearray_t {
  int length; // number of items in array
  int alloc_length; // number of items space was allocated for
  ydb_buffer_t subs[];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t;

// Generate a C-style cachearray of subscripts from a tables/tables/list of subscripts
// _yottadb.cachearray_fromtables(t1[, t2|...])
// The resulting full userdata contains a C array which may be passed to raw _yottadb() functions as a subsarray.
// Note: The resulting cachearray links to Lua strings without referencing them, so the caller
// must take care to ensure they are referenced elsewhere (e.g. in a Lua table) to prevent
// garbage-collection. For the same reason, all elements of t1 and t2 MUST be
// strings (not numbers) because any number converted to a string here would not be
// referenced elsewhere.
// @param t1 is a subsarray table
// @param[opt] t2 a second subsarray table to append to the cachearray.
// Any cachearray in t2 will not be ignored
// @param[opt] ... a list of strings (alternative to t2).
// @return cachearray as a full userdata
int cachearray_fromtable(lua_State *L) {
  size_t len, len1, len2=0;
  int args = lua_gettop(L);
  if (!lua_istable(L, 1))
    luaL_error(L, "Parameter #1 to cachearray_fromtable must be a table");

  // determine depth of array to malloc
  len1 = luaL_len(L, 1);
  int type2 = lua_type(L, 2);
  if (type2 == LUA_TSTRING)
    len2 = args - 1;
  else if (type2 == LUA_TTABLE)
    len2 = luaL_len(L, 2);
  else if (type2 != LUA_TNONE)
    luaL_error(L, "Parameter #2 to cachearray_fromtable, if supplied, must be a table/string_list");

  // Checking the stack lets us push & then pop all subscripts in one function call
  // Must do this check before malloc
  int depth = len1+len2;
  luaL_checkstack(L, depth+1, "Lua stack in cachearray_fromtable() can't grow to fit M subscripts (less than 32)");

  // init array -- leave some room to grow without realloc in case user creates subnodes
  cachearray_t *array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVER_ALLOC)*sizeof(ydb_buffer_t *));
  array->length = depth;
  array->alloc_length = depth+ARRAY_OVER_ALLOC;
  ydb_buffer_t *element = &array->subs[0];

  // Append t1 and, if t2 is a table, also append t2 elements
  for (int arg=1; arg <= 1+(type2==LUA_TTABLE); arg++) {
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
    element->buf_addr = lua_tolstring(L, 2, &len);
    element->len_used = element->len_alloc = len;
    element++;
    for (int i=3; i<=args; i++) {
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
  lua_replace(L, 1);
  lua_pop(L, args-1);
  return 1;
}

// Generate a C-style cachearray of subscripts from a node, its parents, and their names
// _yottadb.cachearray_generate(node)
// The resulting full userdata contains a C array which may be passed to raw _yottadb() functions as a subsarray.
// Note: The resulting cachearray points to Lua strings without referencing them in Lua, so the
// node must keep a reference to them to prevent garbage-collection.
// For the same reason, all subscripts in the node MUST be strings (not numbers) because
// any number converted to a string here would not be referenced elsewhere.
// @param node is a database node object containing the following mandatory attributes:
//
// * `__parent` a reference to the parent node object or a table of subscript strings if has no parent.
// * `__name` of subscript at this node
// * `__depth` of this node (i.e. number of subscripts to arrive at this node)
// @return cachearray as a full userdata object
int cachearray_generate(lua_State *L) {
  cachearray_t *array;
  ydb_buffer_t *element;
  size_t len;
// TODO: change to use a '__parent' Lua string constant for speed
  if (!lua_istable(L, 1) || lua_getfield(L, 1, "__depth") != LUA_TNUMBER)
    luaL_error(L, "Parameter #1 to cachearray_generate must be a node object");
  int depth = lua_tointeger(L, -1);
  if (depth <= 0) {
    lua_pop(L, 2);  // drop node, __depth
    cachearray_t *newarray = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVER_ALLOC)*sizeof(ydb_buffer_t *));
    newarray->alloc_length = depth+ARRAY_OVER_ALLOC;
    newarray->length = 0;
    return 1;
  }
  lua_pop(L, 1); // __depth
  // Does parent have __cachearray or is it the root node?
// TODO: change to use a '__parent' Lua string constant for speed
  if (lua_getfield(L, 1, "__parent") != LUA_TTABLE)
    luaL_error(L, "Node passed to cachearray_generate() has invalid `__parent` field at depth %d", depth);
  // STACK: node, __parent
// TODO: change this to a raw lookup for speed, and use a '__cachearray' Lua string constant
  if (lua_getfield(L, -1, "__cachearray") == LUA_TUSERDATA) {
    // Does parent's cachearray have spare room?
    array = lua_touserdata(L, -1);
    // If no room, then copy __cachearray, but with more space
    if (array->length >= depth || depth >= array->alloc_length) {
      cachearray_t *newarray = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVER_ALLOC)*sizeof(ydb_buffer_t *));
      newarray->alloc_length = depth+ARRAY_OVER_ALLOC;
      memcpy(&newarray->subs[0], &array->subs[0], sizeof(ydb_buffer_t)*(depth-1));
      array = newarray;
      // STACK: node, __parent, parent_cachearray, newarray
      lua_remove(L, -2);  // drop parent's __cachearray and replace it with array
      // STACK: node, __parent, newarray
    }
    goto append_name;

  } else { // no __cachearray
    lua_pop(L, 1); // pop __cachearray (=nil)
    // STACK: node, __parentlist
    // Create array from list of strings in table at __parent (since there is no parent node)
    array = lua_newuserdata(L, sizeof(cachearray_t) + (depth+ARRAY_OVER_ALLOC)*sizeof(ydb_buffer_t *));
    array->length = depth;
    array->alloc_length = depth+ARRAY_OVER_ALLOC;
    // STACK: node, __parentlist, newarray
    element = &array->subs[0];
    for (int i=1; i<depth; i++) {
      lua_geti(L, -2, i); // put subscript onto the stack
      if (lua_type(L, -1) != LUA_TSTRING)  // do not replace with lua_isstring() because it also accepts numbers
        luaL_error(L, "In cachearray_generate(), list of subscripts %d at node.__parent must be a string (got %s)", i, lua_typename(L, lua_type(L, -1)));
      element->buf_addr = lua_tolstring(L, -1, &len);
      element->len_used = element->len_alloc = len;
      element++;
      lua_pop(L, 1); // pop subscript
    }
  }
append_name:  // STACK: node, __parent, newarray
  // Append __name to cachearray
  array->length = depth;
  element = &array->subs[depth-1];  // -1 converts from Lua index to C index
// TODO: change this to a raw lookup for speed, and use a '__name' Lua string constant
  if (lua_getfield(L, 1, "__name") != LUA_TSTRING)
    luaL_error(L, "Node passed to cachearray_generate() has invalid subscript `__name` field at depth %d", depth);
  element->buf_addr = lua_tolstring(L, -1, &len);
  element->len_used = element->len_alloc = len;
  element--;
  // STACK: node, __parent, array, __name
  lua_copy(L, -2, 1);  // replace node with array
  lua_pop(L, 3); // drop __parent, array, __name
  return 1;
}

// Return node.__cachearray, generating it first if necessary using cachearray_generate()
// _yottadb.cachearray(node)
// @return cachearray
// @see cachearray_generate
int cachearray(lua_State *L) {
// TODO: change to use a '__cachearray' Lua string constant for speed
  if (lua_getfield(L, -1, "__cachearray") != LUA_TUSERDATA) {
    lua_pop(L, 1); // pop __cachearray (nil)
    lua_copy(L, 1, lua_upvalueindex(UPVALUE_NODE));  // save tos (node) in upvalue
    cachearray_generate(L);
    // STACK: newarray
    // set: node.__cachearray=newarray
// TODO: change to use a '__cachearray' Lua string constant for speed
    lua_pushstring(L, "__cachearray");
    lua_pushvalue(L, -2);  // duplicate newarray
    // STACK: newarray, "__cachearray", newarray
    lua_rawset(L, lua_upvalueindex(UPVALUE_NODE));
    // STACK: newarray
    lua_pushvalue(L, -1);  // duplicate newarray
  }
  lua_remove(L, -2);
  return 1;
}

// Replace existing element `index` of cachearray with `string`
// _yottadb.cachearray_set(cachearray, index, string)
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
    luaL_error(L, "Parameter #3 to cachearray_replace must be a string");

  size_t len;
  element->buf_addr = luaL_checklstring(L, 3, &len);
  element->len_used = element->len_alloc = len;
  return 0;
}

// Return string of cachearray subscripts or empty string if no subscripts.
// Strings are quoted with %q. Numbers are quoted only if it differs from its string representation
// _yottadb.cachedump(cachearray[, depth])
// @param cachearray userdata
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
  lua_pop(L, args-1); // drop [depth, ...]
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
  lua_replace(L, 1);  // replace cachearray with retval & drop top
  lua_pop(L, 1); // drop string.format()
  return 1;
}
