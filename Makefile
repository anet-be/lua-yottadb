# Copyright 2021-2022 Mitchell. See LICENSE.

SHELL:=/bin/bash

lua:=lua
lua_version:=$(shell LUA_INIT= $(lua) -e 'print(string.match(_VERSION, " ([0-9]+[.][0-9]+)"))')
#Find an existing Lua include path
ifneq (,$(wildcard /usr/include/lua*))
	lua_include:=/usr/include/lua$(lua_version)
else
	lua_include:=/usr/local/share/lua/$(lua_version)
endif

#Ensure tests use our own build of yottadb, not the system one
#Lua5.1 chokes on too many ending semicolons, so don't add them unless it's empty
LUA_PATH ?= ;;
LUA_CPATH ?= ;;
export LUA_PATH:=./?.lua;$(LUA_PATH)
export LUA_CPATH:=./?.so;$(LUA_CPATH)
export LUA_INIT:=

ydb_dist=$(shell pkg-config --variable=prefix yottadb --silence-errors)
ifeq (, $(ydb_dist))
ydb_dist=$(shell pwd)/YDB/install
endif

CC=gcc
CFLAGS=-g -O3 -fPIC -std=c11 -I$(ydb_dist) -I$(lua_include) -pedantic -Wall -Werror -Wno-unknown-pragmas -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb -Wl,-rpath,$(ydb_dist) -Wl,--gc-sections
SOURCES=yottadb.c callins.c cachearray.c compat-5.3/c-api/compat-5.3.c

all: _yottadb.so
_yottadb.so: $(SOURCES) yottadb.h callins.h cachearray.h exports.map Makefile
	$(CC) $(SOURCES) -o $@  -shared -Wl,--version-script=exports.map $(CFLAGS) $(LDFLAGS)
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

PREFIX=/usr/local
share_dir=$(PREFIX)/share/lua/$(lua_version)
lib_dir=$(PREFIX)/lib/lua/$(lua_version)
install: yottadb.lua _yottadb.so
	install -d $(DESTDIR)$(share_dir) $(DESTDIR)$(lib_dir)
	install _yottadb.so $(DESTDIR)$(lib_dir)
	install yottadb.lua $(DESTDIR)$(share_dir)

benchmark: benchmarks
benchmarks:
	source $(ydb_dist)/ydb_env_set && $(lua) tests/mroutine_benchmarks.lua

test: _yottadb.so
	source $(ydb_dist)/ydb_env_set && $(lua) tests/test.lua $(TESTS)
