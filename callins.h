// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// Manage call-in to YDB from Lua

#ifndef CALLINS_H
#define CALLINS_H

#include <assert.h>
#include <lua.h>

typedef struct const_Reg {
  const char *name;
  int value;
} const_Reg;

extern const const_Reg yottadb_types[];

// Make enum that expresses a bitfield for speedy category lookup when processing
// order of bits is also important for YDB_TYPE_ISINTEGRAL to work
#define _YDB_TYPE_ISUNSIGNED 0x01  /* unsigned must be bit1 for enum sequential types to work */
#define _YDB_TYPE_IS32BIT    0x02  /* not set for LONG types which are build-dependent in YDB */
#define _YDB_TYPE_IS64BIT    0x04  /* not set for LONG types which are build-dependent in YDB */
#define _YDB_TYPE_ISPTR      0x08
#define _YDB_TYPE_ISREAL     0x10  /* float or double */
#define _YDB_TYPE_ISSTR      0x80  /* Note: for string types, other bits have different meaning: to distinguish string types */

enum ydb_types {
  YDB_LONG_T  = 0, YDB_ULONG_T,
  YDB_INT_T   = _YDB_TYPE_IS32BIT, YDB_UINT_T,
  YDB_INT64_T = _YDB_TYPE_IS64BIT, YDB_UINT64_T,
  YDB_FLOAT_T = _YDB_TYPE_ISREAL+_YDB_TYPE_IS32BIT,
  YDB_DOUBLE_T= _YDB_TYPE_ISREAL+_YDB_TYPE_IS64BIT,
  YDB_LONG_T_PTR  = _YDB_TYPE_ISPTR, YDB_ULONG_T_PTR,
  YDB_INT_T_PTR   = _YDB_TYPE_ISPTR+_YDB_TYPE_IS32BIT, YDB_UINT_T_PTR,
  YDB_INT64_T_PTR = _YDB_TYPE_ISPTR+_YDB_TYPE_IS64BIT, YDB_UINT64_T_PTR,
  YDB_FLOAT_T_PTR = _YDB_TYPE_ISPTR+_YDB_TYPE_ISREAL+_YDB_TYPE_IS32BIT,
  YDB_DOUBLE_T_PTR= _YDB_TYPE_ISPTR+_YDB_TYPE_ISREAL+_YDB_TYPE_IS64BIT,
  YDB_CHAR_T_PTR  = _YDB_TYPE_ISSTR+_YDB_TYPE_ISPTR /*0x88*/, YDB_STRING_T_PTR /*0x89*/, YDB_BUFFER_T_PTR /*0x8a*/,
  VOID=0xff
};

#define YDB_TYPE_ISSTR(type) (((type)&_YDB_TYPE_ISSTR) != 0)
// The following macros assume the type is already know to be not VOID and not string type
#define YDB_TYPE_ISPTR(type) (((type)&_YDB_TYPE_ISPTR) != 0)
#define YDB_TYPE_ISREAL(type) (((type)&_YDB_TYPE_ISREAL) != 0)
#define YDB_TYPE_IS64BIT(type) (((type)&_YDB_TYPE_IS64BIT) != 0)
#define YDB_TYPE_IS32BIT(type) (((type)&_YDB_TYPE_IS32BIT) != 0)
#define YDB_TYPE_ISUNSIGNED(type) (((type)&_YDB_TYPE_ISUNSIGNED) != 0)
#define YDB_TYPE_ISINTEGRAL(type) ((type) < _YDB_TYPE_ISREAL)

// define a param type that holds any type of param
typedef union {
  ydb_int_t int_n;
  ydb_uint_t uint_n;
  ydb_long_t long_n;
  ydb_ulong_t ulong_n;
  ydb_float_t float_n;

  void* any_ptr; // for storing pointer to any pointer type
  ydb_int_t* int_ptr;
  ydb_uint_t* uint_ptr;
  ydb_long_t* long_ptr;
  ydb_ulong_t* ulong_ptr;
  ydb_float_t* float_ptr;
  ydb_double_t* double_ptr;

  ydb_char_t* char_ptr;
  ydb_string_t* string_ptr;
  ydb_buffer_t* buffer_ptr; // Note: only works with call-in from YDB r1.36 onward

  #if UINTPTR_MAX == 0xffffffffffffffff
    // ydb_double_t doesn't fit in (void*) on 32-bit builds. Instead, use pointer type ydb_double_t*
    ydb_double_t double_n;
    // int64 types do not exist on 32-bit builds
    ydb_int64_t int64_n;
    ydb_uint64_t uint64_n;
    ydb_int64_t* int64_ptr;
    ydb_uint64_t* uint64_ptr;
  #endif
} ydb_param;

// define a space that holds any type of structure that can be pointed to by ydb_xxx_t*
typedef union {
  ydb_param param;  // let us cast from this type to param
  ydb_int_t int_n;
  ydb_uint_t uint_n;
  ydb_long_t long_n;
  ydb_ulong_t ulong_n;
  ydb_float_t float_n;
  ydb_string_t string;
  ydb_buffer_t buffer; // Note: only works with call-in from YDB r1.36 onward
} byref_slot;

static_assert( sizeof(ydb_param) == sizeof(void*),
  "Not all ydb_ci parameters will fit into ydb's gparam_list array. "
  "Need to revise either ydb or lua-yottadb code. Or don't use the offending parameter types."
);

// type of parameter list passed to ydb_call_variadic_plist_func()
typedef struct {
	intptr_t n;				/* Count of parameter/arguments -- must be same type as in YDB's gparam_list */
	ydb_param arg[MAX_GPARAM_LIST_ARGS];	/* Parameter/argument array */
} gparam_list_alltypes;

// struct to house every kind of ydb string
typedef struct {
  union {
    ydb_string_t string;
    ydb_buffer_t buffer;
  } type;
  char data[];  // the actual string
} blob_alltypes;

typedef unsigned char ydb_type_id;  // Must be unsigned to make comparison against larger ints work nicely

// specify type and IO of call-in parameter from call-in table
// (specify __packed__ since these structs are packed end-to-end into a Lua string -- may not be necessary since they're all chars)
typedef struct {
  size_t preallocation; // amount of string space to preallocate: -1 = use YDB_MAX_STR
  ydb_type_id type;  // index into enum ydb_types
  char input, output;  // 1 char boolean flags
} type_spec;

// Manage metadata for ci()
//   specifically, hold param data for each param and malloc pointers that need to be freed
// -- for internal use
// For the sake of speed, init M in pre-allocated space rather than using malloc because stack is
//   much faster. Thus, for minimal functions that don't return strings, malloc is not needed at all.
// Functions defined as inline for speed.
typedef void *ptrarray[];
typedef struct {
	int n;				    // count of mallocs stored so far
  int i;            // count of data pointers stored so far
	void **malloc;    // pointer to array of malloc'ed handles - one for each param
  byref_slot *slot; // pointer to array of byref_slots - one for each param
} metadata;


int ci_tab_open(lua_State *L);
int ci(lua_State *L);

#endif // CALLINS_H
