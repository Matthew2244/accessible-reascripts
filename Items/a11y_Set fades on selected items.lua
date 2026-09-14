--[[
  @description Set fades on selected items (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    Set the fade in and fade out of every selected item to an exact length,
    typed in seconds, from one dialog. Dragging a fade handle by ear works;
    typing 0.02 is faster and lands the same on all forty layers of a scene.

    Leave a field blank to leave that fade alone, so you can set every fade
    out without touching the fade ins. Fade shapes are not changed.

    One undo step for the whole edit.
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

--- Parse one dialog field. Blank means "leave alone"; anything else must
--- be a non-negative number of seconds.
-- @return number|nil seconds, string|nil error
local function parse_seconds(text, label)
  text = (text or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' then return nil, nil end
  local n = tonumber(text)
  if not n or n < 0 then
    return nil, string.format('%s is not a length in seconds for the %s. Nothing changed.',
                              text, label)
  end
  return n, nil
end

local function main()
  local count = reaper.CountSelectedMediaItems(0)
  if count == 0 then
    a11y.abort('No items selected.')
  end

  local ok, answer = reaper.GetUserInputs(
    'Set fades', 2,
    'Fade in seconds (blank keeps),Fade out seconds (blank keeps),extrawidth=60',
    ',')
  if not ok then
    a11y.abort('Cancelled. Nothing changed.')
  end

  local in_text, out_text = answer:match('^(.-),(.-)$')
  local fadein, err_in = parse_seconds(in_text, 'fade in')
  if err_in then a11y.abort(err_in) end
  local fadeout, err_out = parse_seconds(out_text, 'fade out')
  if err_out then a11y.abort(err_out) end

  if fadein == nil and fadeout == nil then
    a11y.abort('Both fields were blank, so there was nothing to change.')
  end

  reaper.Undo_BeginBlock()
  local clipped = 0
  for i = 0, count - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    -- A fade longer than the item would be silently shortened by Reaper;
    -- shorten it deliberately and count the item, so the summary can say
    -- it happened instead of hiding it.
    local item_clipped = false
    if fadein ~= nil then
      if fadein > len then item_clipped = true end
      reaper.SetMediaItemInfo_Value(item, 'D_FADEINLEN', math.min(fadein, len))
    end
    if fadeout ~= nil then
      if fadeout > len then item_clipped = true end
      reaper.SetMediaItemInfo_Value(item, 'D_FADEOUTLEN', math.min(fadeout, len))
    end
    if item_clipped then clipped = clipped + 1 end
  end
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Set fades on selected items', -1)

  local parts = {}
  if fadein ~= nil then
    parts[#parts + 1] = string.format('fade in %g seconds', fadein)
  end
  if fadeout ~= nil then
    parts[#parts + 1] = string.format('fade out %g seconds', fadeout)
  end
  local msg = string.format('Set %s on %s.', a11y.list_phrase(parts),
                            a11y.plural(count, 'item'))
  if clipped > 0 then
    msg = msg .. string.format(
      ' %s shorter than the fade, so the fade was shortened to fit there.',
      a11y.plural(clipped, 'item was', 'items were'))
  end
  a11y.speak(msg)
end

a11y.run(main)
