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

      local sep  = package.config:sub(1, 1)
      local root = ({reaper.get_action_context()})[2]:match('^(.*)' .. sep)
      package.path = root .. sep .. '..' .. sep .. 'Lib' .. sep .. '?.lua;' .. package.path
      local ok, a11y = pcall(require, 'a11y')

  See any script in this repo for the exact preamble, including the
  spoken error shown when the library is missing.
]]

local a11y = {}

a11y.VERSION = '1.0.0'

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

--- Speak a message through the screen reader.
-- Falls back to a message box when OSARA is unavailable, so a script never
-- fails silently on a machine without it.
-- @param msg string
function a11y.speak(msg)
  msg = tostring(msg or '')
  if msg == '' then return end
  if reaper.osara_outputMessage then
    reaper.osara_outputMessage(msg)
  else
    reaper.ShowMessageBox(msg, 'Accessible ReaScripts', 0)
  end
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
  return string.format('%d %s', n, n == 1 and singular or plural_form)
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
-- VoiceOver. Instead we speak a numbered list and ask for a number, which
-- lands in the screen reader's announcement history so it can be reviewed.
--
-- The caller has usually already narrowed the list with a search, so this
-- is normally a handful of items. `max_spoken` caps the read-out so a broad
-- search never turns into a wall of speech.
--
-- @param title string
-- @param items table  list of items (must be non-empty)
-- @param labelfn function|nil  item -> string
-- @param max_spoken number|nil  default 12
-- @return item|nil, index|nil
function a11y.pick(title, items, labelfn, max_spoken)
  labelfn = labelfn or tostring
  max_spoken = max_spoken or 12
  local n = #items
  if n == 0 then return nil end
  if n == 1 then return items[1], 1 end

  local shown = math.min(n, max_spoken)
  local lines = {}
  for i = 1, shown do
    lines[#lines + 1] = string.format('%d, %s', i, labelfn(items[i]))
  end

  local header
  if n > shown then
    header = string.format('%d matches. First %d: ', n, shown)
  else
    header = string.format('%d matches: ', n)
  end
  a11y.speak(header .. table.concat(lines, '. ') .. '.')

  local caption = string.format('Number 1 to %d:', shown)
  local answer = a11y.prompt(title, caption, '1', 60)
  if not answer then return nil end

  local idx = tonumber(answer)
  if not idx or idx < 1 or idx > shown or idx ~= math.floor(idx) then
    a11y.abort(string.format('%s is not a number between 1 and %d. Cancelled.',
                             answer == '' and 'Blank' or answer, shown))
  end
  return items[idx], idx
end

--- Yes/no confirmation. Returns true only on Yes.
function a11y.confirm(title, question)
  return reaper.ShowMessageBox(question, title, 4) == 6
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
function a11y.basename(path, strip_ext)
  local s = a11y.sep()
  local name = path:match('([^' .. s .. ']+)$') or path
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

--- Remember a value between runs (per script key).
function a11y.remember(key, value)
  reaper.SetExtState('accessible_reascripts', key, tostring(value or ''), false)
end

--- Read a value stored by remember().
function a11y.recall(key, default)
  local v = reaper.GetExtState('accessible_reascripts', key)
  if v == nil or v == '' then return default end
  return v
end

return a11y
