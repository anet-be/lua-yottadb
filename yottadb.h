// Lua-yottadb header file

#ifndef LUA_YOTTADB_H
#define LUA_YOTTADB_H

// Define version: Maj,Min
#define LUA_YOTTADB_VERSION 1,0
#define LUA_YOTTADB_VERSION_STRING   WRAP_PARAMETER(CREATE_VERSION_STRING, LUA_YOTTADB_VERSION)   /* "X.Y" format */
#define LUA_YOTTADB_VERSION_NUMBER   WRAP_PARAMETER(CREATE_VERSION_NUMBER, LUA_YOTTADB_VERSION)   /* XXYY integer format */
// Version creation helper macros
#define WRAP_PARAMETER(macro, param) macro(param)
#define CREATE_VERSION_STRING(major, minor) #major "." #minor
#define CREATE_VERSION_NUMBER(major, minor) ((major)*100 + (minor)

extern int ydb_assert(lua_State *L, int code);

#endif // LUA_YOTTADB_H
