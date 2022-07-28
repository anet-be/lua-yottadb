# Copyright 2021-2022 Mitchell. See LICENSE.

SHELL:=/bin/bash

ydb_dist=$(shell pkg-config --variable=prefix yottadb --silence-errors)
ifeq (, $(ydb_dist))
ydb_dist=$(shell pwd)/YDB/install
endif
ydb_gbldir=/tmp/lua-yottadb.gld

CFLAGS=-std=c99 -I$(ydb_dist) -I/usr/include/lua5.3 -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb #-Wl,rpath,YDB/install

_yottadb.so: _yottadb.c
	gcc -g $(CFLAGS) -shared -fPIC -o $@ $< $(LDFLAGS)

PREFIX=/usr/local
share_dir=$(PREFIX)/share/lua/5.3
lib_dir=$(PREFIX)/lib/lua/5.3
install: yottadb.lua _yottadb.so
	install -d $(DESTDIR)$(share_dir) $(DESTDIR)$(lib_dir)
	install _yottadb.so $(DESTDIR)$(lib_dir)
	install yottadb.lua $(DESTDIR)$(share_dir)

clean:
	rm *.so

test:
	rm -f $(ydb_gbldir)
	source $(ydb_dist)/ydb_env_set && ydb_gbldir=$(ydb_gbldir) lua -l_yottadb -lyottadb tests/test.lua $(TESTS)
