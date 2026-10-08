--[[
  Run the lining-up search from Lib/a11y.lua on WAV files, outside REAPER.

      lua tools/align_wavs.lua REF.wav REF_CHANNEL SD1.wav[,SD2.wav,...] SD_CHANNEL [SECONDS] [RANGE] [AT]

  REF.wav is the recording to line up to. The SD files are one console
  session: several files listed in order are treated as one continuous
  recording, the way a long WING-LIVE session is split into chunks.
  Channels count from 1. SECONDS of reference starting AT seconds into it
  (default 20 and 0) are searched for within RANGE seconds either way
  (default 60).

  Prints the offset: how many samples later the same sound sits in the SD
  session than in the reference file, counting both from their first
  sample. It exists so the same Lua the script uses can be checked against
  real files, and by tools/test_align_wavs.py against generated ones.
]]

package.path = 'Lib/?.lua;' .. package.path
reaper = {}
local a11y = require('a11y')

local function open_wav(path)
  local f = assert(io.open(path, 'rb'))
  local head = f:read(12)
  assert(head and head:sub(1, 4) == 'RIFF' and head:sub(9, 12) == 'WAVE',
         path .. ' is not a WAV file')
  local w = { file = f }
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, size = ch:sub(1, 4), string.unpack('<I4', ch, 5)
    if id == 'fmt ' then
      local fmt = f:read(size)
      w.format, w.channels, w.rate = string.unpack('<I2I2I4', fmt)
      w.bits = string.unpack('<I2', fmt, 15)
      if w.format == 0xFFFE then w.format = string.unpack('<I2', fmt, 25) end
      if size % 2 == 1 then f:read(1) end
    elseif id == 'data' then
      w.data = f:seek()
      w.frames = size // (w.channels * w.bits // 8)
      break
    else
      f:seek('cur', size + size % 2)
    end
  end
  assert(w.data, path .. ' has no audio data')
  w.width = w.bits // 8
  w.block = w.channels * w.width
  if w.format == 3 then
    w.code = w.bits == 64 and '<d' or '<f'
    w.scale = 1
  else
    w.code = '<i' .. w.width
    if w.bits == 8 then w.code = '<I1' end
    w.scale = 1 / (2 ^ (w.bits - 1))
  end
  return w
end

-- Read `count` frames of one channel from a list of files played end to end.
local function session_reader(files, channel)
  return function(start, count)
    local out = {}
    for i = 1, count do out[i] = 0 end
    local base = 0
    for _, w in ipairs(files) do
      local lo = math.max(start, base)
      local hi = math.min(start + count, base + w.frames)
      if lo < hi then
        w.file:seek('set', w.data + (lo - base) * w.block)
        local bytes = w.file:read((hi - lo) * w.block)
        local off = (channel - 1) * w.width + 1
        for n = 0, hi - lo - 1 do
          local v = string.unpack(w.code, bytes, n * w.block + off)
          if w.bits == 8 then v = v - 128 end
          out[lo - start + n + 1] = v * w.scale
        end
      end
      base = base + w.frames
    end
    return out
  end
end

local ref_path, ref_ch, sd_list, sd_ch = arg[1], tonumber(arg[2]), arg[3], tonumber(arg[4])
if not (ref_path and ref_ch and sd_list and sd_ch) then
  io.stderr:write('usage: lua tools/align_wavs.lua REF.wav REF_CHANNEL SD1.wav[,SD2.wav] SD_CHANNEL [SECONDS] [RANGE] [AT]\n')
  os.exit(2)
end
local seconds, range, at = tonumber(arg[5] or 20), tonumber(arg[6] or 60), tonumber(arg[7] or 0)

local ref = open_wav(ref_path)
local sd, total = {}, 0
for p in sd_list:gmatch('[^,]+') do
  local w = open_wav(p)
  assert(w.rate == ref.rate, p .. ' is at a different sample rate from the reference')
  sd[#sd + 1] = w
  total = total + w.frames
end

local rate = ref.rate
local origin = math.floor(at * rate)
local read_ref = session_reader({ ref }, ref_ch)
local read_sd = session_reader(sd, sd_ch)
local res, why = a11y.align({
  ref = function(s, c) return read_ref(origin + s, c) end,
  sig = function(s, c) return read_sd(origin + s, c) end,
  rate = rate,
  ref_len = math.min(math.floor(seconds * rate), ref.frames - origin),
  range = math.floor(range * rate),
  sig_lo = -origin, sig_hi = total - origin,
})
if not res then
  print('no answer: ' .. why)
  os.exit(1)
end
print(string.format('offset %d samples (%s), confidence %s, score %.4f, rival %.4f, coarse %.4f%s',
  res.offset, a11y.offset_phrase(res.offset, rate), res.confidence, res.score,
  res.second, res.coarse, res.inverted and ', polarity inverted' or ''))
