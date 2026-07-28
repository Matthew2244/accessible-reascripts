#!/usr/bin/env python3
"""Generate index.xml so this repository can be installed with ReaPack.

ReaPack is how most screen reader users install REAPER scripts, and it is
already part of the standard accessibility setup, so it is worth supporting
properly. It also gives contributors a real distribution channel: push a
change, regenerate the index, and everyone gets the update in place.

Everything ships as ONE package containing every script plus the shared
library. That matters: if each script were its own package they would each
have to provide their own copy of Lib/a11y.lua, which ReaPack reports as a
file conflict, and installing a single script would silently give you a
half-working collection.

Usage:
    python3 tools/build_index.py --url https://github.com/OWNER/REPO --branch main

Writes index.xml at the repo root.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from xml.dom import minidom

PACKAGE_NAME = "Accessible ReaScripts"
CATEGORY = "Accessible ReaScripts"
SCRIPT_DIRS = ("Tracks", "Project", "Navigation")
LIB_FILES = ("Lib/a11y.lua",)


def read_header(path: pathlib.Path) -> dict[str, str]:
    """Pull @description / @version / @author / @about out of a script."""
    text = path.read_text(encoding="utf-8")
    header: dict[str, str] = {}

    for field in ("description", "version", "author"):
        m = re.search(rf"^\s*@{field}\s+(.+)$", text, re.MULTILINE)
        if m:
            header[field] = m.group(1).strip()

    about = re.search(r"^\s*@about\n(.*?)(?=^\s*@\w|\]\])", text,
                      re.MULTILINE | re.DOTALL)
    if about:
        lines = [ln.strip() for ln in about.group(1).splitlines()]
        header["about"] = "\n".join(lines).strip()

    return header


def collect(root: pathlib.Path) -> list[tuple[str, dict[str, str]]]:
    """Every script, as (repo-relative posix path, header)."""
    out = []
    for folder in SCRIPT_DIRS:
        d = root / folder
        if not d.is_dir():
            continue
        for lua in sorted(d.glob("*.lua")):
            header = read_header(lua)
            if "description" not in header:
                print(f"warning: {lua.name} has no @description, skipping",
                      file=sys.stderr)
                continue
            out.append((lua.relative_to(root).as_posix(), header))
    return out


def raw_url(base: str, branch: str, path: str) -> str:
    """Build a raw-file URL. GitHub needs /raw/<branch>/ for raw content."""
    base = base.rstrip("/")
    if base.endswith(".git"):
        base = base[:-4]
    from urllib.parse import quote
    return f"{base}/raw/{branch}/{quote(path)}"


def build(root: pathlib.Path, base_url: str, branch: str, version: str) -> str:
    scripts = collect(root)
    if not scripts:
        raise SystemExit("No scripts found. Run this from the repository root.")

    index = ET.Element("index", version="1", name=PACKAGE_NAME)
    category = ET.SubElement(index, "category", name=CATEGORY)

    authors = {h.get("author", "") for _, h in scripts if h.get("author")}
    author = sorted(authors)[0] if authors else "Accessible ReaScripts contributors"

    pkg = ET.SubElement(category, "reapack", name=PACKAGE_NAME,
                        type="script", desc=PACKAGE_NAME)
    ver = ET.SubElement(pkg, "version", name=version, author=author)

    # Each script is a separate action; the library is installed alongside
    # but is not an action, so it carries no main attribute.
    for path, _header in scripts:
        src = ET.SubElement(ver, "source", main="main", file=path)
        src.text = raw_url(base_url, branch, path)

    for lib in LIB_FILES:
        if not (root / lib).exists():
            raise SystemExit(f"Missing {lib}; every script needs it at runtime.")
        src = ET.SubElement(ver, "source", file=lib)
        src.text = raw_url(base_url, branch, lib)

    # Package description: a readable summary of what you get.
    lines = [
        "Scripts that make REAPER faster to use with a screen reader.",
        "",
        "Every script speaks its result through OSARA, and none of them draw "
        "their own windows, so everything stays readable by VoiceOver and NVDA.",
        "",
        "Included:",
    ]
    for path, header in scripts:
        lines.append(f"- {header['description']}")
    lines += ["", "Requires OSARA. SWS is recommended."]

    meta = ET.SubElement(pkg, "metadata")
    ET.SubElement(meta, "description").text = "\n".join(lines)

    repo_meta = ET.SubElement(index, "metadata")
    link = ET.SubElement(repo_meta, "link", rel="website")
    link.text = base_url

    raw = ET.tostring(index, encoding="utf-8")
    return minidom.parseString(raw).toprettyxml(indent="  ", encoding="utf-8").decode()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", required=True,
                    help="repository web URL, e.g. https://github.com/OWNER/REPO")
    ap.add_argument("--branch", default="main")
    ap.add_argument("--version", default=None,
                    help="package version (default: highest @version found)")
    ap.add_argument("--root", default=".")
    args = ap.parse_args()

    root = pathlib.Path(args.root).resolve()

    version = args.version
    if version is None:
        versions = [h.get("version", "0.0.0") for _, h in collect(root)]
        version = max(versions, key=lambda v: [int(p) for p in
                                               re.findall(r"\d+", v) or [0]])

    xml = build(root, args.url, args.branch, version)
    out = root / "index.xml"
    out.write_text(xml, encoding="utf-8")
    print(f"Wrote {out} (version {version}, {len(collect(root))} scripts).")
    print("Commit and push it, then the repository can be imported in ReaPack as:")
    print(f"  {raw_url(args.url, args.branch, 'index.xml')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
