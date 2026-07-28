--[[
  @description Insert track template by name (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Type part of a track template's name and insert it, instead of arrowing
    through Reaper's Track Templates submenu.

    Search is forgiving. Any of these find "keyscape rhodes suitcase":
      keyscape rhodes suitcase   (the whole name)
      rhodes suit                (several words, any order)
      suitcase                   (a word from the middle)
      krs                        (first letters of each word)

    An exact name always wins, so searching "piano 1" inserts "piano 1"
    and not "piano 1 gospel".

    If more than one template matches, the matches are spoken as a
    numbered list and you type the number you want.

    The whole insert is one undo step.
]]

--------------------------------------------------------------------------
-- Load the shared library.
--------------------------------------------------------------------------
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

local TEMPLATE_EXT = '.RTrackTemplate'

--- Snapshot every track's GUID. Used to work out exactly which tracks the
--- template added -- Reaper inserts relative to the selection, so we cannot
--- assume the new tracks are at the end.
local function track_guids()
  local set = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    set[reaper.GetTrackGUID(reaper.GetTrack(0, i))] = true
  end
  return set
end

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then
    return 'unnamed track'
  end
  return name
end

local function main()
  local dir = a11y.path_join(reaper.GetResourcePath(), 'TrackTemplates')

  local templates = a11y.scan_files(dir, TEMPLATE_EXT)
  if #templates == 0 then
    a11y.abort('No track templates found in ' .. dir ..
               '. Save one first with Track, save tracks as track template.')
  end

  local query = a11y.prompt('Insert track template',
                            'Search (blank lists all):',
                            a11y.recall('template_query', ''), 260)
  if query == nil then
    a11y.abort('Cancelled.')
  end

  local hits = a11y.filter(query, templates, function(t) return t.name end)
  if #hits == 0 then
    a11y.abort(string.format('No track template matches %s. %s available.',
                             query, a11y.plural(#templates, 'template')))
  end

  local chosen = a11y.pick('Insert track template', hits,
                           function(t) return t.name end)
  if chosen == nil then
    a11y.abort('Cancelled.')
  end

  a11y.remember('template_query', query)

  -- Insert. Reaper's own loader handles GUIDs, folder depth, routing and
  -- envelopes, which hand-built chunk insertion would get wrong on the
  -- multi-track templates that contain sends.
  --
  -- Note: no 'noprompt:' prefix. It is tempting, but it also suppresses the
  -- save prompt when Reaper decides to *open* something as a project. If a
  -- path is ever misread, a prompt is recoverable and silent data loss is not.
  local before = track_guids()
  local before_count = reaper.CountTracks(0)

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  reaper.Main_openProject(chosen.path)
  reaper.Undo_EndBlock('Insert track template: ' .. chosen.name, -1)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local added = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if not before[reaper.GetTrackGUID(tr)] then
      added[#added + 1] = { track = tr, index = i + 1 }
    end
  end

  if #added == 0 then
    -- Do not pretend this worked. Say so plainly, with enough detail to
    -- report as a bug.
    a11y.abort(string.format(
      'Reaper did not insert %s. Track count is still %d. The file may be ' ..
      'damaged, or this Reaper version may handle track templates differently.',
      chosen.name, before_count))
  end

  -- Leave exactly the new tracks selected, so the next thing you do lands
  -- on them without any extra navigation.
  reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
  for _, rec in ipairs(added) do
    reaper.SetTrackSelected(rec.track, true)
  end

  local first = added[1]
  if #added == 1 then
    a11y.speak(string.format('Inserted %s. Track %d, %s.',
                             chosen.name, first.index, track_name(first.track)))
  else
    a11y.speak(string.format('Inserted %s. %s, starting at track %d, %s. All selected.',
                             chosen.name, a11y.plural(#added, 'track'),
                             first.index, track_name(first.track)))
  end
end

a11y.run(main)
