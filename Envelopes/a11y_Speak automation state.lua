--[[
  @description Speak automation state (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    One spoken sentence describing the automation you are sitting in: the
    track and envelope, the track's automation mode, whether the envelope is
    armed and visible, how many points it has, the value under the edit
    cursor, how far the nearest points are on either side, and whether there
    is a time selection ready to ramp across.

    Envelope state is spread across several places, none of which announce
    themselves, so rebuilding the picture normally means arrowing around and
    remembering what you heard. This reads it out in one go.

    Changes nothing. Safe to press at any time, including during playback.
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

local AUTOMATION_MODES = {
  [0] = 'trim and read',
  [1] = 'read',
  [2] = 'touch',
  [3] = 'write',
  [4] = 'latch',
  [5] = 'latch preview',
}

-- The global override shares the numbers 0 to 4 but means bypass by 5.
local OVERRIDE_MODES = {
  [0] = 'trim and read',
  [1] = 'read',
  [2] = 'touch',
  [3] = 'write',
  [4] = 'latch',
  [5] = 'bypass',
}

--- A number without a trailing ".0": Lua 5.4 prints 2.0 for a whole float.
local function num(n)
  return (string.format('%.2f', n):gsub('0+$', ''):gsub('%.$', ''))
end

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

--- Read a flag out of the envelope's state chunk.
-- Armed and visible are not exposed as envelope info values, but they sit
-- in the chunk as plain "ARM 1" and "VIS 1" lines.
-- @return boolean|nil  nil when the chunk could not be read
local function chunk_flag(env, key)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok then return nil end
  local value = chunk:match('\n' .. key .. ' (%d)')
  if value == nil then return nil end
  return value == '1'
end


--- The value under the cursor, in the units a person thinks in. These are
--- the same units Ramp envelope over time selection asks for, so what you
--- hear here is what you would type there.
local function value_phrase(env, value)
  local name = envelope_name(env):lower()
  if name == 'mute' then
    return value >= 0.5 and 'muted' or 'unmuted'
  end
  if name == 'volume' or name == 'volume (pre-fx)' or name == 'trim volume' then
    local mode = reaper.GetEnvelopeScalingMode(env)
    local db = a11y.gain_to_db(reaper.ScaleFromEnvelopeMode(mode, value))
    if db <= a11y.MIN_DB then return 'minus infinity dB' end
    return num(db) .. ' dB'
  end
  if name:match('^pan') or name:match('^width') then
    return num(value * 100) .. ' percent'
  end
  -- A plugin parameter is stored in the plugin's own range, which is not
  -- always 0 to 1, so percent is worked out from that range.
  local tr, fx, param = reaper.Envelope_GetParentTrack(env)
  if tr and fx and fx >= 0 and param and param >= 0 then
    local _, lo, hi = reaper.TrackFX_GetParam(tr, fx, param)
    if lo and hi and hi > lo then
      return num((value - lo) / (hi - lo) * 100) .. ' percent'
    end
  end
  -- Take pitch, playrate, tempo and the like: their own numbers.
  return num(value)
end

local function main()
  local env = reaper.GetSelectedEnvelope(0)
  -- The selected envelope can sit on any track, or on a take, so the track
  -- named is the one it belongs to, not whichever track is selected.
  local tr = env and reaper.Envelope_GetParentTrack(env)
  local take = env and not tr and reaper.Envelope_GetParentTake(env)
  if take then tr = reaper.GetMediaItemTake_Track(take) end
  tr = tr or reaper.GetSelectedTrack(0, 0) or reaper.GetLastTouchedTrack()
  if not tr then
    a11y.abort('No track selected.')
  end

  local name = track_name(tr)
  if not env then
    a11y.speak(name .. ', no envelope selected. Use automate plugin parameter ' ..
               'by name, or the OSARA action for selecting the next envelope.')
    return
  end

  local parts = { string.format('%s on %s%s.', envelope_name(env),
                                take and 'an item on ' or '', name) }

  local mode = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_AUTOMODE'))
  parts[#parts + 1] = 'Automation mode ' ..
                      (AUTOMATION_MODES[mode] or ('mode ' .. mode)) .. '.'

  local override = reaper.GetGlobalAutomationOverride()
  if override and override >= 0 then
    parts[#parts + 1] = 'Global override is ' ..
                        (OVERRIDE_MODES[override] or ('mode ' .. override)) .. '.'
  end

  -- Only worth saying when it is not the case, since armed and visible are
  -- the states someone would expect after creating an envelope.
  if chunk_flag(env, 'ARM') == false then parts[#parts + 1] = 'Not armed.' end
  if chunk_flag(env, 'VIS') == false then parts[#parts + 1] = 'Hidden.' end

  local count = reaper.CountEnvelopePoints(env)
  parts[#parts + 1] = a11y.plural(count, 'point') .. '.'

  -- A take envelope keeps its points in the item's own time.
  local cursor, rate = a11y.envelope_time(env, reaper.GetCursorPosition())
  local _, value = reaper.Envelope_Evaluate(env, cursor, 44100, 0)
  parts[#parts + 1] = 'At the cursor, ' .. value_phrase(env, value) .. '.'

  -- Which way to jump, so the next keystroke is an informed one.
  local previous = reaper.GetEnvelopePointByTime(env, cursor)
  if previous and previous >= 0 then
    local ok, time = reaper.GetEnvelopePoint(env, previous)
    if ok and time then
      local gap = (cursor - time) / rate
      if gap < 0.005 then
        parts[#parts + 1] = 'Sitting on a point.'
      else
        parts[#parts + 1] = 'Previous point ' .. a11y.time_phrase(gap) .. ' back.'
      end
    end
  else
    parts[#parts + 1] = 'No point before the cursor.'
  end

  local next_index = (previous or -1) + 1
  if next_index < count then
    local ok, time = reaper.GetEnvelopePoint(env, next_index)
    if ok and time and time > cursor then
      parts[#parts + 1] = 'Next point ' .. a11y.time_phrase((time - cursor) / rate) .. ' ahead.'
    end
  else
    parts[#parts + 1] = 'No point after the cursor.'
  end

  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if end_time > start_time then
    parts[#parts + 1] = 'Time selection ' ..
                        a11y.time_phrase(end_time - start_time) .. ', ready to ramp.'
  else
    parts[#parts + 1] = 'No time selection.'
  end

  a11y.speak(table.concat(parts, ' '))
end

a11y.run(main)
