--[[
  @description Add FX by name to selected tracks (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Type part of a plugin's name and add it to every selected track,
    instead of hunting through the FX browser.

    Search works the same way as the track template script: whole name,
    several words in any order, a word from the middle, or the first
    letters of each word. Plugin names include their format, so you can
    narrow by typing it:

      proq          -> every Pro-Q, in every format
      vst3 proq     -> only the VST3 one
      js loudness   -> only JSFX

    A plugin installed in more than one format appears once per format,
    so you can choose deliberately rather than letting REAPER guess.

    Adds a new instance at the end of each selected track's chain, even if
    the same plugin is already there. One undo step for all tracks.

    Pairs well with OSARA's "View FX parameters for current track" in a
    custom action, if you want to start editing straight after adding.
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

-- Safety rail on the enumeration loop. Machines with very large plugin
-- collections sit in the low thousands; this is far above that and only
-- exists so a misbehaving API can never spin forever.
local MAX_FX = 100000

--- Every installed plugin, as { name = display name, ident = identifier }.
-- The name carries its format prefix ("VST3: Pro-Q 3 (FabFilter)"), which
-- is both what the user searches and what TrackFX_AddByName understands.
local function installed_fx()
  local out, seen = {}, {}
  local i = 0
  while i < MAX_FX do
    local ok, name, ident = reaper.EnumInstalledFX(i)
    if not ok then break end
    if name and name ~= '' and not seen[name] then
      seen[name] = true
      out[#out + 1] = { name = name, ident = ident }
    end
    i = i + 1
  end
  return out
end

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

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then return 'unnamed track' end
  return name
end

local function main()
  local tracks = selected_tracks()
  if #tracks == 0 then
    a11y.abort('No tracks selected. Select the tracks you want the plugin on first.')
  end

  local fx = installed_fx()
  if #fx == 0 then
    a11y.abort('REAPER reports no installed FX. If you have just installed ' ..
               'plugins, rescan them in preferences, plug-ins.')
  end

  local query = a11y.prompt('Add FX', 'Search (blank lists all):',
                            a11y.recall('fx_query', ''), 300)
  if query == nil then
    a11y.abort('Cancelled.')
  end

  local hits = a11y.filter(query, fx, function(f) return f.name end)
  if #hits == 0 then
    a11y.abort(string.format('No plugin matches %s. %s installed.',
                             query, a11y.plural(#fx, 'plugin')))
  end

  local chosen = a11y.pick('Add FX', hits, function(f) return f.name end)
  if chosen == nil then
    a11y.abort('Cancelled.')
  end

  a11y.remember('fx_query', query)

  -- instantiate = -1 means "always create a new instance". A positive value
  -- would silently do nothing when the plugin is already on the track,
  -- which reads as the script having failed.
  reaper.Undo_BeginBlock()
  local added, failed = {}, {}
  for _, rec in ipairs(tracks) do
    local pos = reaper.TrackFX_AddByName(rec.track, chosen.name, false, -1)
    if pos and pos >= 0 then
      added[#added + 1] = { rec = rec, pos = pos }
    else
      failed[#failed + 1] = rec
    end
  end
  reaper.Undo_EndBlock('Add ' .. chosen.name, -1)

  if #added == 0 then
    a11y.abort(string.format(
      'REAPER refused to add %s to %s. The plugin may have failed to scan, ' ..
      'or may not run on this machine.',
      chosen.name, a11y.plural(#tracks, 'track')))
  end

  -- Report position as a human slot number, not the zero-based index the
  -- API uses, so it matches what OSARA reads out in the FX chain.
  local first = added[1]
  local msg
  if #added == 1 then
    msg = string.format('Added %s to %s, slot %d.',
                        chosen.name, track_name(first.rec.track), first.pos + 1)
  else
    msg = string.format('Added %s to %s.',
                        chosen.name, a11y.plural(#added, 'track'))
  end

  if #failed > 0 then
    msg = msg .. string.format(' Failed on %s.', a11y.plural(#failed, 'track'))
  end

  a11y.speak(msg)
end

a11y.run(main)
