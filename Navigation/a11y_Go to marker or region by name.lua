--[[
  @description Go to marker or region by name (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Jump to a marker or region by typing part of its name, rather than
    stepping through them one at a time.

    Search behaves like the track template script: whole name, several
    words in any order, a word from the middle, or the first letters of
    each word. You can also just type a marker's number.

    Choosing a region sets the time selection to that region as well as
    moving the edit cursor, so you can immediately play or render it.
    Markers only move the cursor.
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

--- Read every marker and region in the project.
local function collect()
  local out = {}
  local total = reaper.CountProjectMarkers(0)
  for i = 0, (total or 0) - 1 do
    local ok, isrgn, pos, rgnend, name, number = reaper.EnumProjectMarkers3(0, i)
    if ok and ok ~= 0 then
      local display = (name ~= nil and name ~= '') and name
                      or ((isrgn and 'region ' or 'marker ') .. tostring(number))
      out[#out + 1] = {
        is_region = isrgn and true or false,
        pos       = pos,
        rgnend    = rgnend,
        name      = display,
        number    = number,
        -- Searchable text includes the number, so typing "12" finds
        -- marker 12 even when it has a name.
        search    = display .. ' ' .. tostring(number),
      }
    end
  end
  return out
end

local function label(entry)
  local kind = entry.is_region and 'region' or 'marker'
  if entry.is_region then
    return string.format('%s %d, %s, %s long', kind, entry.number, entry.name,
                         a11y.duration_phrase(entry.rgnend - entry.pos))
  end
  return string.format('%s %d, %s', kind, entry.number, entry.name)
end

local function main()
  local entries = collect()
  if #entries == 0 then
    a11y.abort('This project has no markers or regions.')
  end

  local query = a11y.prompt('Go to marker or region',
                            'Search (blank lists all):',
                            a11y.recall('marker_query', ''), 260)
  if query == nil then
    a11y.abort('Cancelled.')
  end

  local hits = a11y.filter(query, entries, function(e) return e.search end)
  if #hits == 0 then
    a11y.abort(string.format('Nothing matches %s. %s in this project.',
                             query, a11y.plural(#entries, 'marker or region',
                                                'markers and regions')))
  end

  local chosen = a11y.pick('Go to marker or region', hits, label)
  if chosen == nil then
    a11y.abort('Cancelled.')
  end

  a11y.remember('marker_query', query)

  -- Move the cursor, and for a region select its span too so the next
  -- action (play, loop, render) already has the right range.
  reaper.SetEditCurPos(chosen.pos, true, true)
  if chosen.is_region then
    reaper.GetSet_LoopTimeRange(true, false, chosen.pos, chosen.rgnend, false)
    a11y.speak(string.format('%s. Cursor and time selection set.', label(chosen)))
  else
    a11y.speak(string.format('%s.', label(chosen)))
  end
end

a11y.run(main)
