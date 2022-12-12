# Copyright 2021-2022 Mitchell. See LICENSE.

SHELL:=/bin/bash

lua:=lua
lua_version:=$(shell $(lua) -e 'print(string.match(_VERSION, " ([0-9]+[.][0-9]+)"))')
lua_include=/usr/include/lua$(lua_version)

#Ensure tests use our own build of yottadb, not the system one
export LUA_PATH:=./?.lua;$(LUA_PATH);;
export LUA_CPATH:=./?.so;$(LUA_CPATH);;

ydb_dist=$(shell pkg-config --variable=prefix yottadb --silence-errors)
ifeq (, $(ydb_dist))
ydb_dist=$(shell pwd)/YDB/install
endif

CC=gcc
CFLAGS=-std=c99 -I$(ydb_dist) -I$(lua_include) -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb -Wl,-rpath,$(ydb_dist)

_yottadb.so: _yottadb.c
	$(CC) -g $(CFLAGS) -shared -fPIC -o $@ $< $(LDFLAGS)

%: %.c
	$(CC) -g $(CFLAGS) -o $@ $< $(LDFLAGS)

# Requires: 'luarocks install ldoc'
docs: docs/yottadb.html
docs/yottadb.html: *.lua *.c config.ld docs/config/*
	ldoc .

clean:
	rm -f *.so
	rm -f docs/*.css docs/*.html

PREFIX=/usr/local
share_dir=$(PREFIX)/share/lua/
lib_dir=$(PREFIX)/lib/lua/$(lua_version)
install: yottadb.lua _yottadb.so
	install -d $(DESTDIR)$(share_dir) $(DESTDIR)$(lib_dir)
	install _yottadb.so $(DESTDIR)$(lib_dir)
	install yottadb.lua $(DESTDIR)$(share_dir)

test: _yottadb.so
	source $(ydb_dist)/ydb_env_set && $(lua) -l_yottadb -lyottadb tests/test.lua $(TESTS)
