#

SHELL:=/bin/bash

ydb_dist=$(shell pwd)/YDB/install
ydb_gbldir=/tmp/lua-yottadb.gld

CFLAGS=-std=c99 -IYDB/install -I/usr/include/lua5.3 -Wno-discarded-qualifiers
LDFLAGS=-LYDB/install -lyottadb #-Wl,rpath,YDB/install

_yottadb.so: _yottadb.c
	gcc -g $(CFLAGS) -shared -fPIC -o $@ $< $(LDFLAGS)

test:
	rm -f $(ydb_gbldir)
	source $(ydb_dist)/ydb_env_set && ydb_gbldir=$(ydb_gbldir) lua5.3 -l_yottadb tests/test.lua
