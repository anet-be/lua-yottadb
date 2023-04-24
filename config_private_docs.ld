-- Config file for LDoc documentation tool
-- requires: luarocks install ldoc
-- usage: `ldoc . -c config_private.ld` from the config.ld directory

project = 'lua-yottadb (private functions)'
style = 'docs/config'
template = 'docs/config'
dir = 'docs'
file = {'yottadb.c', 'callins.c', 'cachearray.c'}
output = 'yottadb_c'
backtick_references = true
format = 'markdown'
sort = false
merge = true
--readme = 'README.md' -- ldoc's rendering isn't very pretty so just link to README.md on github
--examples = 'examples'  -- ldoc doesn't support .ci and .m files so just link examples to github
