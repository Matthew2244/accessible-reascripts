--[[
  @description Shift the pitch of one note (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Fix one sung or played note that is out of tune, smoothly, without
    touching the notes around it. Put the time selection over the note and
    run this. It asks how many semitones to move it (minus 1 lowers it a
    half step, 0.5 raises it a quarter tone) and how long the glide into
    and out of the new pitch should be.

    The item is split so the note gets a short piece of its own, with
    about 60 milliseconds to spare either side, and the pieces overlap by
    20 milliseconds with fades, so the joins are crossfades rather than
    cuts. Only that middle piece is pitch shifted. It gets a take pitch
    envelope that sits at 0 at both of its edges, glides to the new pitch
    by the time the note starts, holds it, and glides back to 0 just after
    the note ends. The crossfades sit where the pitch is untouched, so you
    hear the note move and nothing else.

    It uses the item under the time selection on a selected item, or on
    the selected track if no item is selected. The time selection has to
    sit inside that one item. Preserve pitch is switched on for the note's
    piece, so its length never changes. An item that already plays at
    another rate, or already has its take pitch set, is going through the
    pitch shifter anyway, so it is not split: the envelope goes on the
    whole item, still at 0 everywhere but the note. If the take already has a pitch
    envelope, the shift is added on top of it, which also means you can
    run this again on the same note to move it further.

    Take pitch is left alone. Only the active take gets the envelope. MIDI
    items are refused, since those want their notes transposed instead.
    The note's piece ends up selected. One undo step.
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

local TITLE = 'Shift the pitch of one note'

-- How far the pieces overlap. Long enough that a join never clicks, short
-- enough that the overlap stays inside audio whose pitch is untouched.
local CROSSFADE = 0.020

-- Untouched audio kept between a crossfade and the start of a glide, so
-- the pitch shifter has settled at 0 before anything moves.
local SETTLE = 0.010

local TOGGLE_TAKE_PITCH_ENVELOPE = 41612 -- Take: Toggle take pitch envelope

local EPS = 0.0005

local function info(item, key) return reaper.GetMediaItemInfo_Value(item, key) end

--- Make one fade a straight line. Going into the note, both sides of the
--- join are the same recording still in phase, because the shifter has not
--- moved anything yet, and REAPER's default equal power fade swells by
--- about 3 dB in the middle of in-phase audio. A straight line keeps the
--- level flat; measured on a render, the swell went away. Coming out of the
--- note, how far the shifter has drifted in phase depends on the shift and
--- the note's length: on renders it swelled for one shift and dipped for
--- another. Equal power is the better bet when the phase is anyone's guess,
--- so that join keeps your default shape.
local function linear(item, which)
  reaper.SetMediaItemInfo_Value(item, 'C_FADE' .. which .. 'SHAPE', 0)
  reaper.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'DIR', 0)
  -- REAPER 7.81 and later read the shape from these instead.
  reaper.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'DIR_NEW', 0)
  reaper.SetMediaItemInfo_Value(item, 'D_FADE' .. which .. 'DIR2_NEW', 0)
end

--- Read a number from a dialog field. Blank means the default.
local function read_number(text, default)
  text = (text or ''):gsub('%s+', ''):gsub('^%+', '')
  if text == '' then return default end
  return tonumber(text)
end

--- "1 semitone", "0.5 semitones", without trailing zeros.
local function semitones_phrase(n)
  local s = string.format('%.2f', math.abs(n)):gsub('0+$', ''):gsub('%.$', '')
  return s .. (s == '1' and ' semitone' or ' semitones')
end

--- Items on `track` that overlap [from, to].
local function items_under(track, from, to)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(track) - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local pos = info(item, 'D_POSITION')
    if pos < to - EPS and pos + info(item, 'D_LENGTH') > from + EPS then
      out[#out + 1] = item
    end
  end
  return out
end

--- The one item the note is in. Selected items win; otherwise the items on
--- the selected tracks. Anything ambiguous stops with a reason.
local function find_item(from, to)
  local found = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local pos = info(item, 'D_POSITION')
    if pos < to - EPS and pos + info(item, 'D_LENGTH') > from + EPS then
      found[#found + 1] = item
    end
  end
  local where = 'selected'
  if #found == 0 then
    if reaper.CountSelectedMediaItems(0) > 0 then
      a11y.abort('None of the selected items is under the time selection. ' ..
                 'Select the item the note is in, or put the time selection on it.')
    end
    local tracks = reaper.CountSelectedTracks(0)
    if tracks == 0 then
      a11y.abort('Select the item or the track the note is on first.')
    end
    for i = 0, tracks - 1 do
      for _, item in ipairs(items_under(reaper.GetSelectedTrack(0, i), from, to)) do
        found[#found + 1] = item
      end
    end
    where = 'on the selected ' .. (tracks == 1 and 'track' or 'tracks')
    if #found == 0 then
      a11y.abort('There is no item under the time selection ' .. where .. '.')
    end
  end
  if #found > 1 then
    a11y.abort(string.format('%s are under the time selection %s. ' ..
      'Select just the one with the note in it.',
      a11y.plural(#found, 'item'), where == 'selected' and 'and selected' or where))
  end
  return found[1]
end

--- The time of a project position inside a take envelope. Take envelope
--- points count from the start of the item, and in the take's own time,
--- so a take at playback rate 2 needs its times doubled.
local function env_time(item_pos, rate, t)
  return (t - item_pos) * rate
end

--- The value of the shift alone at time t, matching the points written
--- below closely enough to add onto points that were already there.
local function bend_at(plan, t)
  if t <= plan.rise_from or t >= plan.fall_to then return 0 end
  if t >= plan.note_from and t <= plan.note_to then return plan.semitones end
  local f
  if t < plan.note_from then
    f = (t - plan.rise_from) / (plan.note_from - plan.rise_from)
  else
    f = (plan.fall_to - t) / (plan.fall_to - plan.note_to)
  end
  return plan.semitones * (1 - math.cos(math.pi * f)) / 2
end

--- Work out every time involved, before anything is edited. Pure, so it
--- can be checked without editing anything.
local function make_plan(item_pos, item_end, note_from, note_to, glide, semitones, no_split)
  local pad = glide + SETTLE + CROSSFADE
  local plan = { semitones = semitones, note_from = note_from, note_to = note_to }

  -- Split points. A side with no room for a split and its crossfade is not
  -- split at all: the note's piece starts or ends with the item instead.
  local cut_in, cut_out = note_from - pad, note_to + pad
  plan.split_in = not no_split and cut_in > item_pos + CROSSFADE and cut_in or nil
  plan.split_out = not no_split and cut_out + CROSSFADE < item_end - CROSSFADE
                   and cut_out or nil

  plan.piece_from = plan.split_in or item_pos
  -- The note's piece runs on over the right-hand piece by one crossfade.
  plan.piece_to = plan.split_out and (plan.split_out + CROSSFADE) or item_end

  -- Untouched audio under the crossfades: the left-hand piece runs on over
  -- the start of the note's piece, so the glide waits until after that.
  local quiet_in = plan.split_in and (plan.split_in + CROSSFADE + SETTLE) or plan.piece_from
  local quiet_out = plan.split_out and (plan.split_out - SETTLE) or plan.piece_to
  plan.rise_from = math.max(note_from - glide, quiet_in)
  plan.fall_to = math.min(note_to + glide, quiet_out)
  if plan.rise_from > note_from then plan.rise_from = note_from end
  if plan.fall_to < note_to then plan.fall_to = note_to end
  plan.squeezed = (note_from - plan.rise_from) < glide - EPS
               or (plan.fall_to - note_to) < glide - EPS
  return plan
end

local function main()
  local from, to = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if to - from < 0.01 then
    a11y.abort('Make a time selection over the note first.')
  end

  local item = find_item(from, to)
  local item_pos = info(item, 'D_POSITION')
  local item_end = item_pos + info(item, 'D_LENGTH')
  if from < item_pos - EPS then
    a11y.abort(string.format('The time selection starts %s before this item does. ' ..
      'Keep it inside one item.', a11y.time_phrase(item_pos - from)))
  end
  if to > item_end + EPS then
    a11y.abort(string.format('The time selection runs %s past the end of this item. ' ..
      'Keep it inside one item.', a11y.time_phrase(to - item_end)))
  end
  if info(item, 'C_LOCK') % 2 == 1 then
    a11y.abort('That item is locked. Unlock it first. Nothing changed.')
  end
  local take = reaper.GetActiveTake(item)
  if not take then
    a11y.abort('That item has no take, so there is no audio to shift.')
  end
  if reaper.TakeIsMIDI(take) then
    a11y.abort('That is a MIDI item. Transpose its notes instead. Nothing changed.')
  end
  local rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if math.abs(rate - 1) > 1e-9
     and reaper.GetMediaItemTakeInfo_Value(take, 'B_PPITCH') == 0 then
    -- Switching preserve pitch on for just the note would drop that piece
    -- back to the pitch of the recording, and the note would jump away
    -- from its neighbours.
    a11y.abort(string.format('That item plays at rate %g without preserve pitch, ' ..
      'so its pitch already comes from the rate. Turn preserve pitch on for ' ..
      'the whole item first, then run this again. Nothing changed.', rate))
  end

  local answers = a11y.prompt_many(TITLE,
    { 'Semitones (minus lowers)', 'Glide in milliseconds' },
    { a11y.recall('note_pitch_semitones', '-1'), a11y.recall('note_pitch_glide_ms', '30') })
  if not answers then a11y.abort('Cancelled. Nothing changed.') end
  local semitones = read_number(answers[1], -1)
  if not semitones or semitones == 0 or math.abs(semitones) > 24 then
    a11y.abort(string.format('%s is not a shift I can use. Type a number of ' ..
      'semitones between minus 24 and 24, other than 0. Nothing changed.',
      answers[1] == '' and 'Blank' or answers[1]))
  end
  local glide_ms = read_number(answers[2], 30)
  if not glide_ms or glide_ms < 0 or glide_ms > 1000 then
    a11y.abort(string.format('%s is not a glide I can use. Type a number of ' ..
      'milliseconds from 0 to 1000. Nothing changed.', answers[2]))
  end
  a11y.remember('note_pitch_semitones', answers[1] ~= '' and answers[1] or '-1')
  a11y.remember('note_pitch_glide_ms', answers[2] ~= '' and answers[2] or '30')
  -- A glide of 0 would put two points at one instant; a millisecond is
  -- inaudible as a glide and keeps the envelope well formed.
  local glide = math.max(glide_ms, 1) / 1000

  -- Splitting exists to keep the rest of the item out of the pitch
  -- shifter. An item already playing at another rate, or already pitched,
  -- is going through it anyway, and splitting it would restart the shifter
  -- at each join: measured on a render at rate 1.5, that cut the level by
  -- 10 dB for a moment at the join. So such an item keeps its shape and
  -- carries the envelope as a whole.
  local whole = math.abs(rate - 1) > 1e-9
             or math.abs(reaper.GetMediaItemTakeInfo_Value(take, 'D_PITCH')) > 1e-9
  local plan = make_plan(item_pos, item_end, from, to, glide, semitones, whole)
  local fade_in = info(item, 'D_FADEINLEN')
  local fade_out = info(item, 'D_FADEOUTLEN')

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Split, then set every edge explicitly. REAPER can be set to overlap
  -- items on its own when splitting, and this must not depend on that.
  local left, note, right = nil, item, nil
  if plan.split_in then
    note = reaper.SplitMediaItem(item, plan.split_in)
    left = item
  end
  if note and plan.split_out then
    right = reaper.SplitMediaItem(note, plan.split_out)
  end
  local split_failed = not note or (plan.split_out and not right)

  if not split_failed then
    if left then
      reaper.SetMediaItemInfo_Value(left, 'D_LENGTH', plan.split_in + CROSSFADE - item_pos)
      reaper.SetMediaItemInfo_Value(left, 'D_FADEINLEN', fade_in)
      reaper.SetMediaItemInfo_Value(left, 'D_FADEOUTLEN', CROSSFADE)
      reaper.SetMediaItemInfo_Value(left, 'D_FADEOUTLEN_AUTO', 0)
      reaper.SetMediaItemInfo_Value(note, 'D_FADEINLEN', CROSSFADE)
      reaper.SetMediaItemInfo_Value(note, 'D_FADEINLEN_AUTO', 0)
      linear(left, 'OUT')
      linear(note, 'IN')
    end
    reaper.SetMediaItemInfo_Value(note, 'D_LENGTH', plan.piece_to - plan.piece_from)
    if right then
      reaper.SetMediaItemInfo_Value(note, 'D_FADEOUTLEN', CROSSFADE)
      reaper.SetMediaItemInfo_Value(note, 'D_FADEOUTLEN_AUTO', 0)
      reaper.SetMediaItemInfo_Value(right, 'D_FADEINLEN', CROSSFADE)
      reaper.SetMediaItemInfo_Value(right, 'D_FADEINLEN_AUTO', 0)
      reaper.SetMediaItemInfo_Value(right, 'D_FADEOUTLEN', fade_out)
    end

    take = reaper.GetActiveTake(note)
    reaper.SetMediaItemTakeInfo_Value(take, 'B_PPITCH', 1)

    local env = reaper.GetTakeEnvelopeByName(take, 'Pitch')
    if not env then
      reaper.SelectAllMediaItems(0, false)
      reaper.SetMediaItemSelected(note, true)
      reaper.Main_OnCommand(TOGGLE_TAKE_PITCH_ENVELOPE, 0)
      env = reaper.GetTakeEnvelopeByName(take, 'Pitch')
    end
    plan.env = env
  end

  local had_movement = false
  if plan.env then
    local env = plan.env
    local pos = info(note, 'D_POSITION')
    local function base_at(t)
      local _, v = reaper.Envelope_Evaluate(env, env_time(pos, rate, t), 0, 0)
      return v
    end

    -- Pitch automation that was already there is kept, and the shift added
    -- to it, rather than flattened.
    for i = 0, reaper.CountEnvelopePoints(env) - 1 do
      local _, _, v = reaper.GetEnvelopePoint(env, i)
      if math.abs(v) > 1e-6 then had_movement = true end
    end
    local mid = (plan.note_from + plan.note_to) / 2
    plan.mid, plan.expected = mid, base_at(mid) + bend_at(plan, mid)
    local wanted = {
      { plan.piece_from, 0 },
      { plan.rise_from, 2 },
      { plan.note_from, 0 },
      { plan.note_to, 2 },
      { plan.fall_to, 0 },
      { plan.piece_to, 0 },
    }
    local new_points = {}
    for _, w in ipairs(wanted) do
      -- A glide squeezed against the item's edge lands on the edge point;
      -- one point per instant is enough.
      local last = new_points[#new_points]
      if not last or w[1] > last.t + EPS then
        new_points[#new_points + 1] = { t = w[1], shape = w[2],
                                        v = base_at(w[1]) + bend_at(plan, w[1]) }
      end
    end
    for i = 0, reaper.CountEnvelopePoints(env) - 1 do
      local _, t, v, shape, tension, sel = reaper.GetEnvelopePoint(env, i)
      local at = pos + t / rate
      if at > plan.rise_from + EPS and at < plan.fall_to - EPS then
        reaper.SetEnvelopePoint(env, i, t, v + bend_at(plan, at), shape, tension, sel, true)
      end
    end
    -- Our points replace any already sitting at the same instants.
    for _, p in ipairs(new_points) do
      local et = env_time(pos, rate, p.t)
      reaper.DeleteEnvelopePointRange(env, et - 0.0001, et + 0.0001)
    end
    for _, p in ipairs(new_points) do
      reaper.InsertEnvelopePoint(env, env_time(pos, rate, p.t), p.v, p.shape, 0, false, true)
    end
    reaper.Envelope_SortPoints(env)
  end

  if note then
    reaper.SelectAllMediaItems(0, false)
    reaper.SetMediaItemSelected(note, true)
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(TITLE, -1)

  if split_failed then
    a11y.speak('REAPER would not split the item, so the note was not shifted. ' ..
               'Undo to put back anything that did change.')
    return
  end
  if not plan.env then
    a11y.speak('The note now has its own piece, but REAPER did not give it a pitch ' ..
               'envelope, so its pitch is unchanged. Undo to put it back.')
    return
  end

  -- Check what REAPER will actually play in the middle of the note. The
  -- pitch envelope has a range set in preferences, and a point past it is
  -- quietly held at the limit.
  local pos = info(note, 'D_POSITION')
  local _, got = reaper.Envelope_Evaluate(plan.env, env_time(pos, rate, plan.mid), 0, 0)
  local said
  if math.abs(got - plan.expected) > 0.01 then
    said = string.format('The note only reached %s %s, not %s, because the pitch ' ..
      'envelope range stops there. Undo, raise the take pitch envelope range in ' ..
      'REAPER\'s preferences, and run this again.',
      got < 0 and 'minus' or 'plus', semitones_phrase(got), semitones_phrase(plan.expected))
  else
    local shape
    if left or right then
      shape = 'It is its own item now, crossfaded with its neighbours, and selected.'
    elseif whole then
      shape = 'The item already goes through the pitch shifter, so it was not ' ..
              'split. The shift is on the whole item, which is selected.'
    else
      shape = 'The note fills the item, so it was not split. The item is selected.'
    end
    said = string.format('%s the note %s, with a %d millisecond glide either side. %s',
      semitones < 0 and 'Lowered' or 'Raised', semitones_phrase(semitones),
      math.floor(glide * 1000 + 0.5), shape)
    if plan.squeezed then
      said = said .. ' The note sits close to the edge of the item, so one glide is shorter.'
    end
    if had_movement then
      said = said .. ' Added on top of the pitch envelope that was already there.'
    end
  end
  a11y.speak(said)
end

a11y.run(main)
