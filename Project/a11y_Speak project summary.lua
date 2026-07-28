--[[
  @description Speak project summary (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Speaks an overview of the current project in one keystroke: name and
    save state, tempo and time signature, length, track and item counts,
    markers and regions, and -- the part that is genuinely hard to notice
    by ear -- how many items point at media files that are missing from
    disk.

    Nothing is changed. This script only reads.

    Handy in a custom action after "File: Save new version of project",
    so you hear which version you have just landed on.
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

-- Checking every item's source file is the slow part of this script. Many
-- items share one source, so each unique path is stat-ed once.
local MAX_ITEMS_CHECKED = 20000

local function project_file()
  local _, path = reaper.EnumProjects(-1)
  if path == nil or path == '' then return nil end
  return path
end

--- Split "song_003.RPP" into "song" and 3. Version is nil when the name
--- carries no numeric suffix.
local function name_and_version(path)
  local base = a11y.basename(path, true)
  local stem, version = base:match('^(.-)_(%d+)$')
  if stem then return stem, tonumber(version) end
  return base, nil
end

--- Count items whose media file is absent from disk.
-- @return missing_count, checked_count, example_name
local function missing_media()
  local total = reaper.CountMediaItems(0)
  local checked = math.min(total, MAX_ITEMS_CHECKED)
  local seen, missing, example = {}, 0, nil

  for i = 0, checked - 1 do
    local item = reaper.GetMediaItem(0, i)
    local take = item and reaper.GetActiveTake(item)
    -- In-project MIDI has no file on disk and is not "missing".
    if take and not reaper.TakeIsMIDI(take) then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local path = reaper.GetMediaSourceFileName(src, '')
        if path and path ~= '' then
          local known = seen[path]
          if known == nil then
            known = reaper.file_exists(path)
            seen[path] = known
          end
          if not known then
            missing = missing + 1
            if example == nil then example = a11y.basename(path) end
          end
        end
      end
    end
  end
  return missing, checked, example
end

local function marker_and_region_counts()
  local total, markers, regions = reaper.CountProjectMarkers(0)
  -- CountProjectMarkers already returns both counts; fall back to walking
  -- the list if an older build returns only the total.
  if markers ~= nil and regions ~= nil then return markers, regions end
  local m, r = 0, 0
  for i = 0, (total or 0) - 1 do
    local ok, isrgn = reaper.EnumProjectMarkers3(0, i)
    if ok and ok ~= 0 then
      if isrgn then r = r + 1 else m = m + 1 end
    end
  end
  return m, r
end

local function main()
  local parts = {}

  -- Name, version, save state.
  local path = project_file()
  if path == nil then
    parts[#parts + 1] = 'Unsaved project, never saved to disk'
  else
    local name, version = name_and_version(path)
    local label = name
    if version then label = label .. ', version ' .. version end
    if reaper.IsProjectDirty(0) == 1 then
      label = label .. ', unsaved changes'
    else
      label = label .. ', saved'
    end
    parts[#parts + 1] = label
  end

  -- Tempo and time signature at the edit cursor, which is what you are
  -- actually working against.
  local cursor = reaper.GetCursorPosition()
  local num, denom, tempo = reaper.TimeMap_GetTimeSigAtTime(0, cursor)
  if tempo and num and denom then
    parts[#parts + 1] = string.format('%g BPM, %d/%d', tempo, num, denom)
  end

  -- Size.
  parts[#parts + 1] = a11y.duration_phrase(reaper.GetProjectLength(0)) .. ' long'

  local tracks = reaper.CountTracks(0)
  local selected = reaper.CountSelectedTracks(0)
  local track_part = a11y.plural(tracks, 'track')
  if selected > 0 then track_part = track_part .. ', ' .. selected .. ' selected' end
  parts[#parts + 1] = track_part

  parts[#parts + 1] = a11y.plural(reaper.CountMediaItems(0), 'item')

  local markers, regions = marker_and_region_counts()
  if markers > 0 or regions > 0 then
    local bits = {}
    if markers > 0 then bits[#bits + 1] = a11y.plural(markers, 'marker') end
    if regions > 0 then bits[#bits + 1] = a11y.plural(regions, 'region') end
    parts[#parts + 1] = a11y.list_phrase(bits)
  else
    parts[#parts + 1] = 'no markers or regions'
  end

  -- The warning worth leading the ear to: say it last so it is the thing
  -- left ringing, and only say anything at all when there is a problem.
  local missing, checked, example = missing_media()
  if missing > 0 then
    local warn = string.format('Warning, %s with missing media',
                               a11y.plural(missing, 'item'))
    if example then warn = warn .. ', for example ' .. example end
    if checked < reaper.CountMediaItems(0) then
      warn = warn .. string.format(' (first %d items checked)', checked)
    end
    parts[#parts + 1] = warn
  end

  a11y.speak(table.concat(parts, '. ') .. '.')
end

a11y.run(main)
