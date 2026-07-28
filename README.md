# Accessible ReaScripts

Scripts that make REAPER faster to use with a screen reader.

Every script here speaks its result out loud through OSARA, and none of them
draw their own windows — REAPER's `gfx` windows are invisible to VoiceOver and
NVDA, so this collection only ever uses native dialogs that screen readers
already read correctly.

Built and tested on macOS with VoiceOver, and used on Windows with NVDA.
Nothing in it is macOS-specific: paths come from REAPER itself rather than
being hardcoded, and the path handling is tested against both separators.

## Requirements

- REAPER 6.44 or newer (developed against 7.78)
- [OSARA](https://osara.reaperaccessibility.com/) — required, this is what
  does the speaking
- [SWS](https://www.sws-extension.org/) — not required, but recommended
- [ReaPack](https://reapack.com/) — optional, only for installing via the
  package manager

The quickest way to get all of these at once is
[RABBIT](https://github.com/Timtam/rabbit), which installs REAPER, OSARA, SWS,
ReaPack and ReaKontrol in one go.

## The scripts

### Insert track template by name

Type part of a track template's name and insert it, instead of arrowing
through the Track Templates submenu. If you have 170 templates, this is the
difference between two keystrokes and two minutes.

Search is forgiving. All of these find `keyscape rhodes suitcase`:

- `keyscape rhodes suitcase` — the whole name
- `rhodes suit` — several words, in any order
- `suitcase` — a word from the middle
- `krs` — the first letter of each word

An exact name always wins, so searching `piano 1` inserts `piano 1` and not
`piano 1 gospel`.

When more than one template matches, the matches are spoken as a numbered
list and you type the number you want. The newly inserted tracks are left
selected, so whatever you do next lands on them. The whole insert is one undo
step.

### Add FX by name

The same idea, for plugins. Type part of a plugin's name and add it to every
selected track, instead of hunting through the FX browser.

Plugin names include their format, so you can narrow by typing it:

- `proq` finds every Pro-Q, in every format
- `vst3 proq` finds only the VST3
- `js loudness` finds only JSFX

A plugin installed in more than one format appears once per format, so you
choose deliberately rather than letting REAPER pick for you.

It adds a new instance at the end of each selected track's chain, even if the
same plugin is already there. One undo step for all tracks.

Pairs well with OSARA's "View FX parameters for current track" in a custom
action, if you want to start editing immediately after adding.

### Go to marker or region by name

Jump straight to a marker or region by typing part of its name, rather than
stepping through them one at a time. You can also just type a marker's number.

Choosing a region sets the time selection to that region as well as moving the
edit cursor, so you can play or render it immediately. Markers only move the
cursor.

### Speak project summary

One keystroke, and you hear: project name and version, whether there are
unsaved changes, tempo and time signature at the cursor, project length, track
and item counts, how many markers and regions, and — the part that is genuinely
hard to notice by ear — how many items point at media files that are missing
from disk.

This script only reads. It changes nothing.

It is useful in a custom action straight after
`File: Save new version of project`, so you hear which version you just landed
on.

### Rename selected tracks

Rename every selected track from one dialog, instead of confirming a separate
dialog per track. Put `#` where the number should go:

- `Vox #` produces Vox 1, Vox 2, Vox 3
- `Tom ##` produces Tom 01, Tom 02 — `##` pads to two digits
- `Kick` produces Kick 1, Kick 2 — `#` is added automatically when you are
  renaming several tracks
- `Kick` stays Kick when only one track is selected

Numbering follows track order, not the order you selected them. One undo step
for the whole rename.

### Automate plugin parameter by name

Type part of a parameter's name and get an envelope for it, ready to edit.
Searches every parameter of every plugin on the selected track, plus the
track's own volume, pan, width and mute.

Exposing a plugin parameter for automation normally means opening the FX
parameters dialog, scrolling until you find the parameter, nudging it so it
becomes the "last touched" one, closing the dialog, pressing the
show-envelope-for-last-touched-parameter action, then cycling envelopes until
you land on the right one. REAPER has `GetFXEnvelope`, which creates the
envelope directly from an index, so none of that is necessary.

The envelope is created if it does not exist, made visible, and selected, so
OSARA's envelope point navigation acts on it straight away.

### Ramp envelope over time selection

Ramp the selected envelope from one value to another across the time
selection: a fade, a filter sweep, a level move under a voiceover. Both values
and the curve are asked for in one dialog, prefilled with what the envelope is
doing now, so leaving a field alone changes nothing.

Values are typed in the units you think in — decibels for volume, percent for
pan, width and plugin parameters, 0 or 1 for mute. Curve shapes are words
rather than numbers: `linear`, `slow`, `fast start`, `fast end`, `square`,
`bezier`.

It pins the value immediately before the time selection. Without that, REAPER
interpolates the new ramp all the way back to the point it adds automatically
at the start of the project, so the value drifts across everything before the
span you chose. Pinning keeps each ramp local, which means you can run this
over one span after another to build up a shape.

### Speak automation state

One spoken sentence describing the automation you are sitting in: the track and
envelope, the track's automation mode, whether the envelope is armed and
visible, how many points it has, the value under the edit cursor, how far the
nearest points are on either side, and whether there is a time selection ready
to ramp across.

This script only reads. It changes nothing.

## Installing

This repository is **private**, so install it by cloning. ReaPack cannot be
used while it stays private: ReaPack fetches the index over a plain HTTPS
request with no way to send a GitHub token, so a private repository just
returns "not found" to it.

An `index.xml` is generated and committed anyway, so if the repository is ever
made public, ReaPack works immediately with no further setup.

### Clone and link

You need access to the repository — ask Matthew for an invite — and a GitHub
account with `gh` or an SSH key set up.

Clone it, then point REAPER at it with a symbolic link, so edits are live
without copying files around each time:

```bash
git clone https://github.com/Matthew2244/accessible-reascripts.git ~/accessible-reascripts
ln -s ~/accessible-reascripts "$HOME/Library/Application Support/REAPER/Scripts/accessible-reascripts"
```

On Windows the Scripts folder is under `%APPDATA%\REAPER\Scripts`, and you can
make the link with:

```
mklink /D "%APPDATA%\REAPER\Scripts\accessible-reascripts" "%USERPROFILE%\accessible-reascripts"
```

Update later with `git pull` in that folder. Nothing needs reinstalling; the
symbolic link means REAPER is already reading the new files.

### If it is ever made public

Regenerate the index and push it:

```bash
python3 tools/build_index.py --url https://github.com/Matthew2244/accessible-reascripts --branch main
```

Then anyone can add it in REAPER under Extensions, ReaPack, Import
repositories, using:

`https://github.com/Matthew2244/accessible-reascripts/raw/main/index.xml`

Keep the `Lib` folder next to the script folders. Every script loads
`Lib/a11y.lua` from one level up, and will say so out loud if it cannot find
it.

## Loading the scripts and assigning shortcuts

REAPER does not pick up script files on its own — each one has to be added to
the action list once:

1. Press the key for Actions, show action list.
2. Choose New action, then Load ReaScript.
3. Select the `.lua` files you want. You can select several at once.
4. Find the action in the list, choose Add, and press the shortcut you want.

Shortcuts are personal, so this collection deliberately does not ship any.
Worth knowing: OSARA's own key map already claims a lot of combinations, so
check a shortcut is free before committing to it.

These scripts are also designed to be chained. `Speak project summary` after
`File: Save new version of project` in a single custom action is a good
example — REAPER does the work, the script tells you what happened.

## Development

Three checks, all runnable from a terminal without opening REAPER:

```bash
lua tools/test_a11y.lua && python3 tools/check_api.py && python3 tools/build_index.py --check
```

`test_a11y.lua` covers the pure logic — search ranking, numbering patterns,
spoken phrasing. `check_api.py` reads the REAPER and extension binaries and
verifies that every `reaper.*` name used in the repo actually exists, which
catches the misspellings that otherwise only surface as a runtime error
mid-edit. `build_index.py --check` confirms `index.xml` still lists every
script, which is the easiest thing to forget when adding one and impossible to
notice by ear.

GitHub Actions runs the first and last of those on every push and pull request,
plus a compile check of every `.lua` file. It cannot run `check_api.py` —
that one needs REAPER installed — so run it yourself before opening a pull
request. Nothing automated tests behaviour inside REAPER; that still takes a
scratch project.

`check_api.py` currently needs macOS or Linux: it reads the API names out of
the REAPER binary with symbol patterns from a clang build, and the MSVC-built
`reaper.exe` mangles them differently. On Windows it says so and stops, rather
than reporting every name as broken. See CONTRIBUTING.md.

See [CONTRIBUTING.md](CONTRIBUTING.md) before adding a script.

## Licence

MIT. See [LICENSE](LICENSE).
