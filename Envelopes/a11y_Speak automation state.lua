--[[
  @description Speak automation state (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
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

local function round(n)
  return math.floor(n * 100 + 0.5) / 100
end

--- The value under the cursor, in the units a person thinks in.
local function value_phrase(env, value)
  local name = envelope_name(env):lower()
  if name == 'mute' then
    return value >= 0.5 and 'muted' or 'unmuted'
  end
  if name == 'volume' or name == 'volume (pre-fx)' then
    local mode = reaper.GetEnvelopeScalingMode(env)
    local db = a11y.gain_to_db(reaper.ScaleFromEnvelopeMode(mode, value))
    return round(db) .. ' dB'
  end
  return round(value * 100) .. ' percent'
end

local function main()
  local tr = reaper.GetSelectedTrack(0, 0) or reaper.GetLastTouchedTrack()
  if not tr then
    a11y.abort('No track selected.')
  end

  local name = track_name(tr)
  local env = reaper.GetSelectedEnvelope(0)
  if not env then
    a11y.speak(name .. ', no envelope selected. Use automate plugin parameter ' ..
               'by name, or the OSARA action for selecting the next envelope.')
    return
  end

  local parts = { string.format('%s on %s.', envelope_name(env), name) }

  local mode = math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_AUTOMODE'))
  parts[#parts + 1] = 'Automation mode ' ..
                      (AUTOMATION_MODES[mode] or ('mode ' .. mode)) .. '.'

  local override = reaper.GetGlobalAutomationOverride()
  if override and override >= 0 then
    parts[#parts + 1] = 'Global override is ' ..
                        (AUTOMATION_MODES[override] or ('mode ' .. override)) .. '.'
  end

  -- Only worth saying when it is not the case, since armed and visible are
  -- the states someone would expect after creating an envelope.
  if chunk_flag(env, 'ARM') == false then parts[#parts + 1] = 'Not armed.' end
  if chunk_flag(env, 'VIS') == false then parts[#parts + 1] = 'Hidden.' end

  local count = reaper.CountEnvelopePoints(env)
  parts[#parts + 1] = a11y.plural(count, 'point') .. '.'

  local cursor = reaper.GetCursorPosition()
  local _, value = reaper.Envelope_Evaluate(env, cursor, 44100, 0)
  parts[#parts + 1] = 'At the cursor, ' .. value_phrase(env, value) .. '.'

  -- Which way to jump, so the next keystroke is an informed one.
  local previous = reaper.GetEnvelopePointByTime(env, cursor)
  if previous and previous >= 0 then
    local ok, time = reaper.GetEnvelopePoint(env, previous)
    if ok and time then
      local gap = cursor - time
      if gap < 0.005 then
        parts[#parts + 1] = 'Sitting on a point.'
      else
        parts[#parts + 1] = 'Previous point ' .. round(gap) .. ' seconds back.'
      end
    end
  else
    parts[#parts + 1] = 'No point before the cursor.'
  end

  local next_index = (previous or -1) + 1
  if next_index < count then
    local ok, time = reaper.GetEnvelopePoint(env, next_index)
    if ok and time and time > cursor then
      parts[#parts + 1] = 'Next point ' .. round(time - cursor) .. ' seconds ahead.'
    end
  else
    parts[#parts + 1] = 'No point after the cursor.'
  end

  local start_time, end_time = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if end_time > start_time then
    parts[#parts + 1] = 'Time selection ' ..
                        a11y.duration_phrase(end_time - start_time) .. ', ready to ramp.'
  else
    parts[#parts + 1] = 'No time selection.'
  end

  a11y.speak(table.concat(parts, ' '))
end

a11y.run(main)
