--[[
  @description Build a vinyl or cassette FX chain on selected tracks (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Builds a lo-fi playback chain in one action, in the right order, on
    every selected track. Three chains:

      Vinyl       Elliptical, Acceleration2, GrooveWear, Vinyl Noise
      Cassette    Dubly3, CHOWTapeModel, Vinyl Noise set for tape hiss
      Noise only  Vinyl Noise on its own

    Only the JSFX is dialled in by the script. The Airwindows steps come
    from Airwindows Consolidated, which is one plugin holding every
    Airwindows algorithm behind a selector, so each instance is renamed
    to the algorithm it wants and the script says which ones you still
    have to select by hand.

    Every step is optional. A plugin that is not installed is skipped and
    named in the spoken summary rather than stopping the chain, so the
    Vinyl chain still builds without Airwindows and the Cassette chain
    still builds without ChowTape.

    Worth knowing about the order. The noise generator goes last so the
    acceleration limiter is not chewing on the crackle transients; move
    it earlier if you want the record's noise to go through the record's
    own top end, which is arguably more honest and definitely darker.

    Airwindows Flutter2 is a good fifth slot on the Vinyl chain if you
    want platter wobble, but it is left out because it needs dialling in
    by hand and starts audible.
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

local MAX_FX = 100000

-- Airwindows Consolidated holds every Airwindows algorithm behind one
-- selector parameter, so all three vinyl steps are the same plugin. The
-- selector is found at runtime rather than by index: it is whichever
-- parameter formats its value as the algorithm's name.
local AIRWINDOWS_QUERY = 'airwindows consolidated'

-- How finely to sweep the selector looking for a named algorithm. There
-- are a few hundred algorithms, so this is roughly four probes each.
local SELECTOR_STEPS = 1600

local CHAINS = {
  {
    name = 'Vinyl',
    steps = {
      { query = AIRWINDOWS_QUERY, algorithm = 'Elliptical' },
      { query = AIRWINDOWS_QUERY, algorithm = 'Acceleration2' },
      { query = AIRWINDOWS_QUERY, algorithm = 'GrooveWear' },
      { query = 'js vinyl noise', label = 'Vinyl Noise', params = {
          ['Crackle level']   = -30,
          ['Crackle density'] = 260,
          ['Pops']            = 14,
          ['Pop level']       = -24,
          ['Hiss level']      = -48,
          ['Rumble level']    = -54,
          ['Hum level']       = -60,
          ['Tone']            = 4500,
          ['Stereo width']    = 70,
        } },
    },
  },
  {
    name = 'Cassette',
    steps = {
      { query = AIRWINDOWS_QUERY, algorithm = 'Dubly3' },
      { query = 'chowtapemodel', label = 'CHOWTapeModel' },
      -- No crackle on tape: hiss forward, narrow, and darker than vinyl.
      { query = 'js vinyl noise', label = 'Vinyl Noise', params = {
          ['Crackle level'] = -60,
          ['Pops']          = 0,
          ['Pop level']     = -60,
          ['Hiss level']    = -36,
          ['Rumble level']  = -60,
          ['Hum level']     = -60,
          ['Tone']          = 3200,
          ['Stereo width']  = 40,
        } },
    },
  },
  {
    name = 'Noise only',
    steps = {
      { query = 'js vinyl noise', label = 'Vinyl Noise' },
    },
  },
}

--------------------------------------------------------------------------

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
    if reaper.IsTrackSelected(tr) then out[#out + 1] = tr end
  end
  return out
end

local function track_name(tr)
  local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
  if name == nil or name == '' then return 'unnamed track' end
  return name
end

--- Best installed plugin for a search query, or nil.
local function resolve(fx_list, query)
  local hits = a11y.filter(query, fx_list, function(f) return f.name end)
  return hits[1]
end

--- Index of the first parameter whose name starts with `name`.
-- Matched on a prefix because REAPER truncates long JSFX slider names,
-- and the units in brackets are exactly what gets cut.
local function param_index(tr, fx, name)
  local want = name:lower()
  for i = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local ok, pname = reaper.TrackFX_GetParamName(tr, fx, i, '')
    if ok and pname and pname:lower():sub(1, #want) == want then return i end
  end
  return nil
end

--- Set a parameter by name, in the parameter's own units.
-- @return true when the parameter existed and was set.
local function set_param(tr, fx, name, value)
  local idx = param_index(tr, fx, name)
  if idx == nil then return false end
  local _, min, max = reaper.TrackFX_GetParam(tr, fx, idx)
  if min and max and max > min then
    value = math.max(min, math.min(max, value))
  end
  return reaper.TrackFX_SetParam(tr, fx, idx, value)
end

--- Point an Airwindows Consolidated instance at one algorithm.
--
-- The selector is not at a known index and its value is not a known
-- number, so both are discovered: sweep every parameter looking for one
-- that formats its value as the wanted name. Nothing here assumes a
-- layout, which means it degrades to "could not select" rather than
-- silently landing on the wrong algorithm.
--
-- @return true when the formatted value confirms the algorithm is selected.
local function select_algorithm(tr, fx, wanted)
  local want = wanted:lower()
  local nparams = reaper.TrackFX_GetNumParams(tr, fx)

  for p = 0, nparams - 1 do
    -- Probing moves the parameter, so its starting value is kept and put
    -- back. Restoring to zero instead would quietly leave every control
    -- the sweep touched at the bottom of its range rather than at the
    -- default the plugin loaded with.
    local original = reaper.TrackFX_GetParamNormalized(tr, fx, p)

    -- A selector formats its value as text, so a parameter that reads as
    -- a plain number at both its current setting and its maximum is not
    -- one. Skipping those keeps the sweep off the continuous controls.
    local _, here = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, '')
    reaper.TrackFX_SetParamNormalized(tr, fx, p, 1)
    local _, top = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, '')

    local found = false
    if tonumber(here) == nil or tonumber(top) == nil then
      -- Every probe switches the algorithm, which makes the plugin rebuild
      -- its DSP, so the number of probes is worth minimising. When REAPER
      -- knows the parameter's step size the sweep lands exactly once on
      -- each value; the blind sweep is only the fallback.
      local steps = SELECTOR_STEPS
      local ok, step = reaper.TrackFX_GetParameterStepSizes(tr, fx, p)
      if ok and step and step > 0 and step <= 1 then
        steps = math.floor(1 / step + 0.5)
      end

      for i = 0, steps do
        reaper.TrackFX_SetParamNormalized(tr, fx, p, i / steps)
        local _, text = reaper.TrackFX_GetFormattedParamValue(tr, fx, p, '')
        if text and text:lower() == want then found = true break end
      end
    end

    if found then return true end
    reaper.TrackFX_SetParamNormalized(tr, fx, p, original)
  end

  return false
end

--- Rename an FX instance so the chain reads correctly aloud.
-- Three instances all announcing "Airwindows Consolidated" are
-- indistinguishable by ear, which is the whole problem.
local function rename_fx(tr, fx, name)
  reaper.TrackFX_SetNamedConfigParm(tr, fx, 'renamed_name', name)
end

--------------------------------------------------------------------------

local function build_on_track(tr, chain, fx_list, report)
  for _, step in ipairs(chain.steps) do
    local wanted_label = step.algorithm or step.label or step.query
    local plugin = resolve(fx_list, step.query)

    if plugin == nil then
      report.missing[wanted_label] = true
    else
      local pos = reaper.TrackFX_AddByName(tr, plugin.name, false, -1)
      if pos == nil or pos < 0 then
        report.failed[wanted_label] = true
      else
        report.added = report.added + 1

        if step.algorithm then
          rename_fx(tr, pos, step.algorithm)
          if not select_algorithm(tr, pos, step.algorithm) then
            report.unselected[step.algorithm] = true
          end
        end

        if step.params then
          for pname, value in pairs(step.params) do
            if not set_param(tr, pos, pname, value) then
              report.unset[pname] = true
            end
          end
        end
      end
    end
  end
end

--- Sorted list of a set's keys, so the spoken summary is stable between runs.
local function keys_of(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

local function main()
  local tracks = selected_tracks()
  if #tracks == 0 then
    a11y.abort('No tracks selected. Select the tracks you want the chain on first.')
  end

  local fx_list = installed_fx()
  if #fx_list == 0 then
    a11y.abort('REAPER reports no installed FX. If you have just installed ' ..
               'plugins, rescan them in preferences, plug-ins.')
  end

  local chain = a11y.pick('Build lo-fi chain', CHAINS, function(c) return c.name end)
  if chain == nil then a11y.abort('Cancelled.') end

  local report = {
    added = 0, missing = {}, failed = {}, unselected = {}, unset = {},
  }

  reaper.Undo_BeginBlock()
  for _, tr in ipairs(tracks) do
    build_on_track(tr, chain, fx_list, report)
  end
  reaper.Undo_EndBlock('Build ' .. chain.name .. ' chain', -1)

  if report.added == 0 then
    a11y.abort(string.format(
      'Could not build the %s chain. None of its plugins are installed, ' ..
      'or REAPER refused to add them.', chain.name))
  end

  local where
  if #tracks == 1 then
    where = 'on ' .. track_name(tracks[1])
  else
    where = 'across ' .. a11y.plural(#tracks, 'track')
  end

  local msg = string.format('%s chain built %s. %s added.',
                            chain.name, where, a11y.plural(report.added, 'plugin'))

  local missing = keys_of(report.missing)
  if #missing > 0 then
    msg = msg .. ' Not installed, so skipped: ' .. a11y.list_phrase(missing) .. '.'
  end

  local failed = keys_of(report.failed)
  if #failed > 0 then
    msg = msg .. ' REAPER refused to add ' .. a11y.list_phrase(failed) .. '.'
  end

  -- The important one: an Airwindows slot that got added but is still
  -- sitting on the wrong algorithm is worse than one that is missing,
  -- because it is silently doing something else.
  local unselected = keys_of(report.unselected)
  if #unselected > 0 then
    msg = msg .. ' Renamed but not selected, so choose the algorithm by hand in ' ..
          a11y.list_phrase(unselected) .. '.'
  end

  local unset = keys_of(report.unset)
  if #unset > 0 then
    msg = msg .. ' Could not find these controls to set: ' ..
          a11y.list_phrase(unset) .. '.'
  end

  a11y.speak(msg)
end

a11y.run(main)
