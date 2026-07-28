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
-- surprises you is worse than one that is merely blunt. Higher is better;
-- nil means no match at all.
--
-- Tiers, in order:
--   exact                    1000
--   prefix                    900 - length penalty
--   word-start ("rho" in "keyscape rhodes")   800 - penalty
--   substring anywhere        700 - penalty
--   initials  ("krs" -> "keyscape rhodes suitcase")  600 - penalty
--   subsequence in order      500 - penalty
--
-- The length penalty breaks ties toward shorter names, so searching
-- "piano 1" prefers "piano 1" over "piano 1 gospel".

local function escape_pattern(s)
  return (s:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
end

--- Split a name into lowercase words.
local function words_of(s)
  local out = {}
  for w in s:lower():gmatch('[%w]+') do out[#out + 1] = w end
  return out
end

--- Do the characters of `q` appear in `s` in order?
local function is_subsequence(q, s)
  local i = 1
  for c = 1, #q do
    local ch = q:sub(c, c)
    local found = s:find(ch, i, true)
    if not found then return false end
    i = found + 1
  end
  return true
end

--- Does `q` match the leading letters of consecutive words in `s`?
local function matches_initials(q, s)
  local initials = {}
  for _, w in ipairs(words_of(s)) do initials[#initials + 1] = w:sub(1, 1) end
  return is_subsequence(q, table.concat(initials))
end

--- Score `candidate` against `query`. Returns a number, or nil for no match.
function a11y.score(query, candidate)
  query = (query or ''):lower():gsub('^%s+', ''):gsub('%s+$', '')
  local cand = (candidate or ''):lower()
  if query == '' then return 1 end -- empty query matches everything, flatly
  if cand == '' then return nil end

  -- Length penalty is capped so a very long name is never ranked below a
  -- worse-tier match purely for being long.
  local penalty = math.min(#cand, 99)

  if cand == query then return 1000 end
  if cand:sub(1, #query) == query then return 900 - penalty end

  -- Word-start: query begins one of the words.
  for _, w in ipairs(words_of(cand)) do
    if w:sub(1, #query) == query then return 800 - penalty end
  end

  if cand:find(escape_pattern(query)) then return 700 - penalty end

  -- Multi-word query: every word must appear somewhere. This makes
  -- "rhodes amp" find "keyscape rhodes 2 amped chorus pan".
  local qwords = words_of(query)
  if #qwords > 1 then
    local all = true
    for _, qw in ipairs(qwords) do
      if not cand:find(escape_pattern(qw)) then all = false break end
    end
    if all then return 650 - penalty end
  end

  local qcompact = query:gsub('%s+', '')
  if matches_initials(qcompact, cand) then return 600 - penalty end
  if is_subsequence(qcompact, cand:gsub('%s+', '')) then return 500 - penalty end

  return nil
end

--- Filter and rank `items` against `query`.
-- @param query string
-- @param items table  list of items
-- @param labelfn function|nil  item -> string (defaults to tostring)
-- @return table  ranked list of items, best first
function a11y.filter(query, items, labelfn)
  labelfn = labelfn or tostring
  local scored = {}
  for i, item in ipairs(items) do
    local s = a11y.score(query, labelfn(item))
    if s then
      -- `order` keeps the sort stable, which keeps results predictable
      -- between identical searches.
      scored[#scored + 1] = { item = item, score = s, order = i }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.order < b.order
  end)
  local out = {}
  for i, rec in ipairs(scored) do out[i] = rec.item end
  return out
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
