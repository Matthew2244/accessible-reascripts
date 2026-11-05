--[[
  @description Rename selected tracks with a numbered pattern (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.1
  @provides [main] .
  @about
    Rename every selected track from one dialog, instead of confirming a
    separate dialog per track.

    Put # where the number should go:
      Vox #      ->  Vox 1, Vox 2, Vox 3
      Tom ##     ->  Tom 01, Tom 02        (## pads to two digits)
      Kick       ->  Kick 1, Kick 2        (# is added when renaming several)
      Kick       ->  Kick                  (left alone for a single track)

    Numbering follows track order, not the order you selected them.

    One undo step for the whole rename.
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

--- Selected tracks in track order, so numbering is predictable.
local function selected_tracks()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.IsTrackSelected(tr) then
      out[#out + 1] = { track = tr, index = i + 1 }
    end
  end
  return out
end

local function main()
  local tracks = selected_tracks()
  if #tracks == 0 then
    a11y.abort('No tracks selected. Select the tracks you want to rename first.')
  end

  -- extrawidth is a caption field of its own, appended after the real
  -- captions -- not something embedded inside one.
  --
  -- Reaper joins the returned values with commas, so a name containing a
  -- comma is still recoverable on the way out (we split at the last one).
  -- It is not recoverable on the way *in*, though: a default of
  -- "Vox, big,1" would fill the two fields as "Vox" and " big". So a
  -- remembered pattern containing a comma is simply not prefilled.
  local remembered = a11y.recall('rename_pattern', '')
  if remembered:find(',', 1, true) then remembered = '' end

  local ok, csv = reaper.GetUserInputs(
    'Rename selected tracks', 2,
    'Name (# = number):,Start number:,extrawidth=220',
    remembered .. ',' .. a11y.recall('rename_start', '1'))
  if not ok then
    a11y.abort('Cancelled.')
  end

  local pattern, start_text = csv:match('^(.-),([^,]*)$')
  if pattern == nil then
    pattern, start_text = csv, '1'
  end

  pattern = pattern:gsub('^%s+', ''):gsub('%s+$', '')
  if pattern == '' then
    a11y.abort('No name given. Nothing renamed.')
  end

  local start = tonumber(start_text)
  if start == nil or start ~= math.floor(start) then
    if start_text == '' then
      a11y.abort('The start number was blank. Nothing renamed.')
    end
    a11y.abort(string.format('Start number %s is not a whole number. Nothing renamed.',
                             start_text))
  end

  -- Renaming several tracks to one identical name is almost never what
  -- anyone means, so add a number when the pattern has no placeholder.
  local effective = pattern
  if #tracks > 1 and not pattern:find('#') then
    effective = pattern .. ' #'
  end

  a11y.remember('rename_pattern', pattern)
  a11y.remember('rename_start', tostring(start))

  reaper.Undo_BeginBlock()
  local first_name, last_name
  for i, rec in ipairs(tracks) do
    local new_name = a11y.number_pattern(effective, start + i - 1)
    reaper.GetSetMediaTrackInfo_String(rec.track, 'P_NAME', new_name, true)
    if i == 1 then first_name = new_name end
    last_name = new_name
  end
  reaper.Undo_EndBlock('Rename ' .. a11y.plural(#tracks, 'track'), -1)
  reaper.TrackList_AdjustWindows(false)

  if #tracks == 1 then
    a11y.speak(string.format('Renamed track %d to %s.', tracks[1].index, first_name))
  else
    a11y.speak(string.format('Renamed %s, %s through %s.',
                             a11y.plural(#tracks, 'track'), first_name, last_name))
  end
end

a11y.run(main)
