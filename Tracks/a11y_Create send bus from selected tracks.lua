--[[
  @description Create send bus from selected tracks (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Make a new bus and send every selected track to it, in one move: type
    a name, and the bus appears at the end of the project with a post
    fader send from each selected track at 0 dB. The classic use is a
    shared reverb or a scene-wide effect return: select the twelve layers
    of a scene, run this once, and put the reverb on the bus it made.

    The tracks' own routing to the master is left exactly as it was; this
    adds sends, it does not move anything. The new bus ends up as the only
    selected track, so the next thing you do, adding the reverb, lands
    on it. One undo step.
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

local function main()
  local selected = reaper.CountSelectedTracks(0)
  if selected == 0 then
    a11y.abort('No tracks selected. Select the tracks that should feed the bus first.')
  end

  local name = a11y.prompt('Create send bus', 'Bus name:', '', 60)
  if name == nil then
    a11y.abort('Cancelled. Nothing changed.')
  end
  name = name:gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' then
    a11y.abort('The bus needs a name, or you will never find it again. Nothing changed.')
  end

  -- Collect the sources before touching anything: creating the bus and
  -- selecting it changes what "selected" means.
  local sources = {}
  for i = 0, selected - 1 do
    sources[#sources + 1] = reaper.GetSelectedTrack(0, i)
  end

  reaper.Undo_BeginBlock()

  local index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(index, true)
  local bus = reaper.GetTrack(0, index)
  if not bus then
    reaper.Undo_EndBlock('Create send bus (failed)', -1)
    a11y.abort('Reaper did not create the track. Nothing was sent anywhere.')
  end
  reaper.GetSetMediaTrackInfo_String(bus, 'P_NAME', name, true)

  local made = 0
  for _, src in ipairs(sources) do
    local idx = reaper.CreateTrackSend(src, bus)
    if idx >= 0 then
      -- New sends follow the send defaults in REAPER's preferences, so the
      -- 0 dB post fader promised below is set rather than assumed.
      reaper.SetTrackSendInfo_Value(src, 0, idx, 'D_VOL', 1)
      reaper.SetTrackSendInfo_Value(src, 0, idx, 'I_SENDMODE', 0)
      made = made + 1
    end
  end

  reaper.SetOnlyTrackSelected(bus)
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock('Create send bus "' .. name .. '"', -1)

  if made == 0 then
    a11y.abort(string.format(
      'Created the bus %s as track %d, but no sends could be made. ' ..
      'The bus is there and selected; the routing is not.', name, index + 1))
  end

  local msg = string.format('Created bus %s as track %d, with sends from %s at 0 dB, ' ..
                            'post fader. The bus is now the selected track.',
                            name, index + 1, a11y.plural(made, 'track'))
  if made < #sources then
    msg = msg .. string.format(' %d of the selected tracks could not be sent.',
                               #sources - made)
  end
  a11y.speak(msg)
end

a11y.run(main)
