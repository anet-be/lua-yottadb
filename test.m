;test function for lua_yottadb

%Run(string,integer,integer2)
 w string_":"_integer,",",integer2,!
 u $p
 quit "retval"

y(a,b)
 w a," ",b,!
 q

x()
 d y(2)