#!/usr/bin/env python3
"""
wire_orphan_tests.py — wire orphan test files into the PalaceTests Sources
build phase.

The Palace project has 42 test files that exist on disk and have
PBXFileReference + PBXGroup entries (so they show in the Xcode navigator)
but are NOT in the PalaceTests target's PBXSourcesBuildPhase. They have
been silently dead code — none of their tests run, none of their assertions
fire, none of their coverage counts.

This script:
  1. Reads /tmp/orphans.txt (one filename per line, basenames)
  2. For each, finds its existing PBXFileReference ID in project.pbxproj
  3. Generates a deterministic PBXBuildFile ID
  4. Appends new PBXBuildFile entries
  5. Appends new entries to the PalaceTests Sources build phase files = ( ... )

Idempotent: re-running with the same orphans is a no-op (skips files that
are already wired).
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

PBXPROJ = "/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj/project.pbxproj"
ORPHANS_FILE = "/tmp/orphans.txt"
TESTS_SOURCES_ID = "2D2B476E1D08F807007F7764"


def gen_id(seed: str) -> str:
    return hashlib.sha256(seed.encode()).hexdigest()[:24].upper()


def main() -> int:
    with open(ORPHANS_FILE) as f:
        orphans = [ln.strip() for ln in f if ln.strip()]
    print(f"Orphans to wire: {len(orphans)}")

    with open(PBXPROJ) as f:
        content = f.read()

    # Locate the existing file ref ID for each orphan basename
    file_ref_re = re.compile(
        r'^\s*([A-F0-9]{24})\s+/\*\s+(\S+\.swift)\s+\*/\s+=\s+\{isa = PBXFileReference;',
        re.MULTILINE,
    )
    fileref_by_name: dict[str, str] = {}
    for m in file_ref_re.finditer(content):
        name = m.group(2)
        if name in orphans and name not in fileref_by_name:
            fileref_by_name[name] = m.group(1)

    missing = [n for n in orphans if n not in fileref_by_name]
    if missing:
        print(f"WARN: {len(missing)} orphans have no existing PBXFileReference (skipped):")
        for n in missing:
            print(f"  - {n}")

    # Idempotency: skip files already in the Sources phase
    # Find the Sources phase block
    phase_match = re.search(
        r"(" + TESTS_SOURCES_ID + r"\s+/\*\s+Sources\s+\*/\s+=\s+\{.*?files\s+=\s+\(\n)(.*?)(\n\s*\);)",
        content,
        re.DOTALL,
    )
    if not phase_match:
        print("ERROR: PalaceTests Sources phase not found", file=sys.stderr)
        return 2

    phase_prefix = phase_match.group(1)
    phase_body = phase_match.group(2)
    phase_suffix = phase_match.group(3)

    already_in_phase: set[str] = set()
    for m in re.finditer(r"/\*\s+(\S+\.swift)\s+in Sources\s+\*/", phase_body):
        already_in_phase.add(m.group(1))

    to_add = [n for n in fileref_by_name if n not in already_in_phase]
    skipped = [n for n in fileref_by_name if n in already_in_phase]
    if skipped:
        print(f"Already in Sources phase ({len(skipped)}, skipped)")
    print(f"Will wire: {len(to_add)}")
    if not to_add:
        print("nothing to do")
        return 0

    # Build the new PBXBuildFile entries
    new_buildfile_lines: list[str] = []
    new_phase_entries: list[str] = []
    for name in sorted(to_add):
        fileref_id = fileref_by_name[name]
        bf_id = gen_id(f"BUILDFILE_PALACETESTS_ORPHAN_{name}_{fileref_id}")
        new_buildfile_lines.append(
            f"\t\t{bf_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref_id} /* {name} */; }};\n"
        )
        new_phase_entries.append(f"\t\t\t\t{bf_id} /* {name} in Sources */,\n")

    # Insert new PBXBuildFile entries right after "/* Begin PBXBuildFile section */"
    bf_section = "/* Begin PBXBuildFile section */"
    bf_idx = content.find(bf_section)
    if bf_idx == -1:
        print("ERROR: PBXBuildFile section header not found", file=sys.stderr)
        return 2
    insert_pos = content.find("\n", bf_idx) + 1
    new_content = content[:insert_pos] + "".join(new_buildfile_lines) + content[insert_pos:]

    # Now patch the Sources phase: append new entries to phase_body
    # We need to find the (now-shifted) phase block in new_content
    phase_match2 = re.search(
        r"(" + TESTS_SOURCES_ID + r"\s+/\*\s+Sources\s+\*/\s+=\s+\{.*?files\s+=\s+\(\n)(.*?)(\n\s*\);)",
        new_content,
        re.DOTALL,
    )
    if not phase_match2:
        print("ERROR: phase re-find failed", file=sys.stderr)
        return 2
    new_phase_body = phase_match2.group(2) + "".join(new_phase_entries).rstrip("\n")
    new_content = (
        new_content[: phase_match2.start()]
        + phase_match2.group(1)
        + new_phase_body
        + phase_match2.group(3)
        + new_content[phase_match2.end() :]
    )

    with open(PBXPROJ, "w") as f:
        f.write(new_content)

    print(f"Wired {len(to_add)} files into PalaceTests Sources phase")
    print("Run: xcodebuild -project Palace.xcodeproj -scheme Palace -destination ... build-for-testing")
    return 0


if __name__ == "__main__":
    sys.exit(main())
