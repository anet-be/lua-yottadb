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

-- format @deprecated tag
custom_display_name_handler = function(item, default_handler)
  if item.tags.deprecated then
    return default_handler(item) .. ('  [deprecated %s]:'):format(item.tags.deprecated[1])
  end
  return default_handler(item)
end

alias('example', 'usage')
custom_tags = {
    {'invocation', title='Invocation', hidden=true},
    {'deprecated', title='Deprecated', hidden=true},
}
