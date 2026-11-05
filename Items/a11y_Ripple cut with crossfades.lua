--[[
  @description Ripple cut with crossfades (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Takes the time selection out of the selected tracks, or every track if
    none is selected, and closes the gap, then crossfades every join it
    just made, so the edit does not click or drop a hole in a room tone.
    Only items move. Envelopes, markers, regions and tempo stay where they
    are, so automation after the cut will sit later than the audio it
    belonged to.

    Reaper's own ripple edit closes the gap. What it does not do is make
    sure the join is crossfaded at a length you chose, and a butt splice in
    the middle of an ambience bed is audible even when the waveform looks
    innocent. Ask anyone who has had a twelve second cut come back with
    "there is a chop right there".

    Where a take has audio before its start it gets a true overlapping
    crossfade. Where it does not, which happens when the edit lands at the
    very beginning of a recording, it gets matched fades instead, and the
    script tells you how many of each you got.

    One undo point for the whole thing.
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

local EPS = 0.0000001

--- Items on a track, in time order, as a plain array we can re-read after
--- splitting without fighting Reaper's own ordering.
local function track_items(track)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    out[#out + 1] = reaper.GetTrackMediaItem(track, i)
  end
  table.sort(out, function(a, b)
    return reaper.GetMediaItemInfo_Value(a, 'D_POSITION')
         < reaper.GetMediaItemInfo_Value(b, 'D_POSITION')
  end)
  return out
end

local function pos_of(item) return reaper.GetMediaItemInfo_Value(item, 'D_POSITION') end
local function len_of(item) return reaper.GetMediaItemInfo_Value(item, 'D_LENGTH') end

--- Split every item that straddles `at`, so nothing crosses the line.
local function split_across(track, at)
  for _, item in ipairs(track_items(track)) do
    local pos = pos_of(item)
    local stop = pos + len_of(item)
    if pos < at - EPS and stop > at + EPS then
      reaper.SplitMediaItem(item, at)
    end
  end
end

local function main()
  local from, to = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if to - from < 0.001 then
    a11y.abort('Make a time selection first. That is the bit I take out.')
  end

  local tracks = {}
  local selected = reaper.CountSelectedTracks(0)
  if selected > 0 then
    for i = 0, selected - 1 do tracks[#tracks + 1] = reaper.GetSelectedTrack(0, i) end
  else
    for i = 0, reaper.CountTracks(0) - 1 do tracks[#tracks + 1] = reaper.GetTrack(0, i) end
  end
  if #tracks == 0 then
    a11y.abort('There are no tracks to cut.')
  end

  local answer = a11y.prompt('Ripple cut with crossfades',
                             'Crossfade length in milliseconds',
                             a11y.recall('ripple_crossfade_ms', '250'))
  if not answer then a11y.abort('Left it alone.') end
  local ms = tonumber((answer:gsub('[^%d%.%-]', '')))
  if not ms or ms < 0 then
    a11y.abort('I could not read "' .. answer .. '" as a number of milliseconds.')
  end
  a11y.remember('ripple_crossfade_ms', ms)
  local fade = ms / 1000

  local gap = to - from
  local removed, crossfaded, butted, moved = 0, 0, 0, 0
  local shortest = math.huge

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for _, track in ipairs(tracks) do
    split_across(track, from)
    split_across(track, to)

    -- Anything now sitting wholly inside the selection goes.
    for _, item in ipairs(track_items(track)) do
      local pos = pos_of(item)
      if pos >= from - EPS and pos + len_of(item) <= to + EPS then
        reaper.DeleteTrackMediaItem(track, item)
        removed = removed + 1
      end
    end

    -- Close the gap.
    local later = {}
    for _, item in ipairs(track_items(track)) do
      if pos_of(item) >= to - EPS then later[#later + 1] = item end
    end
    for _, item in ipairs(later) do
      reaper.SetMediaItemInfo_Value(item, 'D_POSITION', pos_of(item) - gap)
      moved = moved + 1
    end

    -- Crossfade whatever now meets at the join.
    if fade > 0 then
      local before, after
      for _, item in ipairs(track_items(track)) do
        local pos = pos_of(item)
        local stop = pos + len_of(item)
        if math.abs(stop - from) < 0.001 then before = item end
        if math.abs(pos - from) < 0.001 then after = item end
      end

      if before and after then
        local take = reaper.GetActiveTake(after)
        local headroom, rate = 0, 1
        if take then
          -- The offset is in seconds of the source file. At a playback
          -- rate other than 1 that is a different number of seconds on
          -- the timeline.
          rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
          if rate <= 0 then rate = 1 end
          headroom = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS') / rate
        end
        local overlap = math.min(fade, headroom, len_of(before), len_of(after))
        if overlap > 0.001 and take then
          -- Pull the later item back over the join and play the audio that
          -- was always sitting there in the file, so both sides are real.
          -- Every take moves together, so each one's offset moves too.
          reaper.SetMediaItemInfo_Value(after, 'D_POSITION', pos_of(after) - overlap)
          reaper.SetMediaItemInfo_Value(after, 'D_LENGTH', len_of(after) + overlap)
          for t = 0, reaper.CountTakes(after) - 1 do
            local tk = reaper.GetTake(after, t)
            if tk then
              local r = reaper.GetMediaItemTakeInfo_Value(tk, 'D_PLAYRATE')
              local o = reaper.GetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS')
              reaper.SetMediaItemTakeInfo_Value(tk, 'D_STARTOFFS', o - overlap * r)
            end
          end
          shortest = math.min(shortest, overlap)
          reaper.SetMediaItemInfo_Value(after, 'D_FADEINLEN', overlap)
          reaper.SetMediaItemInfo_Value(before, 'D_FADEOUTLEN', overlap)
          crossfaded = crossfaded + 1
        else
          local short = math.min(fade, len_of(before) / 2, len_of(after) / 2)
          if short > 0.001 then
            reaper.SetMediaItemInfo_Value(before, 'D_FADEOUTLEN', short)
            reaper.SetMediaItemInfo_Value(after, 'D_FADEINLEN', short)
            butted = butted + 1
          end
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Ripple cut with crossfades', -1)

  if removed == 0 and moved == 0 then
    a11y.speak('Nothing to cut. The time selection is empty on ' ..
               (selected > 0 and 'the selected tracks.' or 'every track.'))
    return
  end

  local said = string.format('Cut %s out of %s. %s removed, %s moved earlier.',
                             a11y.time_phrase(gap),
                             a11y.plural(#tracks, 'track'),
                             a11y.plural(removed, 'item'),
                             a11y.plural(moved, 'item'))
  if crossfaded > 0 then
    local got = math.floor(shortest * 1000 + 0.5)
    if got < math.floor(fade * 1000 + 0.5) then
      said = said .. string.format(' %s crossfaded, the shortest over %d milliseconds, ' ..
        'because there was not enough audio before the join for %g.',
        a11y.plural(crossfaded, 'join'), got, ms)
    else
      said = said .. string.format(' %s crossfaded over %g milliseconds.',
                                   a11y.plural(crossfaded, 'join'), ms)
    end
  end
  if butted > 0 then
    said = said .. string.format(
      ' %s had no audio to overlap into, so %s matched fades instead.',
      a11y.plural(butted, 'join'), butted == 1 and 'it got' or 'they got')
  end
  if fade == 0 then
    said = said .. ' No crossfades, since you asked for 0 milliseconds.'
  elseif crossfaded == 0 and butted == 0 then
    said = said .. ' Nothing met at the join, so there was nothing to fade.'
  end
  a11y.speak(said)
end

a11y.run(main)
