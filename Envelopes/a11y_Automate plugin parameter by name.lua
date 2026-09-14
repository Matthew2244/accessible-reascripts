--[[
  @description Automate plugin parameter by name (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Type part of a parameter's name and get an envelope for it, ready to
    edit. Searches every parameter of every plugin on the selected track,
    plus the track's own volume, pan, width and mute.

    This exists because exposing a plugin parameter for automation normally
    means opening the FX parameters dialog, scrolling until you find the
    parameter, nudging it so it becomes the "last touched" one, closing the
    dialog, pressing the show-envelope-for-last-touched-parameter action,
    and then cycling envelopes until you land on the right one. REAPER has
    GetFXEnvelope, which creates the envelope directly from an index, so
    none of that is necessary.

    The envelope is created if it does not exist, made visible, and
    selected, so OSARA's envelope point navigation and the ramp script both
    act on it straight away.

    Pairs with "Ramp envelope over time selection": pick the parameter with
    this, select a span, then ramp it.
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

-- Safety rail on the parameter enumeration. Sampler and amp-sim front ends
-- report parameter counts in the low thousands; this sits well above that
-- and only exists so a misbehaving plugin can never spin the loop forever.
local MAX_PARAMS = 20000

-- Track envelopes, with the action that shows and selects each one. These
-- are the "Track: Select ... envelope" actions, which create the envelope
-- when it does not exist yet. The "Toggle ... visible" actions are avoided
-- deliberately: they would hide an envelope that is already showing.
local TRACK_ENVELOPES = {
  { label = 'Track volume', name = 'Volume', command = 41866 },
  { label = 'Track pan',    name = 'Pan',    command = 41868 },
  { label = 'Track width',  name = 'Width',  command = 41870 },
  { label = 'Track mute',   name = 'Mute',   command = 41871 },
}

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then return 'unnamed track' end
  return name
end

--- Everything on this track that can carry an envelope.
local function automatable(tr)
  local out = {}

  for _, entry in ipairs(TRACK_ENVELOPES) do
    out[#out + 1] = {
      label = entry.label, kind = 'track',
      name = entry.name, command = entry.command,
    }
  end

  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, fx_name = reaper.TrackFX_GetFXName(tr, fx, '')
    local count = math.min(reaper.TrackFX_GetNumParams(tr, fx), MAX_PARAMS)
    for param = 0, count - 1 do
      local _, param_name = reaper.TrackFX_GetParamName(tr, fx, param, '')
      if param_name and param_name ~= '' then
        -- Parameter name first, so typing the parameter you have in mind
        -- lands in a better match tier than the plugin name would give it.
        out[#out + 1] = {
          label = param_name .. ' on ' .. fx_name,
          kind = 'fx', fx = fx, param = param,
        }
      end
    end
  end

  return out
end

--- Create, show and return the envelope for `choice`.
-- @return TrackEnvelope|nil, string|nil  envelope, current value as the plugin shows it
local function envelope_for(tr, choice)
  if choice.kind == 'track' then
    local env = reaper.GetTrackEnvelopeByName(tr, choice.name)
    if not env then
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(choice.command, 0)
      env = reaper.GetTrackEnvelopeByName(tr, choice.name)
    end
    return env, nil
  end

  local env = reaper.GetFXEnvelope(tr, choice.fx, choice.param, true)
  local _, shown = reaper.TrackFX_GetFormattedParamValue(tr, choice.fx, choice.param, '')
  return env, shown
end

local function main()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then
    a11y.abort('No track selected. Select the track you want to automate first.')
  end

  local name = track_name(tr)
  local targets = automatable(tr)

  local query = a11y.prompt('Automate on ' .. name, 'Search (blank lists all):',
                            a11y.recall('automate_query', ''), 300)
  if query == nil then
    a11y.abort('Cancelled.')
  end

  local hits = a11y.filter(query, targets, function(t) return t.label end)
  if #hits == 0 then
    a11y.abort(string.format('Nothing on %s matches %s. %s available.',
                             name, query, a11y.plural(#targets, 'parameter')))
  end

  local choice = a11y.pick('Automate on ' .. name, hits, function(t) return t.label end)
  if choice == nil then
    a11y.abort('Cancelled.')
  end

  a11y.remember('automate_query', query)

  reaper.Undo_BeginBlock()
  local env, shown = envelope_for(tr, choice)
  reaper.Undo_EndBlock('Create envelope for ' .. choice.label, -1)

  if not env then
    a11y.abort(string.format(
      'REAPER would not create an envelope for %s on %s. ' ..
      'Report this with the plugin name and REAPER version.', choice.label, name))
  end

  -- Remembering which parameter this envelope belongs to lets the ramp
  -- script speak the plugin's own units instead of a bare percentage.
  if choice.kind == 'fx' then
    a11y.remember('fx_track', reaper.GetTrackGUID(tr))
    a11y.remember('fx_index', choice.fx)
    a11y.remember('fx_param', choice.param)
  else
    a11y.remember('fx_track', '')
  end

  -- Context 2 is the envelope lane. Selecting it here is what makes OSARA's
  -- point navigation and the ramp script act on this envelope next.
  reaper.SetCursorContext(2, env)
  reaper.UpdateArrange()

  local msg = string.format('%s on %s. Envelope ready and selected.', choice.label, name)
  if shown and shown ~= '' then
    msg = msg .. ' Currently ' .. shown .. '.'
  end
  a11y.speak(msg)
end

a11y.run(main)
