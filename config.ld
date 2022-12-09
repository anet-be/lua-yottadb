-- Config file for LDoc documentation tool
-- requires: luarocks install ldoc
-- usage: `ldoc .` from the config.ld directory

project = 'lua-yottadb'
style = 'docs/config'
template = 'docs/config'
dir = 'docs'
file = 'yottadb.lua'
output = 'yottadb'
backtick_references = true
format = 'markdown'
sort = true
--readme = 'README.md'
