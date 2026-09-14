--[[
  @description Speak selected items (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    One keystroke and you hear what is actually selected: each item's name,
    the track it sits on, where it starts, how long it is, its fades, and
    anything applied to the active take that changes the sound — pitch
    shift, playback rate, reverse, mute, or a take other than the last one
    being active.

    Built for layered sound design work, where six items stacked across
    six tracks are one sound and you want to audit the whole stack by ear
    without arrowing through it item by item.

    This script only reads. It changes nothing.
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

-- How many items are described in full before the rest collapse into a
-- count. Beyond this a single utterance stops being reviewable.
local MAX_SPOKEN = 8

--- Seconds as speech: short times keep millisecond precision, longer ones
--- read as minutes and seconds. "0.250 seconds" matters for a fade;
--- "3 minutes 12 seconds" matters for an ambience bed.
local function time_phrase(seconds)
  if seconds < 60 then
    local s = string.format('%.3f', seconds)
    s = s:gsub('0+$', ''):gsub('%.$', '')
    return s .. ' seconds'
  end
  return a11y.duration_phrase(seconds)
end

--- Everything about one item worth hearing, as one sentence.
local function describe(item)
  local track = reaper.GetMediaItem_Track(item)
  local tracknum = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'))
  local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)

  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local fadein = reaper.GetMediaItemInfo_Value(item, 'D_FADEINLEN')
  local fadeout = reaper.GetMediaItemInfo_Value(item, 'D_FADEOUTLEN')
  local muted = reaper.GetMediaItemInfo_Value(item, 'B_MUTE') > 0

  local take = reaper.GetActiveTake(item)
  local name = 'empty item'
  if take then
    name = reaper.GetTakeName(take)
    if name == '' then name = 'unnamed' end
  end

  local parts = {}
  parts[#parts + 1] = string.format('%s on track %s', name,
                                    a11y.track_label(tracknum, trackname))
  parts[#parts + 1] = 'at ' .. reaper.format_timestr(pos, '')
  parts[#parts + 1] = time_phrase(len) .. ' long'

  -- Fades are only worth words when they exist.
  if fadein > 0.0005 then
    parts[#parts + 1] = 'fade in ' .. time_phrase(fadein)
  end
  if fadeout > 0.0005 then
    parts[#parts + 1] = 'fade out ' .. time_phrase(fadeout)
  end

  if take then
    local pitch = reaper.GetMediaItemTakeInfo_Value(take, 'D_PITCH')
    local rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    if math.abs(pitch) > 0.001 then
      parts[#parts + 1] = string.format('pitched %+.2f semitones', pitch)
    end
    if math.abs(rate - 1.0) > 0.001 then
      parts[#parts + 1] = string.format('rate %.3f', rate)
    end
    local takes = reaper.CountTakes(item)
    if takes > 1 then
      local active = math.floor(reaper.GetMediaItemInfo_Value(item, 'I_CURTAKE')) + 1
      parts[#parts + 1] = string.format('take %d of %d', active, takes)
    end
  end

  if muted then parts[#parts + 1] = 'muted' end

  return table.concat(parts, ', ')
end

local function main()
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    a11y.abort('No items selected.')
  end

  local lines = {}
  local shown = math.min(count, MAX_SPOKEN)
  for i = 0, shown - 1 do
    lines[#lines + 1] = describe(reaper.GetSelectedMediaItem(0, i))
  end

  local head = a11y.plural(count, 'item selected', 'items selected') .. '. '
  local tail = ''
  if count > shown then
    tail = string.format(' And %d more not spoken.', count - shown)
  end
  a11y.speak(head .. table.concat(lines, '. ') .. '.' .. tail)
end

a11y.run(main)
