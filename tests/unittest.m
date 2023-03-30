;test function for lua_yottadb
add(n1,n2,n3,n4,n5,n6,n7,n8)
 quit n1+n2+n3+n4+n5+n6+n7+n8

concat(cstring,lstring,byref,cout)
 s concat=cstring_$C(0)_lstring_$C(0)_byref
 s cout=concat
 s byref="abcdefghijklmnopqrstuvwxyz"
 quit concat

;empty routine for use by tests/mroutine_benchmarks.lua
ret()
 quit
