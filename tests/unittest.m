;test function for lua_yottadb
add(string,n1,n2)
 w string u $p
 quit n1+n2

test1(string,n1,n2,byref)
 w "Passed ",n1,"+",n2,"(=",4+7,") and string: ",byref,!  u $p
 s byref="abcdefghijklmnopqrstuvwxyz"
 quit n1+n2
