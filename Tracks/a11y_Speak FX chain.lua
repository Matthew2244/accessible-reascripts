--[[
  @description Speak the FX chain of the selected track (accessible)
  @author Accessible ReaScripts contributors
  @version 1.1.0
  @provides [main] .
  @about
    One keystroke and you hear what is on the selected track: every plugin
    in order, with its position in the chain, and whether it is bypassed or
    offline. The alternative is opening the FX window and arrowing down a
    list to find out.

    Order matters and is spoken, because a compressor before a reverb is a
    different sound from a compressor after one.

    It also says when the whole chain is switched off at the track. That is
    worth hearing first: every plugin can report as enabled while the entire
    chain is bypassed, so without it the track sounds dry for no visible
    reason.

    Pairs with "Add FX by name" -- add a plugin, then check where it landed.

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

--- Longest chain read out in full. Past this it stops and says how many are
--- left, rather than turning one keystroke into half a minute of speech.
local MAX_SPOKEN = 12

--- Every effect on `tr`, in chain order.
local function chain_of(tr)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, i, '')
    out[#out + 1] = {
      name    = name,
      enabled = reaper.TrackFX_GetEnabled(tr, i),
      offline = reaper.TrackFX_GetOffline(tr, i),
    }
  end
  return out
end

--- "3, ReaComp, bypassed" -- position first, because position is the thing
--- you are usually trying to establish.
local function fx_phrase(index, fx)
  local state = ''
  -- Offline wins when both are true: an offline plugin is not processing at
  -- all, so saying "bypassed" would understate it.
  if fx.offline then
    state = ', offline'
  elseif not fx.enabled then
    state = ', bypassed'
  end
  return string.format('%d, %s%s', index, fx.name, state)
end

local function main()
  local selected = reaper.CountSelectedTracks(0)
  if selected == 0 then
    a11y.abort('No track selected.')
  end

  local tr = reaper.GetSelectedTrack(0, 0)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  local number = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER'))
  local label = a11y.track_label(number, name)

  local sentences = {}

  -- Reading several chains back to back is a wall of speech, so only the
  -- first is read. Say so, otherwise the others look like they had no
  -- effects on them.
  if selected > 1 then
    sentences[#sentences + 1] =
      string.format('First of %s selected', a11y.plural(selected, 'track'))
  end

  local chain = chain_of(tr)
  if #chain == 0 then
    sentences[#sentences + 1] = string.format('%s has no effects', label)
    a11y.speak(table.concat(sentences, '. ') .. '.')
    return
  end

  sentences[#sentences + 1] =
    string.format('%s, %s', label, a11y.plural(#chain, 'effect'))

  -- I_FXEN is the whole-chain switch, separate from each plugin's own bypass.
  if reaper.GetMediaTrackInfo_Value(tr, 'I_FXEN') == 0 then
    sentences[#sentences + 1] = 'all effects bypassed for this track'
  end

  local shown = math.min(#chain, MAX_SPOKEN)
  for i = 1, shown do
    sentences[#sentences + 1] = fx_phrase(i, chain[i])
  end
  if #chain > shown then
    sentences[#sentences + 1] = string.format('and %d more', #chain - shown)
  end

  a11y.speak(table.concat(sentences, '. ') .. '.')
end

a11y.run(main)
