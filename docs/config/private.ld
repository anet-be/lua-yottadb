-- Config file for LDoc documentation tool
-- requires: luarocks install ldoc
-- usage: `ldoc . -c private.ld`

project = 'lua-yottadb (private functions)'
style = 'main'
template = 'main'
dir = '..'
file = {'../../yottadb.c', '../../callins.c', '../../cachearray.c'}
output = 'yottadb_c'
backtick_references = true
format = 'markdown'
sort = false
merge = true
--readme = 'README.md' -- ldoc's rendering isn't very pretty so instead link to README.md on github
--examples = 'examples'  -- ldoc doesn't support .ci and .m files so examples are instead links to github

alias('example', 'usage')
custom_tags = {{'invocation', title='Invocation', hidden=true}}
