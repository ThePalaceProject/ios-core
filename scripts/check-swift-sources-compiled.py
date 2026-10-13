#!/usr/bin/env python3
"""
check-swift-sources-compiled.py — fail when a Swift file in the app or test
tree is not compiled by any target in Palace.xcodeproj.

Xcode only builds what a target's Sources phase lists, so a file can sit in the
tree, show up in searches and in review, and never compile. Test files in that
state read as coverage that does not run. This has happened repeatedly: one
census found test files referenced but never built, references to files that
no longer existed, duplicate unbuilt references and tracked files with no
reference at all.

Findings, all whole-tree:
  unreferenced  a tracked .swift under SCOPE_ROOTS (outside a Swift package)
                has no file reference in the project.
  not compiled  a .swift file reference resolves to a file that no target's
                Sources phase compiles.
  dangling      a .swift file reference points at a path with no tracked file.
  duplicate     a .swift file that is compiled also has a second, unbuilt
                reference.

The pbxproj is parsed structurally (no plutil, so it runs on Linux CI). Object
IDs are not assumed to be 24-hex; some in this project are hand-written.

prior-art-checked: check-package-tests-wired.sh covers SwiftPM test targets;
nothing in scripts/ compared the project's Sources phases with the tree.

Usage:
    check-swift-sources-compiled.py [--root DIR] [--pbxproj PATH]
                                    [--files-from LIST] [--quiet]
`--files-from` replaces `git ls-files` with a newline-separated path list, so
the check can be run against a historical tree:
    git show REV:Palace.xcodeproj/project.pbxproj > old.pbxproj
    git ls-tree -r --name-only REV > old-files.txt

Exit codes: 0 clean, 1 findings, 2 usage or parse error.
"""

from __future__ import annotations

import argparse
import os
import posixpath
import re
import subprocess
import sys
from collections import defaultdict
from typing import NamedTuple

PBXPROJ = "Palace.xcodeproj/project.pbxproj"

# Directories whose tracked Swift files must all be compiled. Each is a target
# in Palace.xcodeproj; Swift packages beneath them are excluded because SwiftPM
# builds those.
SCOPE_ROOTS = ("Palace/", "PalaceTests/", "PalaceUITests/")

# Expected findings: path -> (finding kind, reason). An entry that suppresses
# no finding fails the check, so the list cannot outlive its reason.
ALLOWLIST: dict[str, tuple[str, str]] = {
    "Palace/AppInfrastructure/APIKeys.swift": (
        "dangling",
        "Gitignored secret. setup-repo-*.sh copies it from APIKeys.swift.example "
        "before the first build; both app targets compile it.",
    ),
}

FIX_HINT = (
    "Add it to its targets with `ruby scripts/pbxproj_add_swift.rb FILE` "
    "(test files route to PalaceTests automatically), or delete the file."
)


# --- OpenStep plist parser -------------------------------------------------

class ParseError(Exception):
    pass


_TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<block>/\*.*?\*/)
  | (?P<line>//[^\n]*)
  | (?P<quoted>"(?:[^"\\]|\\.)*")
  | (?P<punct>[{}();,=])
  | (?P<bare>(?:[^\s{}();,="/]|/(?![/*]))+)
    """,
    re.VERBOSE | re.DOTALL,
)

_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def _unquote(raw: str) -> str:
    body = raw[1:-1]
    return re.sub(r"\\(.)", lambda m: _ESCAPES.get(m.group(1), m.group(1)), body)


def _tokens(text: str):
    pos = 0
    n = len(text)
    while pos < n:
        m = _TOKEN.match(text, pos)
        if not m:
            raise ParseError(f"unexpected character at offset {pos}: {text[pos:pos + 20]!r}")
        pos = m.end()
        kind = m.lastgroup
        if kind in ("ws", "block", "line"):
            continue
        if kind == "quoted":
            yield ("str", _unquote(m.group()))
        elif kind == "bare":
            yield ("str", m.group())
        else:
            yield (m.group(), m.group())


def parse_pbxproj(text: str) -> dict:
    toks = list(_tokens(text))
    pos = 0

    def expect(kind: str):
        nonlocal pos
        if pos >= len(toks) or toks[pos][0] != kind:
            got = toks[pos][1] if pos < len(toks) else "end of file"
            raise ParseError(f"expected {kind!r}, got {got!r}")
        pos += 1

    def value():
        nonlocal pos
        kind, val = toks[pos]
        if kind == "str":
            pos += 1
            return val
        if kind == "{":
            pos += 1
            out = {}
            while toks[pos][0] != "}":
                key = value()
                if not isinstance(key, str):
                    raise ParseError("dictionary key is not a string")
                expect("=")
                out[key] = value()
                expect(";")
            pos += 1
            return out
        if kind == "(":
            pos += 1
            out = []
            while toks[pos][0] != ")":
                out.append(value())
                if toks[pos][0] == ",":
                    pos += 1
                elif toks[pos][0] != ")":
                    raise ParseError(f"expected ',' or ')', got {toks[pos][1]!r}")
            pos += 1
            return out
        raise ParseError(f"unexpected token {val!r}")

    try:
        root = value()
    except IndexError:
        raise ParseError("unexpected end of file") from None
    if pos != len(toks):
        raise ParseError("trailing content after the root dictionary")
    if not isinstance(root, dict) or not isinstance(root.get("objects"), dict):
        raise ParseError("no objects dictionary")
    return root


# --- Project model ---------------------------------------------------------

def resolve_file_paths(project: dict) -> dict[str, str | None]:
    """Map every PBXFileReference reachable from the main group to its
    repo-relative path, or None when its sourceTree is outside the repo."""
    objects = project["objects"]
    root_obj = objects.get(project.get("rootObject", ""), {})
    main = root_obj.get("mainGroup")
    if main not in objects:
        raise ParseError("project has no main group")

    resolved: dict[str, str | None] = {}

    def join(base: str | None, entry: dict) -> str | None:
        tree = entry.get("sourceTree", "<group>")
        path = entry.get("path")
        if tree == "SOURCE_ROOT":
            return posixpath.normpath(path) if path else ""
        if tree == "<group>" and base is not None:
            return posixpath.normpath(posixpath.join(base, path)) if path else base
        return None

    def walk(group_id: str, base: str | None, seen: set):
        if group_id in seen:
            return
        seen.add(group_id)
        for child_id in objects[group_id].get("children", []):
            child = objects.get(child_id)
            if child is None:
                continue
            full = join(base, child)
            if full == ".":
                full = ""
            isa = child.get("isa")
            if isa in ("PBXGroup", "PBXVariantGroup"):
                walk(child_id, full, seen)
            elif isa == "PBXFileReference":
                resolved[child_id] = full

    walk(main, "", set())
    return resolved


def compiled_refs(objects: dict) -> set[str]:
    """File-reference IDs listed in some target's Sources build phase."""
    out = set()
    for obj in objects.values():
        if obj.get("isa") != "PBXSourcesBuildPhase":
            continue
        for build_id in obj.get("files", []):
            ref = objects.get(build_id, {}).get("fileRef")
            if ref:
                out.add(ref)
    return out


def package_dirs(tracked: list[str]) -> list[str]:
    return sorted(posixpath.dirname(p) + "/" for p in tracked
                  if posixpath.basename(p) == "Package.swift")


def in_scope(path: str, packages: list[str]) -> bool:
    return (path.endswith(".swift")
            and path.startswith(SCOPE_ROOTS)
            and not any(path.startswith(d) for d in packages))


class Finding(NamedTuple):
    path: str
    kind: str
    message: str

    def __str__(self) -> str:
        return f"{self.path}: {self.kind} — {self.message}"


def find_problems(project: dict, tracked: list[str],
                  allowlist: dict[str, tuple[str, str]]) -> tuple[list[Finding], int]:
    """Return (findings after the allowlist, number of in-scope files checked)."""
    objects = project["objects"]
    tracked_set = set(tracked)
    paths = resolve_file_paths(project)
    built = compiled_refs(objects)

    refs_by_path: dict[str, list[str]] = defaultdict(list)
    raw: list[Finding] = []
    for oid, obj in objects.items():
        if obj.get("isa") != "PBXFileReference":
            continue
        name = obj.get("path") or obj.get("name") or ""
        if not name.endswith(".swift"):
            continue
        path = paths.get(oid)
        if path is None:
            raw.append(Finding(name, "unresolvable",
                               f"file reference {oid} is not under the project's main "
                               f"group, or its sourceTree is outside the repo. Remove "
                               f"the reference and re-add the file with "
                               f"`ruby scripts/pbxproj_add_swift.rb FILE`."))
            continue
        refs_by_path[path].append(oid)

    by_basename: dict[str, list[str]] = defaultdict(list)
    for path in refs_by_path:
        if path in tracked_set:
            by_basename[posixpath.basename(path)].append(path)

    for path, ids in sorted(refs_by_path.items()):
        unbuilt = [i for i in ids if i not in built]
        if path not in tracked_set:
            twins = by_basename.get(posixpath.basename(path), [])
            hint = f" It looks like a stale duplicate of {twins[0]}." if len(twins) == 1 else ""
            raw.append(Finding(path, "dangling",
                               f"the project references it ({', '.join(ids)}) but no "
                               f"tracked file exists there.{hint} Remove it with "
                               f"`ruby scripts/pbxproj_remove_swift.rb {path}`, or "
                               f"restore the file."))
        elif unbuilt and len(unbuilt) < len(ids):
            raw.append(Finding(path, "duplicate",
                               f"compiled, but also has unbuilt reference(s) "
                               f"{', '.join(unbuilt)}. Delete the extra "
                               f"PBXFileReference and its group entry."))
        elif unbuilt:
            raw.append(Finding(path, "not compiled",
                               f"referenced, but in no target's Sources phase. {FIX_HINT}"))

    packages = package_dirs(tracked)
    scoped = [p for p in tracked if in_scope(p, packages)]
    for path in sorted(scoped):
        if path not in refs_by_path:
            raw.append(Finding(path, "unreferenced",
                               f"tracked, but not in the project, so nothing compiles "
                               f"it. {FIX_HINT}"))

    findings = [f for f in raw if allowlist.get(f.path, ("",))[0] != f.kind]
    for path, (kind, _reason) in sorted(allowlist.items()):
        if not any(f.path == path and f.kind == kind for f in raw):
            findings.append(Finding(path, "stale allowlist entry",
                                    f"it expects a '{kind}' finding and there is none. "
                                    f"Remove the entry from ALLOWLIST in "
                                    f"scripts/check-swift-sources-compiled.py."))
    return findings, len(scoped)


# --- Entry point -----------------------------------------------------------

def _git_root() -> str:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else os.getcwd()


def _tracked(root: str) -> list[str]:
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise OSError(f"git ls-files failed in {root}: {out.stderr.strip()}")
    return [p for p in out.stdout.split("\0") if p]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", help="repository root (default: git toplevel of cwd)")
    ap.add_argument("--pbxproj", help=f"project file (default: <root>/{PBXPROJ})")
    ap.add_argument("--files-from", help="newline-separated tracked-file list "
                                         "(default: git ls-files)")
    ap.add_argument("--quiet", action="store_true", help="print findings only")
    args = ap.parse_args(argv)

    root = args.root or _git_root()
    pbxproj = args.pbxproj or os.path.join(root, PBXPROJ)
    try:
        with open(pbxproj, encoding="utf-8") as fh:
            project = parse_pbxproj(fh.read())
        if args.files_from:
            with open(args.files_from, encoding="utf-8") as fh:
                tracked = [line.strip() for line in fh if line.strip()]
        else:
            tracked = _tracked(root)
        findings, checked = find_problems(project, tracked, ALLOWLIST)
    except (OSError, ParseError) as exc:
        print(f"check-swift-sources-compiled: ERROR: {exc}", file=sys.stderr)
        return 2

    # An empty scope means the layout moved or the file list is wrong; reporting
    # it as clean would hide every file the check exists to see.
    if checked == 0:
        print("check-swift-sources-compiled: ERROR: no tracked Swift files under "
              f"{', '.join(SCOPE_ROOTS)}; nothing was checked.", file=sys.stderr)
        return 2

    if findings:
        print(f"Swift sources not compiled by Palace.xcodeproj ({len(findings)}):\n")
        for f in findings:
            print(f"  {f}")
        return 1
    if not args.quiet:
        print(f"swift sources compiled ({checked} tracked file(s) checked, 0 findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
