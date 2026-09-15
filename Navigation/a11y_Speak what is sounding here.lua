--[[
  @description Speak what is sounding here (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Answers the question a waveform answers for everyone else: what is
    actually under the cursor, right now, on every track at once.

    For each track with something playing at the edit cursor you hear the
    track, the item, how far into it you are and how much of it is left.
    Muted tracks and muted items are named as muted rather than left out,
    because "nothing here" and "here but silent" are different problems.

    Written after two days of sound design work in which four files turned
    out to contain something other than what their names said. A name can
    lie. What is under the cursor cannot.

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

-- Past this many tracks at once the sentence stops being reviewable, so
-- the rest become a count. Eight is roughly a breath.
local MAX_SPOKEN = 8

--- One track's worth of "what is here", or nil when nothing is.
local function at_cursor(track, pos)
  local count = reaper.CountTrackMediaItems(track)
  for i = 0, count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    -- Items are in time order, so once one starts after the cursor
    -- nothing later can contain it.
    if start > pos then break end
    if pos < start + length then
      local take = reaper.GetActiveTake(item)
      local name = 'empty item'
      if take then
        name = reaper.GetTakeName(take)
        if name == '' then name = 'unnamed item' end
      end
      return {
        name = name,
        into = pos - start,
        left = (start + length) - pos,
        muted = reaper.GetMediaItemInfo_Value(item, 'B_MUTE') > 0,
      }
    end
  end
  return nil
end

local function main()
  local pos = reaper.GetCursorPosition()
  local tracks = reaper.CountTracks(0)
  if tracks == 0 then
    a11y.abort('This project has no tracks yet.')
  end

  local here, silent = {}, 0
  for i = 0, tracks - 1 do
    local track = reaper.GetTrack(0, i)
    local found = at_cursor(track, pos)
    if found then
      local number = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'))
      local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
      local muted = found.muted or reaper.GetMediaTrackInfo_Value(track, 'B_MUTE') > 0
      if muted then silent = silent + 1 end
      here[#here + 1] = {
        label = a11y.track_label(number, trackname),
        name = found.name,
        into = found.into,
        left = found.left,
        muted = muted,
      }
    end
  end

  local when = reaper.format_timestr(pos, '')

  if #here == 0 then
    a11y.speak('Nothing is sounding at ' .. when .. '. ' ..
               a11y.plural(tracks, 'track') .. ', all quiet here.')
    return
  end

  local lines = {}
  local shown = math.min(#here, MAX_SPOKEN)
  for i = 1, shown do
    local h = here[i]
    local line = string.format('%s, %s, %s in with %s left',
                               h.label, h.name,
                               a11y.time_phrase(h.into),
                               a11y.time_phrase(h.left))
    if h.muted then line = line .. ', muted' end
    lines[#lines + 1] = line
  end

  local head = string.format('At %s, %s sounding. ', when,
                             a11y.plural(#here, 'track'))
  local tail = ''
  if #here > shown then
    tail = string.format(' And %d more not spoken.', #here - shown)
  end
  if silent > 0 then
    tail = tail .. string.format(' %d of them muted, so you will not hear %s.',
                                 silent, silent == 1 and 'it' or 'them')
  end

  a11y.speak(head .. table.concat(lines, '. ') .. '.' .. tail)
end

a11y.run(main)
