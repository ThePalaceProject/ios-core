#!/usr/bin/env python3
"""
wire_untracked_tests.py — wire fully-untracked test files (no PBXFileReference,
no PBXGroup entry, no PBXBuildFile entry, no Sources-phase entry) into the
PalaceTests target.

The 5 files this script handles:
  PalaceTests/Accessibility/BookImageViewAccessibilityTests.swift  (3 tests)
  PalaceTests/Accessibility/PDFAccessibilityToolbarTests.swift     (4 tests)
  PalaceTests/Accessibility/TPPBookAccessibilityLabelTests.swift   (8 tests)
  PalaceTests/LCP/LCPSessionOrphaningTests.swift                   (7 tests)
  PalaceTests/Network/URLResponseNYPLTests.swift                   (14 tests)

Total: 36 test methods that have never been compiled.

For each file, the script:
  1. Creates a new PBXFileReference (deterministic ID)
  2. Adds it to the appropriate parent PBXGroup's children list
  3. Creates a new PBXBuildFile
  4. Adds it to the PalaceTests Sources build phase

Idempotent: skips files whose PBXFileReference already exists.
"""

from __future__ import annotations
import hashlib
import re
import sys

PBXPROJ = "/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj/project.pbxproj"
TESTS_SOURCES_ID = "2D2B476E1D08F807007F7764"

# Files to wire: (basename, parent_group_id, group_label_for_diagnostics)
FILES = [
    ("BookImageViewAccessibilityTests.swift", "FDF8747DDC245E6180FB8A81", "PalaceTests/Accessibility"),
    ("PDFAccessibilityToolbarTests.swift",     "FDF8747DDC245E6180FB8A81", "PalaceTests/Accessibility"),
    ("TPPBookAccessibilityLabelTests.swift",   "FDF8747DDC245E6180FB8A81", "PalaceTests/Accessibility"),
    ("LCPSessionOrphaningTests.swift",         "52452B48CF3C52B395874F52", "PalaceTests/LCP"),
    ("URLResponseNYPLTests.swift",             "0DFA52843241739C5213AD8F", "PalaceTests/Network"),
]


def gen_id(seed: str) -> str:
    return hashlib.sha256(seed.encode()).hexdigest()[:24].upper()


def main() -> int:
    with open(PBXPROJ) as f:
        content = f.read()

    new_filerefs = []
    new_buildfiles = []
    new_phase_lines = []
    additions_per_group: dict[str, list[tuple[str, str]]] = {}

    for basename, group_id, label in FILES:
        # Idempotency check
        if f"/* {basename} */" in content:
            print(f"SKIP (already present): {basename}")
            continue

        fileref_id = gen_id(f"FILEREF_UNTRACKED_{basename}")
        buildfile_id = gen_id(f"BUILDFILE_UNTRACKED_{basename}")

        new_filerefs.append(
            f'\t\t{fileref_id} /* {basename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {basename}; sourceTree = "<group>"; }};\n'
        )
        new_buildfiles.append(
            f'\t\t{buildfile_id} /* {basename} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref_id} /* {basename} */; }};\n'
        )
        new_phase_lines.append(f'\t\t\t\t{buildfile_id} /* {basename} in Sources */,\n')
        additions_per_group.setdefault(group_id, []).append((fileref_id, basename))
        print(f"WIRING: {basename}  group={label}")

    if not new_filerefs:
        print("nothing to do")
        return 0

    # 1. Insert PBXFileReference entries after section header
    bf_section = "/* Begin PBXBuildFile section */"
    bf_idx = content.find(bf_section)
    if bf_idx == -1:
        print("ERROR: PBXBuildFile section not found", file=sys.stderr)
        return 2
    insert_at = content.find("\n", bf_idx) + 1
    content = content[:insert_at] + "".join(new_buildfiles) + content[insert_at:]

    fr_section = "/* Begin PBXFileReference section */"
    fr_idx = content.find(fr_section)
    if fr_idx == -1:
        print("ERROR: PBXFileReference section not found", file=sys.stderr)
        return 2
    insert_at = content.find("\n", fr_idx) + 1
    content = content[:insert_at] + "".join(new_filerefs) + content[insert_at:]

    # 2. Add file refs to each parent PBXGroup's children list
    for group_id, additions in additions_per_group.items():
        group_pat = re.compile(
            r"(" + group_id + r"\s+/\*[^*]*\*/\s+=\s+\{\s*isa\s+=\s+PBXGroup;\s*children\s+=\s+\(\n)(.*?)(\n\s*\);)",
            re.DOTALL,
        )
        m = group_pat.search(content)
        if not m:
            print(f"ERROR: group {group_id} not found", file=sys.stderr)
            return 2
        new_children = m.group(2)
        for fileref_id, basename in additions:
            new_children += f"\n\t\t\t\t{fileref_id} /* {basename} */,"
        content = content[: m.start()] + m.group(1) + new_children + m.group(3) + content[m.end():]

    # 3. Add build file refs to PalaceTests Sources build phase
    phase_pat = re.compile(
        r"(" + TESTS_SOURCES_ID + r"\s+/\*\s+Sources\s+\*/\s+=\s+\{.*?files\s+=\s+\(\n)(.*?)(\n\s*\);)",
        re.DOTALL,
    )
    m = phase_pat.search(content)
    if not m:
        print("ERROR: PalaceTests Sources phase not found", file=sys.stderr)
        return 2
    content = content[: m.start()] + m.group(1) + m.group(2) + "".join(new_phase_lines).rstrip("\n") + m.group(3) + content[m.end():]

    with open(PBXPROJ, "w") as f:
        f.write(content)

    print(f"Wired {len(new_filerefs)} previously-untracked test files into PalaceTests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
