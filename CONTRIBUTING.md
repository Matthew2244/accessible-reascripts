# Contributing

Contributions are welcome, including from people using an AI assistant to
write them. This document is written to be complete enough that an assistant
can extend the project correctly from this file alone, without having seen the
conversation that started it.

There is also a [CLAUDE.md](CLAUDE.md) at the repository root, which Claude
Code picks up on its own when you open the repo. It is the short version: the
two rules, the commands that verify a change, and the handful of facts that
cost an afternoon each to rediscover. This file remains the reference.

## Sending a change

You do not need permission to start, and you do not need to be invited. Open an
issue first only if you want to know whether an idea is wanted before spending
time on it. For a fix, just send it.

If you have push access, branch from `main`. Otherwise fork, which is the
normal route:

```bash
gh repo fork Matthew2244/accessible-reascripts --clone
cd accessible-reascripts
git checkout -b my-change

# work, then run the checks:
lua tools/test_a11y.lua && python3 tools/check_api.py && python3 tools/build_index.py --check

git commit -am "Short summary of what changed"
gh pr create --fill
```

CI runs on every pull request, forks included, so you get the compile check,
the library tests and the index check without anyone having to run them for
you. `check_api.py` is the one CI cannot do; run it locally.

Small pull requests get read faster than large ones, and one script per pull
request is easier to test by ear than three.

## The two rules

Everything else is a preference. These two are not.

**1. Speak the outcome.** A script that silently succeeds leaves a screen
reader user guessing whether it ran. Every path through a script ends in
speech: success, cancellation, and failure. Use `a11y.speak` for success and
`a11y.abort` for anything that stops early.

**2. Never draw your own GUI.** REAPER's `gfx` windows are not exposed to
VoiceOver or NVDA. Neither are `gfx.showmenu` popups. Only use native dialogs:
`reaper.GetUserInputs` and `reaper.ShowMessageBox`, both wrapped in
`Lib/a11y.lua` as `a11y.prompt`, `a11y.pick` and `a11y.confirm`.

If you need the user to choose from a list, use `a11y.pick`. It speaks a
numbered list and asks for a number. This is deliberately not a popup menu.

## Some further guidance

**Do not reimplement what REAPER or SWS already does.** Check the action list
first. REAPER has a native `File: Save new version of project`, and SWS has
`Xenakios/SWS: Rename selected tracks`. Where a native action already does the
work but does not say what happened, the useful contribution is a small script
that speaks the result, which the user can chain after it in a custom action,
not a reimplementation.

**Say when something failed.** If an operation did not do what it claimed,
say so plainly and include enough detail to report it as a bug. Never speak a
success message you have not verified. `a11y_Insert track template by name.lua`
counts tracks before and after and refuses to claim success if nothing changed;
copy that habit.

**Wrap edits in one undo block.** `reaper.Undo_BeginBlock()` and
`reaper.Undo_EndBlock(description, -1)`. One keystroke should be one undo.

**Prefer letting REAPER do the work.** For example, track templates are
inserted with `reaper.Main_openProject`, because REAPER's own loader handles
track GUIDs, folder depth, routing and envelopes. Reconstructing that by
editing state chunks looks tempting and breaks on any template containing
sends.

## Adding a script

Scripts live in a folder named for their category: `Tracks`, `Project`,
`Navigation`, `Envelopes`, `Items`, `Media`. Add a folder if none fits;
`tools/build_index.py` and the "What would you like to do" menu both discover
category folders from disk, so a new folder needs no registration anywhere.
(The list used to be hardcoded in `build_index.py`, which silently dropped
new folders from the ReaPack index while `--check` reported everything up to
date; two people hit that independently before it was fixed.) File names
start with `a11y_` and describe the action in plain words.

Start from this skeleton:

```lua
--[[
  @description What it does (accessible)
  @author Accessible ReaScripts contributors
  @version 1.0.0
  @provides [main] .
  @about
    A few lines a stranger can read to decide whether they want this.
    Say what it changes, and what it leaves alone.
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

local function main()
  -- Work here. Call a11y.abort('...') to stop with a spoken reason.
  a11y.speak('Done.')
end

a11y.run(main)
```

`a11y.run` exists so `a11y.abort` can stop a script from anywhere without the
error surfacing as a crash. Real errors are still re-raised, so genuine bugs
appear in the ReaScript console rather than vanishing.

## What is in the library

`Lib/a11y.lua`, all documented inline:

- Speech: `speak`, `abort`, `run`, `has_osara`
- Text: `plural`, `list_phrase`, `duration_phrase`, `number_pattern`
- Matching: `score`, `filter`
- Dialogs: `prompt`, `pick`, `confirm`
- Files: `sep`, `path_join`, `basename`, `scan_files`
- Persistence between runs: `remember`, `recall`

Put reusable pure logic in the library rather than in a script, so it can be
tested without REAPER.

## Testing

```bash
lua tools/test_a11y.lua && python3 tools/check_api.py && python3 tools/build_index.py --check
```

All three run in a terminal with REAPER closed.

GitHub Actions runs the first and third on every pull request, along with a
compile check of every `.lua` file, since the test suite only loads
`Lib/a11y.lua`, so without that a syntax error in a script would stay hidden
until someone pressed the shortcut and heard nothing. `check_api.py` is not in
CI, because it works by reading the REAPER and OSARA binaries and neither can
be installed on a runner. Run it locally.

`tools/test_a11y.lua` tests the library's pure logic against a stubbed
`reaper` table. Search ranking is the part most worth testing: a search that
puts the wrong template first is worse than no search, because you insert
eighteen tracks of a big band before you notice. Add a case for any ranking
behaviour you rely on.

By default the ranking tests run against a small built-in sample of template
names. To exercise them against your own collection instead, dump it into a fixture. That is a
much better test, because real names are messier:

On macOS:

```bash
mkdir -p tools/fixtures
ls "$HOME/Library/Application Support/REAPER/TrackTemplates"/*.RTrackTemplate \
  | sed 's|.*/||; s|\.RTrackTemplate$||' > tools/fixtures/track_templates.txt
```

On Windows, in PowerShell:

```powershell
New-Item -ItemType Directory -Force tools\fixtures | Out-Null
Get-ChildItem "$env:APPDATA\REAPER\TrackTemplates" -Recurse -Filter *.RTrackTemplate |
  ForEach-Object { $_.BaseName } |
  Set-Content -Encoding utf8 tools\fixtures\track_templates.txt
```

That file is git-ignored. Template names tend to include collaborators' and
clients' names, so it stays on your machine.

**`check_api.py` does not work on Windows yet.** It reads the API names out of
the REAPER binary using symbol patterns taken from the macOS build, where clang
uses Itanium C++ mangling. MSVC mangles differently, so the extraction comes up
empty there. Rather than then declaring every name in the repo broken, it
refuses to report at all and says so, but it does mean a Windows contributor
is running two of the three checks, and the missing one is the misspelling
catch. Adding a Windows pattern to `names_from_reaper()` is an open job and a
genuinely useful contribution. Extension names are unaffected either way:
extensions register `API_<Name>` as plain strings, which is platform
independent.

`tools/check_api.py` verifies every `reaper.*` name in the repo really exists.
It reads the names REAPER and the installed extensions register, so it catches
misspellings, which are otherwise nasty: Lua evaluates `reaper.CountTraks(0)`
to `nil` and then dies at runtime, in a dialog, halfway through an edit.

Anything that touches a real project still needs testing by hand in REAPER,
with a scratch project. Say in your pull request what you tested and on which
REAPER version. The pull request template asks for exactly this, because it
is the one thing a reviewer cannot find out any other way.

If you add a script, regenerate the ReaPack index in the same commit:

```bash
python3 tools/build_index.py --url https://github.com/Matthew2244/accessible-reascripts --branch main
```

## Finding out what an API actually does

REAPER's own documentation is not always to hand, and the online copies are
sometimes behind a login. The binaries carry their own documentation, and you
can read it:

```bash
python3 - <<'PY'
import os, platform
BINARY = {
    'Darwin':  '/Applications/REAPER.app/Contents/MacOS/REAPER',
    'Windows': r'C:\Program Files\REAPER (x64)\reaper.exe',
    'Linux':   '/opt/REAPER/reaper',
}[platform.system()]
data = open(BINARY, 'rb').read()
toks = [t.decode('utf-8', 'replace') for t in data.split(b'\x00')]
for i, t in enumerate(toks):
    if t == 'Main_openProject':
        print([x for x in toks[i:i+4] if 0 < len(x) < 500])
        break
PY
```

This one is plain string matching, so it works on every platform.

That prints the argument types, the argument names and the help text for the
function. It is how the track template script was written, and how the
`osara_outputMessage` signature was confirmed: OSARA registers it for
ReaScript but does not mention it in its readme.

The same trick works on extensions; they register names as `API_<Name>` and
document them as `APIdef_<Name>`.

## Style

Match the surrounding code. Two-space indent, `snake_case` for locals,
single quotes for Lua strings. Comments explain why something is done, not
what the line says, particularly where the obvious approach is wrong, since
that is what saves the next person an afternoon.

Write for the ear. Spoken messages are prose, not log lines: "Inserted piano
1. Track 4, UADx Ravel Grand Piano." Avoid abbreviations a screen reader will
mangle, and avoid `track(s)`, which is read aloud as "track parenthesis s";
`a11y.plural` exists for this.
