--[[
  @description Find edges that could click (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Walks every item in the project and finds the item edges that are not
    protected by a fade, and that have real audio sitting right on them.
    Those are the ones that tick. Speaks them loudest first, with the track,
    the time and how loud the audio is at the edge, then offers to lengthen
    the fades in one undo step.

    Reaper puts a 10 millisecond fade on a split by default. That is a
    declick, not a fade, and it is short enough to hear on a bed or a tail.
    Splitting one item can also split items on tracks you were not looking
    at, so the edge that ticks is often not the one you made.

    Three kinds of edge, treated differently:

      Open edge. Nothing next to it. A short fade here can tick, and this
      is what the script offers to fix.

      Split join. Two items butting exactly end to start. The pair of short
      fades makes a dip rather than a tick, and lengthening them makes the
      dip wider. The fix is to overlap the two items so Reaper crossfades
      them, which is an edit this script will not make for you. It reports
      them so you can find them.

      Crossfade. The items already overlap. Skipped.

    It reads each item's own audio, so it hears the file rather than the
    track after FX, volume and envelopes. It cannot tell you whether an edge
    is audible in the mix, only that the edge is exposed and there is sound
    on it. A tick 40 dB under everything else is real and inaudible.

    Finding changes nothing. Only the fix step edits the project, and only
    after you say yes.
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

local RATE = 400          -- peaks per second: 2.5 ms, fine enough to sit on an edge
local WINDOW = 0.03       -- how much audio at the edge counts as "on the edge"
local TOUCH = 0.0005      -- closer than this and two items are butting, not apart
local MAX_SPOKEN = 8

--- The fade Reaper will actually apply at an edge. An auto-crossfade of
--- zero or more overrides the item's own fade; -1 means there is none.
local function effective_fade(item, which)
  local auto = reaper.GetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'LEN_AUTO')
  if auto >= 0 then return auto, true end
  return reaper.GetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'LEN'), false
end

--- Loudest peak in the take's own audio across `window` project-seconds at
--- one end of the item. Returns dB, or nil if the audio could not be read.
local function level_at_edge(item, take, at_start)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local length = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local offset = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
  local rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if not rate or rate <= 0 then rate = 1 end
  local window = math.min(WINDOW, length) * rate
  if window <= 0 then return nil end
  local from = offset
  if not at_start then
    from = math.max(0, offset + length * rate - window)
  end
  local levels = a11y.read_levels(take, RATE, from, window)
  if #levels == 0 then return nil end
  local peak = 0
  for _, v in ipairs(levels) do if v > peak then peak = v end end
  return a11y.gain_to_db(peak)
end

--- Every item in the project, grouped by track, each with its neighbours
--- worked out. Returns the list and how many items were looked at.
local function collect_edges(max_fade)
  local open_edges, joins = {}, {}
  local items, unreadable = 0, 0

  for t = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, t)
    local tracknum = reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')
    local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
    local label = a11y.track_label(tracknum, trackname)

    local on_track = {}
    for j = 0, reaper.CountTrackMediaItems(track) - 1 do
      local item = reaper.GetTrackMediaItem(track, j)
      on_track[#on_track + 1] = {
        item = item,
        pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
        len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
      }
    end
    table.sort(on_track, function(a, b) return a.pos < b.pos end)

    for k, entry in ipairs(on_track) do
      items = items + 1
      local item = entry.item
      local take = reaper.GetActiveTake(item)
      local name = take and reaper.GetTakeName(take) or ''
      if name == '' then name = 'unnamed item' end
      local prev, next_ = on_track[k - 1], on_track[k + 1]

      local sides = {
        { which = 'IN',  at_start = true,  time = entry.pos,
          gap = prev and (entry.pos - (prev.pos + prev.len)) or nil },
        { which = 'OUT', at_start = false, time = entry.pos + entry.len,
          gap = next_ and (next_.pos - (entry.pos + entry.len)) or nil },
      }

      for _, side in ipairs(sides) do
        local overlapping = side.gap ~= nil and side.gap < -TOUCH
        local butting = side.gap ~= nil and math.abs(side.gap) <= TOUCH
        if not overlapping then
          local fade, from_auto = effective_fade(item, side.which)
          if fade <= max_fade then
            local db = level_at_edge(item, take, side.at_start)
            if db == nil then
              if take and not reaper.TakeIsMIDI(take) then unreadable = unreadable + 1 end
            elseif db >= a11y.SILENCE_DB then
              local rec = { item = item, which = side.which, time = side.time,
                            fade = fade, auto = from_auto, db = db,
                            name = name, track = label }
              if butting then joins[#joins + 1] = rec else open_edges[#open_edges + 1] = rec end
            end
          end
        end
      end
    end
  end

  table.sort(open_edges, function(a, b) return a.db > b.db end)
  table.sort(joins, function(a, b) return a.db > b.db end)
  return open_edges, joins, items, unreadable
end

local function describe(e)
  return string.format('%s at %s on %s, %s, audio %.1f dB',
                       e.which == 'IN' and 'start' or 'end',
                       reaper.format_timestr(e.time, ''),
                       e.track,
                       e.name,
                       e.db)
end

local function main()
  if reaper.CountTracks(0) == 0 then
    a11y.abort('This project has no tracks.')
  end

  local answer = a11y.prompt('Find edges that could click',
                             'Flag fades shorter than (milliseconds)',
                             a11y.recall('click_fade_ms', '10'))
  if not answer then a11y.abort('Left it alone.') end
  local ms = tonumber((answer:gsub('[^%d%.]', '')))
  if not ms or ms < 0 then
    a11y.abort('I could not read "' .. answer .. '" as a number of milliseconds.')
  end
  a11y.remember('click_fade_ms', ms)

  local open_edges, joins, items, unreadable = collect_edges(ms / 1000)

  local note = ''
  if unreadable > 0 then
    note = string.format(' %s I could not read the audio of, so they are not in this answer.',
                         a11y.plural(unreadable, 'edge', 'edges'))
  end
  local joins_note = ''
  if #joins > 0 then
    joins_note = string.format(
      ' Also %s where two items butt exactly. Those make a dip rather than a tick, and the fix is to overlap the items, which I will not do for you.',
      a11y.plural(#joins, 'split join'))
    local shown = {}
    for i = 1, math.min(#joins, 3) do shown[#shown + 1] = describe(joins[i]) end
    joins_note = joins_note .. ' Loudest: ' .. table.concat(shown, '. ') .. '.'
  end

  if #open_edges == 0 then
    a11y.speak(string.format(
      'Checked %s. No open edge has a fade under %g milliseconds with sound on it.%s%s',
      a11y.plural(items, 'item'), ms, joins_note, note))
    return
  end

  local lines = {}
  local shown = math.min(#open_edges, MAX_SPOKEN)
  for i = 1, shown do lines[#lines + 1] = describe(open_edges[i]) end
  local tail = ''
  if #open_edges > shown then
    tail = string.format(' And %d quieter ones.', #open_edges - shown)
  end

  a11y.speak(string.format('%s exposed in %s, loudest first. ',
                           a11y.plural(#open_edges, 'open edge'),
                           a11y.plural(items, 'item')) ..
             table.concat(lines, '. ') .. '.' .. tail .. joins_note .. note)

  if not a11y.confirm('Find edges that could click',
                      string.format('Lengthen the fade on %s?',
                                    a11y.plural(#open_edges, 'open edge'))) then
    a11y.speak('Left them alone. Nothing changed.')
    return
  end

  local reply = a11y.prompt('Lengthen fades', 'Fade length (milliseconds)',
                            a11y.recall('click_fix_ms', '20'))
  if not reply then a11y.abort('Cancelled. Nothing changed.') end
  local want = tonumber((reply:gsub('[^%d%.]', '')))
  if not want or want <= 0 then
    a11y.abort('I could not read "' .. reply .. '" as a number of milliseconds. Nothing changed.')
  end
  a11y.remember('click_fix_ms', want)
  local seconds = want / 1000

  reaper.Undo_BeginBlock()
  local changed, shortened = 0, 0
  for _, e in ipairs(open_edges) do
    local len = reaper.GetMediaItemInfo_Value(e.item, 'D_LENGTH')
    local other = reaper.GetMediaItemInfo_Value(
      e.item, e.which == 'IN' and 'D_FADEOUTLEN' or 'D_FADEINLEN')
    -- The two fades share the item, so never let them cross.
    local room = math.max(0, len - math.max(other, 0))
    local apply = math.min(seconds, room)
    if apply < seconds then shortened = shortened + 1 end
    if apply > e.fade then
      reaper.SetMediaItemInfo_Value(e.item, 'D_FADE' .. e.which .. 'LEN', apply)
      -- An auto-crossfade value would override what we just set.
      reaper.SetMediaItemInfo_Value(e.item, 'D_FADE' .. e.which .. 'LEN_AUTO', -1)
      changed = changed + 1
    end
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Lengthen fades on exposed item edges', -1)

  local msg = string.format('Set %s of fade on %s.', a11y.time_phrase(seconds),
                            a11y.plural(changed, 'edge'))
  if changed < #open_edges then
    msg = msg .. string.format(' %s already had more than that and were left alone.',
                               a11y.plural(#open_edges - changed, 'edge was', 'edges were'))
  end
  if shortened > 0 then
    msg = msg .. string.format(' %s too short to hold the whole fade, so it was shortened to fit there.',
                               a11y.plural(shortened, 'item was', 'items were'))
  end
  a11y.speak(msg)
end

a11y.run(main)
