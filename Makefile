#

SHELL:=/bin/bash

ydb_dist=$(shell pwd)/YDB/install
ydb_gbldir=/tmp/lua-yottadb.gld

CFLAGS=-std=c99 -I$(ydb_dist) -I/usr/include/lua5.3 -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb #-Wl,rpath,YDB/install

_yottadb.so: _yottadb.c
	gcc -g $(CFLAGS) -shared -fPIC -o $@ $< $(LDFLAGS)

test:
	rm -f $(ydb_gbldir)
	source $(ydb_dist)/ydb_env_set && ydb_gbldir=$(ydb_gbldir) lua5.3 -l_yottadb -lyottadb tests/test.lua
