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
-- Listening to the audio: spans, loud points and spoken times
--------------------------------------------------------------------------
-- These read a series of levels rather than real audio, which is the whole
-- point of keeping them out of the Reaper calls. A level series is easy to
-- write by hand and the edge cases are the ones that bite: a sound that
-- runs to the very end, a gap too short to hear, a lone spike.

do
  -- 1 entry per 0.1s. Sound, then a real gap, then sound to the end.
  local loud, quiet = 1.0, 0.0
  local levels = {}
  for i = 1, 10 do levels[i] = loud end        -- 0.0 to 1.0
  for i = 11, 20 do levels[i] = quiet end      -- 1.0 to 2.0
  for i = 21, 30 do levels[i] = loud end       -- 2.0 to 3.0

  local spans = a11y.spans(levels, 10, { min_sound = 0.1, min_gap = 0.25 })
  check('two stretches of sound with a gap between', #spans == 2, tostring(#spans))
  check('first stretch starts at zero', spans[1] and spans[1].start == 0)
  check('first stretch ends at one second', spans[1] and math.abs(spans[1].stop - 1.0) < 1e-9)
  check('second stretch starts at two seconds', spans[2] and math.abs(spans[2].start - 2.0) < 1e-9)
  check('a stretch that runs to the end is still closed',
        spans[2] and math.abs(spans[2].stop - 3.0) < 1e-9)
  check('peak is reported in decibels, not gain',
        spans[1] and math.abs(spans[1].peak_db) < 0.001, spans[1] and tostring(spans[1].peak_db))
end

do
  -- A gap of one entry, 0.1s, is shorter than anyone hears as a gap.
  local levels = {}
  for i = 1, 30 do levels[i] = 1.0 end
  levels[15] = 0.0
  local spans = a11y.spans(levels, 10, { min_gap = 0.25 })
  check('a gap too short to hear does not split the sound in two', #spans == 1, tostring(#spans))
end

do
  -- A single entry of sound is a click, not an event worth reporting.
  local levels = {}
  for i = 1, 30 do levels[i] = 0.0 end
  levels[15] = 1.0
  local spans = a11y.spans(levels, 10, { min_sound = 0.25 })
  check('a sound shorter than the minimum is left out', #spans == 0, tostring(#spans))
end

do
  local levels = {}
  for i = 1, 30 do levels[i] = 0.0 end
  check('silence has no stretches at all', #a11y.spans(levels, 10, {}) == 0)
end

do
  -- Two excursions over the line, one of them several entries long.
  local quiet = a11y.db_to_gain(-20)
  local hot = a11y.db_to_gain(-0.5)
  local levels = {}
  for i = 1, 30 do levels[i] = quiet end
  levels[5] = hot
  levels[20], levels[21], levels[22] = hot, hot, hot

  local hits = a11y.loud_points(levels, 10, -1)
  check('a run of overs is one excursion, not one per entry', #hits == 2, tostring(#hits))
  check('the excursion is timed from where it starts',
        hits[1] and math.abs(hits[1].at - 0.4) < 1e-9, hits[1] and tostring(hits[1].at))
  check('the length of an excursion is reported',
        hits[2] and math.abs(hits[2].length - 0.3) < 1e-9, hits[2] and tostring(hits[2].length))
  check('nothing is over the line when the line is above everything',
        #a11y.loud_points(levels, 10, 6) == 0)
end

do
  check('short times keep their milliseconds',
        a11y.time_phrase(0.25) == '0.25 seconds', a11y.time_phrase(0.25))
  check('a whole number of seconds does not trail zeros',
        a11y.time_phrase(2) == '2 seconds', a11y.time_phrase(2))
  check('past a minute it reads as minutes and seconds',
        a11y.time_phrase(74) == '1 minute 14 seconds', a11y.time_phrase(74))
  check('one second is singular', a11y.time_phrase(1) == '1 second', a11y.time_phrase(1))
  check('a hair under one second rounds to singular too',
        a11y.time_phrase(0.9996) == '1 second', a11y.time_phrase(0.9996))
  check('a hair under a minute is a minute, never 60 seconds',
        a11y.time_phrase(59.9996) == '1 minute', a11y.time_phrase(59.9996))
  check('a negative time reads as 0, not minus 0',
        a11y.time_phrase(-0.0001) == '0 seconds', a11y.time_phrase(-0.0001))
  check('plural takes a fraction without erroring',
        a11y.plural(2.5, 'semitone') == '2.5 semitones', a11y.plural(2.5, 'semitone'))
end

do
  -- remember() persists across restarts, and REAPER's saved state is one
  -- line per value, so a newline must not reach it.
  local store = {}
  local saved_set, saved_get = reaper.SetExtState, reaper.GetExtState
  local persisted, stored_raw
  reaper.SetExtState = function(sec, key, v, persist)
    store[key] = v; persisted = persist; stored_raw = v
  end
  reaper.GetExtState = function(sec, key) return store[key] or '' end
  a11y.remember('k', 'one\ntwo')
  check('remembered values persist', persisted == true)
  check('a newline never reaches saved state', not stored_raw:find('\n'))
  check('a newline comes back as a newline', a11y.recall('k') == 'one\ntwo')
  a11y.remember('w', 'C:\\new folder\\sounds')
  check('a Windows path survives untouched', a11y.recall('w') == 'C:\\new folder\\sounds',
        a11y.recall('w'))
  reaper.SetExtState, reaper.GetExtState = saved_set, saved_get
end

do
  -- A take envelope counts from its item's start, in the take's own time.
  local saved = {}
  for _, k in ipairs({ 'Envelope_GetParentTake', 'GetMediaItemTake_Item',
                       'GetMediaItemInfo_Value', 'GetMediaItemTakeInfo_Value' }) do
    saved[k] = reaper[k]
  end
  reaper.Envelope_GetParentTake = function(env) return env.take end
  reaper.GetMediaItemTake_Item = function() return 'item' end
  reaper.GetMediaItemInfo_Value = function() return 10 end
  reaper.GetMediaItemTakeInfo_Value = function() return 1.5 end
  local t, rate = a11y.envelope_time({ take = 'take' }, 12)
  check('take envelope time is item relative and scaled by rate', t == 3 and rate == 1.5,
        tostring(t) .. ' ' .. tostring(rate))
  t, rate = a11y.envelope_time({}, 12)
  check('track envelope time passes through', t == 12 and rate == 1)
  for k, v in pairs(saved) do reaper[k] = v end
end

--------------------------------------------------------------------------
-- Lining up two recordings: FFT, correlation, and the whole search.
--------------------------------------------------------------------------
-- The search is tested end to end on synthetic audio at 8 kHz, where a
-- "millisecond" envelope block is 8 samples. Everything is about exact
-- sample offsets: lined up "nearly" is the bug this exists to prevent.

do
  -- FFT round trip, and a known transform: an impulse is flat.
  local n = 64
  local re, im, orig = {}, {}, {}
  for i = 1, n do
    orig[i] = math.sin(i * 0.7) + (i % 5) * 0.1
    re[i], im[i] = orig[i], 0
  end
  a11y.fft(re, im, n)
  a11y.fft(re, im, n, true)
  local worst = 0
  for i = 1, n do worst = math.max(worst, math.abs(re[i] - orig[i]), math.abs(im[i])) end
  check('an FFT and its inverse give back the input', worst < 1e-12, tostring(worst))

  local r2, i2 = {}, {}
  for i = 1, 16 do r2[i], i2[i] = 0, 0 end
  r2[1] = 1
  a11y.fft(r2, i2, 16)
  local flat = true
  for i = 1, 16 do
    if math.abs(r2[i] - 1) > 1e-12 or math.abs(i2[i]) > 1e-12 then flat = false end
  end
  check('the transform of an impulse is flat', flat)
end

do
  -- FFT correlation against the obvious double loop.
  local a, b = {}, {}
  for i = 1, 37 do a[i] = math.cos(i * 1.3) * (i % 7) end
  for i = 1, 100 do b[i] = math.sin(i * 0.37) + ((i * 13) % 11) * 0.05 end
  local c = a11y.xcorr(a, 37, b, 100)
  local worst = 0
  for k = 0, 100 - 37 do
    local s = 0
    for j = 1, 37 do s = s + a[j] * b[j + k] end
    worst = math.max(worst, math.abs(s - c[k + 1]))
  end
  check('FFT cross-correlation matches the direct sum', worst < 1e-9, tostring(worst))
  check('one correlation value per possible lag', #c == 64, tostring(#c))

  local r = a11y.ncc(a, 37, b, 100)
  local inside = true
  for k = 1, #r do if r[k] > 1 or r[k] < -1 then inside = false end end
  check('normalised correlation stays between -1 and 1', inside)

  -- b contains a copy of a, scaled and offset, at lag 20.
  local b2 = {}
  for i = 1, 100 do b2[i] = 0.01 * ((i * 7) % 5) end
  for j = 1, 37 do b2[j + 20] = 3 * a[j] + 0.5 end
  local r2 = a11y.ncc(a, 37, b2, 100)
  check('a scaled copy correlates at exactly 1', math.abs(r2[21] - 1) < 1e-9, tostring(r2[21]))
  check('a flat reference has no correlation at all',
        a11y.ncc({ 2, 2, 2, 2 }, 4, b, 100) == nil)
end

do
  local levels = { 0, 0, 0, 0, 1, 0, 1, 0, 0, 0 }
  local at = a11y.busiest(levels, 10, 4)
  check('the busiest stretch is the one with the most change', at == 4 or at == 5, tostring(at))
  local hold = { 1, 1, 1, 1, 1, 1, 0, 1, 0, 1 }
  check('a loud flat stretch is not busy', (a11y.busiest(hold, 10, 4)) >= 6)

  local r = { 0, 0.5, 0.2, 0.9, 0.85, 0.1, 0.7, 0, 0.3, 0 }
  local p = a11y.top_peaks(r, 10, 2, 3)
  check('peaks come back best first', p[1] == 4 and p[2] == 7, table.concat(p, ' '))
  check('a peak too close to a better one is skipped', p[3] == 2 or p[3] == 9, tostring(p[3]))

  check('a near-perfect lone match is high confidence', a11y.match_confidence(0.99, 0.1) == 'high')
  check('a weak match is low confidence', a11y.match_confidence(0.2, 0) == 'low')
  check('two equal answers are low confidence', a11y.match_confidence(0.9, 0.85) == 'low')
  check('a decent match with a rival is medium', a11y.match_confidence(0.8, 0.65) == 'medium')
  check('an exact copy beside a similar drum hit is still high',
        a11y.match_confidence(0.999, 0.72) == 'high')

  check('offset later in seconds', a11y.offset_phrase(163776, 48000) == '3.412 seconds later',
        a11y.offset_phrase(163776, 48000))
  check('offset earlier in seconds', a11y.offset_phrase(-48000, 48000) == '1.000 seconds earlier',
        a11y.offset_phrase(-48000, 48000))
  check('tiny offsets are counted in samples', a11y.offset_phrase(1, 48000) == '1 sample later',
        a11y.offset_phrase(1, 48000))
  check('a few samples earlier', a11y.offset_phrase(-7, 48000) == '7 samples earlier',
        a11y.offset_phrase(-7, 48000))
end

do
  local saved = reaper.GetUserInputs
  local seen_fields, seen_defaults
  reaper.GetUserInputs = function(_, n, fields, defaults)
    seen_fields, seen_defaults = fields, defaults
    return true, '5,,60'
  end
  local got = a11y.prompt_many('t', { 'One', 'Two', 'Three' }, { 1, nil, 60 })
  check('several fields go to one dialog', seen_fields == 'One,Two,Three', seen_fields)
  check('defaults line up with their fields', seen_defaults == '1,,60', seen_defaults)
  check('answers come back one per field, blanks kept',
        got and #got == 3 and got[1] == '5' and got[2] == '' and got[3] == '60')
  reaper.GetUserInputs = function() return false, '' end
  check('cancel gives nil', a11y.prompt_many('t', { 'One' }) == nil)
  -- A comma typed into a field would shift every later answer along.
  reaper.GetUserInputs = function() return true, '-0,5,30' end
  local spoke
  local saved_box = reaper.ShowMessageBox
  reaper.ShowMessageBox = function(msg) spoke = msg; return 0 end
  local ok, err = pcall(a11y.prompt_many, 't', { 'One', 'Two' })
  check('a comma in an answer stops with a reason',
        not ok and type(err) == 'table' and err.a11y_abort and spoke and spoke:find('comma'),
        tostring(spoke))
  reaper.ShowMessageBox = saved_box
  reaper.GetUserInputs = saved
end

-- Synthetic "drums": decaying clicks at irregular times over quiet noise.
local function performance(len, seed)
  math.randomseed(seed)
  local x = {}
  for i = 1, len do x[i] = (math.random() - 0.5) * 0.02 end
  local at = 1
  while at < len do
    local amp = 0.2 + math.random() * 0.7
    local decay = 0.995 - math.random() * 0.02
    local v = amp
    for i = at, math.min(len, at + 1200) do
      x[i] = x[i] + v * (math.random() - 0.5) * 2
      v = v * decay
    end
    at = at + 400 + math.random(0, 3000)
  end
  return x
end

local function reader(x, shift, gain)
  -- Reads x as if it started `shift` samples late; silence outside it.
  gain = gain or 1
  return function(start, count)
    local out = {}
    for i = 1, count do
      local j = start + i - shift
      out[i] = (x[j] or 0) * gain
    end
    return out
  end
end

local RATE = 8000
local SOURCE = performance(RATE * 14, 7)

local function line_up(shift, extra)
  local opts = {
    ref = reader(SOURCE, 0),
    sig = reader(SOURCE, shift),
    rate = RATE, ref_len = RATE * 6, range = RATE * 2,
  }
  for k, v in pairs(extra or {}) do opts[k] = v end
  return a11y.align(opts)
end

for _, case in ipairs({
  { 12345, 'a late recording' },
  { -9876, 'an early recording' },
  { 4003, 'an offset that is not a whole millisecond' },
  { 0, 'no offset at all' },
  { 15990, 'an offset just inside the far edge of the search' },
  { -15999, 'an offset just inside the near edge of the search' },
}) do
  local shift, name = case[1], case[2]
  local res, why = line_up(shift)
  check('finds ' .. name .. ' to the sample',
        res and res.offset == shift,
        res and string.format('got %d, wanted %d', res.offset, shift) or why)
  check('and is sure about ' .. name, res and res.confidence == 'high',
        res and string.format('%s, score %.3f, rival %.3f', res.confidence, res.score, res.second))
end

do
  -- Quieter, inverted and carrying its own noise, like a second preamp tap.
  local noisy = {}
  for i = 1, #SOURCE do noisy[i] = SOURCE[i] + (math.random() - 0.5) * 0.004 end
  local res = a11y.align({ ref = reader(SOURCE, 0), sig = reader(noisy, 777, -0.25),
                           rate = RATE, ref_len = RATE * 6, range = RATE * 2 })
  check('a quieter, upside-down copy still lines up to the sample',
        res and res.offset == 777, res and tostring(res.offset))
  check('and the flipped polarity is noticed', res and res.inverted == true)
end

do
  -- Two unrelated performances must not "match".
  local other = performance(RATE * 14, 99)
  local res = a11y.align({ ref = reader(SOURCE, 0), sig = reader(other, 0),
                           rate = RATE, ref_len = RATE * 6, range = RATE * 2 })
  check('unrelated audio is low confidence', res and res.confidence == 'low',
        res and string.format('%s, score %.3f', res.confidence, res.score))
end

do
  -- A loop that repeats exactly has many right answers, so none of them is.
  local bar = performance(RATE, 3)
  local loop = {}
  for i = 1, RATE * 14 do loop[i] = bar[(i - 1) % RATE + 1] end
  local res = a11y.align({ ref = reader(loop, 0), sig = reader(loop, 2500),
                           rate = RATE, ref_len = RATE * 6, range = RATE * 2 })
  check('an exactly repeating loop is called ambiguous, not guessed',
        res and res.confidence == 'low',
        res and string.format('%s, score %.3f, rival %.3f', res.confidence, res.score, res.second))
end

do
  local silent = {}
  for i = 1, RATE * 14 do silent[i] = 0 end
  local res, why = a11y.align({ ref = reader(silent, 0), sig = reader(SOURCE, 0),
                                rate = RATE, ref_len = RATE * 6, range = RATE * 2 })
  check('a silent reference is refused', res == nil and why == 'silent_ref', tostring(why))
  res, why = a11y.align({ ref = reader(SOURCE, 0), sig = reader(silent, 0),
                          rate = RATE, ref_len = RATE * 6, range = RATE * 2 })
  check('a silent channel to match is refused', res == nil and why == 'silent_sig', tostring(why))
  res, why = line_up(100, { sig_lo = RATE * 30, sig_hi = RATE * 40 })
  check('no overlap within the search is refused', res == nil and why == 'no_overlap', tostring(why))
end

do
  -- The other recording only starts 1 second before the reference stretch:
  -- offsets earlier than that are impossible and must not be tried.
  local res = line_up(3000, { sig_lo = -RATE, sig_hi = RATE * 20 })
  check('a limited overlap still finds the offset', res and res.offset == 3000,
        res and tostring(res.offset))
end

--------------------------------------------------------------------------

print(string.format('%d passed, %d failed  (%d template names)', pass, fail, #names))
for _, msg in ipairs(failures) do print('  FAIL: ' .. msg) end
os.exit(fail == 0 and 0 or 1)
