# Notes for Claude Code

This repository is a collection of REAPER ReaScripts for screen reader users.
Read [CONTRIBUTING.md](CONTRIBUTING.md) before writing any Lua here — it has
the script skeleton, the library reference and the style rules. This file is
the short version, plus the things that are easy to get wrong.

**Assume the person you are working for cannot see the screen.** Everyone
involved in this project uses a screen reader. That has consequences for how
you work, not just for what you write:

- Never answer with a screenshot, or with "look at the highlighted line".
- Report results as text that reads well aloud, and say what you verified
  rather than implying it.
- Prefer changes that can be checked from a terminal. If a change can only be
  confirmed by eye, say so plainly instead of claiming it works.

## The two rules

Both are enforced by review, not by a linter. Breaking either makes a script
useless to the people it is for.

1. **Speak the outcome.** Every path through a script ends in speech —
   success, cancellation and failure alike. `a11y.speak` for success,
   `a11y.abort` for anything that stops early. A script that silently succeeds
   leaves the user with no way to know whether it ran.
2. **Never draw a GUI.** REAPER's `gfx` windows and `gfx.showmenu` popups are
   invisible to VoiceOver and NVDA. Only native dialogs: `a11y.prompt`,
   `a11y.pick`, `a11y.confirm`.

## Verifying your work

```bash
lua tools/test_a11y.lua                 # pure logic; no REAPER needed
python3 tools/check_api.py              # every reaper.* name exists (needs REAPER installed)
python3 tools/build_index.py --check    # index.xml still matches the scripts
```

The first and third also run in CI on every pull request, along with a syntax
check of every `.lua` file. `check_api.py` cannot run in CI — it works by
reading the REAPER and OSARA binaries — so run it locally before opening a
pull request.

**None of these test behaviour inside REAPER.** Anything that touches a real
project still needs hand-testing on a scratch project, which you cannot do.
When you finish a script, say exactly what remains to be tested by hand rather
than reporting it as done.

If you add a script, regenerate the index in the same commit:

```bash
python3 tools/build_index.py --url https://github.com/Matthew2244/accessible-reascripts --branch main
```

## Platforms

The collection is developed on macOS with VoiceOver and has a contributor on
Windows with NVDA. Nothing in the scripts is macOS-specific — they get their
paths from `reaper.GetResourcePath()` and join them with `a11y.path_join`, so
keep it that way and never hardcode a path.

Two things to know before touching path handling:

- **Both separators count on Windows.** REAPER returns backslashes, but a
  project can reference media saved with forward slashes. `a11y.basename`
  handles both, and `tools/test_a11y.lua` covers it by swapping
  `package.config` — which means Windows path behaviour is testable from any
  machine. Do that rather than assuming.
- **`check_api.py` does not work on Windows yet.** Its symbol patterns come
  from the macOS build's Itanium C++ mangling; MSVC mangles differently. It
  detects the empty result and refuses to report rather than calling every name
  broken, but a Windows contributor is effectively running two of the three
  checks. Adding a Windows pattern to `names_from_reaper()` is an open job.

## Things that cost an afternoon to rediscover

- **`reaper.osara_outputMessage(const char*)` is real but undocumented.** It is
  a registered ReaScript API and has been for years; it is simply not in
  OSARA's readme. Confirmed by reading the strings in `reaper_osara.dylib`.
- **The binaries carry their own API documentation** — argument types, argument
  names and help text, as NUL-separated strings. Reading them beats the online
  docs, which sit behind a login. CONTRIBUTING.md has the snippet;
  `tools/check_api.py` is built on the same trick. Extensions register names as
  `API_<Name>` and document them as `APIdef_<Name>`.
- **REAPER caches directory listings.** `EnumerateFiles(dir, -1)` forces a
  re-read; without it, a template saved earlier in the session stays invisible
  until REAPER restarts. `a11y.scan_files` already does this.
- **A misspelled `reaper.*` name is not a load error.** Lua evaluates
  `reaper.CountTraks(0)` to `nil` and dies at runtime, in a dialog, halfway
  through an edit. That is what `check_api.py` exists to prevent — run it.
- **Loose search tiers are held in reserve on purpose.** See the tier comment
  in `Lib/a11y.lua`; over 2000 plugin names a bare subsequence search for
  `ssl` matches 472 of them. Do not "fix" this by always enabling them.

## Do not reimplement REAPER or SWS

Check the action list first. Where a native action already does the work but
does not say what happened, the useful contribution is a small script that
speaks the result and can be chained after it in a custom action — not a
reimplementation. `Speak project summary` after `File: Save new version of
project` is the pattern.

## Writing spoken text

Spoken messages are prose, not log lines: "Inserted piano 1. Track 4, UADx
Ravel Grand Piano." Avoid abbreviations a screen reader will mangle, and never
write `track(s)` — it is read aloud as "track parenthesis s". `a11y.plural`
exists for exactly this.
