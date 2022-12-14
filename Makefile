# Copyright 2021-2022 Mitchell. See LICENSE.

SHELL:=/bin/bash

lua:=lua
lua_version:=$(shell $(lua) -e 'print(string.match(_VERSION, " ([0-9]+[.][0-9]+)"))')
#Find an existing Lua include path
ifneq (,$(wildcard /usr/include/lua/))
	lua_include:=/usr/include/lua$(lua_version)
else
	lua_include:=/usr/local/share/lua/$(lua_version)
endif

#Ensure tests use our own build of yottadb, not the system one
export LUA_PATH:=./?.lua;$(LUA_PATH);;
export LUA_CPATH:=./?.so;$(LUA_CPATH);;

ydb_dist=$(shell pkg-config --variable=prefix yottadb --silence-errors)
ifeq (, $(ydb_dist))
ydb_dist=$(shell pwd)/YDB/install
endif

CC=gcc
CFLAGS=-g -fPIC -std=c11 -I$(ydb_dist) -I$(lua_include) -pedantic -Wall -Wno-unknown-pragmas -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb -Wl,-rpath,$(ydb_dist)

_yottadb.so: yottadb.c yottadb.h callins.c callins.h exports.map
	$(CC) yottadb.c callins.c  -o $@  -shared -Wl,--version-script=exports.map $(CFLAGS) $(LDFLAGS)
%: %.c
	$(CC) $<  -o $@  $(CFLAGS) $(LDFLAGS)
%.o: %.c
	$(CC) $<  -o $@  -c $(CFLAGS) $(LDFLAGS)

# Requires: 'luarocks install ldoc'
docs: docs/yottadb.html
docs/yottadb.html: *.lua *.c config.ld docs/config/*
	ldoc .

clean:
	rm -f *.so *.o
	rm -f docs/*.css docs/*.html

PREFIX=/usr/local
share_dir=$(PREFIX)/share/lua/$(lua_version)
lib_dir=$(PREFIX)/lib/lua/$(lua_version)
install: yottadb.lua _yottadb.so
	install -d $(DESTDIR)$(share_dir) $(DESTDIR)$(lib_dir)
	install _yottadb.so $(DESTDIR)$(lib_dir)
	install yottadb.lua $(DESTDIR)$(share_dir)

test: _yottadb.so
	source $(ydb_dist)/ydb_env_set && LUA_INIT= $(lua) -l_yottadb -lyottadb tests/test.lua $(TESTS)
