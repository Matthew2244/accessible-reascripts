--[[
  @description Ramp envelope over time selection (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.2
  @provides [main] .
  @about
    Ramp the selected envelope from one value to another across the time
    selection, in one step. A fade, a filter sweep, a level move under a
    voiceover.

    Placing a ramp by hand means putting the cursor at the start, adding a
    point, typing a value, moving to the end, adding another point, typing
    that value, then fixing the curve shape. This asks for both values and
    the shape in one dialog, both pre-filled with what the envelope is doing
    now, so leaving a field alone changes nothing.

    Values are typed in the units you think in:

      Volume and trim       decibels, so -6 means minus six dB
      Pan                   percent, -100 hard left to 100 hard right
      Width                 percent, -100 to 100
      Mute                  0 or 1
      Plugin parameters     percent of the parameter's range, 0 to 100
      Anything else         the envelope's own numbers, so semitones for
                            take pitch and beats per minute for tempo

    On a take envelope the time selection still means project time, and the
    script works out where that falls inside the item, so the selection has
    to sit inside that item.

    Curve shapes are words, not numbers: linear, slow, fast start, fast end,
    square, bezier. Blank means linear.

    Works on whichever envelope is selected. With none selected it falls
    back to the track's volume envelope, creating it if needed, and says so.

    It also pins the value immediately before the time selection. Without
    that, REAPER interpolates the new ramp all the way back to the point it
    adds automatically at the start of the project, so the value drifts
    across everything before the span you chose. Pinning keeps each ramp
    local, which means you can run this over one span after another to build
    a shape.
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

-- How far before the time selection the previous value is pinned. Short
-- enough to be inaudible, long enough that REAPER keeps it as its own point.
local ANCHOR_GAP = 0.001

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then return 'unnamed track' end
  return name
end

local function envelope_name(env)
  local _, name = reaper.GetEnvelopeName(env, '')
  if name == nil or name == '' then return 'envelope' end
  return name
end

--- Which scale this envelope's values are in. Volume, pan, mute and width
--- each have their own. A plugin parameter is stored in the plugin's own
--- range, which is 0 to 1 for VST and AU but can be anything for JSFX, so
--- the range is read from the plugin. Anything else, such as take pitch or
--- the tempo map, is offered in its own numbers rather than guessed at.
-- @return kind, and for a plugin parameter its track, fx and param indices
local function envelope_kind(env)
  local name = envelope_name(env):lower()
  if name == 'volume' or name == 'volume (pre-fx)' or name == 'trim volume' then
    return 'volume'
  end
  if name == 'pan' or name == 'pan (pre-fx)' then return 'pan' end
  if name == 'width' or name == 'width (pre-fx)' then return 'width' end
  if name == 'mute' then return 'mute' end
  local tr, fx, param = reaper.Envelope_GetParentTrack(env)
  if tr and fx and fx >= 0 and param and param >= 0 then
    return 'fxparam', { track = tr, fx = fx, param = param }
  end
  return 'raw'
end

--- The plugin parameter's range, so percent means percent of what it can do.
local function param_range(fxp)
  local _, lo, hi = reaper.TrackFX_GetParam(fxp.track, fxp.fx, fxp.param)
  if not lo or not hi or hi <= lo then return 0, 1 end
  return lo, hi
end

--- Stored envelope value to the number the user types.
local function to_human(env, kind, value, fxp)
  if kind == 'volume' then
    local mode = reaper.GetEnvelopeScalingMode(env)
    return a11y.gain_to_db(reaper.ScaleFromEnvelopeMode(mode, value))
  elseif kind == 'mute' or kind == 'raw' then
    return value
  elseif kind == 'fxparam' then
    local lo, hi = param_range(fxp)
    return (value - lo) / (hi - lo) * 100
  elseif kind == 'pan' then
    -- A pan envelope stores left as positive, the opposite of the track's
    -- pan control. Measured: a point at +1 renders on the left channel
    -- only, and REAPER shows it as 100%L. Typed values follow the control,
    -- so minus is left.
    return -value * 100
  end
  return value * 100
end

--- The number the user typed, back to what the envelope stores.
local function from_human(env, kind, human, fxp)
  if kind == 'volume' then
    local mode = reaper.GetEnvelopeScalingMode(env)
    return reaper.ScaleToEnvelopeMode(mode, a11y.db_to_gain(human))
  elseif kind == 'mute' then
    return human >= 0.5 and 1 or 0
  elseif kind == 'raw' then
    return human
  elseif kind == 'pan' then
    return math.max(-1, math.min(1, -human / 100))
  elseif kind == 'fxparam' then
    local lo, hi = param_range(fxp)
    return lo + math.max(0, math.min(1, human / 100)) * (hi - lo)
  end
  return math.max(-1, math.min(1, human / 100))
end

--- A number rounded to `places`, without the trailing ".0" Lua 5.4 gives a
--- whole float, which a screen reader reads out as "point zero".
local function round(n, places)
  local s = string.format('%.' .. (places or 1) .. 'f', n)
  s = s:gsub('0+$', ''):gsub('%.$', '')
  if s == '-0' then s = '0' end
  return s
end

local function describe(env, kind, value, fxp)
  if kind == 'mute' then
    return value >= 0.5 and 'muted' or 'unmuted'
  end
  local human = to_human(env, kind, value, fxp)
  if kind == 'volume' then
    if human <= a11y.MIN_DB then return 'minus infinity dB' end
    return round(human, 1) .. ' dB'
  end
  if kind == 'raw' then return round(human, 2) end
  if kind == 'pan' then
    if math.abs(human) < 0.05 then return 'center' end
    return round(math.abs(human), 1) .. ' percent ' .. (human < 0 and 'left' or 'right')
  end
  return round(human, 1) .. ' percent'
end

--- Ask the plugin how it would display a value, so speech can say "240 Hz"
--- rather than only "20 percent". Restores the parameter after.
local function plugin_units(tr, fx, param, value)
  local original = reaper.TrackFX_GetParam(tr, fx, param)
  reaper.TrackFX_SetParam(tr, fx, param, value)
  local _, shown = reaper.TrackFX_GetFormattedParamValue(tr, fx, param, '')
  reaper.TrackFX_SetParam(tr, fx, param, original)
  if shown == nil or shown == '' then return nil end
  return shown
end

local function main()
  -- Checked first, so a run that stops here has created nothing.
  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if end_time <= start_time then
    a11y.abort('No time selection. Select the span you want to ramp across, ' ..
               'then run this again.')
  end

  local env = reaper.GetSelectedEnvelope(0)
  -- The selected envelope can belong to any track, or to a take, so the
  -- track named is the envelope's own.
  local tr = env and reaper.Envelope_GetParentTrack(env)
  local take = env and not tr and reaper.Envelope_GetParentTake(env)
  if take then tr = reaper.GetMediaItemTake_Track(take) end
  tr = tr or reaper.GetSelectedTrack(0, 0) or reaper.GetLastTouchedTrack()
  if not tr then
    a11y.abort('No track selected. Select a track first.')
  end

  local name = track_name(tr)
  if take then name = 'an item on ' .. name end
  local fell_back = false

  if not env then
    env = reaper.GetTrackEnvelopeByName(tr, 'Volume')
    if not env then
      reaper.SetOnlyTrackSelected(tr)
      reaper.Main_OnCommand(41866, 0) -- Track: Select volume envelope
      env = reaper.GetTrackEnvelopeByName(tr, 'Volume')
    end
    fell_back = true
  end
  if not env then
    a11y.abort('No envelope selected, and REAPER would not create a volume ' ..
               'envelope on ' .. name .. '.')
  end

  local kind, fxp = envelope_kind(env)
  local env_name = envelope_name(env)

  -- A take envelope stores its points from the start of its item, so the
  -- time selection is converted; a track envelope's times pass straight
  -- through. Everything below works in the envelope's own times.
  local proj_start, proj_end = start_time, end_time
  start_time = a11y.envelope_time(env, proj_start)
  end_time = a11y.envelope_time(env, proj_end)
  if take and (start_time < 0 or proj_end > reaper.GetMediaItemInfo_Value(
      reaper.GetMediaItemTake_Item(take), 'D_POSITION') +
      reaper.GetMediaItemInfo_Value(reaper.GetMediaItemTake_Item(take), 'D_LENGTH') + 0.0005) then
    a11y.abort('The time selection runs outside the item this envelope belongs to. ' ..
               'Keep it inside the item. Nothing changed.')
  end

  -- Read the current shape of things first, so the dialog can offer it back
  -- and so the pinned value is the one that was really there.
  local _, at_start = reaper.Envelope_Evaluate(env, start_time, 44100, 0)
  local _, at_end = reaper.Envelope_Evaluate(env, end_time, 44100, 0)
  local anchor_time = math.max(0, start_time - ANCHOR_GAP)
  local _, at_anchor = reaper.Envelope_Evaluate(env, anchor_time, 44100, 0)

  local defaults = string.format('%s,%s,%s',
    round(to_human(env, kind, at_start, fxp), 2),
    round(to_human(env, kind, at_end, fxp), 2),
    kind == 'mute' and 'square' or 'linear')

  local ok, answer = reaper.GetUserInputs(
    string.format('Ramp %s on %s', env_name, name), 3,
    'Start value:,End value:,Curve:,extrawidth=110', defaults)
  if not ok then
    a11y.abort('Cancelled.')
  end

  local start_text, end_text, curve_text = answer:match('^([^,]*),([^,]*),(.*)$')
  local start_human = tonumber(start_text)
  local end_human = tonumber(end_text)
  if not start_human or not end_human then
    a11y.abort('Start and end both need to be numbers. Nothing changed.')
  end

  local shape, shape_name = a11y.envelope_shape(curve_text)
  local start_value = from_human(env, kind, start_human, fxp)
  local end_value = from_human(env, kind, end_human, fxp)
  local before_count = reaper.CountEnvelopePoints(env)

  reaper.Undo_BeginBlock()

  -- Clear the span first so running this twice over the same range replaces
  -- the ramp rather than layering a second one on top of it.
  reaper.DeleteEnvelopePointRange(env, start_time - 0.0000001, end_time + 0.0000001)

  if anchor_time > 0 and anchor_time < start_time then
    reaper.InsertEnvelopePoint(env, anchor_time, at_anchor, 0, 0, false, true)
  end
  reaper.InsertEnvelopePoint(env, start_time, start_value, shape, 0, false, true)
  reaper.InsertEnvelopePoint(env, end_time, end_value, 0, 0, false, true)
  reaper.Envelope_SortPoints(env)

  reaper.Undo_EndBlock(string.format('Ramp %s on %s', env_name, name), -1)
  reaper.UpdateArrange()

  -- Never claim a ramp that is not there. Two points is the minimum a
  -- successful run can leave behind.
  local after_count = reaper.CountEnvelopePoints(env)
  if after_count < 2 then
    a11y.abort(string.format(
      'REAPER did not keep the points on %s. It has %s, and had %s before. ' ..
      'Nothing was ramped.', env_name,
      a11y.plural(after_count, 'point'), a11y.plural(before_count, 'point')))
  end

  local start_label = describe(env, kind, start_value, fxp)
  local end_label = describe(env, kind, end_value, fxp)

  -- Reading a plugin's own units means briefly setting the parameter and
  -- asking the plugin to format it. During playback the envelope is driving
  -- that parameter, so the answer would be the envelope's value rather than
  -- ours. Percent is always right, so the extra detail is simply skipped.
  local stopped = (reaper.GetPlayState() & 1) == 0
  if kind == 'fxparam' and stopped then
    local fx_track, fx, param = fxp.track, fxp.fx, fxp.param
    if fx_track then
      local real_start = plugin_units(fx_track, fx, param, start_value)
      local real_end = plugin_units(fx_track, fx, param, end_value)
      if real_start and real_end then
        start_label = start_label .. ', ' .. real_start
        end_label = end_label .. ', ' .. real_end
      end
    end
  end

  local msg = string.format('%s on %s, ramped from %s to %s over %s, %s.',
    env_name, name, start_label, end_label,
    a11y.time_phrase(proj_end - proj_start), shape_name)
  if fell_back then
    msg = 'No envelope was selected, so this used the track volume. ' .. msg
  end
  a11y.speak(msg)
end

a11y.run(main)
