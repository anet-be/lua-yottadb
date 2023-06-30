-- Config file for LDoc documentation tool
-- requires: luarocks install ldoc
-- usage: `ldoc . -c main.ld`

project = 'lua-yottadb'
style = 'main'
template = 'main'
dir = '..'
file = '../../yottadb.lua'
output = 'yottadb'
backtick_references = true
format = 'markdown'
sort = true
--readme = 'README.md' -- ldoc's rendering isn't very pretty so instead link to README.md on github
--examples = 'examples'  -- ldoc doesn't support .ci and .m files so examples are instead links to github

alias('example', 'usage')
custom_tags = {{'invocation', title='Invocation', hidden=true}}
