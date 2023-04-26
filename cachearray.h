// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage C-cached subscript arrays for speed

#ifndef CACHEARRAY_H
#define CACHEARRAY_H

typedef struct cachearray_t {
  int length; // number of items in array
  int alloc_length; // number of items space was allocated for
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t;

typedef struct cachearray_t_maxsize {
  int length; // number of items in array
  int alloc_length; // number of items space was allocated for
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[YDB_MAX_IDENT];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t_maxsize;

int cachearray_create(lua_State *L);
int cachearray_tostring(lua_State *L);
int cachearray_subst(lua_State *L);
int cachearray_append(lua_State *L);

#endif // CACHEARRAY_H
