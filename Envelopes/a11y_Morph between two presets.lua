--[[
  @description Morph between two plugin presets over the time selection (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Pick a plugin, pick a preset to start from and a preset to end on, and
    every parameter that differs between them gets an envelope ramping from
    the first value to the second across the time selection.

    A preset is a snapshot of every parameter at once, so REAPER cannot
    automate "into" one directly -- loading a preset is a jump, and there is
    no preset position to sweep. This turns the jump into movement by
    diffing the two snapshots and writing one envelope per parameter that
    changed.

    Stepped parameters -- filter types, sync divisions, waveform selectors --
    are deliberately not ramped. Dragging a three-position switch through its
    intermediate values produces zipper noise or nothing at all. They are
    switched cleanly at one end instead, and the script says which ones it
    treated that way.

    Optionally fades the plugin's wet control up from silent at the same
    time, so the effect arrives as the morph happens. That uses the wet
    control rather than bypass on purpose: bypass is on or off, so automating
    it clicks.

    Reading preset names means loading each one briefly, because REAPER has
    no call for "name of preset at index". That makes noise, so this refuses
    to run during playback.

    Leaves existing envelopes on parameters that do not differ between the
    two presets completely alone.
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

-- Stepping through presets to read their names costs a plugin state load
-- each time. Guitar Rig and the like ship hundreds, so this caps the read
-- rather than leaving someone waiting with no idea why.
local MAX_PRESETS = 512

-- Normalised parameter values below this much apart count as unchanged.
-- Plugins routinely report a value back a hair different from the one they
-- were given, and a ramp between two identical values is just clutter.
local SAME = 1e-5

-- Keeps the ramp from interpolating back to the point REAPER adds at the
-- start of the project. Same reason as the ramp script.
local ANCHOR_GAP = 0.001

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then return 'unnamed track' end
  return name
end

local function fx_list(tr)
  local out = {}
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, name = reaper.TrackFX_GetFXName(tr, fx, '')
    out[#out + 1] = { index = fx, name = name }
  end
  return out
end

--- Every preset on the plugin, as { index, name }.
-- REAPER has no "name of preset at index" call, so each preset has to be
-- loaded to be read. The original selection is restored before returning.
local function preset_list(tr, fx)
  local original, count = reaper.TrackFX_GetPresetIndex(tr, fx)
  if not count or count < 1 then return {}, 0, false end

  local capped = math.min(count, MAX_PRESETS)
  local out = {}

  reaper.PreventUIRefresh(1)
  for i = 0, capped - 1 do
    if reaper.TrackFX_SetPresetByIndex(tr, fx, i) then
      local _, name = reaper.TrackFX_GetPreset(tr, fx, '')
      if name == nil or name == '' then name = 'Preset ' .. (i + 1) end
      out[#out + 1] = { index = i, name = name }
    end
  end
  reaper.TrackFX_SetPresetByIndex(tr, fx, original)
  reaper.PreventUIRefresh(-1)

  return out, count, count > capped
end

--- Normalised value of every parameter, indexed from 0.
local function snapshot(tr, fx, nparams)
  local values = {}
  for p = 0, nparams - 1 do
    values[p] = reaper.TrackFX_GetParamNormalized(tr, fx, p)
  end
  return values
end

--- True when a parameter moves in steps rather than continuously.
local function is_stepped(tr, fx, param)
  local ok, _, _, _, istoggle = reaper.TrackFX_GetParameterStepSizes(tr, fx, param)
  return ok == true or istoggle == true
end

--- Parameter indices REAPER adds to every plugin, which must not be morphed
--- as if they were part of the preset. Wet is handled separately and on
--- purpose; bypass and delta would be actively wrong to ramp.
local function builtin_params(tr, fx)
  local skip = {}
  for _, ident in ipairs({ ':wet', ':bypass', ':delta' }) do
    local idx = reaper.TrackFX_GetParamFromIdent(tr, fx, ident)
    if idx and idx >= 0 then skip[idx] = ident end
  end
  return skip
end

--- Replace the span with a two point ramp, pinning what came before it.
local function write_ramp(env, start_time, end_time, from_value, to_value, shape)
  local anchor_time = math.max(0, start_time - ANCHOR_GAP)
  local _, before = reaper.Envelope_Evaluate(env, anchor_time, 44100, 0)

  reaper.DeleteEnvelopePointRange(env, start_time - 0.0000001, end_time + 0.0000001)
  if anchor_time > 0 and anchor_time < start_time then
    reaper.InsertEnvelopePoint(env, anchor_time, before, 0, 0, false, true)
  end
  reaper.InsertEnvelopePoint(env, start_time, from_value, shape, 0, false, true)
  reaper.InsertEnvelopePoint(env, end_time, to_value, 0, 0, false, true)
  reaper.Envelope_SortPoints(env)
end

local function main()
  local tr = reaper.GetSelectedTrack(0, 0)
  if not tr then
    a11y.abort('No track selected. Select the track with the plugin on it first.')
  end
  local name = track_name(tr)

  -- Reading preset names loads each one in turn, which is audible.
  if (reaper.GetPlayState() & 1) == 1 then
    a11y.abort('Stop playback first. Reading the preset names means loading ' ..
               'each one briefly, which you would hear.')
  end

  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if end_time <= start_time then
    a11y.abort('No time selection. Select the span you want the morph to ' ..
               'happen across, then run this again.')
  end

  local fxs = fx_list(tr)
  if #fxs == 0 then
    a11y.abort('No plugins on ' .. name .. '.')
  end

  local chosen_fx = fxs[1]
  if #fxs > 1 then
    local query = a11y.prompt('Morph on ' .. name, 'Which plugin (blank lists all):',
                              a11y.recall('morph_fx_query', ''), 300)
    if query == nil then a11y.abort('Cancelled.') end
    local hits = a11y.filter(query, fxs, function(f) return f.name end)
    if #hits == 0 then
      a11y.abort(string.format('No plugin on %s matches %s.', name, query))
    end
    chosen_fx = a11y.pick('Morph on ' .. name, hits, function(f) return f.name end)
    if chosen_fx == nil then a11y.abort('Cancelled.') end
    a11y.remember('morph_fx_query', query)
  end

  local fx = chosen_fx.index
  a11y.speak('Reading presets for ' .. chosen_fx.name .. '.')

  local presets, total, truncated = preset_list(tr, fx)
  if #presets < 2 then
    a11y.abort(string.format('%s reports %s. A morph needs at least two.',
                             chosen_fx.name, a11y.plural(#presets, 'preset')))
  end

  local function choose(label)
    local query = a11y.prompt(label .. ' preset', 'Search (blank lists all):', '', 300)
    if query == nil then a11y.abort('Cancelled.') end
    local hits = a11y.filter(query, presets, function(p) return p.name end)
    if #hits == 0 then
      a11y.abort(string.format('No preset matches %s. %s available.',
                               query, a11y.plural(#presets, 'preset')))
    end
    local pick = a11y.pick(label .. ' preset', hits, function(p) return p.name end)
    if pick == nil then a11y.abort('Cancelled.') end
    return pick
  end

  local from_preset = choose('Start')
  local to_preset = choose('End')

  if from_preset.index == to_preset.index then
    a11y.abort('Start and end are both ' .. from_preset.name ..
               '. Nothing would change.')
  end

  local ok, answer = reaper.GetUserInputs(
    'Morph ' .. from_preset.name .. ' to ' .. to_preset.name, 2,
    'Fade wet in from silent, yes or no:,Switch stepped parameters at start or end:,extrawidth=110',
    a11y.recall('morph_wet', 'no') .. ',' .. a11y.recall('morph_switch', 'end'))
  if not ok then a11y.abort('Cancelled.') end

  local wet_text, switch_text = answer:match('^([^,]*),(.*)$')
  local fade_wet = (wet_text or ''):lower():sub(1, 1) == 'y'
  local switch_at_start = (switch_text or ''):lower():find('start', 1, true) ~= nil
  a11y.remember('morph_wet', fade_wet and 'yes' or 'no')
  a11y.remember('morph_switch', switch_at_start and 'start' or 'end')

  local nparams = reaper.TrackFX_GetNumParams(tr, fx)
  local skip = builtin_params(tr, fx)

  -- Snapshot both ends. The plugin audibly jumps between these two loads,
  -- which is why playback has to be stopped.
  reaper.PreventUIRefresh(1)
  reaper.TrackFX_SetPresetByIndex(tr, fx, from_preset.index)
  local from_values = snapshot(tr, fx, nparams)
  reaper.TrackFX_SetPresetByIndex(tr, fx, to_preset.index)
  local to_values = snapshot(tr, fx, nparams)
  -- Leave the plugin on the preset the morph begins from, so its own state
  -- agrees with where the automation starts.
  reaper.TrackFX_SetPresetByIndex(tr, fx, from_preset.index)
  reaper.PreventUIRefresh(-1)

  local ramped, switched, failed = {}, {}, 0

  reaper.Undo_BeginBlock()

  for p = 0, nparams - 1 do
    local from_v, to_v = from_values[p], to_values[p]
    if not skip[p] and from_v and to_v and math.abs(from_v - to_v) > SAME then
      local env = reaper.GetFXEnvelope(tr, fx, p, true)
      if env then
        local _, param_name = reaper.TrackFX_GetParamName(tr, fx, p, '')
        if is_stepped(tr, fx, p) then
          -- Square shape holds the first value flat and jumps at the far
          -- point, instead of sliding through positions that mean nothing.
          if switch_at_start then
            write_ramp(env, start_time, end_time, to_v, to_v, 1)
          else
            write_ramp(env, start_time, end_time, from_v, to_v, 1)
          end
          switched[#switched + 1] = param_name
        else
          write_ramp(env, start_time, end_time, from_v, to_v, 0)
          ramped[#ramped + 1] = param_name
        end
      else
        failed = failed + 1
      end
    end
  end

  local wet_done = false
  if fade_wet then
    local wet_idx = reaper.TrackFX_GetParamFromIdent(tr, fx, ':wet')
    if wet_idx and wet_idx >= 0 then
      local env = reaper.GetFXEnvelope(tr, fx, wet_idx, true)
      if env then
        write_ramp(env, start_time, end_time, 0, 1, 0)
        wet_done = true
      end
    end
  end

  reaper.Undo_EndBlock(string.format('Morph %s from %s to %s',
    chosen_fx.name, from_preset.name, to_preset.name), -1)
  reaper.UpdateArrange()

  if #ramped == 0 and #switched == 0 and not wet_done then
    a11y.abort(string.format(
      '%s and %s have no parameters that differ, so nothing was written.',
      from_preset.name, to_preset.name))
  end

  local msg = string.format('Morphed %s from %s to %s over %s. %s ramped',
    chosen_fx.name, from_preset.name, to_preset.name,
    a11y.duration_phrase(end_time - start_time),
    a11y.plural(#ramped, 'parameter'))

  if #switched > 0 then
    msg = msg .. string.format('. %s switched at the %s instead of ramping: %s',
      a11y.plural(#switched, 'stepped parameter'),
      switch_at_start and 'start' or 'end',
      a11y.list_phrase(switched))
  end
  if wet_done then
    msg = msg .. '. Wet fades up from silent'
  end
  if failed > 0 then
    msg = msg .. string.format('. %s could not be given an envelope',
                               a11y.plural(failed, 'parameter'))
  end
  if truncated then
    msg = msg .. string.format('. Only the first %d of %d presets were read',
                               MAX_PRESETS, total)
  end

  a11y.speak(msg .. '.')
end

a11y.run(main)
