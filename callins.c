/// Manage call-in to YDB from Lua
// Copyright 2022-2023 Berwyn Hoyt. See LICENSE.
// @module yottadb.c

/// YDB Call-in functions
// @section

// Make sure signal.h imports the stuff we need
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdbool.h>
#include <signal.h>

#include <libyottadb.h>
#include <lua.h>
#include <lauxlib.h>

#include "yottadb.h"
#include "callins.h"


// ~~~ Signal handling to prevent EINTR errors ~~~

// If lua-yottadb ever changes to call ydb with threading calls, change the following to pthread_sigmask() and compile+link with -pthread option
#define SIGPROCMASK(how,set,oldset) sigprocmask((how),(set),(oldset))
// List of signals that YDB can trigger which we don't interrupting MLua slow IO reads/writes
#define BLOCKED_SIGNALS SIGCHLD, SIGTSTP, SIGTTIN, SIGTTOU, SIGCONT, SIGUSR1, SIGUSR2

static sigset_t Sigmask;
static struct sigaction Sigaction;
static lua_CFunction Signal_blocker=NULL;  // enter/exit function for entry/exit of M

// Call the function to enter/exit M with flag to indicate whether it is entering or exiting.
// Inline for speed.
static inline void invoke_signal_blocker(lua_State *L, bool flag) {
  if (Signal_blocker) {
    lua_pushboolean(L, flag);
    lua_pop(L, Signal_blocker(L));  // remove all return values
  }
}

// Initialize Sigmask and Sigaction global to mask signals that YDB uses
// so that we can save time later
// return 0 on failure due to an invalid signal in the list of blocked signals
static int init_sigmask() {
  static bool done=false;
  if (done) return !0;  // initialize only the first time
  int signals[] = {BLOCKED_SIGNALS};
  sigset_t sigmask_temp;
  sigemptyset(&sigmask_temp);
  int *signal = signals;
  while (signal < signals + sizeof(signals)/sizeof(int))
    if (sigaddset(&sigmask_temp, *signal++))
      return 0;
  Sigmask = sigmask_temp;  // copy to input's sigmask atomically, only after we know we have a valid one
  if (sigaction(SIGALRM, NULL, &Sigaction))
    return 0;
  done = true;
  return !0;
}

/// Initialize ydb and set blocking of M signals.
// If `signal_blocker` is specified, block M signals which could otherwise interrupt slow IO operations like reading from user/pipe.
// Assert any errors.
// Also read the notes on signals in the README.
// Note: any calls to the YDB API also initialize YDB; any subsequent call here will set `signal_blocker` but not re-init YDB.
// @function init
// @usage _yottadb.init(signal_blocker)
// @param[opt] signal_blocker specifies a Lua callback CFunction (e.g. `yottadb.block_M_signals()`) which will be
// called with parameter false on entry to M, and with true on exit from M, so as to unblock YDB signals while M is in use.
// Setting `signal_blocker` to nil switches off signal blocking.
//
// Note: Changing this to support a generic Lua function as callback would be possible but slow, as it would require
// fetching the function pointer from a C closure, and using `lua_call()`.
// @return nothing
// @see block_M_signals
int init(lua_State *L) {
  if (lua_gettop(L)>0 && !lua_isnil(L, 1) && !lua_iscfunction(L, 1))
    luaL_error(L, "Parameter #1 to init must be nil or a CFunction");
  // setup Sigmask here to save time on every call to an M routine
  ydb_assert(L, ydb_init());  // init YDB signals before we can init sigmask
  if (!init_sigmask())
    luaL_error(L, "Signal list in callins.c, init_sigmask() contains invalid signal names");
  // turn off blocking using previous signal_blocker func
  invoke_signal_blocker(L, false);
  Signal_blocker = lua_tocfunction(L, 1);
  lua_pop(L, 1);
  // turn on blocking using new signal_blocker func
  invoke_signal_blocker(L, true);
  return 0;
}

/// Block or unblock YDB signals for while M code is running.
// This function is designed to be passed to yottadb.init() as the `signal_blocker` parameter.
// Most signals (listed in `BLOCKED_SIGNALS` in callins.c) are blocked using sigprocmask()
// but SIGLARM is not blocked; instead, sigaction() is used to set its SA_RESTART flag while
// in Lua, and cleared while in M. This makes the OS automatically restart IO calls that are 
// interrupted by SIGALRM. The benefit of this over blocking is that the YDB SIGALRM
// handler does actually run, allowing YDB to flush the database or IO as necessary without
// your M code having to call the M command `VIEW "FLUSH"`.
// Note: this function does take time, as OS calls are slow. Using it will increase the M calling
// overhead by about 1.4 microseconds: 2-5x the bare calling overhead (see `make benchmarks`)
// The call to init() already saves initial values of SIGALRM flags and Sigmask to reduce
// OS calls and make it as fast as possible.
// @function block_M_signals
// @usage yottadb.block_M_signals(bool)
// @param bool true to block; false to unblock all YDB signals
// @return nothing
// @see init
int block_M_signals(lua_State *L) {
  bool block = lua_toboolean(L, 1);
  // two sigprocmask calls (set+unset) take 873 instructions (3018 cycles, 609ns on my i7) - tested with perf
  // two sigaction calls (set+unset) take 925 instructions (3000 cycles, 685ns on my i7) - tested with perf
  // But once installed in the whole M_routine callback system, they slow down an empty M call and return
  // by 1400 ns -- discrepancy presumably due to something with CPU caching?
  if (block) {
    Sigaction.sa_flags |= SA_RESTART;
    sigaction(SIGALRM, &Sigaction, NULL);
    SIGPROCMASK(SIG_BLOCK, &Sigmask, NULL);
  } else {
    SIGPROCMASK(SIG_UNBLOCK, &Sigmask, NULL);
    Sigaction.sa_flags &= ~SA_RESTART;
    sigaction(SIGALRM, &Sigaction, NULL);
  }
  lua_pop(L, 1);
  return 0;
}

// ~~~ M Routine parameter model and parameter metadata allocation ~~~

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
#define DEBUG_META_FLAG 0
#if DEBUG_META_FLAG
  #define DEBUG_META(str, value) printf(str, (value)), fflush(stdout)
#else
  #define DEBUG_META(str, value)
#endif
#define create_metadata(n) \
  NULL; /* fake return value -- M is patched later */ \
  byref_slot __slots[(n)]; \
  void *__malloc_spaces[(n)]; \
  metadata __M = {0, 0, __malloc_spaces, __slots}; \
  M = &__M; /* ptr makes it same for user as if we made non-macro version */ \
  DEBUG_META("Allocating stack space for %ld params\n", (n)); \
  DEBUG_META("  using a total stack space of %ld bytes:\n", sizeof(metadata)+sizeof(__slots)+sizeof(__malloc_spaces)); \
  DEBUG_META("    sizeof(metadata)=%ld\n", sizeof(metadata)); \
  DEBUG_META("   +params*sizeof(__slots)=%ld\n", sizeof(__slots)); \
  DEBUG_META("   +params*sizeof(__malloc_spaces)=%ld\n", sizeof(__malloc_spaces)); \
  DEBUG_META("&M->malloc=%p\n", &M->malloc); \
  DEBUG_META("&M->slot=%p\n", &M->slot); \
  DEBUG_META("&__slots=%p\n", &__slots); \
  DEBUG_META("&__malloc_spaces=%p\n", &__malloc_spaces); \
  DEBUG_META("M->malloc=%p\n", M->malloc); \
  DEBUG_META("M->slot=%p\n", M->slot);
static inline void *add_malloc(metadata *M, size_t size) {
  void *space = MALLOC_SAFE(size);
  DEBUG_META("Assigning malloc space %p\n", space);
  DEBUG_META("  to malloc slot number %d\n", M->n);
  DEBUG_META("  at address M->malloc[M->n]=%p\n", &M->malloc[M->n]);
  return M->malloc[M->n++] = space;
}
// Free each pointer in an array of malloc'ed pointers unless it is NULL
// ensure the first element is freed last because it contains the malloc structure itself
static inline void free_mallocs(metadata *M) {
  for (int i = M->n-1; i >= 0; i--) {
    DEBUG_META("Free %p\n", M->malloc[i]);
    free(M->malloc[i]);
  }
}
// Return pointer to the next free metadata slot
static inline byref_slot *get_slot(metadata *M) {
  DEBUG_META("Allocating byref slot number %d\n", M->i);
  DEBUG_META("  at address &M->slot[M->i]=%p\n", &M->slot[M->i]);
  return &M->slot[M->i++];
}

// Define number of arguments to cip() before var_args
#define CIP_ARGS 3

typedef struct {
  metadata *M;  // malloc metadata
  // add any more function-specific data here
} cip_metadata;

// Cleanup function for cip() to help with early error exits
// inline for speed
static inline void cip_cleanup(lua_State *L, cip_metadata *meta) {
  free_mallocs(meta->M);
  // do the following function last in case it produces an error (since it's a user-supplied function)
  invoke_signal_blocker(L, true);
}

// Free mallocs and assert type error
// Prints argument # of M routine rather than argument of cip()
static void typeerror_cleanup(lua_State*L, cip_metadata *meta, int argi, char *expected_type) {
  cip_cleanup(L, meta);
  luaL_error(L, "bad argument #%d of M routine wrapper (expected %s, got %s)", argi-CIP_ARGS, expected_type, lua_typename(L, lua_type(L, argi)));
}

// Cast Lua parameter at Lua stack index argi to ydb type type->type
// Store any malloc'ed data in metadata struct M
// On error, free all mallocs tracked in M and raise a Lua error
// Notes:
//
// * this is inner loop param processing, so limit cast2ydb() args to 4 to use speedy register params.
// * gcc passes double/float types in FPU registers instead of in the parameter array
// which means we cannot pass them in gparam_list. (YDB should have used sseregparm attribute on ydb_ci)
// * similarly for ydb_int_t in some architectures, although my gcc seems to pass 32-bit params as 64-bits;
// see: https://en.wikipedia.org/wiki/X86_calling_conventions
//
// All of this means we must pass float, double, and int as pointers instead of actuals.
// The wrapper in yottadb.lua will auto-convert the call-in table to these ideals.
static ydb_param cast2ydb(lua_State *L, int argi, type_spec *ydb_type, cip_metadata *meta) {
  ydb_param param;
  int success;
  ydb_type_id type = ydb_type->type;
  char isinput = ydb_type->input;
  char isoutput = ydb_type->output;

  // Use IF statement -- faster than SWITCH (even if table lookup) due to pipelining (untested)
  if (YDB_TYPE_ISSTR(type)) {
    // first handle all string types (number types later)
    size_t preallocation = ydb_type->preallocation;
    if (preallocation==(size_t)-1) preallocation=YDB_MAX_STR;
    size_t length;
    char *s=NULL;  // does nothing but satisfy gcc that we're not using it uninitialized
    if (isinput) {
      s = lua_tolstring(L, argi, &length);
      if (!s) typeerror_cleanup(L, meta, argi, "string");
    }
    if (type == YDB_CHAR_T_PTR) {
      // handle ydb_char_t* type
      if (isoutput) {
        preallocation = YDB_MAX_STR;  // always full size since YDB cannot check for overruns
        param.char_ptr = add_malloc(meta->M, preallocation+1); // +1 for null safety-terminator
        if (isinput) {
          if (length > preallocation) length = preallocation; // prevent writing past preallocation
          memcpy(param.char_ptr, s, length); // also copy Lua's NUL safety-terminator
          param.char_ptr[length] = '\0';  // make sure it's null-terminated somewhere
        } else
          param.char_ptr[0] = '\0'; // make it a blank string to start with if it's not an input
      } else
        param.char_ptr = s;
    } else if (type == YDB_STRING_T_PTR) {
      // handle ydb_string_t* type
      byref_slot *slot = get_slot(meta->M);
      param.string_ptr = &slot->string;
      if (isoutput) {
        slot->string.address = add_malloc(meta->M, preallocation);
        slot->string.length = preallocation;
        if (isinput) {
          if (length > preallocation) length = preallocation; // prevent writing past preallocation
          memcpy(slot->string.address, s, length);
          slot->string.length = length;
        }
      } else {  // it's input only
        slot->string.address = s;
        slot->string.length = length;
      }
    } else if (type == YDB_BUFFER_T_PTR) {
      // handle ydb_buffer_t* type
      byref_slot *slot = get_slot(meta->M);
      param.buffer_ptr = &slot->buffer;
      if (isoutput) {
        if (length > preallocation) length = preallocation; // prevent writing past preallocation
        slot->buffer.buf_addr = add_malloc(meta->M, preallocation);
        slot->buffer.len_alloc = preallocation;
        slot->buffer.len_used = 0;
        if (isinput) {
          memcpy(slot->buffer.buf_addr, s, length);
          slot->buffer.len_used = length;
        }
      } else {  // it's input only
        slot->buffer.buf_addr = s;
        slot->buffer.len_alloc = length;
        slot->buffer.len_used = length;
      }
    } else {
        cip_cleanup(L, meta);
        luaL_error(L, "M routine argument #%d has invalid type id %d supplied in M routine call-in specification", argi-CIP_ARGS, type);
    }

  } else {
    // now handle number types
    if (isinput) {
      if (YDB_TYPE_ISINTEGRAL(type)) {
        // handle long and int64
        param.long_n = lua_tointegerx(L, argi, &success);
        if (!success) typeerror_cleanup(L, meta, argi, "integer");
        if (YDB_TYPE_IS32BIT(type)) {
          // handle int32 (ydb_int_t is specifically 32-bits)
          if (!YDB_TYPE_ISUNSIGNED(type) && (param.long_n > 0x7fffffffL || param.long_n < -0x80000000L))
            typeerror_cleanup(L, meta, argi, "number that will fit in 32-bit signed integer");
          if (YDB_TYPE_ISUNSIGNED(type) && (param.long_n > 0xffffffffL || param.long_n < 0))
            typeerror_cleanup(L, meta, argi, "number that will fit in 32-bit unsigned integer");
          param.int_n = param.long_n; // cast in case we're running big-endian which won't auto-cast
        }
      } else if (YDB_TYPE_ISREAL(type)) {
        param.double_n = lua_tonumberx(L, argi, &success);
        if (!success) typeerror_cleanup(L, meta, argi, "number");
        if (YDB_TYPE_IS32BIT(type)) {
          param.float_n = param.double_n; // cast
        }
      }
    } else
      param.long_n = 0;
    if (YDB_TYPE_ISPTR(type)) {
      // If it's a pointer type, store the actual data in the next metadata slot, then make param point to it
      byref_slot *slot = get_slot(meta->M);
      slot->param = param;
      param.any_ptr = &slot->param;
    }
  }

  return param;
}

// Cast retval/output param from ydb_type to a Lua type and push onto the Lua stack as a return value.
// Only called for output types
// There are no errors
// Note: this is inner loop param processing, so limit cast2lua() args to 4 for speedy register params
static void cast2lua(lua_State *L, ydb_param *param, ydb_type_id type) {
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

// Turn on the following code to debug problems with the array of parameters passed to ydb_ci
// For example, see the comments on floats under cast2ydb()
#define DEBUG_VA_ARGS 0
#if DEBUG_VA_ARGS
void dump(void *p, size_t n, int inc) {
  for (; n; n--, p+=inc) {
    printf("%016lx, ", *(unsigned long *)p);
  }
   printf("\b\b  \n");
}

static int _num_params=0;
int ydb_ci_stub(char *name, ...) { //ydb_string_t *retval, ydb_string_t *n, long a, double x, ydb_char_t *msg, long q, long w, ...) {
  va_list ap;
  va_start(ap, name);
  printf("%17s(", name);
  for (int i=0; i<_num_params-1; i++)
    printf("%016lx, ", va_arg(ap, ydb_long_t));
  printf("\b\b) \n");
}
#endif


// any 'random' 4-byte ID "Mrtn" so we can double-check this is our own struct type
#define TYPEID ((int)'M'<<24 | (int)'r'<<16 | (int)'t'<<8 | 'n')
typedef struct {
  int typeid;
  char *entrypoint;
  ci_name_descriptor ci_info; // a ydb type
} ci_name_userdata;


/// Call an M routine.
// Notes:
//
// * This function is intended to be called by a wrapper in yottadb.lua rather than by the user,
// so validity of type_list array is not checked.
// * If you change the number of parameters before var_args then you MUST also adjust CIP_ARGS.
// * You must pass float, double, and int as pointers instead of actuals: see note in cast2ydb().
// * This is designed for speed, which means all temporary data is allotted on the stack.
// and it does no mallocs unless it has to return strings (which can be large so need malloc).
// This is because mallocs+free takes 200 CPU instructions (50 cycles, 13ns  on my i7) - tested with perf stat.
// So if you want it to be super fast, don't return strings or make them outputs!
// * TODO: could improve speed by having caller metadata remember total string-malloc space required and doing just one malloc for all.
// But first check benchmarks first to see if YDB end is slow enough to make optimization meaningless.
// @function cip
// @usage _yottadb.cip(ci_handle, routine_name_handle, type_list[, param1][, param2][, ...])
// @param ci_handle is a call-in table opened by ci_tab_open() that contains routine_name
// @param routine_name_handle is the handle of an M routine registered by _yottadb.register_routine()
// @param type_list is a Lua string containing an array of type_spec[] specifying ret_val and each parameter per the call-in table
//    (so the number of type_spec array elements must equal (1+n) where n is the number of parameters in the call-in file)
// @param<n> must list the parameters specified specified in the call-in table
//    each parameter is converted from its Lua type to the correct C type (e.g. ydb_int_t*) before calling the M routine
//    an error results if the number of parameters does not match the number specified in the call-in table
//    if too few parameters are supplied, an error results
//    if too many parameters are supplied, they are ignored (typical Lua behaviour)
// @return: Function's return value (unless ret_type='void') followed by any params listed as outputs (O or IO) in the call-in table.
// Returned values are all converted from the call-in table type to Lua types
int cip(lua_State *L) {
  uintptr_t old_handle, ci_handle = luaL_checkinteger(L, 1);
  if (!lua_isuserdata(L, 2))
    luaL_error(L, "parameter #2 must be userdata returned by register_routine()");
  ci_name_userdata *u = lua_touserdata(L, 2);
  if (!u || u->typeid != TYPEID)
    luaL_error(L, "parameter #2 must be userdata returned by register_routine()");

  size_t type_list_len;
  char *type_string = lua_tolstring(L, 3, &type_list_len);

  type_spec *type_list = (type_spec *)type_string;
  type_spec *types_end = (type_spec*)(type_string + type_list_len);
  bool has_retval = type_list->type != VOID;
  if (!has_retval) type_list++; // Don't need the first type any more if its type is VOID

  gparam_list_alltypes ci_arg; // list of args to send to ydb_cip()
  int lua_args = lua_gettop(L);
  ci_arg.n = (intptr_t)(types_end - type_list + 1); // +1 for ci_info
  if (lua_args-CIP_ARGS < ci_arg.n-1-has_retval)
    luaL_error(L, "not enough parameters to M routine %s() to match call-in specification", u->ci_info.rtn_name.address);

  // NOTE: after this, we must not error out without first calling cip_cleanup()
  // The following is a user function, so could produce an error. So do it before create_metadata() which requires cleanup.
  invoke_signal_blocker(L, false);
  // Allocate space to store metadata for each param to ydb_cip() except routine_name_handle
  // (actually we only use one metadata entry per output_type parameter, but we don't have that count handy)
  metadata *M = create_metadata(ci_arg.n-1);
  cip_metadata _meta = {M};
  cip_metadata *meta = &_meta;

  int argi=0;  // output argument index
  ci_arg.arg[argi++].ci_info_ptr = &u->ci_info;
  type_spec *typeptr = type_list;
  for (; typeptr<types_end; typeptr++, argi++) {
    ci_arg.arg[argi] = cast2ydb(L, argi+CIP_ARGS-has_retval, typeptr, meta);
  }

  // Set new ci_table if we haven't previously populated ci_info.handle by calling ydb_cip()
  int status;
  status = ydb_ci_tab_switch(ci_handle, &old_handle);
  if (status != YDB_OK) { cip_cleanup(L, meta); ydb_assert(L, status); }

  fflush(stdout); // Avoid mingled stdout; ydb routine also needs to flush with (U $P) after it outputs

  // Call the M routine
  // Note: ydb function ydb_call_variadic_plist_func() assumes all parameters passed are sizeof(void*)
  // So ydb_int_t,  float, double must be passed as pointers because ydb_cip() expects them in FPU registers per calling convention.
  // Use of pointers for these is ensured in Lua by the call-in file loader.
  // (YDB could have used sseregparam attribute on ydb_cip() to avoid this, but pointers will have to suffice)

  #if DEBUG_VA_ARGS
    dump(ci_arg.arg, 8, ci_arg.n);
    _num_params = ci_arg.n;
    ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_ci_stub, (gparam_list*)&ci_arg);
  #endif
  status = ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_cip, (gparam_list*)&ci_arg);

  // Restore ci_table if we set it
  int status2 = ydb_ci_tab_switch(old_handle, &ci_handle);
  if (status == YDB_OK) status=status2; // report the first error
  if (status == -150373978) {
    cip_cleanup(L, meta);
    luaL_error(L, "%s%d: %%YDB-E-ZLINKFILE, Error while zlinking M entrypoint '%s')", LUA_YDB_ERR_PREFIX, status, u->entrypoint);
  }

  if (status != YDB_OK) { cip_cleanup(L, meta); ydb_assert(L, status); }
  lua_pop(L, lua_args); // pop all args

  // Push return values
  int nreturns = 0;
  typeptr = type_list;
  for (argi=1;  typeptr<types_end;  typeptr++, argi++) {
    if (!typeptr->output) continue;
    cast2lua(L, &ci_arg.arg[argi], typeptr->type);
    nreturns++;
  }
  cip_cleanup(L, meta);
  return nreturns;
}

/// Register a routine name for subsequent passing to `cip()`.
// @function register_routine
// @usage _yottadb.register_routine(routine_name, entrypoint)
// @param routine_name is the C name of the M routine (first field in the call-in table)
// @param entrypoint is the M entrypoint specified in the call-in table
// @return the handle (a ydb ci_name_descriptor struct in a new Lua userdata object).
int register_routine(lua_State *L) {
  ci_name_userdata *u;
  u = lua_newuserdata(L, sizeof(ci_name_userdata));
  u->typeid = TYPEID;
  u->ci_info.rtn_name.address = luaL_checklstring(L, 1, &u->ci_info.rtn_name.length);
  u->ci_info.handle = NULL;  // have to sete ci_info.handle to NULL before first call to that M routine
  u->entrypoint = luaL_checkstring(L, 2);
  return 1;
}

/// Open a call-in table using ydb_ci_tab_open()
// @function ci_tab_open
// @usage _yottadb.ci_tab_open(ci_table_filename)
// @param ci_table_filename refers to the ydb call-in table file to open
// @return integer handle to call-in table
int ci_tab_open(lua_State *L) {
  uintptr_t ci_handle;
  ydb_assert(L, ydb_ci_tab_open(luaL_checkstring(L, 1), &ci_handle));
  lua_pop(L, 1);
  lua_pushinteger(L, ci_handle);
  return 1;
}

/// @section end
