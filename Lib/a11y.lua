--[[
  a11y.lua -- shared helpers for the Accessible ReaScripts collection.

  Everything here exists to make ReaScripts usable by ear. The two rules
  that shape this whole file:

    1. Speak the outcome. A script that silently succeeds is a script that
       leaves a screen reader user guessing. Every action ends in speech.
    2. Never draw our own GUI. Reaper's gfx windows are not exposed to
       VoiceOver or NVDA. We only ever use native dialogs (GetUserInputs,
       ShowMessageBox), which screen readers already read correctly.

  Loading this from a script:

      local script_dir = ({ reaper.get_action_context() })[2]:match('^(.*[\\/])')
      package.path = script_dir .. '../Lib/?.lua;' .. package.path
      local loaded, a11y = pcall(require, 'a11y')

  See any script in this repo, or the skeleton in CONTRIBUTING.md, for the
  exact preamble, including the spoken error shown when the library is
  missing.
]]

local a11y = {}

a11y.VERSION = '1.3.0'

--------------------------------------------------------------------------
-- Speech
--------------------------------------------------------------------------

-- True when OSARA is present and exposing its ReaScript API. OSARA does not
-- document osara_outputMessage in its readme, but it has been a registered
-- API function for years; the signature straight out of the binary is
-- `void osara_outputMessage(const char* message)`.
function a11y.has_osara()
  return reaper.osara_outputMessage ~= nil
end

-- When a dialog closes, focus goes back to REAPER's main window and the
-- screen reader announces where it landed. Tested with VoiceOver: that
-- announcement came about 0.9 seconds after Return, and cut off a result
-- spoken straight away ("Track 21" was replaced by "New project button"
-- 0.4 seconds in). So speech within this long of a dialog closing waits
-- until the focus has settled, then speaks over the focus announcement.
a11y.AFTER_DIALOG = 1.2

local last_dialog = nil

-- Every native dialog a script opens, through this library or directly,
-- records when it closed. Each script runs in its own Lua state, so this
-- touches only the script that loaded the library.
for _, name in ipairs({ 'GetUserInputs', 'ShowMessageBox' }) do
  local original = reaper[name]
  if original then
    reaper[name] = function(...)
      local results = table.pack(original(...))
      last_dialog = reaper.time_precise and reaper.time_precise() or nil
      return table.unpack(results, 1, results.n)
    end
  end
end

--- Speak a message through the screen reader.
-- Falls back to a message box when OSARA is unavailable, so a script never
-- fails silently on a machine without it. Right after a dialog closes the
-- message is held back briefly, see AFTER_DIALOG.
-- @param msg string
function a11y.speak(msg)
  msg = tostring(msg or '')
  if msg == '' then return end
  if not reaper.osara_outputMessage then
    reaper.ShowMessageBox(msg, 'Accessible ReaScripts', 0)
    return
  end
  local due = last_dialog and (last_dialog + a11y.AFTER_DIALOG)
  if due and reaper.defer and reaper.time_precise() < due then
    local function later()
      if reaper.time_precise() < due then
        reaper.defer(later)
      else
        reaper.osara_outputMessage(msg)
      end
    end
    reaper.defer(later)
    return
  end
  reaper.osara_outputMessage(msg)
end

--- Speak a message and stop the script.
function a11y.abort(msg)
  a11y.speak(msg)
  error({ a11y_abort = true }, 0)
end

--- Run `fn`, swallowing the sentinel thrown by abort().
-- Any other error is re-raised so real bugs still surface in Reaper's
-- ReaScript console rather than disappearing.
function a11y.run(fn)
  local ok, err = pcall(fn)
  if ok then return true end
  if type(err) == 'table' and err.a11y_abort then return false end
  error(err, 0)
end

--------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------

--- "1 track" / "3 tracks", without the awkward "1 track(s)" a screen reader
--- has to read out as "track parenthesis s".
function a11y.plural(n, singular, plural_form)
  plural_form = plural_form or (singular .. 's')
  -- %d refuses a number with a fraction, so 2.5 is written as it is.
  local shown = n == math.floor(n) and string.format('%d', n) or tostring(n)
  return shown .. ' ' .. (n == 1 and singular or plural_form)
end

--- Join a list into speech-friendly prose: "a, b and c".
function a11y.list_phrase(items, conjunction)
  conjunction = conjunction or 'and'
  local n = #items
  if n == 0 then return '' end
  if n == 1 then return tostring(items[1]) end
  if n == 2 then return items[1] .. ' ' .. conjunction .. ' ' .. items[2] end
  return table.concat(items, ', ', 1, n - 1) .. ' ' .. conjunction .. ' ' .. items[n]
end

--- Speech-friendly label for a track: "4, Lead Vox".
--
-- The number goes first because that is how Reaper and OSARA refer to a track
-- everywhere else, so hearing it first lines up with everything around it. An
-- unnamed track says so rather than leaving a gap, which otherwise sounds
-- identical to speech that was cut off.
function a11y.track_label(number, name)
  if name == nil or name == '' then name = 'unnamed' end
  return string.format('%d, %s', number, name)
end

--- Seconds to a spoken duration: "3 minutes 4 seconds".
function a11y.duration_phrase(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local h = math.floor(seconds / 3600)
  local m = math.floor((seconds % 3600) / 60)
  local s = seconds % 60
  local parts = {}
  if h > 0 then parts[#parts + 1] = a11y.plural(h, 'hour') end
  if m > 0 then parts[#parts + 1] = a11y.plural(m, 'minute') end
  if s > 0 or #parts == 0 then parts[#parts + 1] = a11y.plural(s, 'second') end
  return table.concat(parts, ' ')
end

--------------------------------------------------------------------------
-- Envelope values
--------------------------------------------------------------------------
-- Envelope points are stored in whatever scale the envelope uses, which is
-- rarely the scale anyone thinks in. Volume is linear gain; people think in
-- decibels. Plugin parameters are normalised 0 to 1; people think in percent.
-- Converting in the script means every envelope script gets it subtly
-- different, so it lives here where it can be tested without Reaper.

--- Quietest decibel value we represent. Below this, gain is treated as
--- silence, because the conversion runs to negative infinity and a spoken
--- "minus infinity dB" helps nobody.
a11y.MIN_DB = -150

--- Linear gain to decibels. Silence floors at a11y.MIN_DB rather than
--- returning -inf, which formats as "-inf" and reads badly aloud.
function a11y.gain_to_db(gain)
  if not gain or gain <= 0 then return a11y.MIN_DB end
  local db = 20 * (math.log(gain) / math.log(10))
  if db < a11y.MIN_DB then return a11y.MIN_DB end
  return db
end

--- Decibels back to linear gain.
function a11y.db_to_gain(db)
  if not db or db <= a11y.MIN_DB then return 0 end
  return 10 ^ (db / 20)
end

-- Point shapes, as the integers InsertEnvelopePoint expects. Each entry
-- lists the words a user might reasonably type for it.
local SHAPES = {
  { id = 0, name = 'linear',              words = { 'linear', 'lin', 'straight' } },
  { id = 1, name = 'square',              words = { 'square', 'hold', 'step' } },
  { id = 2, name = 'slow start and end',  words = { 'slow', 'smooth', 'ease' } },
  { id = 3, name = 'fast start',          words = { 'fast start', 'faststart', 'start' } },
  { id = 4, name = 'fast end',            words = { 'fast end', 'fastend', 'end' } },
  { id = 5, name = 'bezier',              words = { 'bezier', 'bez' } },
}

--- Project time to the time an envelope's points are stored in.
--
-- Track envelopes use project time. A take envelope counts from the start
-- of its item, in the take's own time, so at playback rate 2 a point one
-- second into the item is stored at 2. Measured in REAPER 7.82 by rendering
-- a take pitch envelope on an item at rate 1.5: the pitch moved where this
-- conversion said it would. Returns the envelope time and the rate, so a
-- distance between points can be turned back into seconds with / rate.
function a11y.envelope_time(env, project_time)
  local take = reaper.Envelope_GetParentTake and reaper.Envelope_GetParentTake(env)
  if not take then return project_time, 1 end
  local item = reaper.GetMediaItemTake_Item(take)
  local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local rate = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
  if not rate or rate <= 0 then rate = 1 end
  return (project_time - pos) * rate, rate
end

--- Parse a curve shape from plain words, so nobody has to remember that
--- "fast end" is 4. Unrecognised text becomes linear, which is the shape
--- someone typing a guess almost always wanted.
--
-- Two details keep the bare 'start' and 'end' keywords from misfiring.
-- Exact matches are tried across every shape before any substring match, so
-- 'fast end' resolves on its own name rather than being caught by the
-- 'start' keyword listed under fast start. And the substring pass walks the
-- table in order, so 'slow start and end' meets 'slow' before it can meet
-- either 'start' or 'end'. Reordering SHAPES would break that second one.
-- @return number shape id, string spoken name
function a11y.envelope_shape(text)
  local q = (text or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  if q == '' then return 0, 'linear' end

  for _, shape in ipairs(SHAPES) do
    for _, word in ipairs(shape.words) do
      if q == word then return shape.id, shape.name end
    end
  end

  for _, shape in ipairs(SHAPES) do
    for _, word in ipairs(shape.words) do
      if q:find(word, 1, true) then return shape.id, shape.name end
    end
  end

  return 0, 'linear'
end

--------------------------------------------------------------------------
-- Fuzzy matching
--------------------------------------------------------------------------
-- Scoring is deliberately simple and explainable, because a search that
-- surprises you is worse than one that is merely blunt.
--
-- Every match lands in a numbered tier, best first:
--
--   1  exact
--   2  prefix                  "key"   -> "keyscape rhodes"
--   3  word-start              "rho"   -> "keyscape rhodes"
--   4  substring anywhere      "hode"  -> "keyscape rhodes"
--   5  all query words present "rhodes amp" -> "keyscape rhodes 2 amped"
--   6  consecutive initials    "krs"   -> "keyscape rhodes suitcase"
--   7  loose subsequence       "kysc"  -> "keyscape"
--
-- Tiers 6 and 7 are FALLBACKS. They only appear when nothing matched at
-- tier 5 or better -- see a11y.filter. This matters enormously once the
-- list is large: over ~2000 plugin names, a bare subsequence search for
-- "ssl" matches 472 of them, because almost any name has an s, an s and
-- an l somewhere in it. Useful on a short list, useless noise on a long
-- one, so it is kept but held in reserve.
--
-- Tier 7 additionally requires the matched characters to sit reasonably
-- close together, so "valhalla" does not match "elysia alpha mix" by
-- scavenging one letter at a time across the whole string.
--
-- Score is (8 - tier) * 1000 minus a small length penalty, so tiers never
-- overlap and, within a tier, the shorter name wins. That is what makes
-- "piano 1" rank above "piano 1 gospel".

local TIER_EXACT, TIER_PREFIX, TIER_WORD_START = 1, 2, 3
local TIER_SUBSTRING, TIER_ALL_WORDS = 4, 5
local TIER_INITIALS, TIER_SUBSEQUENCE = 6, 7

--- Tiers above this number are fallbacks, used only when nothing better matched.
local LOOSEST_STRICT_TIER = TIER_ALL_WORDS

--- Shortest query allowed to match by subsequence. Below this, a query is
--- too small to mean anything at that tier.
local MIN_SUBSEQUENCE_QUERY = 3

local function escape_pattern(s)
  return (s:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

--- Split a name into lowercase words.
local function words_of(s)
  local out = {}
  for w in s:lower():gmatch('[%w]+') do out[#out + 1] = w end
  return out
end

--- Find `q` as a subsequence of `s`.
-- @return start position, end position -- or nil when there is no match.
local function subsequence_span(q, s)
  local first, i = nil, 1
  for c = 1, #q do
    local found = s:find(q:sub(c, c), i, true)
    if not found then return nil end
    if first == nil then first = found end
    i = found + 1
  end
  return first, i - 1
end

--- The first letter of each word, joined: "keyscape rhodes 2" -> "kr2".
local function initials_of(s)
  local out = {}
  for _, w in ipairs(words_of(s)) do out[#out + 1] = w:sub(1, 1) end
  return table.concat(out)
end

--- Score `candidate` against `query`.
-- @return number score, number tier  -- or nil when there is no match.
function a11y.score(query, candidate)
  query = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  local cand = (candidate or ''):lower()
  if query == '' then return 1, TIER_EXACT end -- empty query matches everything
  if cand == '' then return nil end

  -- Capped so a very long name is never pushed below a worse tier purely
  -- for being long.
  local penalty = math.min(#cand, 99)
  local function score_for(tier) return (8 - tier) * 1000 - penalty end

  if cand == query then return score_for(TIER_EXACT), TIER_EXACT end
  if cand:sub(1, #query) == query then
    return score_for(TIER_PREFIX), TIER_PREFIX
  end

  for _, w in ipairs(words_of(cand)) do
    if w:sub(1, #query) == query then
      return score_for(TIER_WORD_START), TIER_WORD_START
    end
  end

  if cand:find(escape_pattern(query)) then
    return score_for(TIER_SUBSTRING), TIER_SUBSTRING
  end

  -- Every word of a multi-word query must appear somewhere, in any order.
  local qwords = words_of(query)
  if #qwords > 1 then
    local all = true
    for _, qw in ipairs(qwords) do
      if not cand:find(escape_pattern(qw)) then all = false break end
    end
    if all then return score_for(TIER_ALL_WORDS), TIER_ALL_WORDS end
  end

  local qcompact = query:gsub('%s+', '')

  -- Initials must be consecutive words, not merely scattered ones, so
  -- "krs" finds "keyscape rhodes suitcase" without also finding every
  -- name that happens to contain those three initials somewhere.
  if #qcompact >= 2 and initials_of(cand):find(qcompact, 1, true) then
    return score_for(TIER_INITIALS), TIER_INITIALS
  end

  if #qcompact >= MIN_SUBSEQUENCE_QUERY then
    local compact = cand:gsub('%s+', '')
    local first, last = subsequence_span(qcompact, compact)
    if first then
      -- Require the letters to be reasonably close together. Without this,
      -- an eight-letter query can strip one letter at a time from a
      -- forty-character name and call it a match.
      local span = last - first + 1
      if span <= math.max(#qcompact * 3, #qcompact + 6) then
        return score_for(TIER_SUBSEQUENCE), TIER_SUBSEQUENCE
      end
    end
  end

  return nil
end

--- Filter and rank `items` against `query`.
--
-- Fallback tiers (initials, subsequence) are dropped entirely whenever any
-- item matched at a strict tier. So a search that has real substring hits
-- shows only those, and the loose tiers exist purely to rescue a search
-- that would otherwise come back empty.
--
-- @param query string
-- @param items table  list of items
-- @param labelfn function|nil  item -> string (defaults to tostring)
-- @return table  ranked list of items, best first
function a11y.filter(query, items, labelfn)
  labelfn = labelfn or tostring
  local scored, has_strict = {}, false

  for i, item in ipairs(items) do
    local s, tier = a11y.score(query, labelfn(item))
    if s then
      if tier <= LOOSEST_STRICT_TIER then has_strict = true end
      -- `order` keeps the sort stable, so identical searches stay in the
      -- same order between runs.
      scored[#scored + 1] = { item = item, score = s, tier = tier, order = i }
    end
  end

  local out = {}
  for _, rec in ipairs(scored) do
    if not has_strict or rec.tier <= LOOSEST_STRICT_TIER then
      out[#out + 1] = rec
    end
  end

  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)

  local items_out = {}
  for i, rec in ipairs(out) do items_out[i] = rec.item end
  return items_out
end

--- Substitute each run of '#' in `pattern` with `number`, zero-padded to
--- the length of the run: 'Tom #' -> 'Tom 3', 'Tom ##' -> 'Tom 03'.
-- @return string result, boolean whether any '#' was present
function a11y.number_pattern(pattern, number)
  local found = false
  local result = pattern:gsub('#+', function(hashes)
    found = true
    return string.format('%0' .. #hashes .. 'd', number)
  end)
  return result, found
end

--------------------------------------------------------------------------
-- Native dialogs
--------------------------------------------------------------------------

--- Single-field text prompt. Returns nil if cancelled.
-- @param title string  dialog title
-- @param caption string  field label
-- @param default string|nil  prefilled value
-- @param width number|nil  extra width in pixels
function a11y.prompt(title, caption, default, width)
  local field = caption
  if width then field = field .. ',extrawidth=' .. tostring(width) end
  local ok, value = reaper.GetUserInputs(title, 1, field, default or '')
  if not ok then return nil end
  return value
end

--- Accessible chooser over a list.
--
-- Deliberately not a popup menu: Reaper's gfx menus are invisible to
-- VoiceOver. Instead the numbered list is the label of a native text field,
-- which the screen reader reads when the field takes focus.
--
-- The caller has usually already narrowed the list with a search, so this
-- is normally a handful of items. `max_spoken` caps the read-out so a broad
-- search never turns into a wall of speech.
--
-- @param title string
-- @param items table  list of items (must be non-empty)
-- @param labelfn function|nil  item -> string
-- @param max_spoken number|nil  default 12
-- @param intro string|nil  read first, as part of the same label, since a
--   separate message just before the dialog would be cut off
-- @return item|nil, index|nil
function a11y.pick(title, items, labelfn, max_spoken, intro)
  labelfn = labelfn or tostring
  max_spoken = max_spoken or 12
  local n = #items
  if n == 0 then return nil end
  if n == 1 then return items[1], 1 end

  -- A long list is read a page at a time. Every number in the whole list
  -- can be typed, and m reads the next page, so nothing is out of reach.
  --
  -- The list is the dialog's field label, not a separate message. Tested
  -- with VoiceOver: a message spoken just before GetUserInputs opens is
  -- cut off within a quarter of a second by the dialog's own announcement,
  -- so the list was never heard. The label is read in full when the field
  -- takes focus, and again whenever you return to it. Labels cannot hold
  -- commas (GetUserInputs splits on them), so commas become semicolons.
  local first, default = 1, '1'
  while true do
    local last = math.min(n, first + max_spoken - 1)
    local lines = {}
    for i = first, last do
      lines[#lines + 1] = string.format('%d: %s', i, (labelfn(items[i]):gsub(',', ';')))
    end

    local header, ask
    if n > max_spoken then
      header = string.format('%d matches. %d to %d. ', n, first, last)
      ask = last < n and string.format(' Type a number from 1 to %d or m for more:', n)
                      or string.format(' Type a number from 1 to %d or m to start again:', n)
    else
      header = string.format('%d matches. ', n)
      ask = string.format(' Type a number from 1 to %d:', n)
    end
    local caption = (intro and (intro:gsub(',', ';') .. ' ') or '') .. header ..
                    table.concat(lines, '. ') .. '.' .. ask
    intro = nil

    local answer = a11y.prompt(title, caption, default, 60)
    if not answer then return nil end
    answer = answer:gsub('^%s+', ''):gsub('%s+$', '')

    if n > max_spoken and answer:lower():sub(1, 1) == 'm' then
      first = last < n and last + 1 or 1
      default = tostring(first)
    else
      local idx = tonumber(answer)
      if not idx or idx < 1 or idx > n or idx ~= math.floor(idx) then
        a11y.abort(string.format('%s is not a number between 1 and %d. Cancelled.',
                                 answer == '' and 'Blank' or answer, n))
      end
      return items[idx], idx
    end
  end
end

--- Yes/no confirmation. Returns true only on Yes.
-- Yes, No and Cancel rather than Yes and No: tested with VoiceOver on
-- macOS, Escape does nothing in a Yes/No box, so the only way out was to
-- find the No button. Cancel gives Escape somewhere to go, and counts as no.
function a11y.confirm(title, question)
  return reaper.ShowMessageBox(question, title, 3) == 6
end

--------------------------------------------------------------------------
-- Small Reaper conveniences
--------------------------------------------------------------------------

--- Path separator for the current platform.
function a11y.sep()
  return package.config:sub(1, 1)
end

--- Join path components.
function a11y.path_join(...)
  return table.concat({ ... }, a11y.sep())
end

--- Filename without its directory or extension.
--
-- On Windows both separators have to count. Reaper hands back backslashes,
-- but a project can easily reference media saved with forward slashes, and
-- matching only the platform separator then finds no separator at all and
-- returns the whole path. That is not a silent bug: it is read out loud, so
-- `Speak project summary` announces "C colon backslash Songs backslash take
-- underscore 003" where it should say "take, version 3".
--
-- Off Windows a backslash is a legal character in a filename, so it stays a
-- normal character there rather than being treated as a separator.
function a11y.basename(path, strip_ext)
  local set = a11y.sep() == '\\' and '\\/' or '/'
  local name = path:match('([^' .. set .. ']+)$') or path
  if strip_ext then name = name:gsub('%.[^.]+$', '') end
  return name
end

--- List files under `dir` matching `ext` (e.g. '.RTrackTemplate'),
--- recursing into subfolders. Returns a list of
--- { path = absolute path, name = display name, folder = relative folder }.
function a11y.scan_files(dir, ext, _folder, _acc)
  _acc = _acc or {}
  _folder = _folder or ''
  local lower_ext = ext:lower()

  -- Index -1 forces Reaper to re-read the directory instead of serving a
  -- cached listing. Without this, a template saved earlier in the session
  -- stays invisible until Reaper restarts.
  reaper.EnumerateFiles(dir, -1)
  reaper.EnumerateSubdirectories(dir, -1)

  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():sub(-#lower_ext) == lower_ext then
      local display = f:gsub('%.[^.]+$', '')
      _acc[#_acc + 1] = {
        path   = a11y.path_join(dir, f),
        name   = _folder ~= '' and (_folder .. '/' .. display) or display,
        folder = _folder,
      }
    end
    i = i + 1
  end

  local j = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(dir, j)
    if not sub then break end
    a11y.scan_files(a11y.path_join(dir, sub), ext,
                    _folder ~= '' and (_folder .. '/' .. sub) or sub, _acc)
    j = j + 1
  end

  return _acc
end

-- Stored values must survive a restart, and REAPER's saved state is one
-- line per value, so a newline is swapped for a character no path or name
-- contains, and back again on reading.
local NEWLINE_STANDIN = '\31'

--- Remember a value between runs (per script key), including after REAPER
--- restarts.
function a11y.remember(key, value)
  local v = tostring(value or ''):gsub('\n', NEWLINE_STANDIN)
  reaper.SetExtState('accessible_reascripts', key, v, true)
end

--- Read a value stored by remember().
function a11y.recall(key, default)
  local v = reaper.GetExtState('accessible_reascripts', key)
  if v == nil or v == '' then return default end
  return (v:gsub(NEWLINE_STANDIN, '\n'))
end


--------------------------------------------------------------------------
-- Listening to the audio itself
--------------------------------------------------------------------------
-- Everything below exists because of one gap: a sighted person answers
-- "what is actually there, and when" by looking at a waveform. These turn
-- that question into something you can ask out loud.
--
-- The pure logic lives here, separate from the Reaper calls, so it can be
-- tested in a terminal. Peak reading itself is in `read_levels`, which
-- needs Reaper; `spans` and `loud_points` do not.

--- Quietest level we bother calling sound. Anything under this reads as
--- silence to a listener, and dither noise sits well below it.
a11y.SILENCE_DB = -60

--- Seconds as speech. Short times keep milliseconds, because a fade or a
--- gap of a quarter second is a real thing you need the number for.
--- Longer times read as minutes and seconds, because "203.417 seconds"
--- tells you nothing you can act on.
function a11y.time_phrase(seconds)
  seconds = math.max(0, seconds or 0)
  local s = string.format('%.3f', seconds)
  -- Anything that rounds to a whole minute reads as minutes, so 59.9996
  -- is "1 minute", never "60 seconds".
  if tonumber(s) < 60 then
    s = s:gsub('0+$', ''):gsub('%.$', '')
    return s .. (s == '1' and ' second' or ' seconds')
  end
  return a11y.duration_phrase(seconds)
end

--- Find the stretches of a level series that are above `threshold_db`.
--
-- @param levels  array of magnitudes, 0 to 1, evenly spaced
-- @param rate    how many entries per second
-- @param opts    threshold_db  (default a11y.SILENCE_DB)
--                min_sound     shortest run of sound worth reporting, seconds
--                min_gap       shortest quiet worth breaking a span for
-- @return array of { start = seconds, stop = seconds, peak_db = number }
--
-- The two minimums matter more than the threshold does. Without them a
-- tremolo or a footstep pattern comes back as forty spans, which is a
-- worse answer than one. Bridging short gaps first, then dropping short
-- sounds, is the order that keeps a rhythmic passage as one event.
function a11y.spans(levels, rate, opts)
  opts = opts or {}
  local threshold = opts.threshold_db or a11y.SILENCE_DB
  local min_sound = opts.min_sound or 0.10
  local min_gap = opts.min_gap or 0.25
  local gate = a11y.db_to_gain(threshold)

  local raw, open = {}, nil
  for i = 1, #levels do
    if levels[i] >= gate then
      if not open then open = { first = i, last = i, peak = levels[i] } end
      open.last = i
      if levels[i] > open.peak then open.peak = levels[i] end
    elseif open then
      raw[#raw + 1] = open
      open = nil
    end
  end
  if open then raw[#raw + 1] = open end

  -- Bridge gaps too short to hear as a gap.
  local joined = {}
  for _, span in ipairs(raw) do
    local prev = joined[#joined]
    if prev and (span.first - prev.last - 1) / rate < min_gap then
      prev.last = span.last
      if span.peak > prev.peak then prev.peak = span.peak end
    else
      joined[#joined + 1] = span
    end
  end

  local out = {}
  for _, span in ipairs(joined) do
    local length = (span.last - span.first + 1) / rate
    if length >= min_sound then
      out[#out + 1] = {
        start = (span.first - 1) / rate,
        stop = span.last / rate,
        peak_db = a11y.gain_to_db(span.peak),
      }
    end
  end
  return out
end

--- Find where a level series goes over `threshold_db`, one entry per
--- excursion rather than one per sample over.
--
-- Reported as { at = seconds, peak_db = number, length = seconds }. A run
-- of consecutive overs is a single excursion, because "clipping at 3.48,
-- 3.49, 3.50" is the same fact said thirty times.
function a11y.loud_points(levels, rate, threshold_db)
  local gate = a11y.db_to_gain(threshold_db)
  local out, open = {}, nil
  for i = 1, #levels do
    if levels[i] >= gate then
      if not open then open = { first = i, peak = levels[i] } end
      open.last = i
      if levels[i] > open.peak then open.peak = levels[i] end
    elseif open then
      out[#out + 1] = { at = (open.first - 1) / rate,
                        peak_db = a11y.gain_to_db(open.peak),
                        length = (open.last - open.first + 1) / rate }
      open = nil
    end
  end
  if open then
    out[#out + 1] = { at = (open.first - 1) / rate,
                      peak_db = a11y.gain_to_db(open.peak),
                      length = (open.last - open.first + 1) / rate }
  end
  return out
end

--- Read a take's audio as a series of peak magnitudes.
--
-- `start_time` is a PROJECT time, not a time in the source file: REAPER
-- reads the take as it plays in its item, offset and playback rate
-- included. Pass the item's position to start at the item's start.
-- Measured in REAPER 7.82: an item at 30 seconds with a sound one second
-- into it reads that sound at 31, and nothing at 1.
--
-- Returns levels, rate. Levels are 0 to 1, one entry per 1/rate second,
-- taken as the larger of the positive and negative peak across every
-- channel, so a mostly-negative transient still counts.
--
-- This reads the SOURCE audio of the take. Track FX, track volume and
-- envelopes are not in it. Any script using this should say so rather
-- than let someone believe they are hearing the mix.
--
-- Reaper hands peaks back interleaved: all the maximums for the block,
-- then all the minimums. The return value packs the sample count into its
-- low 20 bits, which is why it is masked rather than used directly.
function a11y.read_levels(take, rate, start_time, length)
  rate = rate or 40
  local want = math.max(1, math.floor(length * rate + 0.5))
  local channels = 2
  local source = reaper.GetMediaItemTake_Source(take)
  if source then
    local n = reaper.GetMediaSourceNumChannels(source)
    if n and n > 0 then channels = math.min(n, 4) end
  end

  local levels = {}
  local CHUNK = 4096
  local done = 0
  while done < want do
    local this = math.min(CHUNK, want - done)
    local buf = reaper.new_array(this * channels * 3)
    buf.clear()
    local packed = reaper.GetMediaItemTake_Peaks(
      take, rate, start_time + done / rate, channels, this, 0, buf)
    local got = packed & 0xfffff
    if got <= 0 then break end
    local t = buf.table()
    -- Layout: the maximums block first, then the minimums block. Inside
    -- each block the channels are interleaved per sample, so sample i of
    -- channel c is at (i - 1) * channels + c + 1.
    local minimums = got * channels
    for i = 1, got do
      local level = 0
      local base = (i - 1) * channels
      for c = 1, channels do
        local hi = math.abs(t[base + c] or 0)
        local lo = math.abs(t[minimums + base + c] or 0)
        if hi > level then level = hi end
        if lo > level then level = lo end
      end
      levels[done + i] = level
    end
    done = done + got
    if got < this then break end
  end
  return levels, rate
end

--------------------------------------------------------------------------
-- Several fields in one dialog
--------------------------------------------------------------------------

--- Ask several short questions in one native dialog, so a script that needs
--- three numbers costs one Enter rather than three dialogs in a row.
--
-- Each caption is a field label; defaults line up with captions. Returns a
-- table of strings (one per field), or nil if cancelled. Values must not
-- contain commas: GetUserInputs separates fields with them.
function a11y.prompt_many(title, captions, defaults, width)
  local fields = table.concat(captions, ',')
  if width then fields = fields .. ',extrawidth=' .. tostring(width) end
  local values = {}
  for i = 1, #captions do values[i] = tostring((defaults or {})[i] or '') end
  local ok, answer = reaper.GetUserInputs(title, #captions, fields,
                                          table.concat(values, ','))
  if not ok then return nil end
  local out = {}
  for v in (answer .. ','):gmatch('([^,]*),') do out[#out + 1] = v end
  -- A comma typed into a field splits it in two and shifts every answer
  -- after it into the wrong field. Stop rather than act on that.
  if #out > #captions then
    a11y.abort('One of those answers has a comma in it, which this dialog ' ..
               'cannot take. Use a point for decimals. Nothing changed.')
  end
  for i = #out + 1, #captions do out[i] = '' end
  return out
end

--------------------------------------------------------------------------
-- Lining up two recordings of the same performance
--------------------------------------------------------------------------
-- A console that records to its own card while REAPER records over USB
-- gives two copies of the same signals that started a few seconds apart.
-- When both run off the same clock there is no drift, only one constant
-- offset, and finding it is a cross-correlation problem.
--
-- Doing that directly at 48 kHz over a minute of search is far too slow in
-- Lua, so it is done in two passes:
--
--   1. Coarse. Both signals become a level envelope at about 1 kHz (mean of
--      the absolute value over each millisecond), and the envelopes are
--      correlated over the whole search range with an FFT. That finds the
--      offset to within a millisecond or so, and does not care about
--      polarity or small differences in processing.
--   2. Fine. Around each of the best few coarse candidates, a second or two
--      of the real waveform is correlated at full rate over a small window,
--      which pins the offset to the sample.
--
-- Fine-checking several coarse candidates, not just the best, is what makes
-- the confidence honest: music that repeats bar after bar gives envelope
-- peaks of nearly equal height, and the waveform tells them apart where the
-- envelope cannot. When even the waveform cannot, the answer is "I am not
-- sure", never a guess.
--
-- Everything here is pure: the audio comes in through reader functions, so
-- the same code runs on REAPER's audio accessors and on test arrays.

--- Smallest power of two that is at least n.
function a11y.next_pow2(n)
  local p = 1
  while p < n do p = p * 2 end
  return p
end

local twiddle_cache = {}

--- In-place radix-2 FFT over 1-based arrays `re` and `im` of length `n`, a
--- power of two. `inverse` runs the inverse transform, scaled by 1/n so a
--- round trip returns the input.
function a11y.fft(re, im, n, inverse)
  n = math.tointeger(n) or n
  -- Bit-reversal permutation, 0-based indices, +1 on access.
  local j = 0
  for i = 0, n - 2 do
    if i < j then
      re[i + 1], re[j + 1] = re[j + 1], re[i + 1]
      im[i + 1], im[j + 1] = im[j + 1], im[i + 1]
    end
    local m = n // 2
    while m >= 1 and j >= m do
      j = j - m
      m = m // 2
    end
    j = j + m
  end

  -- Twiddles computed once per size; a running product drifts at 2^18.
  local tw = twiddle_cache[n]
  if not tw then
    tw = { c = {}, s = {} }
    for k = 0, n // 2 - 1 do
      local a = -2 * math.pi * k / n
      tw.c[k + 1], tw.s[k + 1] = math.cos(a), math.sin(a)
    end
    twiddle_cache[n] = tw
  end
  local tc, ts = tw.c, tw.s
  local sign = inverse and -1 or 1

  local len = 2
  while len <= n do
    local half = len // 2
    local stride = n // len
    for k = 0, half - 1 do
      local wr = tc[k * stride + 1]
      local wi = sign * ts[k * stride + 1]
      for start = 0, n - 1, len do
        local a = start + k + 1
        local b = a + half
        local br, bi = re[b], im[b]
        local xr = br * wr - bi * wi
        local xi = br * wi + bi * wr
        local ar, ai = re[a], im[a]
        re[b] = ar - xr
        im[b] = ai - xi
        re[a] = ar + xr
        im[a] = ai + xi
      end
    end
    len = len * 2
  end

  if inverse then
    for i = 1, n do
      re[i] = re[i] / n
      im[i] = im[i] / n
    end
  end
end

--- Raw cross-correlation of two real signals:
---   c[k + 1] = sum over j = 1..na of a[j] * b[j + k],  k = 0 .. nb - na
--- `a` is the shorter one. Both real signals ride in one complex FFT (a in
--- the real part, b in the imaginary), which halves the work.
function a11y.xcorr(a, na, b, nb)
  local n = a11y.next_pow2(nb)
  local re, im = {}, {}
  for i = 1, n do
    re[i] = i <= na and a[i] or 0.0
    im[i] = i <= nb and b[i] or 0.0
  end
  a11y.fft(re, im, n)
  -- Separate the two spectra: A = (Z[k] + conj Z[-k]) / 2,
  -- B = (Z[k] - conj Z[-k]) / 2i, then form conj(A) * B.
  local pr, pi = {}, {}
  for k = 0, n - 1 do
    local m = (n - k) % n
    local zr, zi = re[k + 1], im[k + 1]
    local mr, mi = re[m + 1], im[m + 1]
    local ar, ai = (zr + mr) * 0.5, (zi - mi) * 0.5
    local br, bi = (zi + mi) * 0.5, (mr - zr) * 0.5
    pr[k + 1] = ar * br + ai * bi
    pi[k + 1] = ar * bi - ai * br
  end
  a11y.fft(pr, pi, n, true)
  local c = {}
  for k = 1, nb - na + 1 do c[k] = pr[k] end
  return c
end

--- Normalised (Pearson) cross-correlation: r[k + 1] is the correlation
--- coefficient between a[1..na] and b[k+1 .. k+na], from -1 to 1. Gain does
--- not matter, so a fader or trim difference between recordings is
--- invisible to it. Returns nil when `a` is perfectly flat, because
--- correlation with a constant means nothing.
function a11y.ncc(a, na, b, nb)
  local sum = 0
  for i = 1, na do sum = sum + a[i] end
  local mean = sum / na
  local a0, ea = {}, 0
  for i = 1, na do
    local v = a[i] - mean
    a0[i] = v
    ea = ea + v * v
  end
  if ea <= 1e-24 * na then return nil end

  local c = a11y.xcorr(a0, na, b, nb)
  local s1, s2 = { [0] = 0 }, { [0] = 0 }
  for i = 1, nb do
    local v = b[i]
    s1[i] = s1[i - 1] + v
    s2[i] = s2[i - 1] + v * v
  end
  local r = {}
  for k = 0, nb - na do
    local S1 = s1[k + na] - s1[k]
    local S2 = s2[k + na] - s2[k]
    local var = S2 - S1 * S1 / na
    local value = 0
    if S2 > 0 and var > 1e-9 * S2 then
      value = c[k + 1] / math.sqrt(ea * var)
      if value > 1 then value = 1 elseif value < -1 then value = -1 end
    end
    r[k + 1] = value
  end
  return r
end

--- Level envelope: the mean absolute value of each full block of `hop`
--- samples of x[1..count], appended to `out` (or a new table).
function a11y.envelope(x, count, hop, out)
  out = out or {}
  local n = #out
  for start = 0, count - hop, hop do
    local s = 0
    for i = start + 1, start + hop do
      local v = x[i]
      if v < 0 then v = -v end
      s = s + v
    end
    n = n + 1
    out[n] = s / hop
  end
  return out
end

--- Where is the busiest stretch of `width` entries in a level series?
--- "Busiest" is the most change from one entry to the next, not simply the
--- loudest: a held organ chord is loud but flat, and gives a correlation
--- nothing to lock onto, while drums and speech are full of edges.
--- Returns the 1-based start index and its score.
function a11y.busiest(levels, count, width)
  if width >= count then return 1, 0 end
  local d = { 0 }
  for i = 2, count do d[i] = math.abs(levels[i] - levels[i - 1]) end
  local s = 0
  for i = 2, width do s = s + d[i] end
  local best, best_at = s, 1
  for start = 2, count - width + 1 do
    -- The window now runs start .. start + width - 1; its first difference
    -- (into `start`) leaves, the last one joins.
    s = s - d[start] + d[start + width - 1]
    if s > best then best, best_at = s, start end
  end
  return best_at, best
end

--- The `count` highest local maxima of r, at least `min_sep` entries apart,
--- best first. Returns a list of 1-based indices.
function a11y.top_peaks(r, n, min_sep, count)
  local cands = {}
  for i = 1, n do
    local v = r[i]
    local left = i > 1 and r[i - 1] or -math.huge
    local right = i < n and r[i + 1] or -math.huge
    if v >= left and v > right then cands[#cands + 1] = i end
  end
  table.sort(cands, function(x, y) return r[x] > r[y] end)
  local out = {}
  for _, i in ipairs(cands) do
    local ok = true
    for _, j in ipairs(out) do
      if math.abs(i - j) < min_sep then ok = false; break end
    end
    if ok then
      out[#out + 1] = i
      if #out >= count then break end
    end
  end
  return out
end

--- How sure is a match? `best` is the strength of the winning waveform
--- correlation (0 to 1) and `second` the strongest rival found at a
--- different offset. Two recordings of the same digital signal score close
--- to 1; unrelated audio scores close to 0; music that repeats exactly gives
--- two near-equal answers, which is not a match, it is a coin toss.
function a11y.match_confidence(best, second)
  second = second or 0
  if best < 0.35 then return 'low' end
  if second >= 0.9 * best then return 'low' end
  -- A near-perfect copy stays high even beside a strong rival: a kick drum
  -- hit correlates around 0.7 with the next hit, but only the true offset
  -- reaches 1.
  if best >= 0.95 and second <= 0.85 * best then return 'high' end
  if best >= 0.7 and second < 0.7 * best then return 'high' end
  return 'medium'
end

--- A shift in samples as speech, three decimals of a second: "3.412 seconds
--- later". Under half a millisecond the seconds would read as 0.000, so it
--- counts samples instead.
function a11y.offset_phrase(samples, rate)
  local dir = samples > 0 and 'later' or 'earlier'
  local n = math.abs(samples)
  if n / rate < 0.0005 then
    n = math.floor(n + 0.5)
    return a11y.plural(n, 'sample') .. ' ' .. dir
  end
  return string.format('%.3f seconds %s', n / rate, dir)
end

--- Find the constant offset between two recordings of the same signal.
--
-- Sample positions are counted from a shared origin. The reference is read
-- over [0, ref_len); the other recording is read wherever it is needed.
-- If the same sound sits at reference sample n and at sample n + e in the
-- other recording, the answer is e: positive means the other recording is
-- late, and moving it e samples earlier lines the two up.
--
-- opts:
--   ref(start, count)   returns `count` reference samples from `start`
--   sig(start, count)   the same for the recording being lined up
--   rate                sample rate
--   ref_len             samples of reference to analyse
--   range               search this many samples either way
--   sig_lo, sig_hi      optional: where the other recording actually has
--                       audio, so offsets that would run off it are skipped
--   hop                 envelope block, default 1 ms
--   fine_len            waveform stretch for the fine pass, default 2 s
--   fine_radius         fine search either side of a candidate, default 20 ms
--   candidates          coarse candidates checked at full rate, default 3
--
-- Returns a result table { offset, score, second, coarse, confidence,
-- inverted, candidates }, or nil and a reason: 'short', 'silent_ref',
-- 'flat_ref', 'silent_sig', 'no_overlap'.
function a11y.align(opts)
  local rate = opts.rate
  local hop = opts.hop or math.max(1, math.floor(rate / 1000 + 0.5))
  local bins_r = opts.ref_len // hop
  local ref_len = bins_r * hop
  local range = hop * math.ceil(opts.range / hop)
  local radius = opts.fine_radius or math.max(2, math.floor(rate * 0.02 + 0.5))
  local fine_len = math.min(opts.fine_len or math.floor(rate * 2 + 0.5), ref_len)
  if bins_r < 16 or fine_len < 4 * hop then return nil, 'short' end
  local gate = a11y.db_to_gain(a11y.SILENCE_DB)
  local CHUNK = hop * 4096

  -- Reference envelope.
  local env_r = {}
  for start = 0, ref_len - 1, CHUNK do
    local n = math.min(CHUNK, ref_len - start)
    a11y.envelope(opts.ref(start, n), n, hop, env_r)
  end
  local loudest = 0
  for i = 1, bins_r do if env_r[i] > loudest then loudest = env_r[i] end end
  if loudest < gate then return nil, 'silent_ref' end

  -- Offsets worth trying: inside the range, and where the other recording
  -- covers the whole reference stretch.
  local lo, hi = -range, range
  if opts.sig_lo then lo = math.max(lo, hop * math.ceil(opts.sig_lo / hop)) end
  if opts.sig_hi then hi = math.min(hi, hop * ((opts.sig_hi - ref_len) // hop)) end
  if lo > hi then return nil, 'no_overlap' end

  local span = hi - lo + ref_len
  local env_s = {}
  for start = 0, span - 1, CHUNK do
    local n = math.min(CHUNK, span - start)
    a11y.envelope(opts.sig(lo + start, n), n, hop, env_s)
  end
  local bins_s = #env_s
  local any = false
  for i = 1, bins_s do if env_s[i] >= gate then any = true; break end end
  if not any then return nil, 'silent_sig' end

  local coarse = a11y.ncc(env_r, bins_r, env_s, bins_s)
  if not coarse then return nil, 'flat_ref' end
  local nlags = bins_s - bins_r + 1
  local sep = math.max(2 * radius // hop + 2, math.floor(0.05 * rate / hop))
  local peaks = a11y.top_peaks(coarse, nlags, sep, opts.candidates or 3)

  -- Fine pass on the busiest part of the reference.
  local fine_bins = math.ceil(fine_len / hop)
  local fb = a11y.busiest(env_r, bins_r, fine_bins)
  local f0 = math.min((fb - 1) * hop, ref_len - fine_len)
  local ref_fine = opts.ref(f0, fine_len)

  local results = {}
  for _, p in ipairs(peaks) do
    local guess = lo + (p - 1) * hop
    local seg = opts.sig(f0 + guess - radius, fine_len + 2 * radius)
    local r = a11y.ncc(ref_fine, fine_len, seg, fine_len + 2 * radius)
    if r then
      local bi, bv = 1, -1
      for k = 1, #r do
        local v = math.abs(r[k])
        if v > bv then bi, bv = k, v end
      end
      results[#results + 1] = { offset = guess - radius + (bi - 1),
                                score = bv, inverted = r[bi] < 0,
                                coarse = coarse[p] }
    end
  end
  if #results == 0 then return nil, 'flat_ref' end
  table.sort(results, function(x, y) return x.score > y.score end)

  local best = results[1]
  local second = 0
  for i = 2, #results do
    if results[i].offset ~= best.offset and results[i].score > second then
      second = results[i].score
    end
  end
  return {
    offset = best.offset,
    score = best.score,
    second = second,
    coarse = best.coarse,
    inverted = best.inverted,
    confidence = a11y.match_confidence(best.score, second),
    candidates = results,
  }
end

return a11y
