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

PREFIX:=/usr/local
# Determine whether make was called from luarocks using the --local flag (or a prefix within user's $HOME directory)
# If so, put mlua.so and mlua.xc files into a local directory
local:=$(shell echo "$(LUAROCKS_PREFIX)" | grep -q "^$(HOME)" && echo 1)
ifeq ($(local),1)
  PREFIX:=$(LUAROCKS_PREFIX)
endif

#Ensure tests use our own build of yottadb, not the system one
#Lua5.1 chokes on too many ending semicolons, so don't add them unless it's empty
LUA_PATH ?= ;;
LUA_CPATH ?= ;;
export LUA_PATH:=./?.lua;$(LUA_PATH)
export LUA_CPATH:=./?.so;$(LUA_CPATH)
export LUA_INIT:=

ydb_dist?=$(shell pkg-config --variable=prefix yottadb --silence-errors)
ifeq (, $(ydb_dist))
ydb_dist=$(shell pwd)/YDB/install
endif

CC=gcc
CFLAGS=-g -O3 -fPIC -std=c11 -I$(ydb_dist) -I$(lua_include) -pedantic -Wall -Werror -Wextra -Wno-cast-function-type -Wno-unknown-pragmas -Wno-discarded-qualifiers
LDFLAGS=-L$(ydb_dist) -lyottadb -Wl,-rpath,$(ydb_dist) -Wl,--gc-sections
SOURCES=yottadb.c callins.c cachearray.c compat-5.3/c-api/compat-5.3.c

all: _yottadb.so
_yottadb.so: $(SOURCES) yottadb.h callins.h cachearray.h exports.map Makefile
	$(CC) $(SOURCES) -o $@  -shared -Wl,--version-script=exports.map $(CFLAGS) $(LDFLAGS)
%: %.c _yottadb.so
	$(CC) $<  -o $@  $(CFLAGS) $(LDFLAGS)  -llua -lm -l:_yottadb.so -L.

# Requires: 'luarocks install ldoc'
DOC_DEPS = *.lua *.c docs/config/* Makefile
docs: docs/yottadb.html docs/yottadb_c.html docs/lua-yottadb-ydbdocs.rst
docs/yottadb.html: $(DOC_DEPS)
	@echo
	@echo "Making yottadb.html"
	ldoc . -c docs/config/main.ld
docs/yottadb_c.html: $(DOC_DEPS)
	@echo
	@echo "Making yottadb_private.html"
	ldoc . -c docs/config/private.ld
docs/lua-yottadb-ydbdocs.rst: $(DOC_DEPS)
	@echo
	@echo "Making docs for YDB manual yottadb_ydb.rst"
	ldoc . -c docs/config/ydb.ld
	@echo "Alert: Be sure to test lua-yottadb-ydbdocs.rst by cloning YDBDoc and running 'make html': it is included by YDBDoc/MultiLangProgGuide/luaprogram.rst"
	@echo

# ~~~ Release a new version and create luarock

#Fetch lua-yottadb version from yottadb.h. You can override this with "VERSION=x.y-z" to regenerate a specific rockspec
VERSION=$(shell sed -Ene 's/#define LUA_YOTTADB_VERSION ([0-9]+),([0-9]+).*/\1.\2-1/p' yottadb.h)
tag=v$(shell echo $(VERSION) | grep -Eo '[0-9]+.[0-9]+')

# Prevent git from giving detachedHead warning during `luarocks pack`
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=advice.detachedHead
export GIT_CONFIG_VALUE_0=false

rockspec: rockspecs/lua-yottadb.rockspec.template
	@echo Creating lua-yottadb rockspec $(VERSION)
	sed -Ee "s/(version += +['\"]).*(['\"].*)/\1$(VERSION)\2/" rockspecs/lua-yottadb.rockspec.template >rockspecs/lua-yottadb-$(VERSION).rockspec
release: rockspec
	git add rockspecs/lua-yottadb-$(VERSION).rockspec
	@git diff --quiet || { echo "Commit changes to git first"; exit 1; }
	@echo
	@read -p "About to push lua-yottadb git tag $(tag) with rockspec $(VERSION). Continue (y/n)? " -n1 && echo && [ "$$REPLY" = "y" ]
	@git merge-base --is-ancestor HEAD master@{upstream} || { echo "Push changes to git first"; exit 1; }
	rm -f tests/*.o  # Don't add these to the rock
	luarocks make --local  # test that basic make works first
	! git tag -n $(tag) | grep -q ".*" || { echo "Tag $(tag) already exists. Run 'make untag' to remove the git tag first"; exit 1; }
	git tag -a $(tag)
	git push origin $(tag)
	git remote -v | grep "^upstream" && git push upstream $(tag)
	luarocks pack rockspecs/lua-yottadb-$(VERSION).rockspec
	luarocks upload $(LRFLAGS) rockspecs/lua-yottadb-$(VERSION).rockspec \
		|| { echo "Try 'make release LRFLAGS=--api-key=<key>'"; exit 2; }
untag:
	git tag -d $(tag)
	git push -d origin $(tag)
	git remote -v | grep "^upstream" && git push -d upstream $(tag)

listing: _yottadb.so
	objdump -Mintel -rRwS _yottadb.so >_yottadb.lst

clean:
	rm -f *.so *.o *.lst lua-yottadb-*.rock

share_dir=$(PREFIX)/share/lua/$(lua_version)
lib_dir=$(PREFIX)/lib/lua/$(lua_version)
install: yottadb.lua _yottadb.so
	install -d $(share_dir) $(lib_dir)
	install _yottadb.so $(lib_dir)
	install yottadb.lua $(share_dir)

benchmark: benchmarks
benchmarks:
	source $(ydb_dist)/ydb_env_set && $(lua) tests/mroutine_benchmarks.lua

test: _yottadb.so
	source $(ydb_dist)/ydb_env_set && $(lua) tests/test.lua $(TESTS)

.PHONY: all docs listing clean install benchmark benchmarks test
.PHONY: rockspec release untag
