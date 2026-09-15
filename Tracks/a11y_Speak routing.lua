--[[
  @description Speak routing (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    One keystroke and you hear where the selected track's audio actually
    goes: whether it feeds the master or a folder parent, every send with
    its destination, level and pre or post position, every receive with
    where it comes from, and whether any hardware outputs are assigned.

    In a layered session, a track that sounds wrong is very often a track
    routed wrong: a send left muted, a master send switched off, a receive
    you forgot existed. This reads the whole picture in one pass.

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

local SEND_MODES = {
  [0] = 'post fader', [1] = 'pre FX', [2] = 'post FX', [3] = 'pre fader',
}

--- Linear volume as spoken dB.
local function db_phrase(vol)
  if vol <= 0.0000001 then return 'minus infinity dB' end
  local db = 20 * math.log(vol, 10)
  if math.abs(db) < 0.05 then return '0 dB' end
  return string.format('%+.1f dB', db)
end

local function label_of(track)
  local number = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'))
  local _, name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  return a11y.track_label(number, name)
end

local function main()
  local selected = reaper.CountSelectedTracks(0)
  if selected == 0 then
    a11y.abort('No track selected.')
  end
  local track = reaper.GetSelectedTrack(0, 0)

  local parts = {}
  local head = 'Routing for track ' .. label_of(track)
  if selected > 1 then
    head = head .. string.format(', the first of %d selected', selected)
  end
  parts[#parts + 1] = head

  -- Where the main signal goes: master, a folder parent, or nowhere --
  -- the last being the classic silent-track mystery, so it is said early.
  local mainsend = reaper.GetMediaTrackInfo_Value(track, 'B_MAINSEND') > 0
  local parent = reaper.GetParentTrack(track)
  if not mainsend then
    parts[#parts + 1] = 'Main send is OFF, so this track feeds nothing but its sends'
  elseif parent then
    parts[#parts + 1] = 'feeds its folder parent, track ' .. label_of(parent)
  else
    parts[#parts + 1] = 'feeds the master'
  end

  if reaper.GetMediaTrackInfo_Value(track, 'I_FOLDERDEPTH') == 1 then
    parts[#parts + 1] = 'It is a folder parent, so its children mix into it'
  end

  local sends = reaper.GetTrackNumSends(track, 0)
  if sends == 0 then
    parts[#parts + 1] = 'No sends'
  else
    parts[#parts + 1] = a11y.plural(sends, 'send')
    for i = 0, sends - 1 do
      local _, dest = reaper.GetTrackSendName(track, i, '')
      local vol = reaper.GetTrackSendInfo_Value(track, 0, i, 'D_VOL')
      local muted = reaper.GetTrackSendInfo_Value(track, 0, i, 'B_MUTE') > 0
      local mode = math.floor(reaper.GetTrackSendInfo_Value(track, 0, i, 'I_SENDMODE'))
      local line = string.format('send %d to %s at %s, %s', i + 1, dest,
                                 db_phrase(vol), SEND_MODES[mode] or 'unknown tap')
      if muted then line = line .. ', MUTED' end
      parts[#parts + 1] = line
    end
  end

  local receives = reaper.GetTrackNumSends(track, -1)
  if receives > 0 then
    parts[#parts + 1] = a11y.plural(receives, 'receive')
    for i = 0, receives - 1 do
      local _, src = reaper.GetTrackReceiveName(track, i, '')
      local vol = reaper.GetTrackSendInfo_Value(track, -1, i, 'D_VOL')
      local muted = reaper.GetTrackSendInfo_Value(track, -1, i, 'B_MUTE') > 0
      local line = string.format('receive %d from %s at %s', i + 1, src, db_phrase(vol))
      if muted then line = line .. ', MUTED' end
      parts[#parts + 1] = line
    end
  end

  local hardware = reaper.GetTrackNumSends(track, 1)
  if hardware > 0 then
    parts[#parts + 1] = a11y.plural(hardware, 'hardware output') .. ' assigned'
  end

  a11y.speak(table.concat(parts, '. ') .. '.')
end

a11y.run(main)
