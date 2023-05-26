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
#define get_subslen(array, depth, subsdata) (&(array)->varname+(depth))->buf_addr + (&(array)->varname+(depth))->len_used - (subsdata);

#define member_size(type, member) sizeof( ((type *)0)->member )
#define member_len(type, member) ( member_size(type, member) / sizeof(((type *)0)->member[0]) )

#define MUTABLE_BIT 1

typedef struct cachearray_t {
  struct cachearray_t *dereference; // allow creation of a cachearray that is nothing more than a pointer to a different one of the same
  short depth; // first depth of this object (could be less than depth_used if subscripts are appended later)
  short flags;
  // Note: the next 2 MUST be filled in by the inital allocator code so that subsequent code knows where & how big it is
  int subsdata_alloc;  // length of subsdata
  short depth_alloc; // number of items space was allocated for

  short depth_used; // number of used items in array
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[];  // first lot of subs stored here, then moved to another malloc if it grows too much
} cachearray_t;

typedef struct cachearray_dereferenced {
  struct cachearray_t *dereferenced; // merely points to a cachearray
  short depth; // number of items in array
  short flags;
} cachearray_dereferenced;

// cachearray_t but with max subscripts and fairly large subsdata_string preallocated
// intended for speedy stack pre-allocation of working cachearray
typedef struct cachearray_t_maxsize {
  struct cachearray_t *dereference; // allow creation of a cachearray that is nothing more than a pointer to a different one of the same
  short depth; // number of items in array
  short flags;
  int subsdata_alloc;  // length of subsdata
  short depth_alloc; // number of items space was allocated for

  short depth_used; // number of used items in array
  ydb_buffer_t varname;  // must precede subs so we can copy them all in one chunk
  ydb_buffer_t subs[YDB_MAX_SUBS];
  char _subsdata[YDB_LARGE_SUBSLEN];
} cachearray_t_maxsize;

cachearray_t *_cachearray_create(lua_State *L, cachearray_t_maxsize *array_prealloc);
int cachearray_create(lua_State *L);
int cachearray_setmetatable(lua_State *L);
int cachearray_tomutable(lua_State *L);
int cachearray_subst(lua_State *L);
int cachearray_flags(lua_State *L);
int cachearray_append(lua_State *L);
int cachearray_tostring(lua_State *L);
int cachearray_depth(lua_State *L);
int cachearray_subscript(lua_State *L);

#endif // CACHEARRAY_H
