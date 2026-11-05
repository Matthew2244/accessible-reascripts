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
project still needs testing on a scratch project. When you finish a script,
say exactly what was tested and what remains to be tested by hand rather
than reporting it as done.

**Testing inside REAPER is possible, and was done for 1.3.0 to 1.3.2.** The
pattern: run REAPER with its own throwaway config (`REAPER -cfgfile
<scratch>/reaper.ini`, so the resource folder is the scratch folder and
nobody's real settings or projects are touched), then drive it with
`open -a REAPER test.lua`. A test script can replace `reaper.GetUserInputs`,
`reaper.ShowMessageBox`, `reaper.osara_outputMessage` and
`reaper.get_action_context` before `dofile`-ing a real script, which answers
its dialogs and records what it says. Render with `RENDER_*` project settings
and action 42230 to check audio. For a screen reader pass, link OSARA into the
scratch config's `UserPlugins`, launch REAPER with `open -a` (VoiceOver did
not follow a REAPER started straight from the binary), and poll
`tell application "VoiceOver" to get content of last phrase` with timestamps:
a phrase replaced within a fraction of a second was cut off.

Facts measured in REAPER 7.82 that are easy to get wrong:

- `GetMediaItemTake_Peaks` takes a **project** time, not a source time. An
  item at 30 seconds with a sound one second in reads that sound at 31.
  Three listening scripts passed the take offset instead until 1.3.0, so
  they read the wrong stretch of any item not at position 0.
- A **take** envelope's point times count from the item's start, in the
  take's own time, so at playback rate 2 they are doubled.
  `a11y.envelope_time` converts. `GetTrackSendName` counts hardware outputs
  before sends; use `P_DESTTRACK` instead.
- `D_FADEINLEN_AUTO` reads 0 on an ordinary item, meaning no automatic fade,
  and 0 is also how you clear one. Not -1.
- A pan envelope stores left as positive: +1 renders on the left only, and
  REAPER shows it as 100%L. That is the opposite of the track's `D_PAN`.
- Under VoiceOver, a message spoken just before a dialog opens is cut off by
  the dialog's announcement, and one spoken as a dialog closes is cut off by
  the main window's. That is why `a11y.pick` puts its list in the field label
  and `a11y.speak` waits after a dialog. Escape does nothing in a Yes/No
  message box on macOS; `a11y.confirm` uses Yes/No/Cancel.

If you add a script, regenerate the index in the same commit:

```bash
python3 tools/build_index.py --url https://github.com/Matthew2244/accessible-reascripts
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

## Maintainer notes

**The repo is public** (since 2026-11-04). ReaPack reads `index.xml` from
`raw/main/`, and each file in it points at the release tag `v<VERSION>`, so
a version's files never change after it ships. Push the tag with the
commit, or ReaPack gets "not found" for the files. Verified before the repo
was opened up: the git history
has only ever contained the files currently tracked, and
`tools/fixtures/track_templates.txt` — which holds real client and
collaborator names — has never been committed on any branch. Re-run that check
before publishing anything else:

```bash
git log --all --pretty=format: --name-only --diff-filter=A | sort -u
```

**Adding a script means regenerating the index in the same commit.**
`build_index.py --check` runs in CI and will catch it, but catching it locally
is faster:

```bash
python3 tools/build_index.py --url https://github.com/Matthew2244/accessible-reascripts
```

**Bump `@version` when a script's behaviour changes**, and `a11y.VERSION` when
the library's does. **And raise `VERSION` at the repo root for every
release.** That file is the package version ReaPack sees. It used to be the
highest `@version` of any script, so adding a script at 1.0.0, or fixing one
below the top version, shipped nothing: seven scripts sat unreleased at
1.2.1 that way. CONTRIBUTING.md has the release steps.

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
