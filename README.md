# Accessible ReaScripts

Scripts that make REAPER faster to use with a screen reader.

Every script here speaks its result out loud through OSARA, and none of them
draw their own windows. REAPER's `gfx` windows are invisible to VoiceOver and
NVDA, so this collection only ever uses native dialogs that screen readers
already read correctly.

Built and tested on macOS with VoiceOver, and used on Windows with NVDA.
Nothing in it is macOS-specific: paths come from REAPER itself rather than
being hardcoded, and the path handling is tested against both separators.

## Requirements

- REAPER 6.44 or newer (developed against 7.78)
- [OSARA](https://osara.reaperaccessibility.com/) is required. It does the
  speaking.
- [SWS](https://www.sws-extension.org/) is recommended, not required.
- [ReaPack](https://reapack.com/) is optional, only for installing via the
  package manager.

The quickest way to get all of these at once is
[RABBIT](https://github.com/Timtam/rabbit), which installs REAPER, OSARA, SWS,
ReaPack and ReaKontrol in one go.

## The scripts

### What would you like to do (the menu)

The front door to everything else. Bind this one script to one keystroke and
forget every other shortcut: it asks what you would like to do, finds the
script that does it, and runs it. That script then asks its own questions,
exactly as if you had run it directly.

Type a few words of what you want ("fades", "reverb bus", "insert a sound")
and the matches come back as a numbered list. A script can be found by
anything its documentation says as well as its name, so "reverb" finds the
send bus script. Clear the box to browse instead: first the categories, then
the scripts in the one you pick, so nothing is ever more than two short lists
away.

It also remembers you, across restarts. The box comes prefilled with your
last search, so running the same tool again is two presses of Enter, and the
last three scripts you ran sit at the top of browsing as a Recent group.
Scripts whose names match what you typed come first, then scripts that only
mention it.

The menu discovers scripts from the folders on disk, so anything added to
the collection later shows up in it automatically.

### Insert track template by name

Type part of a track template's name and insert it, instead of arrowing
through the Track Templates submenu. If you have 170 templates, this is the
difference between two keystrokes and two minutes.

Search is forgiving. All of these find `keyscape rhodes suitcase`:

- `keyscape rhodes suitcase`, the whole name
- `rhodes suit`, several words, in any order
- `suitcase`, a word from the middle
- `krs`, the first letter of each word

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

### Speak FX chain

One keystroke and you hear what is actually on the selected track: every
plugin in order, with its position, and whether it is bypassed or offline.
Order is spoken because it matters. A compressor before a reverb is a
different sound from one after it.

It also tells you when the whole chain is switched off at the track, which is
worth hearing first: every plugin can report as enabled while the entire chain
is bypassed, and the track then sounds dry for no reason you can find.

Pairs with `Add FX by name`: add a plugin, then check where it landed.

This script only reads. It changes nothing.

### Build vinyl or cassette chain

Builds a lo-fi playback chain on every selected track, in one action and in
the right order:

- **Vinyl**: Elliptical, Acceleration2, GrooveWear, Vinyl Noise
- **Cassette**: Dubly3, CHOWTapeModel, Vinyl Noise set for tape hiss
- **Noise only**: Vinyl Noise on its own

The three Airwindows steps all come out of Airwindows Consolidated, which is
one plugin holding every Airwindows algorithm behind a selector. A chain of
them is unreadable by ear, three slots all announcing the same name, so each
instance is renamed to the algorithm it is meant to be running, and the
script sweeps the selector to set it. If it cannot confirm the selection it
says which slots you still have to set by hand, rather than leaving one
quietly running the wrong algorithm.

A plugin that is not installed is skipped and named in the summary instead of
stopping the chain, so Vinyl still builds without Airwindows and Cassette
still builds without ChowTape.

Vinyl Noise is a JSFX crackle, pops, hiss, rumble and hum generator. It is
not part of this repository, it lives in your own `Effects` folder, and the
script only sets its controls when it finds it.

### Go to track by name

Jump to a track by typing part of its name, instead of arrowing through the
track list. In a forty-track session that is two keystrokes instead of a lot
of counting. You can also just type a track number.

Typing a number puts that track first, so `3` finds track 3 rather than
tracks 30 to 39. The chosen track becomes the only selected track, so
whatever you do next lands on it, and only on it.

### Go to marker or region by name

Jump straight to a marker or region by typing part of its name, rather than
stepping through them one at a time. You can also just type a marker's number.

Choosing a region sets the time selection to that region as well as moving the
edit cursor, so you can play or render it immediately. Markers only move the
cursor.

### Speak what is sounding here

What is actually under the edit cursor, right now, on every track at once.
For each track with something at the cursor you hear the track, the item,
how far into it you are and how much of it is left. Muted tracks and muted
items are named as muted rather than left out, because "nothing here" and
"here but silent" are different problems.

This script only reads. It changes nothing.

### Speak project summary

One keystroke, and you hear: project name and version, whether there are
unsaved changes, tempo and time signature at the cursor, project length, track
and item counts, how many markers and regions, and the part that is genuinely
hard to notice by ear: how many items point at media files that are missing
from disk.

This script only reads. It changes nothing.

It is useful in a custom action straight after
`File: Save new version of project`, so you hear which version you just landed
on.

### Where does this project really end

Finds the last moment anything is actually audible, and compares it with
where the project stops and where a render would stop. If those disagree
you are about to bounce dead air onto the end of your piece. Render bounds
set to a fixed range or to the time selection are checked, render tail
included.

It reads the items' own audio, so a tail made only by a reverb plugin is not
counted, and it says so. Muted items and items on muted tracks are left out,
because they are not in a render.

This script only reads. It changes nothing.

### Rename selected tracks

Rename every selected track from one dialog, instead of confirming a separate
dialog per track. Put `#` where the number should go:

- `Vox #` produces Vox 1, Vox 2, Vox 3
- `Tom ##` produces Tom 01, Tom 02, since `##` pads to two digits
- `Kick` produces Kick 1, Kick 2, because `#` is added automatically when you
  are renaming several tracks
- `Kick` stays Kick when only one track is selected

Numbering follows track order, not the order you selected them. One undo step
for the whole rename.

### Speak routing

One keystroke and you hear where the selected track's audio actually goes:
whether it feeds the master or a folder parent, every send with its
destination, level and pre or post position, every receive with where it
comes from, and whether hardware outputs are assigned.

A track that sounds wrong is very often a track routed wrong: a send left
muted, a master send switched off, a receive you forgot existed. A main send
that is off is announced early and loudly, because that is the classic
silent-track mystery.

This script only reads. It changes nothing.

### Create send bus from selected tracks

Make a new bus and send every selected track to it, in one move: type a
name, and the bus appears at the end of the project with a post-fader send
from each selected track at 0 dB, whatever your send defaults say. The classic use is a shared reverb or a
scene-wide effect. Select the twelve layers of a scene, run this once, and
put the reverb on the bus it made.

The tracks' own routing to the master is untouched; this adds sends, it does
not move anything. The new bus ends up as the only selected track, so the
next thing you do, adding the reverb, lands on it. One undo step.

### Speak selected items

Hear what is actually selected: each item's name, the track it sits on,
where it starts, how long it is, its fades, and anything on the active take
that changes the sound: pitch shift, playback rate, reverse, a mute, and
which take is active when there is more than one.

Built for layered sound design, where six items stacked across six tracks
are one sound and you want to audit the whole stack by ear without arrowing
through it item by item.

This script only reads. It changes nothing.

### Set fades on selected items

Set the fade in and fade out of every selected item to an exact length,
typed in seconds, from one dialog. Dragging a fade handle by ear works;
typing `0.02` is faster and lands the same on all forty layers of a scene.

Leave a field blank to leave that fade alone, so you can set every fade out
without touching the fade ins. A fade longer than an item is shortened to
fit, and the summary says on how many items that happened. Where REAPER made
an automatic crossfade, the length you type replaces it, so the fade you set
is the one you hear. Fade shapes are not changed. One undo step.

### Make variations of selected items

Turn one sound into a family of near copies. Each selected item gets a row
of duplicates laid out after it on the same track, every copy nudged in
pitch and, if you want, in time. Play the row and pick the one that sits
right, or keep several and layer them.

This is the oldest trick in sound design. A door slam repeated verbatim
sounds like a machine, and the same slam a quarter of a semitone off sounds
like a second take. Doing it by hand means duplicate, nudge, open pitch,
type a number, and again for every copy. This does the whole family in one
pass.

You choose how many copies, how far the pitch may wander in either
direction, how much timing jitter to add, and the gap between copies. Pitch
changes use REAPER's ordinary take pitch, so length is preserved and
everything else about the item, fades and take FX included, comes along
into each copy.

The copies end up selected, so the next thing you do, like setting fades on
the whole family, lands on them and not the original. The original is never
changed. One undo step.

### Shift the pitch of one note

Fix one sung or played note that's out of tune, smoothly, without touching
the notes around it. Put the time selection over the note, on the selected
item or the selected track, and run this. It asks how many semitones to move
it and how long the glide into and out of the new pitch should be. Minus 1
lowers it a half step. 0.5 raises it a quarter tone. The glide starts at 30
milliseconds.

The item is split so the note gets a short piece of its own, with about 60
milliseconds to spare either side, and the pieces overlap by 20
milliseconds with fades, so the joins are crossfades rather than cuts. Only that piece gets a take pitch envelope. It sits at 0 at both
edges, glides to the new pitch by the time the note starts, holds it, and
glides back to 0 just after the note ends. The crossfades sit where the
pitch is untouched.

If the take already has a pitch envelope, the shift is added on top, so you
can run it again on the same note to move it further. An item that already
plays at another rate, or already has its take pitch set, is going through
the pitch shifter anyway, so it isn't split; the envelope goes on the whole
item instead. MIDI items are refused. The note's piece ends up selected. One
undo step.

### Ripple cut with crossfades

Takes the time selection out of the selected tracks, or every track if none
is selected, closes the gap, and crossfades every join it made, at a length
you type. A butt splice in the middle of an ambience bed is audible even when
the waveform looks innocent.

Where a take has audio before its start it gets a true overlapping
crossfade. Where it doesn't, it gets matched fades, and the summary says how
many of each. If there wasn't enough audio for the whole length you asked
for, it says the shortest it managed. Only items move. Envelopes, markers,
regions and tempo stay put, so automation after the cut sits later than the
audio it belonged to. One undo step.

### Find edges that could click

Walks every item in the project and finds the edges with no real fade and
audio sitting right on them. Those are the ones that tick. It speaks them
loudest first, with the track, the time and the level at the edge, then
offers to lengthen those fades in one undo step.

Items that butt exactly end to start are reported separately: lengthening
their fades only widens the dip, and the fix is to overlap them, which it
leaves to you. Edges that already crossfade are skipped. It reads each
item's own audio, not the mix.

### Find the loud bits

Asks for a level, minus 1 dB unless you change it, then speaks every moment
in the selected items that goes over it, with the time and how loud it got,
loudest first. It reads each item's own audio, so if nothing here is over
the line but your master is clipping, the level is being added further down
the chain.

This script only reads. It changes nothing.

### Speak where the sound is

Walks the selected item's audio and tells you where the sound actually
lives: each stretch of sound with its peak, and how long the quiet is
between them, counted from the start of the item. This is how you find the
chime buried at the head of a file, or notice that a stem called "train" is
thirty seconds of nothing followed by a door.

This script only reads. It changes nothing.

### Line up WING-LIVE recordings

When a console records to its own card while REAPER records over USB, you
end up with two copies of the same performance that started a few seconds
apart. This finds that gap by listening to a signal both recordings caught,
such as the kick drum, and moves the console's files into place to the
sample.

Select the console items you want moved and one item REAPER recorded. The
console items can be the multichannel chunk files straight off the card or
the mono files split from them. The script asks which item is the REAPER
one, which console item has the same signal and on which channel, and how
many seconds either way to search (60 unless you change it). Every selected
item except the REAPER one moves by the same amount, so chunks that sit end
to end stay that way.

It works for any two recordings that ran off the same clock. If they did
not, the start will line up and the end will drift, and this is the wrong
tool.

If it can't find a clear match it says so and moves nothing. That includes
music that repeats so exactly that two offsets fit equally well. A busier
shared signal, like overheads or a vocal, usually solves it. One undo step.

### Ramp last touched parameter

Write a rise or fall on whatever FX parameter you touched last, without
placing a single envelope point by hand. A filter opening over eight
seconds, a reverb swelling into a scene change, a send dying away.

Touch the parameter (OSARA's FX parameters dialog counts), select the time
the ramp should cover, run the script, and type where the ramp starts and
ends as percentages of the parameter's range. The start is prefilled with
where the parameter is now. With no time selection, the ramp runs from the
edit cursor for however many seconds you type. Curves are words rather than
numbers: `linear`, `slow`, `fast start`, `fast end`, `square`, `bezier`.

The ramp replaces any envelope points already inside that stretch of time,
the value just before it is pinned so nothing earlier bends, and the
parameter holds its ending value afterwards. When playback is stopped, the
confirmation also speaks the plugin's own units, so you hear "230 Hz" as
well as the percentage, and the envelope is left selected for OSARA's point
navigation.

This is the sibling of `Ramp envelope over time selection`: that one ramps
whichever envelope is selected and covers track volume, pan, width and mute;
this one is the shortcut for a parameter your hands are already on.

### Insert sound by name

Type part of a sound's name and insert it from your sample library onto the
selected track at the edit cursor, without walking the Media Explorer's
folder tree to get there. The first run asks where your sounds live; after
that the folder is remembered, and the same dialog lets you change it any
time. Every audio file under that folder, subfolders included, is
searchable, and search is the collection's usual forgiving kind.

The Media Explorer with OSARA is still the tool for browsing and
auditioning when you do not know what you want. This is for when you do.

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

Values are typed in the units you think in: decibels for volume and trim,
percent for pan (minus 100 is hard left) and width, percent of the parameter's own range for plugin
parameters, 0 or 1 for mute. Anything else, such as a take pitch envelope or
the tempo map, uses its own numbers, so semitones or beats per minute. On a
take envelope the time selection still means project time; the script
works out where that falls inside the item. Curve shapes are words
rather than numbers: `linear`, `slow`, `fast start`, `fast end`, `square`,
`bezier`.

It pins the value immediately before the time selection. Without that, REAPER
interpolates the new ramp all the way back to the point it adds automatically
at the start of the project, so the value drifts across everything before the
span you chose. Pinning keeps each ramp local, which means you can run this
over one span after another to build up a shape.

### Morph between two presets

Pick a plugin, pick a preset to start from and a preset to end on, and every
parameter that differs between them gets an envelope ramping from the first
value to the second across the time selection.

REAPER cannot automate "into" a preset directly. A preset is a snapshot of
every parameter at once, so loading one is a jump and there is no preset
position to sweep. This turns that jump into movement by diffing the two
snapshots and writing one envelope per parameter that changed, which is the
part that is impractical by hand, since a single preset change can move a
dozen parameters or more.

Stepped parameters, such as filter types, sync divisions and waveform
selectors, are deliberately not ramped. Dragging a three-position switch
through its intermediate values gives zipper noise or nothing at all, so they
are switched cleanly at one end instead, and the script names the ones it
treated that way.

It can also fade the plugin's wet control up from silent at the same time, so
the effect arrives as the morph happens. Wet drops to silent over the 20
milliseconds before the span rather than jumping. That uses wet rather than
bypass on purpose: bypass is on or off, so automating it clicks.

Reading preset names means loading each one briefly, because REAPER has no
call for "name of preset at index". That is audible, so the script refuses to
run during playback.

### Speak automation state

One spoken sentence describing the automation you are sitting in: the track and
envelope, the track's automation mode, whether the envelope is armed and
visible, how many points it has, the value under the edit cursor, how far the
nearest points are on either side, and whether there is a time selection ready
to ramp across.

This script only reads. It changes nothing.

## Installing

Two routes: ReaPack if you just want the scripts, a clone if you might change
them.

### With ReaPack

In REAPER, go to Extensions, ReaPack, Import repositories, and paste:

`https://github.com/Matthew2244/accessible-reascripts/raw/main/index.xml`

Then Extensions, ReaPack, Browse packages, and install "Accessible ReaScripts".
It arrives as a single package, every script plus the shared library, so
there is nothing to keep in sync by hand, and updates come through ReaPack
like any other repository.

Each release raises the package version, which is how ReaPack knows there
is something new. Releases are listed on the repository's Releases page.

### By cloning

The better route if you might change anything, because your edits are live in
REAPER with no reinstall step. This is how contributors work.

Clone it, then point REAPER at it with a symbolic link:

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

Keep the `Lib` folder next to the script folders. Every script loads
`Lib/a11y.lua` from one level up, and will say so out loud if it cannot find
it.

## Loading the scripts and assigning shortcuts

REAPER does not pick up script files on its own. Each one has to be added to
the action list once:

1. Press the key for Actions, show action list.
2. Choose New action, then Load ReaScript.
3. Select the `.lua` files you want. You can select several at once.
4. Find the action in the list, choose Add, and press the shortcut you want.

Shortcuts are personal, so this collection deliberately does not ship any.
Worth knowing: OSARA's own key map already claims a lot of combinations, so
check a shortcut is free before committing to it.

If remembering shortcuts is not your idea of fun, load just
`Menu/a11y_What would you like to do.lua`, give it one key, and reach
everything else through it. The menu runs scripts straight off the disk, so
the others work through it without being loaded into the action list at all.

These scripts are also designed to be chained. `Speak project summary` after
`File: Save new version of project` in a single custom action is a good
example: REAPER does the work, the script tells you what happened.

## Development

Three checks, all runnable from a terminal without opening REAPER:

```bash
lua tools/test_a11y.lua && python3 tools/check_api.py && python3 tools/build_index.py --check
```

`test_a11y.lua` covers the pure logic: search ranking, numbering patterns,
spoken phrasing, and the offset search behind Line up WING-LIVE recordings. `check_api.py` reads the REAPER and extension binaries and
verifies that every `reaper.*` name used in the repo actually exists, which
catches the misspellings that otherwise only surface as a runtime error
mid-edit. `build_index.py --check` confirms `index.xml` still lists every
script, which is the easiest thing to forget when adding one and impossible to
notice by ear.

GitHub Actions runs the first and last of those on every push and pull request,
plus a compile check of every `.lua` file. It cannot run `check_api.py`, since
that one needs REAPER installed, so run it yourself before opening a pull
request. Nothing automated tests behaviour inside REAPER; that still takes a
scratch project.

`check_api.py` currently needs macOS or Linux: it reads the API names out of
the REAPER binary with symbol patterns from a clang build, and the MSVC-built
`reaper.exe` mangles them differently. On Windows it says so and stops, rather
than reporting every name as broken. See CONTRIBUTING.md.

`python3 tools/test_align_wavs.py` is an extra check for that offset search.
It builds a small fake session of real WAV files in a temporary folder (a
32-channel console recording split into two chunk files, and a REAPER-style
reference) and confirms the offset comes back to the exact sample. It needs
numpy, so it isn't in CI. `lua tools/align_wavs.lua` runs the same search on
any WAV files you point it at, which is handy for checking real recordings
outside REAPER.

See [CONTRIBUTING.md](CONTRIBUTING.md) before adding a script.

## Licence

MIT. See [LICENSE](LICENSE).
