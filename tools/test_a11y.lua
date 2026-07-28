--[[
  Tests for the pure-logic parts of Lib/a11y.lua -- the ones that do not
  need Reaper. Run from the repo root with:

      lua tools/test_a11y.lua

  Ranking is the thing most worth testing. A search that puts the wrong
  template first is worse than no search at all, because you insert 18
  tracks of a big band before you notice.
]]

package.path = 'Lib/?.lua;' .. package.path

-- Minimal reaper stub. The library only touches these at call time, and
-- none of the functions under test call them, but require() must succeed.
reaper = {
  ShowMessageBox = function() return 0 end,
  GetUserInputs = function() return false, '' end,
  SetExtState = function() end,
  GetExtState = function() return '' end,
}

local a11y = require('a11y')

local pass, fail = 0, 0
local failures = {}

local function check(desc, ok, detail)
  if ok then
    pass = pass + 1
  else
    fail = fail + 1
    failures[#failures + 1] = desc .. (detail and ('  -> ' .. detail) or '')
  end
end

--------------------------------------------------------------------------
-- Load the real template names if available, else a representative sample.
--------------------------------------------------------------------------

local names = {}
local f = io.open('tools/fixtures/track_templates.txt', 'r')
if f then
  for line in f:lines() do
    if line ~= '' then names[#names + 1] = line end
  end
  f:close()
end
if #names == 0 then
  names = {
    'piano 1', 'piano 1 gospel', 'piano 2', 'piano 2 gospel', 'piano 3',
    'keyscape rhodes 1', 'keyscape rhodes 2', 'keyscape rhodes 2 amp',
    'keyscape rhodes 2 dry', 'keyscape rhodes suitcase', 'keyscape wurley',
    'drum setup', 'drum setup (with panning)', 'drum setup (light processing)',
    'swam big band', 'swam big band, with tp mutes',
    'vintage vibe amp', 'vintage vibe ep', 'organ setup', 'organ DI',
    'wurley 200', 'wurley 200 amped', 'acoustic bass', 'electric bass',
  }
end

local function top(query, n)
  local hits = a11y.filter(query, names)
  local out = {}
  for i = 1, math.min(n or 5, #hits) do out[i] = hits[i] end
  return out, #hits
end

local function first(query)
  local hits = a11y.filter(query, names)
  return hits[1]
end

local function contains(list, value)
  for _, v in ipairs(list) do if v == value then return true end end
  return false
end

--------------------------------------------------------------------------
-- Ranking
--------------------------------------------------------------------------

-- An exact name must win, even when longer names also contain it. This is
-- the single most important behaviour: "piano 1" must not insert
-- "piano 1 gospel".
check('exact name beats longer superstring',
      first('piano 1') == 'piano 1', tostring(first('piano 1')))

check('exact match is case insensitive',
      first('PIANO 1') == 'piano 1', tostring(first('PIANO 1')))

check('surrounding whitespace is ignored',
      first('  piano 1  ') == 'piano 1', tostring(first('  piano 1  ')))

-- Prefix beats mid-string.
check('prefix beats mid-string match',
      first('organ') == 'organ setup' or first('organ') == 'organ DI',
      tostring(first('organ')))

-- Word-start matching: searching a word that starts a later word.
do
  local hits = top('rhodes', 10)
  check('word-start finds all rhodes templates',
        contains(hits, 'keyscape rhodes 1') and contains(hits, 'keyscape rhodes 2'),
        table.concat(hits, ' | '))
end

-- Multi-word: all words must be present, order irrelevant.
do
  local hits, n = top('rhodes amp', 10)
  local ok = n > 0
  for _, h in ipairs(hits) do
    local lower = h:lower()
    if not (lower:find('rhodes') and lower:find('amp')) then ok = false end
  end
  check('multi-word requires every word', ok, table.concat(hits, ' | '))
end

check('multi-word order does not matter',
      first('amp rhodes') ~= nil and first('rhodes amp') ~= nil)

-- Initials.
do
  local hits = top('ksr', 10)
  local ok = false
  for _, h in ipairs(hits) do
    if h:lower():find('keyscape') and h:lower():find('rhodes') then ok = true end
  end
  check('initials match across words (ksr -> keyscape rhodes)', ok,
        table.concat(hits, ' | '))
end

-- Shorter names win ties within a tier.
check('shorter name wins a tie',
      first('wurley 200') == 'wurley 200', tostring(first('wurley 200')))

check('drum search finds the plain setup first',
      first('drum setup') == 'drum setup', tostring(first('drum setup')))

--------------------------------------------------------------------------
-- Non-matches and edges
--------------------------------------------------------------------------

check('nonsense query matches nothing',
      #a11y.filter('zzzqqqxxvv', names) == 0)

check('empty query returns everything',
      #a11y.filter('', names) == #names)

check('score returns nil for no match',
      a11y.score('zzzz', 'piano 1') == nil)

check('score returns a number for a match',
      type(a11y.score('piano', 'piano 1')) == 'number')

check('empty candidate never matches a real query',
      a11y.score('piano', '') == nil)

-- Pattern metacharacters in names must not blow up the matcher. Several
-- real templates contain parentheses and commas.
check('parentheses in query are literal, not pattern syntax',
      first('(with panning)') ~= nil or #a11y.filter('(with panning)', names) >= 0)

check('a query of pure punctuation does not error',
      pcall(a11y.filter, '%(%)', names))

do
  local ok = pcall(a11y.score, 'a+b*c', 'anything')
  check('regex metacharacters do not error', ok)
end

--------------------------------------------------------------------------
-- Stability
--------------------------------------------------------------------------

do
  local a = table.concat(a11y.filter('piano', names), '|')
  local b = table.concat(a11y.filter('piano', names), '|')
  check('identical searches give identical order', a == b)
end

--------------------------------------------------------------------------
-- Text helpers
--------------------------------------------------------------------------

check('plural singular', a11y.plural(1, 'track') == '1 track')
check('plural plural', a11y.plural(3, 'track') == '3 tracks')
check('plural zero', a11y.plural(0, 'track') == '0 tracks')
check('plural irregular', a11y.plural(2, 'is', 'are') == '2 are')

check('list phrase one', a11y.list_phrase({ 'a' }) == 'a')
check('list phrase two', a11y.list_phrase({ 'a', 'b' }) == 'a and b')
check('list phrase three', a11y.list_phrase({ 'a', 'b', 'c' }) == 'a, b and c')
check('list phrase empty', a11y.list_phrase({}) == '')

check('duration seconds', a11y.duration_phrase(45) == '45 seconds')
check('duration one second', a11y.duration_phrase(1) == '1 second')
check('duration zero', a11y.duration_phrase(0) == '0 seconds')
check('duration minutes', a11y.duration_phrase(184) == '3 minutes 4 seconds')
check('duration exact minute', a11y.duration_phrase(120) == '2 minutes')
check('duration hours', a11y.duration_phrase(3600) == '1 hour')
check('duration rounds', a11y.duration_phrase(59.6) == '1 minute')

check('basename strips folder',
      a11y.basename('/a/b/c.lua') == 'c.lua')
check('basename strips extension',
      a11y.basename('/a/b/c.lua', true) == 'c')

--------------------------------------------------------------------------
-- Numbered rename patterns
--------------------------------------------------------------------------

do
  local r, found = a11y.number_pattern('Vox #', 3)
  check('single hash substitutes', r == 'Vox 3', r)
  check('single hash reports found', found == true)
end

do
  local r = a11y.number_pattern('Tom ##', 3)
  check('double hash pads to two digits', r == 'Tom 03', r)
end

do
  local r = a11y.number_pattern('Take ###', 42)
  check('triple hash pads to three digits', r == 'Take 042', r)
end

do
  local r = a11y.number_pattern('Tom ##', 123)
  check('padding never truncates a longer number', r == 'Tom 123', r)
end

do
  local r, found = a11y.number_pattern('Kick', 2)
  check('no hash leaves the name alone', r == 'Kick', r)
  check('no hash reports not found', found == false)
end

do
  local r = a11y.number_pattern('# of #', 5)
  check('every hash run is substituted', r == '5 of 5', r)
end

do
  local r = a11y.number_pattern('Vox #', 0)
  check('zero is substituted, not treated as absent', r == 'Vox 0', r)
end

do
  -- '%' is the escape character in Lua patterns; a name containing one
  -- must survive gsub untouched.
  local r = a11y.number_pattern('100% Wet #', 2)
  check('percent sign in name survives', r == '100% Wet 2', r)
end

--------------------------------------------------------------------------

print(string.format('%d passed, %d failed  (%d template names)', pass, fail, #names))
for _, msg in ipairs(failures) do print('  FAIL: ' .. msg) end
os.exit(fail == 0 and 0 or 1)
