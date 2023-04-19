// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage C-cached subscript arrays for speed

#ifndef CACHEARRAY_H
#define CACHEARRAY_H

typedef struct cachearray_t {
  int length; // number of items in array
  int alloc_length; // number of items space was allocated for
  ydb_buffer_t subs[];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t;

enum upvalues {
  UPVALUE_NODE=1, __DEPTH, __PARENT, __CACHEARRAY, __NAME,
};

int cachearray(lua_State *L);
int cachearray_generate(lua_State *L);
int cachearray_fromtable(lua_State *L);
int cachearray_tostring(lua_State *L);
int cachearray_replace(lua_State *L);

#endif // CACHEARRAY_H
