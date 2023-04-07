// Lua-yottadb header file

#ifndef LUA_YOTTADB_H
#define LUA_YOTTADB_H

// Enable build against Lua older than 5.3
// for setting of COMPAT53_PREFIX see docs at: https://github.com/lunarmodules/lua-compat-5.3
// but although it builds, it doesn't find the compat functions when run, so comment out:
//#define COMPAT53_PREFIX luacompat
#include "compat-5.3/c-api/compat-5.3.h"

// Define version: Maj,Min
#define LUA_YOTTADB_VERSION 1,2
#define LUA_YOTTADB_VERSION_STRING   WRAP_PARAMETER(CREATE_VERSION_STRING, LUA_YOTTADB_VERSION)   /* "X.Y" format */
#define LUA_YOTTADB_VERSION_NUMBER   WRAP_PARAMETER(CREATE_VERSION_NUMBER, LUA_YOTTADB_VERSION)   /* XXYY integer format */
// Version creation helper macros
#define WRAP_PARAMETER(macro, param) macro(param)
#define CREATE_VERSION_STRING(major, minor) #major "." #minor
#define CREATE_VERSION_NUMBER(major, minor) ((major)*100 + (minor)


extern int ydb_assert(lua_State *L, int code);
extern int _memory_error(size_t size, int line, char *file);


// Define safe malloc routines that exit with error on failure, rather than unpredictably continuing

static __inline__ void *_malloc_safe(size_t size, int line, char *file) {
  void *buf = malloc(size);
  if (!buf) _memory_error(size, line, file);
  return buf;
}

static __inline__ void *_realloc_safe(void *buf, size_t size, int line, char *file) {
  buf = realloc(buf, size);
  if (!buf) _memory_error(size, line, file);
  return buf;
}

#define MALLOC_SAFE(LEN) _malloc_safe((LEN), __LINE__, __FILE__)
#define REALLOC_SAFE(BUF, LEN) _realloc_safe((BUF), (LEN), __LINE__, __FILE__)

#define YDB_MALLOC_BUFFER_SAFE(BUFFERP, LEN) { \
  YDB_MALLOC_BUFFER((BUFFERP), (LEN)); \
  if (!(BUFFERP)->buf_addr) _memory_error((LEN), __LINE__, __FILE__); \
}

#define YDB_REALLOC_BUFFER_SAFE(BUFFERP) { \
  int len_used = (BUFFERP)->len_used; \
  YDB_FREE_BUFFER(BUFFERP); \
  YDB_MALLOC_BUFFER_SAFE((BUFFERP), len_used); \
}

#endif // LUA_YOTTADB_H
