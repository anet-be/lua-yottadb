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
--readme = 'README.md' -- ldoc's rendering isn't very pretty so just link to README.md on github
--examples = 'examples'  -- ldoc doesn't support .ci and .m files so just link examples to github
