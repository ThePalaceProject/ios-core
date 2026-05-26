#!/usr/bin/env python3
"""
Remove duplicate entries in PBXSourcesBuildPhase sections of a pbxproj file.
Also removes (null) build file entries.
"""

import re
import sys

def fix_pbxproj_duplicates(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    lines = content.split('\n')
    result = []
    in_sources_phase = False
    in_files_list = False
    seen_in_phase = set()
    removed_count = 0
    null_count = 0
    brace_depth = 0

    i = 0
    while i < len(lines):
        line = lines[i]

        # Detect start of a Sources build phase block
        if 'isa = PBXSourcesBuildPhase;' in line:
            in_sources_phase = True
            seen_in_phase = set()
            brace_depth = 0
            result.append(line)
            i += 1
            continue

        if in_sources_phase:
            # Track files list
            if 'files = (' in line:
                in_files_list = True
                result.append(line)
                i += 1
                continue

            if in_files_list:
                stripped = line.strip()

                # End of files list
                if stripped == ');':
                    in_files_list = False
                    result.append(line)
                    i += 1
                    continue

                # Check for (null) entries
                if '(null) in Sources' in line:
                    null_count += 1
                    print(f"  Removing (null) entry at line {i + 1}")
                    i += 1
                    continue

                # Extract the build file ID
                match = re.match(r'(\w+)\s+/\*', stripped)
                if match:
                    build_file_id = match.group(1)
                    if build_file_id in seen_in_phase:
                        removed_count += 1
                        print(f"  Removing duplicate: {stripped.rstrip(',')} at line {i + 1}")
                        i += 1
                        continue
                    seen_in_phase.add(build_file_id)

            # Detect end of the build phase block
            if line.strip() == '};' and not in_files_list:
                in_sources_phase = False

        result.append(line)
        i += 1

    if removed_count > 0 or null_count > 0:
        with open(filepath, 'w') as f:
            f.write('\n'.join(result))
        print(f"\nRemoved {removed_count} duplicate(s) and {null_count} null entry/entries.")
    else:
        print("No duplicates or null entries found.")

    return removed_count + null_count

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python3 fix_pbxproj_duplicates.py <path/to/project.pbxproj>")
        sys.exit(1)

    filepath = sys.argv[1]
    changes = fix_pbxproj_duplicates(filepath)
    sys.exit(0 if changes >= 0 else 1)
