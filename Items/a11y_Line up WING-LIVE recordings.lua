--[[
  @description Line up WING-LIVE recordings (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Lines up a console's own recording with the one REAPER made of the same
    performance, to the sample, by listening to a signal both of them
    caught.

    Built for a Behringer WING recording to its WING-LIVE card while REAPER
    records over USB, but it works for any two recordings of the same
    signals that ran off one clock: an X-Live card, a second interface on
    word clock, a backup recorder fed digitally.

    Select every console item you want moved (the multichannel chunk files,
    or the mono files split from them) and one item REAPER recorded. The
    script asks which item is the REAPER one, which console item carries
    the same signal and on which channel, and how far either way to
    search. It then finds the offset and moves every other selected item
    by exactly that much, so chunks that sit end to end stay end to end.

    Same clock means no drift, only one offset, so one match lines up the
    whole session. If the recordings were not on the same clock this is
    the wrong tool: the start will line up and the end will not.

    It refuses rather than guesses. If it cannot find a clear match, or the
    music repeats so exactly that two offsets fit equally well, it says so
    and moves nothing. Try a busier shared signal, such as overheads or a
    vocal, instead.

    The REAPER item is never moved. One undo step.
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

local TITLE = 'Line up WING-LIVE recordings'
local LISTEN_SECONDS = 20   -- how much of the reference is compared
local MIN_SECONDS = 3       -- less than this is not worth trusting
local MAX_RANGE = 600       -- seconds either way; beyond this it gets slow
local BLOCK = 8192          -- frames per audio accessor read

local function channels_phrase(n)
  if n == 1 then return 'mono' end
  if n == 2 then return 'stereo' end
  return string.format('%d channels', n)
end

local function source_folder(source)
  local name = reaper.GetMediaSourceFileName(source, '')
  if (name == nil or name == '') and reaper.GetMediaSourceParent then
    local parent = reaper.GetMediaSourceParent(source)
    if parent then name = reaper.GetMediaSourceFileName(parent, '') end
  end
  return (name or ''):match('^(.*)[\\/]') or ''
end

-- Everything about a selected item the script needs, read once.
local function describe(item)
  local track = reaper.GetMediaItem_Track(item)
  local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  local info = {
    item = item,
    track = track,
    tracknum = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER')),
    trackname = trackname,
    pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
    len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
  }
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      info.take = take
      info.name = reaper.GetTakeName(take)
      if info.name == '' then info.name = 'unnamed take' end
      info.channels = math.floor(reaper.GetMediaSourceNumChannels(source))
      info.rate = reaper.GetMediaSourceSampleRate(source)
      info.offs = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
      info.playrate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
      info.folder = source_folder(source)
    end
  end
  return info
end

local function label(info)
  return string.format('%s, on track %s, at %s, %s', info.name,
                       a11y.track_label(info.tracknum, info.trackname),
                       reaper.format_timestr(info.pos, ''),
                       channels_phrase(info.channels))
end

-- A reader for one channel of a take, in samples from `origin` (project
-- time). Take accessors count time from the start of the item; the check
-- on the start time is there in case a REAPER version ever counts from the
-- project start instead.
local function open_reader(info, channel, origin)
  local acc = reaper.CreateTakeAudioAccessor(info.take)
  local base = info.pos
  local acc_start = reaper.GetAudioAccessorStartTime(acc)
  if info.pos > 0 and math.abs(acc_start - info.pos) < 1e-9 then base = 0 end
  local nch, rate = info.channels, info.rate
  local buf = reaper.new_array(BLOCK * nch)

  local function read(start, count)
    local out, done = {}, 0
    while done < count do
      local n = math.min(BLOCK, count - done)
      buf.clear()
      local t = origin + (start + done) / rate - base
      local got = reaper.GetAudioAccessorSamples(acc, rate, nch, t, n, buf)
      if got == 1 then
        for i = 1, n do out[done + i] = buf[(i - 1) * nch + channel] end
      else
        for i = 1, n do out[done + i] = 0 end
      end
      done = done + n
    end
    return out
  end
  return read, function() reaper.DestroyAudioAccessor(acc) end
end

-- Where in the reference to listen. It must sit where the console item
-- will cover it whatever the offset turns out to be, and it should be busy:
-- drums and speech give a correlation edges to lock onto, a held chord or
-- a quiet intro does not. A handful of short probes per candidate stretch
-- is enough to tell busy from quiet without reading the whole recording.
local function choose_stretch(ref, match, range, read_at)
  local r0, r1 = ref.pos, ref.pos + ref.len
  local s0, s1 = match.pos, match.pos + match.len
  -- Keep a margin inside the console item, so it still covers the stretch
  -- once the offset is applied. The whole search range is the safe margin;
  -- smaller ones are tried next, because a real offset is usually a few
  -- seconds and an item can be shorter than the range allows for. Last
  -- resort, a stretch that only overlaps the item once shifted.
  local tiers = {}
  for _, margin in ipairs({ range, 30, 10, 5, 0 }) do
    if margin <= range then
      tiers[#tiers + 1] = { math.max(r0, s0 + margin), math.min(r1, s1 - margin) }
    end
  end
  tiers[#tiers + 1] = { math.max(r0, s0 - range), math.min(r1, s1 + range) }

  -- More margin beats more listening: ten seconds is plenty to match on,
  -- and a stretch the console item does not cover cannot match at all.
  local lo, hi
  for _, need in ipairs({ math.min(10, LISTEN_SECONDS), MIN_SECONDS }) do
    for _, t in ipairs(tiers) do
      if not lo and t[2] - t[1] >= need then lo, hi = t[1], t[2] end
    end
  end
  if not lo then return nil end

  local length = math.min(LISTEN_SECONDS, hi - lo)
  local starts = {}
  local room = hi - lo - length
  local tries = room > 0 and 10 or 1
  for i = 0, tries - 1 do
    starts[#starts + 1] = lo + (tries > 1 and room * i / (tries - 1) or 0)
  end

  local rate = ref.rate
  local hop = math.max(1, math.floor(rate / 1000 + 0.5))
  local probe = math.floor(rate * 0.5)
  local best, best_score = starts[1], -1
  for _, start in ipairs(starts) do
    local score = 0
    for j = 0, 3 do
      local t = start + (j + 0.5) * length / 4 - 0.25
      local env = a11y.envelope(read_at(t, probe), probe, hop)
      local busy = 0
      for k = 2, #env do busy = busy + math.abs(env[k] - env[k - 1]) end
      score = score + busy
    end
    if score > best_score then best, best_score = start, score end
  end
  return best, length
end

local function main()
  local count = reaper.CountSelectedMediaItems(0)
  if count < 2 then
    a11y.abort((count == 0 and 'Nothing is selected. ' or 'Only one item is selected. ') ..
               'Select the console recordings you want moved, plus one item ' ..
               'recorded in REAPER that shares a signal with them.')
  end

  local all, audio = {}, {}
  for i = 0, count - 1 do
    local info = describe(reaper.GetSelectedMediaItem(0, i))
    all[#all + 1] = info
    if info.take and info.channels > 0 and info.rate > 0 then audio[#audio + 1] = info end
  end
  if #audio < 2 then
    a11y.abort('Fewer than two of the selected items have audio in them, ' ..
               'so there is nothing to compare. Nothing moved.')
  end

  -- The REAPER recording is usually the odd one out: its file sits in the
  -- project folder while the console's files share a folder of their own.
  -- Listing the smallest group first puts it near the top of the list.
  local per_folder = {}
  for _, info in ipairs(audio) do
    per_folder[info.folder] = (per_folder[info.folder] or 0) + 1
  end
  local by_folder = {}
  for i, info in ipairs(audio) do by_folder[i] = info end
  table.sort(by_folder, function(a, b)
    local ca, cb = per_folder[a.folder], per_folder[b.folder]
    if ca ~= cb then return ca < cb end
    if a.tracknum ~= b.tracknum then return a.tracknum < b.tracknum end
    return a.pos < b.pos
  end)
  local ref = a11y.pick('Which item did REAPER record (line up to it)?', by_folder, label)
  if not ref then a11y.abort('Cancelled. Nothing moved.') end

  -- Candidates for the matching item: those near the reference in time
  -- first, then those whose track name sounds like the reference's.
  local range_guess = tonumber(a11y.recall('wing_range', '60')) or 60
  local others = {}
  for _, info in ipairs(audio) do
    if info ~= ref then
      local near = info.pos < ref.pos + ref.len + range_guess and
                   info.pos + info.len > ref.pos - range_guess
      local s = a11y.score(ref.trackname, info.trackname) or 0
      others[#others + 1] = { info = info, near = near and 1 or 0, s = s }
    end
  end
  table.sort(others, function(a, b)
    if a.near ~= b.near then return a.near > b.near end
    if a.s ~= b.s then return a.s > b.s end
    if a.info.tracknum ~= b.info.tracknum then return a.info.tracknum < b.info.tracknum end
    return a.info.pos < b.info.pos
  end)
  local candidates = {}
  for i, o in ipairs(others) do candidates[i] = o.info end
  local match = a11y.pick('Which console item has the same signal?', candidates, label)
  if not match then a11y.abort('Cancelled. Nothing moved.') end

  for _, info in ipairs({ ref, match }) do
    if math.abs(info.playrate - 1) > 1e-9 then
      a11y.abort(string.format('%s plays at rate %.3f, not 1. Lining up assumes both ' ..
                               'recordings play at their own speed. Reset the rate first. ' ..
                               'Nothing moved.', info.name, info.playrate))
    end
  end
  if math.abs(ref.rate - match.rate) > 0.5 then
    a11y.abort(string.format('The two recordings are at different sample rates, %d and %d. ' ..
                             'They cannot have come off the same clock. Nothing moved.',
                             math.floor(ref.rate + 0.5), math.floor(match.rate + 0.5)))
  end

  -- One dialog for the remaining questions.
  local captions, defaults, fields = {}, {}, {}
  if match.channels > 1 then
    captions[#captions + 1] = string.format('Console channel with the signal (1 to %d)',
                                            match.channels)
    local last = tonumber(a11y.recall('wing_sd_channel', '1')) or 1
    defaults[#defaults + 1] = last <= match.channels and last or 1
    fields.match = #captions
  end
  if ref.channels > 1 then
    captions[#captions + 1] = string.format('REAPER item channel (1 to %d)', ref.channels)
    defaults[#defaults + 1] = 1
    fields.ref = #captions
  end
  captions[#captions + 1] = 'Search this many seconds either way'
  defaults[#defaults + 1] = a11y.recall('wing_range', '60')
  fields.range = #captions

  local answers = a11y.prompt_many(TITLE, captions, defaults, 80)
  if not answers then a11y.abort('Cancelled. Nothing moved.') end

  local function channel_answer(key, info, what)
    if not fields[key] then return 1 end
    local text = answers[fields[key]]
    local n = tonumber((text:gsub('%s', '')))
    if not n or n ~= math.floor(n) or n < 1 or n > info.channels then
      a11y.abort(string.format('"%s" is not a channel number from 1 to %d for the %s. ' ..
                               'Nothing moved.', text, info.channels, what))
    end
    return math.floor(n)
  end
  local match_ch = channel_answer('match', match, 'console item')
  local ref_ch = channel_answer('ref', ref, 'REAPER item')
  local range_text = answers[fields.range]
  local range = tonumber((range_text:gsub('[^%d%.]', '')))
  if not range or range <= 0 then
    a11y.abort('I could not read "' .. range_text .. '" as a number of seconds. Nothing moved.')
  end
  if range > MAX_RANGE then
    a11y.abort(string.format('%d seconds either way would take a very long time to search. ' ..
                             'Move the console items roughly into place first, then search ' ..
                             'up to %d seconds. Nothing moved.', math.floor(range), MAX_RANGE))
  end
  if fields.match then a11y.remember('wing_sd_channel', match_ch) end
  a11y.remember('wing_range', range)

  if a11y.has_osara() then
    a11y.speak('Listening to both recordings. This takes a few seconds.')
  end

  local rate = ref.rate
  local ref_src0 = ref.pos - ref.offs
  local result, why, origin, length

  -- Accessors must be destroyed on every path, including a real error, so
  -- the work runs under pcall and anything it raises is re-raised after.
  local read_ref, close_ref = open_reader(ref, ref_ch, 0)
  local ok, err = pcall(function()
    local probe_reader = function(t, n)
      return read_ref(math.floor(t * rate + 0.5), n)
    end
    local start
    start, length = choose_stretch(ref, match, range, probe_reader)
    if not start then why = 'short'; return end
    -- Start on one of the reference's own samples, so its reads are never
    -- interpolated.
    origin = ref_src0 + math.ceil((start - ref_src0) * rate - 1e-6) / rate
    local ref_len = math.floor(length * rate)
    if origin + ref_len / rate > ref.pos + ref.len then ref_len = ref_len - 1 end

    local read_ref2, close_ref2 = open_reader(ref, ref_ch, origin)
    local read_sig, close_sig = open_reader(match, match_ch, origin)
    local ok2, err2 = pcall(function()
      result, why = a11y.align({
        ref = read_ref2,
        sig = read_sig,
        rate = rate,
        ref_len = ref_len,
        range = math.floor(range * rate + 0.5),
        sig_lo = math.ceil((match.pos - origin) * rate),
        sig_hi = math.floor((match.pos + match.len - origin) * rate),
      })
    end)
    close_ref2()
    close_sig()
    if not ok2 then error(err2, 0) end
  end)
  close_ref()
  if not ok then error(err, 0) end

  local pair = string.format('channel %d of %s', match_ch, match.name)
  if not result then
    local reasons = {
      short = 'The REAPER item and ' .. match.name .. ' do not overlap by enough to compare, ' ..
              'even allowing for the search range. Move the console items roughly into ' ..
              'place first, or widen the search.',
      silent_ref = 'The REAPER item is silent where I listened. Pick a reference with ' ..
                   'signal in it.',
      flat_ref = 'The REAPER item does not change in level where I listened, so there is ' ..
                 'nothing to lock onto. Try a busier signal, such as overheads.',
      silent_sig = string.format('%s is silent where it should overlap the reference. ' ..
                                 'Check the channel number.', pair),
      no_overlap = string.format('Within %s either way, %s never covers the stretch of ' ..
                                 'reference I listened to. Widen the search, or move the ' ..
                                 'console items roughly into place first.',
                                 a11y.plural(math.floor(range), 'second'), match.name),
    }
    a11y.abort((reasons[why] or ('The comparison failed: ' .. tostring(why) .. '.')) ..
               ' Nothing moved.')
  end

  if result.confidence == 'low' then
    if result.second >= 0.9 * result.score and result.score >= 0.35 then
      a11y.abort(string.format('Two different offsets fit %s about equally well, so the ' ..
                               'music probably repeats too exactly here. Nothing moved. ' ..
                               'Try a signal with more variety, such as overheads or a vocal.',
                               pair))
    end
    a11y.abort(string.format('Could not find a clear match between the REAPER item and %s. ' ..
                             'Nothing moved. Check the channel number, widen the search, or ' ..
                             'choose a different shared signal, such as overheads.', pair))
  end

  -- The other recording is result.offset samples late. Move it that much
  -- earlier, then snap so its samples land exactly on the reference's: both
  -- were clocked together, so the true answer is a whole number of samples
  -- between the two files.
  local shift = -result.offset / rate
  local match_src0 = match.pos - match.offs
  local delta = (match_src0 + shift) - ref_src0
  delta = math.floor(delta * rate + 0.5) / rate
  shift = ref_src0 + delta - match_src0

  local moving, same_track, earliest = {}, 0, math.huge
  for _, info in ipairs(all) do
    if info ~= ref then
      moving[#moving + 1] = info
      if info.track == ref.track then same_track = same_track + 1 end
      if info.pos < earliest then earliest = info.pos end
    end
  end

  local notes = {}
  notes[#notes + 1] = 'Confidence ' .. result.confidence .. '.'
  if result.confidence == 'medium' then
    notes[#notes + 1] = 'Worth listening at a few spots to check.'
  end
  if result.inverted then
    notes[#notes + 1] = string.format('%s is in opposite polarity to the reference.', pair)
  end

  if math.abs(shift) * rate < 0.5 then
    a11y.speak(string.format('Already lined up to the sample with %s. Nothing moved. %s',
                             pair, table.concat(notes, ' ')))
    return
  end

  if earliest + shift < 0 then
    a11y.abort(string.format('Lining up means moving %s, which would push the first ' ..
                             'console item before the start of the project. Move ' ..
                             'everything later first, then run this again. Nothing moved.',
                             a11y.offset_phrase(shift * rate, rate)))
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  for _, info in ipairs(moving) do
    reaper.SetMediaItemInfo_Value(info.item, 'D_POSITION', info.pos + shift)
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(TITLE, -1)

  local moved = 0
  for _, info in ipairs(moving) do
    local now = reaper.GetMediaItemInfo_Value(info.item, 'D_POSITION')
    if math.abs(now - (info.pos + shift)) < 1e-7 then moved = moved + 1 end
  end
  if moved == 0 then
    a11y.abort('REAPER did not move any of the items. Are they locked? Nothing changed.')
  end

  if same_track > 0 then
    notes[#notes + 1] = string.format('%s on the same track as the reference moved too, ' ..
                                      'so check for overlaps.',
                                      a11y.plural(same_track, 'item', 'items'))
  end
  local missed = ''
  if moved < #moving then
    missed = string.format(' %d did not move, possibly locked.', #moving - moved)
  end

  a11y.speak(string.format('Moved %s %s, matched to the sample on %s.%s %s',
                           a11y.plural(moved, 'item'),
                           a11y.offset_phrase(shift * rate, rate),
                           pair, missed, table.concat(notes, ' ')))
end

a11y.run(main)
