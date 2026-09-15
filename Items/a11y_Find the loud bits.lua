--[[
  @description Find the loud bits (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Asks you for a level, then speaks every moment in the selected items
    that goes over it, with the time and how loud it got. Answers "where
    is it too hot" without staring at a meter for six minutes.

    Defaults to minus 1 dB, which is where a master starts running out of
    room. Type a different number for a different question: minus 20 finds
    the loudest gestures in a quiet bed.

    It reads each item's own audio, so it hears the file rather than the
    track after FX, volume and envelopes. If nothing here is over the line
    but your master is clipping, the level is being added further down the
    chain and this is the wrong end to look.

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

local RATE = 100          -- peaks per second: fine enough to time a transient
local MAX_SPOKEN = 8

local function main()
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    a11y.abort('Select the items you want checked first.')
  end

  local answer = a11y.prompt('Find the loud bits',
                             'Speak anything louder than (dB)',
                             a11y.recall('loud_threshold', '-1'))
  if not answer then a11y.abort('Left it alone.') end
  local threshold = tonumber((answer:gsub('[^%-%d%.]', '')))
  if not threshold then
    a11y.abort('I could not read "' .. answer .. '" as a number of decibels.')
  end
  a11y.remember('loud_threshold', threshold)

  local found, loudest, loudest_at, unreadable = {}, -math.huge, 0, 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    if take and not reaper.TakeIsMIDI(take) then
      local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local offset = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
      local levels = a11y.read_levels(take, RATE, offset, length)
      if #levels == 0 then
        unreadable = unreadable + 1
      else
        for _, hit in ipairs(a11y.loud_points(levels, RATE, threshold)) do
          hit.at = hit.at + pos
          hit.name = reaper.GetTakeName(take)
          if hit.name == '' then hit.name = 'unnamed item' end
          found[#found + 1] = hit
        end
        for _, level in ipairs(levels) do
          local db = a11y.gain_to_db(level)
          if db > loudest then loudest = db end
        end
      end
    end
  end

  table.sort(found, function(a, b) return a.peak_db > b.peak_db end)

  local note = ''
  if unreadable > 0 then
    note = string.format(' %s I could not read, so they are not in this answer.',
                         a11y.plural(unreadable, 'item', 'items'))
  end

  if #found == 0 then
    a11y.speak(string.format(
      'Nothing over %.1f dB in %s. The loudest thing in there is %.1f dB.%s',
      threshold, a11y.plural(count, 'item'), loudest, note))
    return
  end

  local lines = {}
  local shown = math.min(#found, MAX_SPOKEN)
  for i = 1, shown do
    local h = found[i]
    lines[#lines + 1] = string.format('%.1f dB at %s in %s, lasting %s',
                                      h.peak_db,
                                      reaper.format_timestr(h.at, ''),
                                      h.name,
                                      a11y.time_phrase(h.length))
  end

  local tail = ''
  if #found > shown then
    tail = string.format(' And %d quieter ones over the line.', #found - shown)
  end

  a11y.speak(string.format('%s over %.1f dB, loudest first. ',
                           a11y.plural(#found, 'moment'), threshold) ..
             table.concat(lines, '. ') .. '.' .. tail .. note)
end

a11y.run(main)
