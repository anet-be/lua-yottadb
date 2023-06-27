-- Config file for LDoc documentation tool
-- Builds docs suitable to be included in the official YottaDB multi-language documentation
-- requires: luarocks install ldoc
-- usage: `ldoc . -c ydb.ld`

project = 'lua-yottadb'
ext = 'MD'
template = 'ydb2'
template_escape = '>'  -- this is normally done automatically by ext = 'md', but that trumps output, so we use ext = 'MD'
dir = '..'
file = '../../yottadb.lua'
output = 'yottadb_ydb'
backtick_references = true
format = 'markdown'
sort = true
