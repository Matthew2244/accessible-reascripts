--[[
  @description What would you like to do (accessible menu)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    The front door to the whole collection. Bind this one script to one
    keystroke and forget every other shortcut: it asks what you would like
    to do, finds the script that does it, and runs it — and that script
    then asks its own questions, exactly as if you had run it directly.

    Type a few words of what you want ("fades", "reverb bus", "insert a
    sound") and the matches are spoken as a numbered list. Leave the box
    blank to browse instead: first the categories, then the scripts in the
    one you pick, so nothing is ever more than two short lists away.

    The menu discovers scripts from the folders on disk, so anything added
    to the collection later shows up here with no changes to this file.
]]

local script_dir = ({ reaper.get_action_context() })[2]:match('^(.*[\\/])')
package.path = script_dir .. '../Lib/?.lua;' .. package.path
local loaded, a11y = pcall(require, 'a11y')
if not loaded then
  local m = 'Accessible ReaScripts: could not load the shared library Lib/a11y.lua. ' ..
            'Make sure the Lib folder sits next to the script folders.'
  if reaper.osara_outputMessage then reaper.osara_outputMessage(m) end
  reaper.ShowMessageBox(m, 'Accessible ReaScripts', 0)
  return
end

--------------------------------------------------------------------------

-- Folders that hold no runnable scripts, and this script's own name --
-- a menu that offers to open itself is a hall of mirrors.
local SKIP_DIRS = { Lib = true, tools = true }
local SELF_NAME = ({ reaper.get_action_context() })[2]:match('([^\\/]+)$')

--- The repository root: one level up from the folder this script sits in.
local function repo_root()
  return script_dir:gsub('[^\\/]+[\\/]$', '')
end

--- Read a script's header comment, for search text. A script is findable
--- by anything its author wrote about it -- "reverb" finds the send bus
--- script because its description mentions reverb -- not just its name.
local function header_text(path)
  local f = io.open(path, 'r')
  if not f then return '' end
  local text = f:read(4096) or ''
  f:close()
  local block = text:match('%-%-%[%[(.-)%]%]')
  return (block or ''):lower()
end

--- Every runnable script in the collection, grouped and searchable.
local function collect()
  local root = repo_root()
  local scripts, categories, by_category = {}, {}, {}

  reaper.EnumerateSubdirectories(root, -1)
  local d = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(root, d)
    if not sub then break end
    if not SKIP_DIRS[sub] and sub:sub(1, 1) ~= '.' then
      local dir = a11y.path_join(root:gsub('[\\/]$', ''), sub)
      reaper.EnumerateFiles(dir, -1)
      local i = 0
      while true do
        local f = reaper.EnumerateFiles(dir, i)
        if not f then break end
        if f:match('^a11y_.*%.lua$') and f ~= SELF_NAME then
          local name = f:gsub('^a11y_', ''):gsub('%.lua$', '')
          local path = a11y.path_join(dir, f)
          local entry = {
            name = name,
            category = sub,
            path = path,
            corpus = (name .. ' ' .. sub):lower() .. ' ' .. header_text(path),
          }
          scripts[#scripts + 1] = entry
          if not by_category[sub] then
            by_category[sub] = {}
            categories[#categories + 1] = sub
          end
          local cat = by_category[sub]
          cat[#cat + 1] = entry
        end
        i = i + 1
      end
    end
    d = d + 1
  end

  table.sort(categories)
  table.sort(scripts, function(a, b) return a.name < b.name end)
  for _, list in pairs(by_category) do
    table.sort(list, function(a, b) return a.name < b.name end)
  end
  return scripts, categories, by_category
end

--- Browse: pick a category, then a script inside it.
local function browse(categories, by_category)
  local cat = a11y.pick('Choose a category', categories, function(c)
    return string.format('%s, %s', c, a11y.plural(#by_category[c], 'script'))
  end)
  if not cat then
    a11y.abort('Cancelled. Nothing was run.')
  end
  local entry = a11y.pick(cat, by_category[cat], function(e) return e.name end)
  if not entry then
    a11y.abort('Cancelled. Nothing was run.')
  end
  return entry
end

local function main()
  local scripts, categories, by_category = collect()
  if #scripts == 0 then
    a11y.abort('No scripts were found next to the menu. The category folders ' ..
               'should sit beside the Menu folder this script lives in.')
  end

  -- No comma in the caption: GetUserInputs treats commas as field
  -- separators, and would silently cut the caption short.
  local query = a11y.prompt('What would you like to do?',
                            'A few words (blank to browse):', '', 80)
  if query == nil then
    a11y.abort('Cancelled. Nothing was run.')
  end
  query = query:gsub('^%s+', ''):gsub('%s+$', '')

  local entry
  if query == '' then
    entry = browse(categories, by_category)
  else
    local matches = a11y.filter(query, scripts, function(e) return e.corpus end)
    if #matches == 0 then
      a11y.speak(string.format('Nothing here does "%s" yet. Browsing instead.', query))
      entry = browse(categories, by_category)
    else
      entry = a11y.pick('What would you like to do?', matches,
                        function(e) return e.name end)
      if not entry then
        a11y.abort('Cancelled. Nothing was run.')
      end
    end
  end

  -- Hand over to the chosen script. It asks its own questions and speaks
  -- its own outcome; from here on it behaves exactly as if it had been
  -- bound to a key of its own.
  local ok, err = pcall(dofile, entry.path)
  if not ok then
    if type(err) == 'table' and err.a11y_abort then return end
    a11y.abort(string.format('%s stopped with an error: %s', entry.name,
                             tostring(err)))
  end
end

a11y.run(main)
