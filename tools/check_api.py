#!/usr/bin/env python3
"""Verify that every reaper.* call in this repo actually exists.

A misspelled API name is the nastiest class of ReaScript bug: Lua happily
evaluates `reaper.CountTraks(0)` to nil and then dies with "attempt to call
a nil value" at runtime, in a dialog, halfway through an edit -- which is a
miserable thing to debug by ear.

This script reads the REAPER application binary (and the installed OSARA and
SWS extensions, if present), extracts the names they actually register for
Lua, and checks every reaper.* name used in the .lua files here against that
set.

Usage:
    python3 tools/check_api.py
    python3 tools/check_api.py --reaper /path/to/REAPER.app

Exit code 0 if every name resolves, 1 otherwise.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import platform
import re
import sys

HOME = pathlib.Path.home()

# First candidate that exists wins; --reaper and --plugins override both.
REAPER_CANDIDATES = {
    "Darwin": [
        "/Applications/REAPER.app/Contents/MacOS/REAPER",
        str(HOME / "Applications/REAPER.app/Contents/MacOS/REAPER"),
    ],
    "Windows": [
        r"C:\Program Files\REAPER (x64)\reaper.exe",
        r"C:\Program Files\REAPER\reaper.exe",
        r"C:\Program Files (x86)\REAPER\reaper.exe",
    ],
    "Linux": ["/opt/REAPER/reaper", str(HOME / "opt/REAPER/reaper")],
}

PLUGIN_CANDIDATES = {
    "Darwin": [HOME / "Library/Application Support/REAPER/UserPlugins"],
    "Windows": [pathlib.Path(os.environ.get("APPDATA", HOME / "AppData/Roaming"))
                / "REAPER" / "UserPlugins"],
    "Linux": [HOME / ".config/REAPER/UserPlugins"],
}

# A real REAPER build registers many hundreds of names. Anything near zero
# means the extraction failed, not that REAPER has no API -- and reporting a
# result from that would mark almost every name in the repo as broken.
MIN_PLAUSIBLE_API_NAMES = 200


def first_existing(candidates) -> str | None:
    for c in candidates:
        if pathlib.Path(c).exists():
            return str(c)
    return None

# Names used in the scripts that are provided by the ReaScript runtime
# itself rather than registered as API functions.
RUNTIME_NAMES = {
    "get_action_context",
    "defer",
    "atexit",
    "runloop",
}


def names_from_reaper(path: pathlib.Path) -> set[str]:
    """Extract the API names REAPER registers for Lua.

    The symbols are C++ mangled, e.g.

        __ZL18lua_CountTracksP9lua_State
        __ZL24__eel_api_CountTracksPvlPPd

    so the name has to be bounded on both sides. Matching `lua_(\\w+)`
    greedily instead captures "CountTracksP9lua_State", which then fails to
    match anything the scripts use -- the whole repo looks broken while the
    checker is the thing at fault.

    Both patterns come from the macOS build, where clang uses Itanium C++
    mangling. The Windows build is compiled with MSVC, which mangles names a
    different way entirely, so `P9lua_State` never appears there and this
    returns an empty set. main() refuses to report a result in that case
    rather than declaring every name broken -- see MIN_PLAUSIBLE_API_NAMES.
    """
    data = path.read_bytes()
    names: set[str] = set()
    for pattern in (rb"lua_([A-Za-z_][A-Za-z0-9_]*?)P9lua_State",
                    rb"__eel_api_([A-Za-z_][A-Za-z0-9_]*?)PvlPPd"):
        names |= {m.decode() for m in re.findall(pattern, data)}
    return names


def names_from_extension(path: pathlib.Path) -> set[str]:
    """Extensions register through `API_<Name>` / `APIdef_<Name>`.

    These are plain strings rather than mangled symbols, so unlike
    names_from_reaper this half works identically on every platform.
    """
    data = path.read_bytes()
    return set(m.decode() for m in re.findall(rb"API_([A-Za-z_][A-Za-z0-9_]*)", data))


def used_names(root: pathlib.Path) -> dict[str, list[tuple[pathlib.Path, int]]]:
    """Map each reaper.<Name> used in the repo to where it is used."""
    uses: dict[str, list[tuple[pathlib.Path, int]]] = {}
    for lua in sorted(root.rglob("*.lua")):
        for lineno, line in enumerate(lua.read_text(encoding="utf-8").splitlines(), 1):
            # Ignore comment-only lines so prose mentioning an API does not
            # count as a use.
            if line.lstrip().startswith("--"):
                continue
            for name in re.findall(r"\breaper\.([A-Za-z_][A-Za-z0-9_]*)", line):
                uses.setdefault(name, []).append((lua.relative_to(root), lineno))
    return uses


def main() -> int:
    system = platform.system()
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--reaper", default=None,
                    help="path to the REAPER executable")
    ap.add_argument("--plugins", default=None,
                    help="path to the UserPlugins folder")
    ap.add_argument("--root", default=".", help="repo root to scan")
    args = ap.parse_args()

    candidates = REAPER_CANDIDATES.get(system, [])
    found = args.reaper or first_existing(candidates)
    if found is None:
        print(f"REAPER not found on this {system} machine. Looked in:",
              file=sys.stderr)
        for c in candidates:
            print(f"  {c}", file=sys.stderr)
        print("Pass --reaper with the path to the executable "
              "(inside REAPER.app/Contents/MacOS on macOS, reaper.exe on Windows).",
              file=sys.stderr)
        return 2

    reaper_bin = pathlib.Path(found)
    if not reaper_bin.exists():
        print(f"REAPER binary not found at {reaper_bin}.", file=sys.stderr)
        return 2

    core = names_from_reaper(reaper_bin)
    if len(core) < MIN_PLAUSIBLE_API_NAMES:
        print(f"Only {len(core)} API names could be read out of {reaper_bin}, "
              f"which is far too few to check against -- a real REAPER build "
              f"registers many hundreds.", file=sys.stderr)
        print("\nRefusing to report a result, because doing so would mark "
              "almost every name in the repository as broken and none of it "
              "would be true.", file=sys.stderr)
        if system == "Windows":
            print("\nThis is expected on Windows. The extraction patterns come "
                  "from the macOS build, where clang uses Itanium C++ mangling "
                  "(lua_CountTracksP9lua_State). MSVC mangles differently, so "
                  "names_from_reaper() needs a Windows pattern adding before "
                  "this check can work here.", file=sys.stderr)
            print("\nThe other two checks are unaffected and worth running:\n"
                  "  lua tools/test_a11y.lua\n"
                  "  python3 tools/build_index.py --check", file=sys.stderr)
        return 2

    known = core | RUNTIME_NAMES
    sources = [f"REAPER ({len(known)} names)"]

    plugins = pathlib.Path(args.plugins or
                           first_existing(PLUGIN_CANDIDATES.get(system, [])) or
                           "/nonexistent")
    if plugins.is_dir():
        for dylib in sorted(plugins.glob("*.dylib")) + sorted(plugins.glob("*.so")) \
                + sorted(plugins.glob("*.dll")):
            found = names_from_extension(dylib)
            if found:
                known |= found
                sources.append(f"{dylib.name} ({len(found)})")

    print("Checked against: " + ", ".join(sources))

    uses = used_names(pathlib.Path(args.root))
    missing = {n: locs for n, locs in uses.items() if n not in known}

    print(f"{len(uses)} distinct reaper.* names used across the repo.")

    if not missing:
        print("All resolve. OK.")
        return 0

    print(f"\n{len(missing)} name(s) do not resolve:")
    for name in sorted(missing):
        for path, lineno in missing[name]:
            print(f"  {path}:{lineno}: reaper.{name}")
    print("\nA name can fail here for three reasons: it is misspelled, it needs "
          "an extension that is not installed, or it is newer than this REAPER "
          "build. Check which before assuming a typo.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
