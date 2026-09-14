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
-- Fallback tiers
--------------------------------------------------------------------------
-- These guard a real bug. The loose tiers were fine over 170 track template
-- names and became useless noise over ~2000 plugin names: a subsequence
-- search for "ssl" matched 472 of them, because nearly any name contains an
-- s, an s and an l somewhere. Loose tiers are now held back unless nothing
-- better matched, and subsequence matches must be reasonably compact.

local fx = {
  'VST3: Pro-Q 4 (FabFilter)', 'AU: FabFilter: Pro-Q 4',
  'VST: FabFilter Pro-Q 4 (FabFilter)', 'AU: Waves: SSLEQ (m)',
  'AU: Waves: SSLComp (m)', 'VST3: Scheps Omni Channel (Waves)',
  'VST: elysia alpha mix (Plugin Alliance)',
  'AU: Spectrasonics: Keyscape', 'AU: Apple: AUDelay',
  'VST3: Shadow Hills Mastering Compressor (Plugin Alliance)',
}

do
  -- "ssl" has real substring hits, so the scattered-letter matches that
  -- also technically qualify must not be shown at all.
  local hits = a11y.filter('ssl', fx)
  local all_real = true
  for _, h in ipairs(hits) do
    if not h:lower():find('ssl') then all_real = false end
  end
  check('strict matches suppress loose ones', all_real, table.concat(hits, ' | '))
  check('strict match count is small', #hits == 2, tostring(#hits))
end

do
  -- Nothing here is a Valhalla plugin. Scavenging v-a-l-h-a-l-l-a across
  -- "VST: elysia alpha mix (Plugin Alliance)" must not count.
  local hits = a11y.filter('valhalla', fx)
  check('absent plugin returns nothing rather than scattered noise',
        #hits == 0, table.concat(hits, ' | '))
end

do
  local hits = a11y.filter('proq', fx)
  check('proq finds exactly the three Pro-Q formats', #hits == 3,
        table.concat(hits, ' | '))
end

do
  -- Loose tiers still rescue a search that would otherwise be empty.
  local hits = a11y.filter('keysc', { 'Keyscape', 'unrelated thing' })
  check('loose tier still rescues an otherwise empty search', #hits >= 1,
        table.concat(hits, ' | '))
end

do
  local _, tier = a11y.score('piano 1', 'piano 1')
  check('score reports tier 1 for an exact match', tier == 1, tostring(tier))
  local _, t2 = a11y.score('pia', 'piano 1')
  check('score reports tier 2 for a prefix', t2 == 2, tostring(t2))
end

do
  -- A two-character query is too short to mean anything by subsequence.
  check('very short query does not match by subsequence',
        a11y.score('xz', 'existing zebra material') == nil)
end

do
  -- Initials must be consecutive words, not scattered through the name.
  check('initials match consecutive words',
        a11y.score('krs', 'keyscape rhodes suitcase') ~= nil)
  check('initials do not match scattered words',
        a11y.score('kzq', 'keyscape rhodes suitcase') == nil)
end

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
-- Envelope values
--------------------------------------------------------------------------
-- These get their own tests because a wrong conversion is silent. The ramp
-- lands, the script speaks a confident number, and the automation is simply
-- in the wrong place.

local function near(a, b, tolerance)
  return math.abs(a - b) <= (tolerance or 0.0001)
end

check('unity gain is 0 dB', near(a11y.gain_to_db(1), 0))
check('half gain is about -6 dB', near(a11y.gain_to_db(0.5), -6.0206, 0.001))
check('double gain is about +6 dB', near(a11y.gain_to_db(2), 6.0206, 0.001))
check('0 dB is unity gain', near(a11y.db_to_gain(0), 1))
check('-6.0206 dB is half gain', near(a11y.db_to_gain(-6.0206), 0.5, 0.0001))

do
  -- Silence would otherwise run to negative infinity, which formats as
  -- "-inf" and is read aloud as nonsense.
  check('zero gain floors instead of returning -inf',
        a11y.gain_to_db(0) == a11y.MIN_DB)
  check('negative gain floors too', a11y.gain_to_db(-1) == a11y.MIN_DB)
  check('the floor converts back to silence', a11y.db_to_gain(a11y.MIN_DB) == 0)
end

do
  local worst = 0
  for db = -60, 12 do
    local back = a11y.gain_to_db(a11y.db_to_gain(db))
    worst = math.max(worst, math.abs(back - db))
  end
  check('dB survives a round trip across the useful range', worst < 0.0001,
        'worst drift ' .. worst)
end

--------------------------------------------------------------------------
-- Envelope point shapes
--------------------------------------------------------------------------

do
  local cases = {
    { 'linear', 0 }, { '', 0 }, { 'lin', 0 }, { 'straight', 0 },
    { 'square', 1 }, { 'hold', 1 }, { 'step', 1 },
    { 'slow', 2 }, { 'smooth', 2 }, { 'ease', 2 },
    { 'fast start', 3 }, { 'faststart', 3 }, { 'start', 3 },
    { 'fast end', 4 }, { 'fastend', 4 }, { 'end', 4 },
    { 'bezier', 5 }, { 'bez', 5 },
  }
  for _, case in ipairs(cases) do
    local id = a11y.envelope_shape(case[1])
    check(string.format('shape %q is %d', case[1], case[2]), id == case[2],
          'got ' .. tostring(id))
  end
end

do
  -- The two that the bare 'start' and 'end' keywords could plausibly break.
  -- 'fast end' is saved by exact matches running first; 'slow start and end'
  -- is saved by SHAPES being walked in order, so reordering that table would
  -- break this one and not the other.
  check('fast end is not captured by the start keyword',
        a11y.envelope_shape('fast end') == 4)
  check('slow start and end is slow, not start or end',
        a11y.envelope_shape('slow start and end') == 2)
end

do
  local id, name = a11y.envelope_shape('total gibberish')
  check('unrecognised text falls back to linear', id == 0 and name == 'linear',
        tostring(id) .. ' ' .. tostring(name))
end

do
  local _, name = a11y.envelope_shape('fastend')
  check('the spoken name is prose, not the typed word', name == 'fast end', name)
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
-- Track labels
--------------------------------------------------------------------------

do
  local l = a11y.track_label(4, 'Lead Vox')
  check('track label puts the number first', l == '4, Lead Vox', l)
end

do
  -- An unnamed track has to say so. A trailing comma and silence sounds
  -- exactly like speech that got cut off.
  local l = a11y.track_label(12, '')
  check('empty track name says unnamed', l == '12, unnamed', l)
  local n = a11y.track_label(12, nil)
  check('nil track name says unnamed', n == '12, unnamed', n)
end

--------------------------------------------------------------------------
-- Windows paths
--------------------------------------------------------------------------
-- a11y.sep() reads package.config on every call, so Windows behaviour can be
-- exercised from any platform by swapping that string out. Worth doing
-- properly: this collection has a Windows and NVDA contributor, and nobody
-- developing it runs Windows, so these paths would otherwise only ever be
-- tested by someone hearing them go wrong.

do
  local real_config = package.config
  package.config = '\\\n;\n?\n!\n-\n'

  check('sep is a backslash on Windows', a11y.sep() == '\\', a11y.sep())

  local joined = a11y.path_join('C:', 'Users', 'tony')
  check('path_join uses backslashes', joined == 'C:\\Users\\tony', joined)

  local b1 = a11y.basename('C:\\Songs\\take_003.RPP')
  check('basename handles a backslash path', b1 == 'take_003.RPP', b1)

  -- Reaper returns backslashes, but a project can reference media saved with
  -- forward slashes. Matching only the platform separator returns the whole
  -- path, and that path is then spoken aloud.
  local b2 = a11y.basename('C:/Songs/take_003.RPP')
  check('basename handles a forward-slash path on Windows',
        b2 == 'take_003.RPP', b2)

  local b3 = a11y.basename('C:\\Songs\\take_003.RPP', true)
  check('basename strips the extension on Windows', b3 == 'take_003', b3)

  package.config = real_config
end

do
  -- Off Windows a backslash is a legal filename character, not a separator.
  --
  -- This needs the same package.config swap as the Windows cases above, and
  -- for the same reason in reverse. Run bare, it asserts non-Windows
  -- behaviour against whatever platform the developer happens to be on, so
  -- it passes on macOS and fails on Windows -- on the machine of the very
  -- contributor these path tests were written for.
  local real_config = package.config
  package.config = '/\n;\n?\n!\n-\n'

  local b = a11y.basename('/tmp/odd\\name.RPP')
  check('backslash stays part of the name off Windows', b == 'odd\\name.RPP', b)

  package.config = real_config
end

--------------------------------------------------------------------------

print(string.format('%d passed, %d failed  (%d template names)', pass, fail, #names))
for _, msg in ipairs(failures) do print('  FAIL: ' .. msg) end
os.exit(fail == 0 and 0 or 1)
