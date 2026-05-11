#!/usr/bin/env python3
"""
export-module-contracts.py — emit a public-surface contract sidecar per Palace module.

For each top-level Swift module under Palace/, this scans all .swift files and writes
a contract JSON to .forgeos/contracts/<module>.json capturing:
  - public_types         (public class/struct/enum/protocol/actor)
  - objc_surface         (@objc / @objcMembers / @objc(name) decls)
  - public_functions     (top-level public func, NOT methods inside types)
  - internal_protocols   (top-level `protocol X` with no access modifier — DI seams)
  - file_count
  - shared_singleton_reads (.shared reads, excluding Foundation system APIs)

Consumers:
  - /swarm triage agent (future)
  - scripts/verify-pr.sh — runs `--check` to flag drift between code and contract

Stdlib only. Regex-based (sourcekitten not available). "Good enough" comment stripping.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths

REPO_ROOT = Path(__file__).resolve().parent.parent
PALACE_DIR = REPO_ROOT / "Palace"
DEFAULT_OUTPUT_DIR = REPO_ROOT / ".forgeos" / "contracts"

# Subdirectories of Palace/ that are NOT first-class modules for contract purposes.
SKIP_DIRS = {"Packages"}  # already SPM packages with their own surface

# Foundation/system .shared APIs that aren't migration targets.
FOUNDATION_SHARED_PREFIXES = (
    "URLCache.shared",
    "HTTPCookieStorage.shared",
    "URLSession.shared",
    "FileManager.default",
    "NotificationCenter.default",
    "UserDefaults.standard",
    "ProcessInfo.processInfo",
)

# ---------------------------------------------------------------------------
# Comment stripping (good-enough pass)

_BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
_LINE_COMMENT_RE = re.compile(r"//[^\n]*")


def strip_comments(src: str) -> str:
    """Strip /* ... */ and // ... comments. Doesn't try to be string-literal aware
    beyond a "good enough" pass — block comments inside string literals are extremely
    rare in Swift and not worth a full lexer."""
    src = _BLOCK_COMMENT_RE.sub("", src)
    src = _LINE_COMMENT_RE.sub("", src)
    return src


# ---------------------------------------------------------------------------
# Regex patterns
#
# Each declaration regex matches at start-of-line (with optional leading whitespace)
# and accepts a stack of modifiers in any order: final, public, @MainActor, @objc,
# @objcMembers, override, etc. We capture the keyword (class/struct/enum/protocol/actor)
# and the identifier.

# Modifiers we may see between line-start and the declaration keyword.
# Includes both attributes (@X) and access/modifier keywords.
_MODIFIER_TOKEN = (
    r"(?:"
    r"@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?"  # @MainActor, @objc(name), @available(...)
    r"|public|private|fileprivate|internal|open"
    r"|final|static|class|dynamic|override|required|convenience|indirect"
    r"|weak|unowned|lazy|mutating|nonmutating"
    r"|async|throws|rethrows"
    r")"
)
_MODIFIERS = rf"(?:{_MODIFIER_TOKEN}\s+)*"

# Public type declaration. Keyword set: class/struct/enum/protocol/actor.
# Match where modifier stack contains `public` somewhere.
_PUBLIC_TYPE_RE = re.compile(
    rf"^[ \t]*(?P<mods>{_MODIFIERS})"
    rf"(?P<kw>class|struct|enum|protocol|actor)\s+"
    rf"(?P<name>[A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)

# @objc surface. Match @objc / @objcMembers / @objc(Name) on a declaration.
# We accept the @objc on the SAME line as the decl OR on the line above.
_OBJC_RE = re.compile(
    rf"^[ \t]*(?P<mods>{_MODIFIERS})"
    rf"(?P<kw>class|struct|enum|protocol|extension|func|var|let)\s+"
    rf"(?P<name>[A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)

_OBJC_ATTR_RE = re.compile(r"@objc(?:Members)?(?:\([^)]*\))?")

# Top-level public func (NOT methods inside types).
# We can't easily tell "top-level" from regex alone, but indentation is a strong
# proxy in this codebase: top-level decls start at column 0 (no leading whitespace).
_PUBLIC_FUNC_RE = re.compile(
    rf"^(?P<mods>{_MODIFIERS})"  # NO leading whitespace — top-level only
    rf"func\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)"
    rf"(?P<rest>[^\n]*)",
    re.MULTILINE,
)

# Internal protocol: `protocol X` at column 0 with NO public/private/fileprivate.
# The modifier set we explicitly REJECT: public, private, fileprivate.
# `internal` is the implicit default but may also be explicit — both count.
_PROTOCOL_RE = re.compile(
    rf"^(?P<mods>{_MODIFIERS})"  # column 0
    rf"protocol\s+(?P<name>[A-Za-z_][A-Za-z0-9_]*)",
    re.MULTILINE,
)

# .shared reads (not writes; we don't try to distinguish — `\.shared` token alone is fine).
_SHARED_RE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\.shared\b")


# ---------------------------------------------------------------------------
# Helpers


def line_of(src: str, pos: int) -> int:
    """1-indexed line number for a byte offset in src."""
    return src.count("\n", 0, pos) + 1


def has_modifier(mods: str, name: str) -> bool:
    """True if `name` appears as a whole word in the captured modifier stack."""
    return re.search(rf"\b{re.escape(name)}\b", mods) is not None


def has_access_modifier(mods: str, names: tuple[str, ...]) -> bool:
    return any(has_modifier(mods, n) for n in names)


# ---------------------------------------------------------------------------
# Per-file extraction


def extract_from_file(path: Path) -> dict:
    """Return the four lists for a single Swift file."""
    raw = path.read_text(encoding="utf-8", errors="replace")
    src = strip_comments(raw)

    rel_file = path.name
    public_types: list[dict] = []
    objc_surface: list[dict] = []
    public_functions: list[dict] = []
    internal_protocols: list[dict] = []

    # public_types — anything with `public` in modifier stack on a class/struct/enum/protocol/actor
    for m in _PUBLIC_TYPE_RE.finditer(src):
        mods = m.group("mods") or ""
        if not has_modifier(mods, "public") and not has_modifier(mods, "open"):
            continue
        public_types.append(
            {
                "name": m.group("name"),
                "kind": m.group("kw"),
                "file": rel_file,
                "line": line_of(src, m.start()),
            }
        )

    # objc_surface — modifier stack contains @objc or @objcMembers
    for m in _OBJC_RE.finditer(src):
        mods = m.group("mods") or ""
        if not _OBJC_ATTR_RE.search(mods):
            continue
        objc_surface.append(
            {
                "name": m.group("name"),
                "kind": m.group("kw"),
                "file": rel_file,
                "line": line_of(src, m.start()),
            }
        )

    # public_functions — top-level (column 0, modifier stack contains `public`)
    for m in _PUBLIC_FUNC_RE.finditer(src):
        mods = m.group("mods") or ""
        if not (has_modifier(mods, "public") or has_modifier(mods, "open")):
            continue
        # Reconstruct the "signature" as the full matched line, trimmed.
        line_start = src.rfind("\n", 0, m.start()) + 1
        line_end = src.find("\n", m.end())
        if line_end == -1:
            line_end = len(src)
        sig = src[line_start:line_end].strip()
        public_functions.append(
            {
                "name": m.group("name"),
                "signature": sig,
                "file": rel_file,
                "line": line_of(src, m.start()),
            }
        )

    # internal_protocols — top-level `protocol X` with NO public/open modifier.
    # We accept implicit-internal AND explicit `internal`.
    for m in _PROTOCOL_RE.finditer(src):
        mods = m.group("mods") or ""
        if has_access_modifier(mods, ("public", "open", "private", "fileprivate")):
            continue
        # Also check the @objc-protocol case — those are already in objc_surface,
        # but they're still internal protocols if no public modifier. Keep them in
        # both lists; objc_surface tracks the bridge, internal_protocols tracks DI.
        internal_protocols.append(
            {
                "name": m.group("name"),
                "file": rel_file,
                "line": line_of(src, m.start()),
            }
        )

    # shared_singleton_reads — count `.shared` minus Foundation system APIs.
    shared_count = 0
    for m in _SHARED_RE.finditer(src):
        token = m.group(0)  # e.g. "URLCache.shared"
        # Whole token check — the regex captured `Type.shared`; the receiver is group(1).
        full = m.group(0)
        if any(full.startswith(prefix) for prefix in FOUNDATION_SHARED_PREFIXES):
            continue
        shared_count += 1
    # Also count `.default` / `.standard` / `.processInfo`? No — spec only mentions .shared.

    return {
        "public_types": public_types,
        "objc_surface": objc_surface,
        "public_functions": public_functions,
        "internal_protocols": internal_protocols,
        "shared_singleton_reads": shared_count,
    }


# ---------------------------------------------------------------------------
# Per-module aggregation


def discover_modules(palace_dir: Path) -> list[Path]:
    """Return top-level module dirs under Palace/, excluding dotfiles and SKIP_DIRS."""
    out: list[Path] = []
    for child in sorted(palace_dir.iterdir()):
        if not child.is_dir():
            continue
        if child.name.startswith("."):
            continue
        if child.name in SKIP_DIRS:
            continue
        if child.name.endswith(".lproj"):  # localization bundles
            continue
        out.append(child)
    return out


def build_contract(module_dir: Path) -> dict:
    swift_files = sorted(module_dir.rglob("*.swift"))

    public_types: list[dict] = []
    objc_surface: list[dict] = []
    public_functions: list[dict] = []
    internal_protocols: list[dict] = []
    shared_total = 0

    for f in swift_files:
        result = extract_from_file(f)
        # Re-anchor file paths so they're module-relative for cross-checkout stability.
        rel_to_module = f.relative_to(module_dir).as_posix()
        for entry in result["public_types"]:
            entry["file"] = rel_to_module
            public_types.append(entry)
        for entry in result["objc_surface"]:
            entry["file"] = rel_to_module
            objc_surface.append(entry)
        for entry in result["public_functions"]:
            entry["file"] = rel_to_module
            public_functions.append(entry)
        for entry in result["internal_protocols"]:
            entry["file"] = rel_to_module
            internal_protocols.append(entry)
        shared_total += result["shared_singleton_reads"]

    # Stable sort for deterministic diffs.
    def sort_key(d: dict) -> tuple:
        return (d.get("name", ""), d.get("file", ""), d.get("line", 0))

    public_types.sort(key=sort_key)
    objc_surface.sort(key=sort_key)
    public_functions.sort(key=sort_key)
    internal_protocols.sort(key=sort_key)

    return {
        "module": module_dir.name,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "file_count": len(swift_files),
        "shared_singleton_reads": shared_total,
        "public_types": public_types,
        "objc_surface": objc_surface,
        "public_functions": public_functions,
        "internal_protocols": internal_protocols,
    }


# ---------------------------------------------------------------------------
# IO


def write_contract(contract: dict, output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"{contract['module']}.json"
    payload = json.dumps(contract, indent=2, sort_keys=False) + "\n"
    path.write_text(payload, encoding="utf-8")
    return path


def diff_contracts(existing: dict, fresh: dict) -> bool:
    """True if the substantive surface differs (ignoring `generated_at`)."""
    keys = (
        "module",
        "file_count",
        "shared_singleton_reads",
        "public_types",
        "objc_surface",
        "public_functions",
        "internal_protocols",
    )
    for k in keys:
        if existing.get(k) != fresh.get(k):
            return True
    return False


# ---------------------------------------------------------------------------
# CLI


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--module", help="Scan one module by name (e.g. SignInLogic)")
    parser.add_argument(
        "--check",
        action="store_true",
        help="Compare to existing files; exit 1 if any contract differs.",
    )
    parser.add_argument(
        "--output-dir",
        default=str(DEFAULT_OUTPUT_DIR),
        help=f"Output dir for contract JSONs (default: {DEFAULT_OUTPUT_DIR})",
    )
    args = parser.parse_args(argv)

    output_dir = Path(args.output_dir)

    if not PALACE_DIR.is_dir():
        print(f"error: Palace/ directory not found at {PALACE_DIR}", file=sys.stderr)
        return 2

    modules = discover_modules(PALACE_DIR)
    if args.module:
        modules = [m for m in modules if m.name == args.module]
        if not modules:
            print(f"error: module {args.module!r} not found under Palace/", file=sys.stderr)
            return 2

    drifted: list[str] = []
    written: list[str] = []

    for module_dir in modules:
        contract = build_contract(module_dir)

        if args.check:
            target = output_dir / f"{contract['module']}.json"
            if not target.exists():
                drifted.append(contract["module"] + " (missing)")
                continue
            try:
                existing = json.loads(target.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                drifted.append(contract["module"] + " (corrupt)")
                continue
            if diff_contracts(existing, contract):
                drifted.append(contract["module"])
        else:
            path = write_contract(contract, output_dir)
            written.append(path.name)

    if args.check:
        if drifted:
            print(
                "Contract drift detected in module(s): "
                + ", ".join(drifted)
                + "\nRun: python3 scripts/export-module-contracts.py",
                file=sys.stderr,
            )
            return 1
        print(f"All {len(modules)} module contracts up to date.")
        return 0

    print(f"Wrote {len(written)} contract(s) to {output_dir}")
    for name in written:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
