// Program simply to set variadic call functions of YDB
// It turns out there are problems passing certain parameters to ydb using ydb_call_variadic_plist_func()
// These are documented in callins.c near ydb_ci_stub()

#include <stdio.h>
#include <libyottadb.h>
#include <stdint.h>
#include "callins.h"

// Pull in needed bits from YDB source:
#define VAR_ARGS4(ar)	ar[0], ar[1], ar[2], ar[3]
#define VAR_ARGS8(ar)	VAR_ARGS4(ar), ar[4], ar[5], ar[6], ar[7]
typedef intptr_t INTPTR_T;
typedef INTPTR_T intszofptr_t;
typedef	INTPTR_T (*callgfnptr)(intszofptr_t cnt, ...);

INTPTR_T callg(callgfnptr fnptr, gparam_list *paramlist) {
	switch(paramlist->n)
	{
		case 0:
			return (fnptr)(0);
		case 1:
		case 2:
		case 3:
		case 4:
			return (fnptr)(paramlist->n, VAR_ARGS4(paramlist->arg));
		case 5:
		case 6:
		case 7:
		case 8:
			return (fnptr)(paramlist->n, VAR_ARGS8(paramlist->arg));
  }
  return 0;
}


void dump(void *p, size_t n, int inc) {
  for (; n; n--, p+=inc) {
    printf("%16lx ", *(unsigned long *)p);
  }
}

int ydb_ci_stub(char *name, ...) { //ydb_string_t *retval, ydb_string_t *n, long a, double x, ydb_char_t *msg, long q, long w, ...) {
  va_list ap;
  va_start(ap, name);
  printf("  va_list        ");
  for (int i=0; i<7; i++)
    printf("%16lx ", va_arg(ap, ydb_long_t));
  printf("\n");
}

int main() {
  ydb_string_t str = {3, "abc"};
  char *name="name";
  char *last="last";
  printf("Pointer locations are; name=%p, str=%p, str=%p, last=%p\n", name, &str, &str, last);

  gparam_list_alltypes ci_arg = {8, {(long)name, (long)&str, (long)&str, 1, (long)8.0, (long)last, 4, 5}};

  printf("arraydump"); dump(ci_arg.arg, 8, 8);   printf("\n");
  printf("variadic "); ydb_call_variadic_plist_func((ydb_vplist_func)&ydb_ci_stub, (gparam_list*)&ci_arg);
  printf("direct   "); ydb_ci_stub(name, &str, &str, 1L, 8L, last, 4L, 5L);
  printf("viaarray "); ydb_ci_stub(ci_arg.arg[0].char_ptr, ci_arg.arg[1].string_ptr, ci_arg.arg[2].string_ptr, ci_arg.arg[3].long_n, 8L, ci_arg.arg[5].char_ptr, ci_arg.arg[5].long_n, ci_arg.arg[7].long_n);

  return 0;
}
