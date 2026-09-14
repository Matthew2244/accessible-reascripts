--[[
  @description Ramp last touched parameter (accessible)
  @author Accessible ReaScripts contributors
  @version 1.2.0
  @provides [main] .
  @about
    Write a rise or fall on whatever FX parameter you touched last — a
    filter opening over eight seconds, a reverb swelling into a scene
    change, a send dying away — without drawing a single envelope point
    by hand.

    Touch the parameter (OSARA's FX parameters dialog counts), select the
    time the ramp should cover, run the script, and type where the ramp
    starts and ends as percentages of the parameter's range. The start is
    prefilled with where the parameter is now, so leaving it alone ramps
    from the current value. With no time selection, the ramp runs from the
    edit cursor for however many seconds you type. Curves are words, not
    numbers: linear, slow, fast start, fast end, square, bezier.

    The ramp replaces any envelope points already inside that stretch of
    time, and the parameter holds its ending value afterwards. The value
    just before the ramp is pinned first, so the new points never bend
    what came earlier. When playback is stopped, the confirmation speaks
    the plugin's own units too — "230 Hz", not just "20 percent".

    The envelope is left selected, so OSARA's point navigation and "Ramp
    envelope over time selection" act on it immediately. That script is
    this one's sibling: it ramps whichever envelope is selected, pairs
    with "Automate plugin parameter by name", and works on track volume,
    pan, width and mute as well. This one is the shortcut for a parameter
    your hands are already on. One undo step either way.
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

-- How far before the ramp the previous value is pinned, so the new start
-- point cannot bend the automation that came before it. Tony's trick, from
-- "Ramp envelope over time selection".
local ANCHOR_GAP = 0.001

--- Ask the plugin how it displays a value, so speech can say "230 Hz"
--- rather than only "20 percent". Sets the parameter briefly and restores
--- it, so it is only safe while playback is stopped.
local function plugin_units(track, fx, parm, raw)
  local original = reaper.TrackFX_GetParam(track, fx, parm)
  reaper.TrackFX_SetParam(track, fx, parm, raw)
  local _, shown = reaper.TrackFX_GetFormattedParamValue(track, fx, parm, '')
  reaper.TrackFX_SetParam(track, fx, parm, original)
  if shown == nil or shown == '' then return nil end
  return shown
end

--- The FX parameter the user touched last, as track, fx index, param index.
-- Prefers the modern API (Reaper 7), which can tell a take FX from a track
-- FX; falls back to the older one on Reaper 6.
local function last_touched()
  if reaper.GetTouchedOrFocusedFX then
    local ok, trackidx, itemidx, _, fxidx, parm = reaper.GetTouchedOrFocusedFX(0)
    if not ok then return nil end
    if itemidx >= 0 then
      return nil, 'The last touched parameter belongs to a take FX on an item. ' ..
                  'This script only ramps track FX so far.'
    end
    local track = trackidx == -1 and reaper.GetMasterTrack(0)
                                  or reaper.GetTrack(0, trackidx)
    if not track then return nil end
    return { track = track, fx = fxidx, parm = parm }
  end

  local ok, tracknumber, fxnumber, paramnumber = reaper.GetLastTouchedFX()
  if not ok then return nil end
  -- In this older API, a take FX packs the item index into the high word
  -- of tracknumber and the take index into the high word of fxnumber.
  if math.floor(tracknumber / 65536) ~= 0 or math.floor(fxnumber / 65536) ~= 0 then
    return nil, 'The last touched parameter belongs to a take FX on an item. ' ..
                'This script only ramps track FX so far.'
  end
  local track = tracknumber == 0 and reaper.GetMasterTrack(0)
                                   or reaper.GetTrack(0, tracknumber - 1)
  if not track then return nil end
  return { track = track, fx = fxnumber, parm = paramnumber }
end

--- Parse a percentage field. Values can sit slightly outside 0 to 100 only
--- by typing them deliberately wrong, so refuse those with the reason.
local function parse_percent(text, label, allow_blank)
  text = (text or ''):gsub('^%s+', ''):gsub('%s+$', ''):gsub('%%$', '')
  if text == '' then
    if allow_blank then return nil, nil end
    return nil, 'The ' .. label .. ' was blank. Nothing changed.'
  end
  local n = tonumber(text)
  if not n or n < 0 or n > 100 then
    return nil, string.format('%s is not a percentage between 0 and 100 for the %s. ' ..
                              'Nothing changed.', text, label)
  end
  return n, nil
end

local function main()
  local touched, why = last_touched()
  if not touched then
    a11y.abort(why or 'No FX parameter has been touched yet. Move or enter a value ' ..
               'on the parameter you want to ramp, then run this again.')
  end

  local track, fx, parm = touched.track, touched.fx, touched.parm
  local tracknum = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'))
  local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  local track_phrase = tracknum == -1 and 'the master track'
                       or ('track ' .. a11y.track_label(tracknum, trackname))
  local _, fxname = reaper.TrackFX_GetFXName(track, fx, '')
  local _, parmname = reaper.TrackFX_GetParamName(track, fx, parm, '')
  local val, minval, maxval = reaper.TrackFX_GetParam(track, fx, parm)
  if maxval <= minval then
    a11y.abort(string.format('%s on %s reports no usable range, so it cannot be ramped.',
                             parmname, fxname))
  end
  local current_pct = (val - minval) / (maxval - minval) * 100

  -- Where in time the ramp goes: the time selection when there is one,
  -- otherwise from the edit cursor for a typed number of seconds.
  local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local have_selection = sel_end > sel_start

  a11y.speak(string.format('Ramping %s on %s, %s. Now at %.0f percent.',
                           parmname, fxname, track_phrase, current_pct))

  local ok, answer = reaper.GetUserInputs(
    'Ramp ' .. parmname, 4,
    'Start percent,End percent 0 to 100,' ..
    'Seconds (blank = time selection),Curve (linear slow fast start...),extrawidth=80',
    string.format('%.0f,,,linear', current_pct))
  if not ok then
    a11y.abort('Cancelled. Nothing changed.')
  end

  local f1, f2, f3, f4 = answer:match('^(.-),(.-),(.-),(.-)$')

  local start_pct, err = parse_percent(f1, 'start percent', true)
  if err then a11y.abort(err) end
  if start_pct == nil then start_pct = current_pct end

  local end_pct, err2 = parse_percent(f2, 'end percent', false)
  if err2 then a11y.abort(err2) end

  local ramp_start, ramp_end
  if have_selection then
    ramp_start, ramp_end = sel_start, sel_end
  else
    local secs = tonumber((f3 or ''):gsub('%s', ''))
    if not secs or secs <= 0 then
      a11y.abort('There is no time selection, and no number of seconds was given, ' ..
                 'so there is nowhere to put the ramp. Nothing changed.')
    end
    ramp_start = reaper.GetCursorPosition()
    ramp_end = ramp_start + secs
  end

  local shape, shape_name = a11y.envelope_shape(f4)

  reaper.Undo_BeginBlock()

  local env = reaper.GetFXEnvelope(track, fx, parm, true)
  if not env then
    reaper.Undo_EndBlock('Ramp FX parameter (failed)', -1)
    a11y.abort(string.format('Could not create an envelope for %s on %s. Nothing changed.',
                             parmname, fxname))
  end

  local mode = reaper.GetEnvelopeScalingMode(env)
  local function env_value(pct)
    return reaper.ScaleToEnvelopeMode(mode, minval + pct / 100 * (maxval - minval))
  end
  local function raw_value(pct)
    return minval + pct / 100 * (maxval - minval)
  end

  -- Pin the value just before the ramp, so the new start point cannot bend
  -- the automation that came earlier.
  local anchor_time = math.max(0, ramp_start - ANCHOR_GAP)
  local _, at_anchor = reaper.Envelope_Evaluate(env, anchor_time, 44100, 0)

  -- The ramp owns its stretch of time: points already inside it would
  -- fight the new shape, so they go.
  reaper.DeleteEnvelopePointRange(env, ramp_start, ramp_end)
  if anchor_time > 0 and anchor_time < ramp_start then
    reaper.InsertEnvelopePoint(env, anchor_time, at_anchor, 0, 0, false, true)
  end
  reaper.InsertEnvelopePoint(env, ramp_start, env_value(start_pct), shape, 0, false, true)
  -- The final point is linear so whatever follows the ramp is not bent
  -- by the ramp's own shape.
  reaper.InsertEnvelopePoint(env, ramp_end, env_value(end_pct), 0, 0, false, true)
  reaper.Envelope_SortPoints(env)

  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format('Ramp %s (%s)', parmname, fxname), -1)

  -- Never claim a ramp that is not there.
  if reaper.CountEnvelopePoints(env) < 2 then
    a11y.abort(string.format('REAPER did not keep the points on %s, %s. ' ..
                             'Nothing was ramped.', parmname, fxname))
  end

  -- Leave the envelope selected, so OSARA point navigation and the sibling
  -- ramp script act on it next; and record which parameter it belongs to,
  -- so that script can speak the plugin's own units later.
  reaper.SetCursorContext(2, env)
  if math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')) > 0 then
    a11y.remember('fx_track', reaper.GetTrackGUID(track))
    a11y.remember('fx_index', fx)
    a11y.remember('fx_param', parm)
  end

  local start_label = string.format('%.0f percent', start_pct)
  local end_label = string.format('%.0f percent', end_pct)

  -- Speaking the plugin's own units means briefly setting the parameter and
  -- reading back how the plugin formats it. During playback the envelope is
  -- driving the parameter, so the answer would be wrong; percent is always
  -- right, so the extra detail is simply skipped then.
  if (reaper.GetPlayState() & 1) == 0 then
    local shown_start = plugin_units(track, fx, parm, raw_value(start_pct))
    local shown_end = plugin_units(track, fx, parm, raw_value(end_pct))
    if shown_start and shown_end then
      start_label = start_label .. ', ' .. shown_start
      end_label = end_label .. ', ' .. shown_end
    end
  end

  a11y.speak(string.format(
    'Wrote a %s ramp on %s, %s, %s: %s to %s over %s, ending at %s. Envelope selected.',
    shape_name, parmname, fxname, track_phrase, start_label, end_label,
    string.format('%.3g seconds', ramp_end - ramp_start),
    reaper.format_timestr(ramp_end, '')))
end

a11y.run(main)
