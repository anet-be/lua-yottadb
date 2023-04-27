// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage C-cached subscript arrays for speed

#ifndef CACHEARRAY_H
#define CACHEARRAY_H

#include <libyottadb.h>

// Maximum number of characters we allow in a ^varname+subscripts string
// 1+ for '^' global var character 
#define YDB_TYPICAL_SUBLEN 10 /* initial guess of string length to allocate for each subscript */
#define YDB_LARGE_SUBSLEN (YDB_TYPICAL_SUBLEN*YDB_MAX_SUBS)

#define get_subsdata(array) (char *)&(array)->subs[(array)->depth_alloc];
#define member_size(type, member) sizeof( ((type *)0)->member )
#define member_len(type, member) ( member_size(type, member) / sizeof(((type *)0)->member[0]) )

typedef struct cachearray_t {
  // Note: the first 2 must be filled in by the allocator code so that subsequent code knows how big it is
  int subsdata_alloc;  // length of subsdata
  int depth_alloc; // number of items space was allocated for

  int depth; // number of items in array
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t;

// cachearray_t but with max subscripts and fairly large subsdata_string preallocated
// intended for speedy stack pre-allocation of working cachearray
typedef struct cachearray_t_maxsize {
  int subsdata_alloc;  // length of subsdata
  int depth_alloc; // number of items space was allocated for

  int depth; // number of items in array
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[YDB_MAX_SUBS];
  char _subsdata[YDB_LARGE_SUBSLEN];
} cachearray_t_maxsize;

int _cachearray_create(lua_State *L, cachearray_t_maxsize *array_prealloc);
int cachearray_create(lua_State *L);
int cachearray_createmutable(lua_State *L);
int cachearray_subst(lua_State *L);
int cachearray_append(lua_State *L);
int cachearray_tostring(lua_State *L);

#endif // CACHEARRAY_H
