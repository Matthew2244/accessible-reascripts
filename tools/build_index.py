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
    python3 tools/build_index.py --check

Writes index.xml at the repo root. --check writes nothing and reports whether
the committed index still matches the scripts on disk, which is the one thing
about adding a script that is easy to forget and impossible to notice by ear.

The package version comes from the VERSION file at the repo root. It used to
be the highest @version of any script, which meant a release that added a
script at 1.0.0, or fixed one below the top version, produced the same
package version as before, and ReaPack users were never offered it. Seven
scripts went unshipped that way. Raise VERSION for every release.
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
# Folders that hold things other than scripts. Script folders themselves are
# discovered, not listed: a hardcoded list silently drops any new category
# folder from the index, and --check then reports "up to date" while ReaPack
# users never receive the new scripts. That happened once; not again.
NON_SCRIPT_DIRS = {"Lib", "tools"}
LIB_FILES = ("Lib/a11y.lua",)


def script_dirs(root: pathlib.Path) -> list[str]:
    """Top-level folders that contain scripts, discovered from disk."""
    out = []
    for d in sorted(root.iterdir()):
        if not d.is_dir() or d.name in NON_SCRIPT_DIRS or d.name.startswith("."):
            continue
        if any(d.glob("a11y_*.lua")):
            out.append(d.name)
    return out


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
    for folder in script_dirs(root):
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


def version_key(v: str) -> list[int]:
    return [int(p) for p in re.findall(r"\d+", v) or [0]]


def default_version(root: pathlib.Path) -> str:
    """The package version: the VERSION file, which must be at least as
    high as any script's own @version. Without the file, the highest
    @version, as before."""
    versions = [h.get("version", "0.0.0") for _, h in collect(root)]
    highest = max(versions, key=version_key)
    vfile = root / "VERSION"
    if not vfile.exists():
        return highest
    version = vfile.read_text(encoding="utf-8").strip()
    if version_key(version) < version_key(highest):
        raise SystemExit(f"VERSION says {version}, but a script declares "
                         f"@version {highest}. Raise VERSION.")
    return version


def target_from_index(path: pathlib.Path) -> tuple[str, str]:
    """Recover the --url and --branch a committed index.xml was built with.

    So --check needs no arguments: the answer is already in the file, and a
    checker you have to hand the right answer to is one more thing to get
    wrong.
    """
    root = ET.parse(path).getroot()
    link = root.find("./metadata/link[@rel='website']")
    url = (link.text or "").strip() if link is not None else ""
    branch = ""
    for src in root.iter("source"):
        m = re.search(r"/raw/([^/]+)/", (src.text or "").strip())
        if m:
            branch = m.group(1)
            break
    return url, branch


def source_files(node: ET.Element) -> set[str]:
    """Every file path an index declares."""
    return {src.get("file", "") for src in node.iter("source")}


def check(root: pathlib.Path, url: str | None, branch: str | None,
          version: str | None) -> int:
    """Compare the committed index.xml with what the scripts on disk imply."""
    path = root / "index.xml"
    if not path.exists():
        print("No index.xml here. Generate one with --url first.", file=sys.stderr)
        return 1

    found_url, found_branch = target_from_index(path)
    url = url or found_url
    branch = branch or found_branch or "main"
    if not url:
        print("index.xml records no website link, so the repository URL cannot "
              "be inferred. Pass --url.", file=sys.stderr)
        return 1

    version = version or default_version(root)
    expected = build(root, url, branch, version)

    # Canonical XML with whitespace stripped, so pretty-printing that differs
    # between Python versions can never fail a check that is about content.
    if ET.canonicalize(expected, strip_text=True) == \
            ET.canonicalize(from_file=str(path), strip_text=True):
        print(f"index.xml is up to date: version {version}, "
              f"{len(collect(root))} scripts.")
        return 0

    committed = ET.parse(path).getroot()
    print("index.xml no longer matches the scripts in this repository.",
          file=sys.stderr)

    have, want = source_files(committed), source_files(ET.fromstring(expected))
    for missing in sorted(want - have):
        print(f"  missing from the index: {missing}", file=sys.stderr)
    for extra in sorted(have - want):
        print(f"  in the index but not on disk: {extra}", file=sys.stderr)

    node = committed.find(".//version")
    if node is not None and node.get("name") != version:
        print(f"  version: the index says {node.get('name')}, "
              f"the scripts say {version}", file=sys.stderr)

    print("\nRegenerate it and commit the result:\n"
          f"  python3 tools/build_index.py --url {url} --branch {branch}",
          file=sys.stderr)
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default=None,
                    help="repository web URL, e.g. https://github.com/OWNER/REPO")
    ap.add_argument("--branch", default=None, help="default: main")
    ap.add_argument("--version", default=None,
                    help="package version (default: highest @version found)")
    ap.add_argument("--root", default=".")
    ap.add_argument("--check", action="store_true",
                    help="write nothing; report whether index.xml is still current")
    args = ap.parse_args()

    root = pathlib.Path(args.root).resolve()

    if args.check:
        return check(root, args.url, args.branch, args.version)

    if not args.url:
        ap.error("--url is required when writing the index "
                 "(--check infers it from the existing index.xml)")

    version = args.version or default_version(root)

    branch = args.branch or "main"
    xml = build(root, args.url, branch, version)
    out = root / "index.xml"
    out.write_text(xml, encoding="utf-8")
    print(f"Wrote {out} (version {version}, {len(collect(root))} scripts).")
    print("Commit and push it, then the repository can be imported in ReaPack as:")
    print(f"  {raw_url(args.url, branch, 'index.xml')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
