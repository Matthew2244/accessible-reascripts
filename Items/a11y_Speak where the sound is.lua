--[[
  @description Speak where the sound is (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Walks the selected item's audio and tells you where the sound actually
    lives: "0 seconds to 4.5 seconds, peak minus 3 dB, quiet for 1.1
    seconds, 5.6 seconds to 22 seconds". The times count from the start of
    the item, not the project.

    This is how you find the chime buried at the head of a file, or notice
    that a stem you were told was a train is thirty seconds of nothing
    followed by a door. Both really happened.

    It reads the item's own audio. Track FX, track volume and any envelope
    are not part of what it hears, so it tells you what is in the file
    rather than what the mix is doing with it.

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

-- Peaks per second. 40 puts the edges within a frame of where you would
-- draw them and keeps a six minute item well under a second of work.
local RATE = 40

-- Past this many the list stops being something you can hold in your head.
local MAX_SPOKEN = 10

local function main()
  if reaper.CountSelectedMediaItems(0) == 0 then
    a11y.abort('Select an item first, then I can tell you what is in it.')
  end
  local item = reaper.GetSelectedMediaItem(0, 0)
  local take = reaper.GetActiveTake(item)
  if not take then
    a11y.abort('That item has no take, so there is no audio to look at.')
  end
  if reaper.TakeIsMIDI(take) then
    a11y.abort('That is a MIDI take. This one reads audio.')
  end

  local length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local levels = a11y.read_levels(take, RATE, pos, length)
  if #levels == 0 then
    a11y.abort('I could not read the audio for that item. If it is still ' ..
               'building peaks, give it a moment and try again.')
  end

  local spans = a11y.spans(levels, RATE, { threshold_db = a11y.SILENCE_DB })
  local name = reaper.GetTakeName(take)
  if name == '' then name = 'this item' end

  if #spans == 0 then
    a11y.speak(name .. ': silent all the way through, ' ..
               a11y.time_phrase(length) .. ' of nothing.')
    return
  end

  local parts = {}
  local shown = math.min(#spans, MAX_SPOKEN)
  for i = 1, shown do
    local s = spans[i]
    parts[#parts + 1] = string.format('%s to %s, peak %.1f dB',
                                      a11y.time_phrase(s.start),
                                      a11y.time_phrase(s.stop),
                                      s.peak_db)
    local nxt = spans[i + 1]
    if nxt and i < shown then
      parts[#parts + 1] = string.format('quiet for %s',
                                        a11y.time_phrase(nxt.start - s.stop))
    end
  end

  local head
  if #spans == 1 then
    head = string.format('%s: one stretch of sound in %s. ', name,
                         a11y.time_phrase(length))
  else
    head = string.format('%s: %s of sound in %s. ', name,
                         a11y.plural(#spans, 'stretch', 'stretches'),
                         a11y.time_phrase(length))
  end

  local lead = spans[1].start
  if lead > 0.05 then
    head = head .. string.format('Nothing for the first %s. ',
                                 a11y.time_phrase(lead))
  end

  local tail = ''
  if #spans > shown then
    tail = string.format(' And %d more not spoken.', #spans - shown)
  end
  local trailing = length - spans[#spans].stop
  if trailing > 0.05 and #spans <= shown then
    tail = tail .. string.format(' Then %s of nothing to the end.',
                                 a11y.time_phrase(trailing))
  end

  a11y.speak(head .. table.concat(parts, ', ') .. '.' .. tail)
end

a11y.run(main)
