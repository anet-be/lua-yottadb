-- Config file for LDoc documentation tool
-- Builds .rst docs suitable to be included in the official YottaDB multi-language documentation
-- requires: luarocks install ldoc
-- usage: `ldoc . -c ydb.ld`

project = 'lua-yottadb'
ext = 'rst'
style = 'main' -- not actually referenced by yottadb-ydb.rst but skipping this overwrites the ldoc.css that is used for yottadb.html
template = 'ydb'
template_escape = '>'
dir = '..'
file = '../../yottadb.lua'
output = 'yottadb_ydb'
backtick_references = true
format = 'markdown'
sort = true

alias('example', 'usage')
custom_tags = {{'invocation', title='Invocation', hidden=true}}
