--[[
  @description Insert sound by name (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Type part of a sound's name and insert it from your sample library
    onto the selected track at the edit cursor — without walking the Media
    Explorer's folder tree to get there. If you know the sound you want is
    called something like "door slam heavy", this is the fastest route
    from wanting it to hearing it in context.

    The first run asks where your sounds live; after that the folder is
    remembered, and the same dialog lets you change it whenever you like.
    Every audio file under that folder, subfolders included, is searchable.

    Search is the collection's usual forgiving kind: whole name, several
    words in any order, a word from the middle, or initials. Matches are
    spoken as a numbered list and you pick by number.

    The Media Explorer with OSARA is still the tool for browsing and
    auditioning when you do not know what you want. This is for when you do.
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

local AUDIO_EXT = {
  wav = true, aif = true, aiff = true, flac = true, mp3 = true,
  ogg = true, m4a = true, caf = true, wv = true, opus = true,
}

--- Walk `dir` collecting audio files in one pass, whatever their extension.
-- Same shape as a11y.scan_files, but matching a set of extensions so a
-- large library is only traversed once.
local function scan_audio(dir, folder, acc)
  acc = acc or {}
  folder = folder or ''

  reaper.EnumerateFiles(dir, -1)
  reaper.EnumerateSubdirectories(dir, -1)

  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    local ext = f:match('%.([^.]+)$')
    if ext and AUDIO_EXT[ext:lower()] then
      local display = f:gsub('%.[^.]+$', '')
      acc[#acc + 1] = {
        path = a11y.path_join(dir, f),
        name = folder ~= '' and (folder .. '/' .. display) or display,
      }
    end
    i = i + 1
  end

  local j = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(dir, j)
    if not sub then break end
    scan_audio(a11y.path_join(dir, sub), folder ~= '' and (folder .. '/' .. sub) or sub, acc)
    j = j + 1
  end

  return acc
end

local function main()
  local selected = reaper.CountSelectedTracks(0)
  if selected == 0 then
    a11y.abort('No track selected. Select the track the sound should land on first.')
  end
  local track = reaper.GetSelectedTrack(0, 0)

  local remembered = a11y.recall('sound_folder', '')

  -- One dialog carries both the search and the folder, so changing where
  -- you search is never a separate mode -- edit the second field and go.
  -- The separator is a pipe because folder paths can contain commas.
  local ok, answer = reaper.GetUserInputs(
    'Insert sound', 2,
    'Search:,Sound folder:,extrawidth=120,separator=|',
    '|' .. remembered)
  if not ok then
    a11y.abort('Cancelled. Nothing inserted.')
  end

  local query, folder = answer:match('^(.-)|(.-)$')
  query = (query or ''):gsub('^%s+', ''):gsub('%s+$', '')
  folder = (folder or ''):gsub('^%s+', ''):gsub('%s+$', '')

  if folder == '' then
    a11y.abort('No sound folder was given. Type the full path of the folder your ' ..
               'sounds live in into the second field; it will be remembered.')
  end

  local files = scan_audio(folder)
  if #files == 0 then
    a11y.abort(string.format('No audio files found under %s. Check the folder path ' ..
               'in the second field of the dialog.', folder))
  end

  -- The folder produced files, so it is worth remembering -- even if this
  -- particular search now comes up empty.
  a11y.remember('sound_folder', folder)

  if query == '' then
    a11y.abort(string.format('%s under that folder, but the search was blank. ' ..
               'Type part of a name to narrow it down.',
               a11y.plural(#files, 'audio file')))
  end

  local matches = a11y.filter(query, files, function(f) return f.name end)
  if #matches == 0 then
    a11y.abort(string.format('Nothing matching %s among %s under %s.',
               query, a11y.plural(#files, 'audio file'), folder))
  end

  local chosen = a11y.pick('Insert sound', matches, function(f) return f.name end)
  if not chosen then
    a11y.abort('Cancelled. Nothing inserted.')
  end

  local before = reaper.CountTrackMediaItems(track)
  local cursor = reaper.GetCursorPosition()

  reaper.Undo_BeginBlock()
  reaper.SetOnlyTrackSelected(track)
  reaper.InsertMedia(chosen.path, 0)
  reaper.Undo_EndBlock('Insert sound "' .. a11y.basename(chosen.path, true) .. '"', -1)

  -- Never claim success unverified: count the track's items before and
  -- after, exactly like the template script does.
  local after = reaper.CountTrackMediaItems(track)
  if after <= before then
    a11y.abort(string.format('Reaper did not insert %s. The file may be missing or ' ..
               'not a format this machine can read. Nothing changed.', chosen.name))
  end

  local tracknum = math.floor(reaper.GetMediaTrackInfo_Value(track, 'IP_TRACKNUMBER'))
  local _, trackname = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  a11y.speak(string.format('Inserted %s on track %s at %s.',
             a11y.basename(chosen.path, true),
             a11y.track_label(tracknum, trackname),
             reaper.format_timestr(cursor, '')))
end

a11y.run(main)
