// Lua-yottadb header file

#ifndef LUA_YOTTADB_H
#define LUA_YOTTADB_H

/* Version History
v1.2 Version number bump purely MLua benchmark requires this version
 - Enhance node:gettree() so that you can easily use it as a generic tree iterator.
v1.1 Signal safety and robustness improvements
v1.0 First release by Berwyn Hoyt:
 - Syntax changes documented [here](v1.0-syntax-upgrade.md).
 - Ability to call M routines
 - Add new 'node' object. Deprecate 'key' object but retain it for backward compatibility
 - Overhauled [README](../README.md) and [reference documentation](yottadb.html)
 - Bugs fixed, including some that were critical
v0.1 Initial release by Mitchel:
 - Supports direct database access and access via Lua 'key' object.
*/

// Define version: Maj,Min
#define LUA_YOTTADB_VERSION 1,2
#define LUA_YOTTADB_VERSION_STRING   WRAP_PARAMETER(CREATE_VERSION_STRING, LUA_YOTTADB_VERSION)   /* "X.Y" format */
#define LUA_YOTTADB_VERSION_NUMBER   WRAP_PARAMETER(CREATE_VERSION_NUMBER, LUA_YOTTADB_VERSION)   /* XXYY integer format */
// Version creation helper macros
#define WRAP_PARAMETER(macro, param) macro(param)
#define CREATE_VERSION_STRING(major, minor) #major "." #minor
#define CREATE_VERSION_NUMBER(major, minor) ((major)*100 + (minor)


// Enable build against Lua older than 5.3
// for setting of COMPAT53_PREFIX see docs at: https://github.com/lunarmodules/lua-compat-5.3
// but although it builds, it doesn't find the compat functions when run, so comment out:
//#define COMPAT53_PREFIX luacompat
#include "compat-5.3/c-api/compat-5.3.h"

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

// Debug macro to dump the Lua stack
inline static void dumpStack (lua_State *L) {
  int i;
  int top = lua_gettop(L); /* depth of the stack */
  printf("STACK: ");
  for (i = 1; i <= top; i++) { /* repeat for each level */
    int t = lua_type(L, i);
    switch (t) {
      case LUA_TSTRING: { /* strings */
        printf("'%s'", lua_tostring(L, i));
        break;
      }
      case LUA_TBOOLEAN: { /* Booleans */
        printf(lua_toboolean(L, i) ? "true" : "false");
        break;
      }
      case LUA_TNUMBER: { /* numbers */
        printf("%g", lua_tonumber(L, i));
        break;
      }
      default: { /* other values */
        printf("%s", lua_typename(L, t));
        break;
      }
    }
    printf(" "); /* put a separator */
  }
  printf("\n"); /* end the listing */
}

// Debug macro to print a field `fieldstr` of the table at index
inline static void printField(lua_State *L, int index, char *fieldstr) {
  lua_getfield(L, index, fieldstr);
  printf("%s=%s(%s)\n", fieldstr, lua_tostring(L, -1), lua_typename(L, lua_type(L, -1)));
  fflush(stdout);
  lua_pop(L, 1);
}

#endif // LUA_YOTTADB_H
