-- Config file for LDoc documentation tool
-- requires: luarocks install ldoc
-- usage: `ldoc .` from the config.ld directory

project = 'lua-yottadb'
title = 'lua-yottadb documentation'
description = 'Access yottadb data and routines from Lua'

style = 'docs/config'
template = 'docs/config'
dir = 'docs'
file = 'yottadb.lua'
output = 'yottadb'
backtick_references = true
format = 'markdown'
--no_summary = true
--readme = 'README.md'
