--[[
  @description Go to track by name (accessible)
  @author Accessible ReaScripts contributors
  @version 1.1.1
  @provides [main] .
  @about
    Jump to a track by typing part of its name, instead of arrowing through
    the track list one at a time. In a forty-track session that is the
    difference between two keystrokes and a lot of counting.

    Search behaves like the rest of the collection: the whole name, several
    words in any order, a word from the middle, or the first letter of each
    word. You can also just type a track number.

    The chosen track becomes the only selected track, so whatever you do
    next lands on it. Nothing else about the project changes.
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

--- Read every track in the project.
local function collect()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr then
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
      local number = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'))
      out[#out + 1] = {
        track  = tr,
        number = number,
        name   = name,
        search = (name ~= '' and name) or 'unnamed',
      }
    end
  end
  return out
end

--- Rank the search. A query that is a whole number goes straight to that
--- number first; everything else is searched by name. Searching name and
--- number together used to let "3" put tracks 30 to 39 ahead of track 3,
--- and "piano 1" put track 12, Piano, ahead of track 3, Piano 1.
local function search(query, entries, name_of)
  local hits = a11y.filter(query, entries, name_of)
  local n = tonumber((query:gsub('^%s+', ''):gsub('%s+$', '')))
  if not n or n ~= math.floor(n) then return hits end
  local out, seen = {}, {}
  for _, e in ipairs(entries) do
    if e.number == n then out[#out + 1] = e; seen[e] = true end
  end
  for _, e in ipairs(hits) do
    if not seen[e] then out[#out + 1] = e end
  end
  return out
end

local function label(entry)
  return a11y.track_label(entry.number, entry.name)
end

local function main()
  local tracks = collect()
  if #tracks == 0 then
    a11y.abort('This project has no tracks.')
  end

  local query = a11y.prompt('Go to track', 'Search (blank lists all):',
                            a11y.recall('track_query', ''), 260)
  if query == nil then
    a11y.abort('Cancelled.')
  end

  local hits = search(query, tracks, function(t) return t.search end)
  if #hits == 0 then
    a11y.abort(string.format('Nothing matches %s. %s in this project.',
                             query, a11y.plural(#tracks, 'track')))
  end

  local chosen = a11y.pick('Go to track', hits, label)
  if chosen == nil then
    a11y.abort('Cancelled.')
  end

  a11y.remember('track_query', query)

  -- Selection is what every other action keys off, so replace the selection
  -- rather than adding to it. Adding would silently widen the target of
  -- whatever the user runs next, which is the sort of thing you only notice
  -- after it has happened.
  reaper.SetOnlyTrackSelected(chosen.track)
  reaper.SetMixerScroll(chosen.track)
  reaper.TrackList_AdjustWindows(false)

  -- Deliberately no Main_OnCommand to scroll the arrange view. That needs a
  -- numeric command ID, and a wrong ID runs some other action instead --
  -- silently, and possibly destructively. Nothing here can verify one from a
  -- terminal, so it is left out. Worth adding for anyone who can confirm the
  -- ID inside Reaper.

  a11y.speak(string.format('Track %s.', label(chosen)))
end

a11y.run(main)
