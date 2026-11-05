--[[
  @description Where does this project really end (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Finds the last moment anything is actually audible, and compares it
    with where the project stops and where a render would stop. If those
    disagree you are about to bounce dead air onto the end of your piece.

    That is not a hypothetical. A finished six minute piece went out to a
    mixer with three seconds of silence on the end, because the render was
    bounded by the longest item rather than by the music, and nobody could
    see it.

    It reads the items' own audio, so a tail created entirely by a reverb
    plugin on a track is not counted. Where that matters it says so.

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

local RATE = 40

--- Every item in the project, latest ending first.
local function items_by_end()
  local all = {}
  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      -- A muted item, or one on a muted track, is not in a render.
      if reaper.GetMediaItemInfo_Value(item, 'B_MUTE') == 0
         and reaper.GetMediaTrackInfo_Value(track, 'B_MUTE') == 0 then
        local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
        local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
        all[#all + 1] = { item = item, pos = pos, len = len, stop = pos + len }
      end
    end
  end
  table.sort(all, function(a, b) return a.stop > b.stop end)
  return all
end

local function main()
  local all = items_by_end()
  if #all == 0 then
    a11y.abort('There are no unmuted items in this project to listen to.')
  end

  local last_audible, last_name, unreadable = nil, nil, 0

  for _, entry in ipairs(all) do
    -- Once an item cannot possibly end later than what we have found,
    -- there is nothing left to learn.
    if last_audible and entry.stop <= last_audible then break end
    local take = reaper.GetActiveTake(entry.item)
    if take and not reaper.TakeIsMIDI(take) then
      local levels = a11y.read_levels(take, RATE, entry.pos, entry.len)
      if #levels == 0 then
        unreadable = unreadable + 1
      else
        local spans = a11y.spans(levels, RATE, { min_sound = 0.02, min_gap = 0.05 })
        if #spans > 0 then
          local stop = entry.pos + spans[#spans].stop
          if not last_audible or stop > last_audible then
            last_audible = stop
            last_name = reaper.GetTakeName(take)
            if last_name == '' then last_name = 'an unnamed item' end
          end
        end
      end
    elseif take then
      -- MIDI has no peaks to read, so trust its item end.
      if not last_audible or entry.stop > last_audible then
        last_audible = entry.stop
        last_name = 'a MIDI item'
      end
    end
  end

  if not last_audible then
    a11y.abort('I could not find any audible material to measure against.')
  end

  local project_end = reaper.GetProjectLength(0)
  local parts = {}
  parts[#parts + 1] = string.format('Last sound at %s, in %s.',
                                    reaper.format_timestr(last_audible, ''),
                                    last_name)

  local slack = project_end - last_audible
  if slack > 0.25 then
    parts[#parts + 1] = string.format(
      'The project runs to %s, so there is %s of nothing after it.',
      reaper.format_timestr(project_end, ''), a11y.time_phrase(slack))
  else
    parts[#parts + 1] = 'The project stops with the sound, which is what you want.'
  end

  -- Render bounds only matter when they are set to something fixed: 0 is
  -- custom bounds, 2 the time selection. Each can also carry a render tail,
  -- which adds its own silence after the end.
  local flag = math.floor(reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 0, false))
  local tail_bits = math.floor(reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, false))
  local tail = reaper.GetSetProjectInfo(0, 'RENDER_TAILMS', 0, false) / 1000
  local from, to, kind, tail_bit
  if flag == 0 then
    from = reaper.GetSetProjectInfo(0, 'RENDER_STARTPOS', 0, false)
    to = reaper.GetSetProjectInfo(0, 'RENDER_ENDPOS', 0, false)
    kind, tail_bit = 'a fixed range', 1
  elseif flag == 2 then
    from, to = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    kind, tail_bit = 'the time selection', 4
  elseif flag == 1 then
    tail_bit = 2
  end
  local with_tail = tail_bit and (tail_bits & tail_bit) ~= 0 and tail > 0
  if flag == 1 and with_tail then
    parts[#parts + 1] = string.format('Rendering the whole project adds a %s tail.',
                                      a11y.time_phrase(tail))
  end
  if from and to and to > from then
    if with_tail then to = to + tail end
    local over = to - last_audible
    if over > 0.25 then
      parts[#parts + 1] = string.format(
        'Your render is set to %s ending at %s%s, so a bounce ' ..
        'would carry %s of silence. Worth moving before you send it anywhere.',
        kind, reaper.format_timestr(to, ''), with_tail and ', counting the tail' or '',
        a11y.time_phrase(over))
    else
      parts[#parts + 1] = string.format('Render range is %s to %s, which fits.',
                                        reaper.format_timestr(from, ''),
                                        reaper.format_timestr(to, ''))
    end
  end

  if unreadable > 0 then
    parts[#parts + 1] = string.format(
      '%s I could not read, so treat this as the earliest honest answer.',
      a11y.plural(unreadable, 'item', 'items'))
  end

  parts[#parts + 1] = 'Reverb tails made by a plugin are not counted here.'

  a11y.speak(table.concat(parts, ' '))
end

a11y.run(main)
