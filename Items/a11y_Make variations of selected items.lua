--[[
  @description Make variations of selected items (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Turn one sound into a family of near copies. Each selected item gets a
    row of duplicates laid out after it on the same track, every copy
    nudged in pitch and, if you want, in time. Play the row and pick the
    one that sits right, or keep several and layer them.

    This is the oldest trick in sound design: a door slam repeated
    verbatim sounds like a machine, and the same slam a quarter of a
    semitone off sounds like a second take. Doing it by hand means
    duplicate, nudge, open pitch, type a number, and again for every copy.
    This does the whole family in one pass.

    You choose how many copies, how far the pitch may wander in either
    direction, how much timing jitter to add, and the gap between copies.
    Pitch changes use REAPER's ordinary take pitch, so length is
    preserved and everything else about the item, fades and take FX
    included, comes along into each copy.

    The copies end up selected, so the next thing you do, like setting
    fades on the whole family, lands on them and not the original. The
    original is never changed. One undo step.
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

-- More copies than this stops being a family and starts being a playlist,
-- and the undo block gets heavy. Raise it if you genuinely want more.
local MAX_COPIES = 50

local DUPLICATE_ITEMS = 41295 -- Item: Duplicate items

local function parse_number(text, label, min, max, default)
  text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' then return default, nil end
  local n = tonumber(text)
  if not n or n < min or n > max then
    return nil, string.format('%s is not a number between %g and %g for %s. ' ..
                              'Nothing changed.', text, min, max, label)
  end
  return n, nil
end

local function item_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return 'empty item' end
  local name = reaper.GetTakeName(take)
  if name == '' then return 'unnamed' end
  return name
end

--- Duplicate `item` once via REAPER's own action, so takes, fades and FX
--- all come along. Returns the copy, or nil.
local function duplicate(item)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(DUPLICATE_ITEMS, 0)
  local copy = reaper.GetSelectedMediaItem(0, 0)
  if copy == item then return nil end
  return copy
end

local function main()
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    a11y.abort('No items selected. Select the sound you want variations of first.')
  end

  local sources = {}
  for i = 0, count - 1 do
    sources[#sources + 1] = reaper.GetSelectedMediaItem(0, i)
  end

  local ok, answer = reaper.GetUserInputs(
    'Make variations', 4,
    'Copies (1 to 50):,Pitch range in semitones:,' ..
    'Timing jitter in milliseconds:,Gap between copies in seconds:,extrawidth=60',
    '5,1,0,0.5')
  if not ok then
    a11y.abort('Cancelled. Nothing changed.')
  end

  local f1, f2, f3, f4 = answer:match('^(.-),(.-),(.-),(.-)$')
  local copies, e1 = parse_number(f1, 'copies', 1, MAX_COPIES, 5)
  if e1 then a11y.abort(e1) end
  copies = math.floor(copies)
  local pitch_range, e2 = parse_number(f2, 'the pitch range', 0, 48, 1)
  if e2 then a11y.abort(e2) end
  local jitter_ms, e3 = parse_number(f3, 'the timing jitter', 0, 2000, 0)
  if e3 then a11y.abort(e3) end
  local gap, e4 = parse_number(f4, 'the gap', 0, 60, 0.5)
  if e4 then a11y.abort(e4) end

  math.randomseed(math.floor(reaper.time_precise() * 1000) % 2147483647)

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local made, failed = {}, 0
  local low_pitch, high_pitch

  for _, item in ipairs(sources) do
    local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    for i = 1, copies do
      local copy = duplicate(item)
      if not copy then
        failed = failed + 1
      else
        local jitter = jitter_ms > 0
          and (math.random() * 2 - 1) * jitter_ms / 1000 or 0
        reaper.SetMediaItemInfo_Value(copy, 'D_POSITION',
          math.max(0, pos + i * (len + gap) + jitter))
        local take = reaper.GetActiveTake(copy)
        if take and pitch_range > 0 then
          local base = reaper.GetMediaItemTakeInfo_Value(take, 'D_PITCH')
          local shift = (math.random() * 2 - 1) * pitch_range
          reaper.SetMediaItemTakeInfo_Value(take, 'D_PITCH', base + shift)
          if not low_pitch or shift < low_pitch then low_pitch = shift end
          if not high_pitch or shift > high_pitch then high_pitch = shift end
        end
        made[#made + 1] = copy
      end
    end
  end

  -- Leave the family selected, not the originals, so the next action
  -- lands on the new copies. If nothing was made, put the original
  -- selection back, so "Nothing changed" is true.
  reaper.SelectAllMediaItems(0, false)
  for _, copy in ipairs(#made > 0 and made or sources) do
    reaper.SetMediaItemSelected(copy, true)
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Make variations of selected items', -1)

  if #made == 0 then
    a11y.abort('REAPER did not duplicate anything. Nothing changed.')
  end

  local what = count == 1 and item_name(sources[1])
                          or a11y.plural(count, 'item')
  local msg = string.format('Made %s of %s, laid out after the original',
                            a11y.plural(#made, 'variation'), what)
  if pitch_range > 0 and low_pitch then
    msg = msg .. string.format(', pitched between %+.2f and %+.2f semitones',
                               low_pitch, high_pitch)
  end
  if jitter_ms > 0 then
    msg = msg .. string.format(', timing loosened by up to %g milliseconds', jitter_ms)
  end
  msg = msg .. '. The copies are selected.'
  if failed > 0 then
    msg = msg .. string.format(' %s could not be made.', a11y.plural(failed, 'copy', 'copies'))
  end
  a11y.speak(msg)
end

a11y.run(main)
