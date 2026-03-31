#!/usr/bin/env python3
"""
Fix incomplete pbxproj entries for new feature files.

Scans specified directories for .swift files and ensures each has:
- PBXFileReference entry
- PBXBuildFile entries (2 for main sources, 1 for test sources)
- Presence in correct PBXSourcesBuildPhase sections
"""

import os
import re
import hashlib
import shutil
import subprocess
import sys

PROJ_ROOT = "/Users/mauricework/PalaceProject/ios-core"
PBXPROJ = os.path.join(PROJ_ROOT, "Palace.xcodeproj/project.pbxproj")

# Build phase IDs
PALACE_SOURCES = "A823D809192BABA400B55DE2"
NODRM_SOURCES = "73EB0A6425821DF4006BC997"
TEST_SOURCES = "2D2B476E1D08F807007F7764"

# Directories to scan
MAIN_DIRS = [
    "Palace/Discovery",
    "Palace/Stats",
    "Palace/Reader2/Typography",
    "Palace/Audiobooks/CarMode",
    "Palace/Social",
    "Palace/Platform",
]
TEST_DIRS = [
    "PalaceTests/Discovery",
    "PalaceTests/Stats",
    "PalaceTests/Reader2/Typography",
    "PalaceTests/Audiobooks/CarMode",
    "PalaceTests/Social",
    "PalaceTests/Platform",
]


def find_swift_files(directories):
    """Find all .swift files in the given directories."""
    files = []
    for d in directories:
        full = os.path.join(PROJ_ROOT, d)
        if not os.path.isdir(full):
            continue
        for root, _, fnames in os.walk(full):
            for f in fnames:
                if f.endswith(".swift"):
                    rel = os.path.relpath(os.path.join(root, f), PROJ_ROOT)
                    files.append((f, rel))
    return files


def generate_id(seed, existing_ids):
    """Generate a unique 24-char hex ID."""
    counter = 0
    while True:
        h = hashlib.sha256(f"{seed}_{counter}".encode()).hexdigest()
        uid = h[:24].upper()
        if uid not in existing_ids:
            existing_ids.add(uid)
            return uid
        counter += 1


def main():
    # Back up
    backup = PBXPROJ + ".pre-fix-backup"
    shutil.copy2(PBXPROJ, backup)
    print(f"Backed up to {backup}")

    with open(PBXPROJ, "r") as f:
        content = f.read()
    lines = content.split("\n")

    # Collect all existing IDs
    existing_ids = set(re.findall(r'\b([0-9A-F]{24})\b', content))

    # Find all swift files
    main_files = find_swift_files(MAIN_DIRS)
    test_files = find_swift_files(TEST_DIRS)

    print(f"Found {len(main_files)} main source files, {len(test_files)} test files")

    # Track what we need to add
    new_file_refs = []       # (id, filename, path)
    new_build_files = []     # (id, fileref_id, filename)
    new_phase_entries = {}   # phase_id -> [(build_file_id, filename)]

    # For each phase, init the list
    for phase_id in [PALACE_SOURCES, NODRM_SOURCES, TEST_SOURCES]:
        new_phase_entries[phase_id] = []

    stats = {
        "file_refs_added": 0,
        "build_files_added": 0,
        "phase_entries_added": 0,
        "files_already_complete": 0,
    }

    def process_file(filename, rel_path, is_test):
        """Process a single file, determining what entries are missing."""
        # Check for PBXFileReference
        # Pattern: HEXID /* filename */ = {isa = PBXFileReference; ...
        fileref_pattern = re.compile(
            r'([0-9A-F]{24})\s*/\*\s*' + re.escape(filename) + r'\s*\*/\s*=\s*\{isa\s*=\s*PBXFileReference'
        )
        fileref_match = fileref_pattern.search(content)

        if fileref_match:
            fileref_id = fileref_match.group(1)
        else:
            # Need to add PBXFileReference
            fileref_id = generate_id(f"fileref_{rel_path}", existing_ids)
            new_file_refs.append((fileref_id, filename, rel_path))
            stats["file_refs_added"] += 1

        # Check for PBXBuildFile entries referencing this fileref
        buildfile_pattern = re.compile(
            r'([0-9A-F]{24})\s*/\*\s*' + re.escape(filename) + r'\s+in\s+Sources\s*\*/\s*=\s*\{isa\s*=\s*PBXBuildFile;\s*fileRef\s*=\s*' + re.escape(fileref_id)
        )
        buildfile_matches = buildfile_pattern.findall(content)
        existing_buildfile_ids = set(buildfile_matches)

        if is_test:
            needed_phases = [TEST_SOURCES]
            needed_count = 1
        else:
            needed_phases = [PALACE_SOURCES, NODRM_SOURCES]
            needed_count = 2

        # Check which phases already have this file
        phases_with_file = []
        for phase_id in needed_phases:
            # Find the phase section and check if any buildfile for this file is in it
            phase_pattern = re.compile(
                r'([0-9A-F]{24})\s*/\*\s*' + re.escape(filename) + r'\s+in\s+Sources\s*\*/'
            )
            # Find the phase section boundaries
            phase_start_pattern = f"{phase_id} /* Sources */ = {{"
            phase_idx = content.find(phase_start_pattern)
            if phase_idx == -1:
                continue
            phase_end = content.find(");", phase_idx)
            phase_section = content[phase_idx:phase_end]

            found_in_phase = phase_pattern.search(phase_section)
            if found_in_phase:
                phases_with_file.append(phase_id)

        # Determine missing build files and phase entries
        missing_phases = [p for p in needed_phases if p not in phases_with_file]

        if not missing_phases and len(existing_buildfile_ids) >= needed_count:
            stats["files_already_complete"] += 1
            return

        for phase_id in missing_phases:
            # Check if there's an existing buildfile not yet in the phase
            # If buildfile count < needed, create a new one
            bf_id = generate_id(f"buildfile_{phase_id}_{rel_path}", existing_ids)
            new_build_files.append((bf_id, fileref_id, filename))
            new_phase_entries[phase_id].append((bf_id, filename))
            stats["build_files_added"] += 1
            stats["phase_entries_added"] += 1

    # Process all files
    for filename, rel_path in main_files:
        process_file(filename, rel_path, is_test=False)

    for filename, rel_path in test_files:
        process_file(filename, rel_path, is_test=True)

    if stats["file_refs_added"] == 0 and stats["build_files_added"] == 0:
        print("All files already have complete entries. Nothing to do.")
        return

    # Now modify the file
    lines = content.split("\n")

    # 1. Add PBXFileReference entries (before "/* End PBXFileReference section */")
    if new_file_refs:
        end_fileref_line = None
        for i, line in enumerate(lines):
            if "/* End PBXFileReference section */" in line:
                end_fileref_line = i
                break

        if end_fileref_line is None:
            print("ERROR: Could not find PBXFileReference section end")
            sys.exit(1)

        ref_lines = []
        for fid, fname, fpath in sorted(new_file_refs, key=lambda x: x[1]):
            ref_lines.append(
                f'\t\t{fid} /* {fname} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fname}; sourceTree = "<group>"; }};'
            )

        for j, rl in enumerate(ref_lines):
            lines.insert(end_fileref_line + j, rl)
        # Adjust line numbers for subsequent insertions
        offset1 = len(ref_lines)
    else:
        offset1 = 0

    # 2. Add PBXBuildFile entries (before "/* End PBXBuildFile section */")
    if new_build_files:
        end_buildfile_line = None
        for i, line in enumerate(lines):
            if "/* End PBXBuildFile section */" in line:
                end_buildfile_line = i
                break

        if end_buildfile_line is None:
            print("ERROR: Could not find PBXBuildFile section end")
            sys.exit(1)

        bf_lines = []
        for bfid, frid, fname in sorted(new_build_files, key=lambda x: x[2]):
            bf_lines.append(
                f'\t\t{bfid} /* {fname} in Sources */ = {{isa = PBXBuildFile; fileRef = {frid} /* {fname} */; }};'
            )

        for j, bl in enumerate(bf_lines):
            lines.insert(end_buildfile_line + j, bl)
        offset2 = len(bf_lines)
    else:
        offset2 = 0

    # 3. Add entries to PBXSourcesBuildPhase sections
    # Find each phase's closing ");" and insert before it
    for phase_id, entries in new_phase_entries.items():
        if not entries:
            continue

        # Find the phase section
        phase_marker = f"{phase_id} /* Sources */ = {{"
        phase_line = None
        for i, line in enumerate(lines):
            if phase_marker in line:
                phase_line = i
                break

        if phase_line is None:
            print(f"ERROR: Could not find phase {phase_id}")
            continue

        # Find the ");" closing the files list
        files_end = None
        for i in range(phase_line, len(lines)):
            if lines[i].strip() == ");":
                files_end = i
                break

        if files_end is None:
            print(f"ERROR: Could not find end of files list for phase {phase_id}")
            continue

        phase_lines = []
        for bfid, fname in sorted(entries, key=lambda x: x[1]):
            phase_lines.append(f"\t\t\t\t{bfid} /* {fname} in Sources */,")

        for j, pl in enumerate(phase_lines):
            lines.insert(files_end + j, pl)

    # Write back
    with open(PBXPROJ, "w") as f:
        f.write("\n".join(lines))

    print(f"\n=== Summary ===")
    print(f"PBXFileReference entries added: {stats['file_refs_added']}")
    print(f"PBXBuildFile entries added:     {stats['build_files_added']}")
    print(f"Build phase entries added:      {stats['phase_entries_added']}")
    print(f"Files already complete:         {stats['files_already_complete']}")
    print()

    # Print details
    if new_file_refs:
        print("New PBXFileReference entries:")
        for fid, fname, fpath in sorted(new_file_refs, key=lambda x: x[1]):
            print(f"  {fname} ({fid})")
        print()

    if new_build_files:
        print("New PBXBuildFile entries:")
        for bfid, frid, fname in sorted(new_build_files, key=lambda x: x[2]):
            print(f"  {fname} -> build={bfid}, fileRef={frid}")
        print()

    for phase_id, entries in new_phase_entries.items():
        if entries:
            phase_name = {
                PALACE_SOURCES: "Palace",
                NODRM_SOURCES: "Palace-noDRM",
                TEST_SOURCES: "PalaceTests",
            }[phase_id]
            print(f"Added to {phase_name} Sources build phase:")
            for bfid, fname in sorted(entries, key=lambda x: x[1]):
                print(f"  {fname}")
            print()

    # Validate
    print("Validating with plutil...")
    result = subprocess.run(
        ["plutil", "-lint", PBXPROJ],
        capture_output=True, text=True
    )
    print(result.stdout.strip())
    if result.returncode != 0:
        print(f"VALIDATION FAILED: {result.stderr}")
        print("Restoring backup...")
        shutil.copy2(backup, PBXPROJ)
        print("Backup restored.")
        sys.exit(1)
    else:
        print("Validation passed!")


if __name__ == "__main__":
    main()
