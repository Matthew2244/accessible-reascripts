<!--
Delete anything that does not apply. Prose is fine — this is a prompt for what
reviewers need to know, not a form to fill in exactly.
-->

## What this changes

<!-- One or two sentences. If it adds a script, say what the script does and
     what it deliberately leaves alone. -->

## Tested by hand in REAPER

<!-- The automated checks cannot open REAPER, so this is the part a reviewer
     cannot get anywhere else. Say what you actually did. -->

- REAPER version:
- Platform and screen reader: <!-- e.g. macOS 15 with VoiceOver, Windows 11 with NVDA -->
- What you tried:
- What it said out loud:

<!-- If it is a documentation-only change, say so here and skip the rest. -->

## Checks

```bash
lua tools/test_a11y.lua
python3 tools/check_api.py
python3 tools/build_index.py --check
```

- [ ] All three pass locally. (`check_api.py` needs REAPER installed; CI runs
      the other two.)
- [ ] Every path through the script speaks — success, cancellation and failure.
- [ ] No `gfx` window and no `gfx.showmenu`; native dialogs only.
- [ ] Edits are wrapped in one `Undo_BeginBlock` / `Undo_EndBlock` pair.
- [ ] Nothing claims success it has not verified.
- [ ] A new script is in a category folder, named `a11y_...`, and `index.xml`
      has been regenerated.

## Anything you are unsure about

<!-- Genuinely useful to say. A ranking rule that felt arbitrary, a phrase you
     could not make read well aloud, an API whose behaviour you had to guess —
     flag it and someone will test it on their setup. -->
