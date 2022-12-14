;Arithmetic routine to test M calls from lua-yottadb

addVerbose(message,n1,n2)
 w message,n1+n2,!  u $p
 quit message_(n1+n2)

add(n1,n2)
 quit n1+n2

sub(n1,n2)
 quit n1-n2
