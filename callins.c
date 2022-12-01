// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage call-in to YDB from Lua

#include <stdio.h>
#include <stdbool.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

#include "callins.h"

int ydb_assert(lua_State *L, int code);

// Make table of constants for export to Lua
const const_Reg yottadb_types[] = {
  {"ydb_long_t", YDB_LONG_T}, {"ydb_ulong_t", YDB_ULONG_T},
  {"ydb_int_t", YDB_INT_T}, {"ydb_uint_t", YDB_UINT_T},
  {"ydb_int64_t", YDB_INT64_T}, {"ydb_uint64_t", YDB_UINT64_T},
  {"ydb_float_t", YDB_FLOAT_T}, {"ydb_double_t", YDB_DOUBLE_T},
  {"ydb_long_t*", YDB_LONG_T_PTR}, {"ydb_ulong_t*", YDB_ULONG_T_PTR},
  {"ydb_int_t*", YDB_INT_T_PTR}, {"ydb_uint_t*", YDB_UINT_T_PTR},
  {"ydb_int64_t*", YDB_INT64_T_PTR}, {"ydb_uint64_t*", YDB_UINT64_T_PTR},
  {"ydb_float_t*", YDB_FLOAT_T_PTR}, {"ydb_double_t*", YDB_DOUBLE_T_PTR},
  {"ydb_char_t*", YDB_CHAR_T_PTR},
  {"ydb_string_t*", YDB_STRING_T_PTR},
  {"ydb_buffer_t*", YDB_BUFFER_T_PTR},
  {"void", VOID},
  {NULL, 0},
};

// Allocate metadata structure for 'n' params
// Metadata is used, to store param data and mallocs (for subsequent freeing)
// Allocate on the stack for speed (hence need to use a macro)
// Invoke with: metadata M* = create_metadata(n) -- must use letter M to work
#define DEBUG_MALLOC 0
#if DEBUG_MALLOC
  #define DEBUG_MALLOCS(str, value) printf(str, (value)), fflush(stdout)
#else
  #define DEBUG_MALLOCS(str, value)
#endif
#define create_metadata(n) \
  NULL; /* fake return value -- M is patched later */ \
  ydb_param __param_spaces[(n)]; \
  void *__malloc_spaces[(n)]; \
  metadata __M = {0, 0, __malloc_spaces, (ydb_param **)&__param_spaces}; \
  M = &__M; /* ptr makes it same for user as if we made non-macro version */ \
  DEBUG_MALLOCS("sizeof(metadata)=%ld\b", sizeof(metadata)); \
  DEBUG_MALLOCS("sizeof(__param_spaces)=%ld\n", sizeof(__param_spaces)); \
  DEBUG_MALLOCS("sizeof(__malloc_spaces)=%ld\n", sizeof(__malloc_spaces)); \
  DEBUG_MALLOCS("&__param_spaces=%p\n", &__param_spaces); \
  DEBUG_MALLOCS("&__malloc_spaces=%p\n", &__malloc_spaces); \
  DEBUG_MALLOCS("Stack space for %ld params\n", (n));
static inline void *add_malloc(metadata *M, size_t size) {
  void *space = M->malloc[M->n++] = malloc(size);
  DEBUG_MALLOCS("Malloc %p\n", space);
  return space;
}
// Free each pointer in an array of malloc'ed pointers unless it is NULL
// ensure the first element is freed last because it contains the malloc structure itself
static inline void free_mallocs(metadata *M) {
  for (int i = M->n-1; i >= 0; i--) {
    DEBUG_MALLOCS("Free %p\n", M->malloc[i]);
    free(M->malloc[i]);
  }
}
// Return pointer to the next free metadata slot
static inline ydb_param *get_metadata(metadata *M) {
  DEBUG_MALLOCS("Using slot at M->data[%p]\n", M->data[M->i]);
  return M->data[M->i++];
}

// Cast Lua parameter at Lua stack index argi to ydb type type->type
// Store any malloc'ed data in metadata struct M
// On error, free all mallocs tracked in M and raise a Lua error
// Note: this is inner loop param processing, so limit cast_2ydb() args to 4 for speedy register params
static ydb_param cast_2ydb(lua_State *L, int argi, type_spec *ydb_type, metadata *M) {
  char *expected;  // expected type for error message
  ydb_param param;
  int isint;
  int success;
  ydb_type_id type = ydb_type->type;
  char isinput = ydb_type->input;
  char isoutput = ydb_type->output;

  // Use IF statement -- faster than SWITCH (even if table lookup) due to pipelining (untested)
  if (YDB_TYPE_ISSTR(type)) {
    // first handle all string types (number types later)
    size_t preallocation = ydb_type->preallocation;
    if (!preallocation) preallocation=YDB_MAX_STR;
    size_t length;
    char *s = lua_tolstring(L, argi, &length);
    if (length > preallocation) length = preallocation; // prevent writing past preallocation
    if (!s) { expected="string"; goto type_error; }
    if (type == YDB_CHAR_T_PTR) {
      // handle ydb_char_t* type
      if (isoutput) {
        // TODO: could check here whether YDB avoids overwriting string of strlen(input_string) -- maybe we don't need to malloc preallocation, and maybe we need to fill an input string with junk to the preallocation
        param.char_ptr = add_malloc(M, preallocation+1); // +1 for null safety-terminator
        if (isinput) {
          memcpy(param.char_ptr, s, length); // also copy Lua's NUL safety-terminator
          param.char_ptr[length] = '\0';  // make sure it's null-terminated somewhere
        } else
          param.char_ptr[0] = '\0'; // make it a blank string to start with if it's not an input
      } else {
        param.char_ptr = s;
      }
    } else if (type == YDB_STRING_T_PTR) {
      // handle ydb_string_t* type
      if (isoutput) {
        // TODO: check by trial whether YDB avoids overwriting string of strlen(input_string) -- maybe we don't need to malloc preallocation
        blob_alltypes *blob = add_malloc(M, preallocation+sizeof(blob_alltypes));
        param.string_ptr = &blob->type.string;
        param.string_ptr->address = blob->data;
        param.string_ptr->length = preallocation;
        if (isinput)
          memcpy(param.string_ptr->address, s, length);
      } else {
        blob_alltypes *blob = add_malloc(M, sizeof(blob_alltypes));
        param.string_ptr = &blob->type.string;
        param.string_ptr->address = s;
        param.string_ptr->length = length;
      }
    } else if (type == YDB_BUFFER_T_PTR) {
      // handle ydb_buffer_t* type
      if (isoutput) {
        blob_alltypes *blob = add_malloc(M, preallocation+sizeof(blob_alltypes));
        param.buffer_ptr = &blob->type.buffer;
        param.buffer_ptr->buf_addr = blob->data;
        param.buffer_ptr->len_alloc = preallocation;
        param.buffer_ptr->len_used = 0;
        if (isinput) {
          memcpy(param.buffer_ptr->buf_addr, s, length);
          param.buffer_ptr->len_used = length;
        }
      } else {
        blob_alltypes *blob = add_malloc(M, sizeof(blob_alltypes));
        param.buffer_ptr = &blob->type.buffer;
        param.buffer_ptr->buf_addr = s;
        param.buffer_ptr->len_alloc = length;
        param.buffer_ptr->len_used = length;
      }
    } else {
        free_mallocs(M);
        luaL_error(L, "M routine param #%d has invalid type id %d supplied in M routine call-in specification", argi-2, type);
    }

  } else {
    // now handle number types
    if (isinput) {
      if (YDB_TYPE_ISINTEGRAL(type)) {
        // handle long and int64
        param.long_n = lua_tointegerx(L, argi, &success);
        if (!success) { expected="integer"; goto type_error; }
        if (YDB_TYPE_IS32BIT(type))
          // handle int32 (ydb_int_t is specifically 32-bits)
          param.int_n = param.long_n; // cast in case we're running big-endian
      } else if (YDB_TYPE_ISREAL(type)) {
        param.double_n = lua_tonumberx(L, argi, &success);
        if (!success) { expected="number"; goto type_error; }
        if (type == YDB_FLOAT_T)
          param.float_n = param.double_n; // cast
      }
    } else
      param.long_n = 0;
    if (YDB_TYPE_ISPTR(type)) {
      // If it's a pointer type, store the actual data in the next metadata slot, then make param point to it
      ydb_param *p_ptr = get_metadata(M);
      *p_ptr = param;
      param.any_ptr = p_ptr;
    }
  }

  // TODO: confirm in assembler output that compiler returns an efficient single 64-bit value for param
  return param;
type_error:
  free_mallocs(M);
  luaL_typeerror(L, argi, expected);
}

// Cast retval/output param from ydb_type to a Lua type and push onto the Lua stack as a return value.
// Only called for output types
// There are no errors
// Note: this is inner loop param processing, so limit cast_2lua() args to 4 for speedy register params
static void cast_2lua(lua_State *L, ydb_param *param, ydb_type_id type) {
  // Use IF statement -- faster than SWITCH (even if table lookup) due to pipelining (untested)
  if (YDB_TYPE_ISSTR(type)) {
    // first handle all string types (number types later)
    if (type == YDB_CHAR_T_PTR)
      lua_pushstring(L, param->char_ptr);
    else if (type == YDB_STRING_T_PTR)
      lua_pushlstring(L, param->string_ptr->address, param->string_ptr->length);
    else if (type == YDB_BUFFER_T_PTR)
      lua_pushlstring(L, param->buffer_ptr->buf_addr, param->buffer_ptr->len_used);

  } else {
    // now handle number types
    if (YDB_TYPE_ISINTEGRAL(type)) {
      if (YDB_TYPE_IS32BIT(type))  // handle int32 (ydb_int_t is specifically 32-bits)
        lua_pushinteger(L, *param->int_ptr);
      else
        lua_pushinteger(L, *param->long_ptr);
    } else if (YDB_TYPE_ISREAL(type)) {
      if (type == YDB_FLOAT_T_PTR)
        lua_pushnumber(L, *param->float_ptr);
      else
        lua_pushnumber(L, *param->double_ptr);
    }
  }
}


// Call an M routine using ydb_ci()
// Note: this function is intended to be called by a wrapper in yottadb.lua rather than by the user
//    (so validity of type_list array is not checked)
// _yottadb.ci(ci_handle, routine_name, type_list[, param1][, param2][, ...])
// Call M routine routine_name which was specified in call-in table ci_handle, cf. ci_tab_open()
// @param type_list is a Lua string containing an array of type_spec[] specifying for ret_val and each parameter per the call-in table
//    (so the number of type_spec array elements must equal (1+n) where n is the number of parameters in the call-in file)
// @param<n> must list the parameters specified specified in the call-in table
//    each parameter is converted from its Lua type to the correct C type (e.g. ydb_int_t*) before calling the M routine
//    an error results if the number of parameters does not match the number specified in the call-in table
//    if too few parameters are supplied, an error results
//    if too many parameters are supplied, they are ignored (typical Lua behaviour)
// return: function's return value (unless ret_type='void') followed by any params listed as outputs (O or IO) in the call-in table
//    returned values are all converted from the call-in table type to Lua types
// NOTE: This is designed for speed, which means it does no mallocs unless it has to return strings
//    (because mallocs take ~50 CPU cycles each, according to google)
// TODO: could improve speed by having caller metadata remember total malloc space required and doing just one malloc for all
int ci(lua_State *L) {
  uintptr_t old_handle, ci_handle = luaL_checkinteger(L, 1);
  char *routine_name = luaL_checkstring(L, 2);

  size_t type_list_len;
  char *type_string = lua_tolstring(L, 3, &type_list_len);
  type_spec *type_list = (type_spec *)type_string;
  type_spec *types_end = (type_spec*)(type_string + type_list_len);
  bool has_retval = type_list->type != VOID;
  if (!has_retval) type_list++; // Don't need the first type any more if its type is VOID

  gparam_list_alltypes ci_arg; // list of args to send to ydb_ci()
  int lua_args = lua_gettop(L);
  ci_arg.n = (intptr_t)(types_end - type_list + 1); // +1 for routine_name
  if (lua_args-3 < ci_arg.n-1-has_retval)
    luaL_error(L, "not enough parameters to M routine %s() to match call-in specification", routine_name);

  // Allocate space to store a metadata for each param to ydb_ci() except routine_name
  // (actually we only need one per output_type parameter, but we don't have that count handy)
  // Note: after this, must not error out without first calling free_mallocs(M)
  metadata *M = create_metadata(ci_arg.n-1);

  int argi=0;  // output argument index
  ci_arg.arg[argi++].char_ptr = routine_name;
  type_spec *typeptr = type_list;
  for (; typeptr<types_end; typeptr++, argi++) {
    ci_arg.arg[argi] = cast_2ydb(L, argi+3-has_retval, typeptr, M);
  }

  // Set new ci_table
  int status = ydb_ci_tab_switch(ci_handle, &old_handle);
  if (status != YDB_OK) { free_mallocs(M); ydb_assert(L, status); }

  // Call the M routine
  fflush(stdout); // Avoid mingled stdout; ydb routine also needs to flush with (U $P) after it outputs
  // Note: ydb function ydb_call_variadic_plist_func() assumes all parameters passed are sizeof(void*)
  // which works, luckily, because gcc pads even 32-bit ydb_int_t to 64-bits
  status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_ci, (gparam_list*)&ci_arg);

  // Restore ci_table
  int status2 = ydb_ci_tab_switch(old_handle, &ci_handle);
  if (status == YDB_OK) status=status2; // report the first error
  if (status != YDB_OK) { free_mallocs(M); ydb_assert(L, status); }
  lua_pop(L, lua_args); // pop all args

  // Push return values
  int nreturns = 0;
  typeptr = type_list;
  for (argi=1;  typeptr<types_end;  typeptr++, argi++) {
    if (!typeptr->output) continue;
    cast_2lua(L, &ci_arg.arg[argi], typeptr->type);
    nreturns++;
  }
  free_mallocs(M);
  return nreturns;
}

// Open a call-in table using ydb_ci_tab_open()
// _yottadb.ci_tab_open(ci_table_filename)
// return: integer handle to call-in table
int ci_tab_open(lua_State *L) {
  uintptr_t ci_handle;
  ydb_assert(L, ydb_ci_tab_open(luaL_checkstring(L, 1), &ci_handle));
  lua_pop(L, 1);
  lua_pushinteger(L, ci_handle);
  return 1;
}