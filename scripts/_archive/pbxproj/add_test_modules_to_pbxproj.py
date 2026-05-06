#!/usr/bin/env python3
"""
Wire newly-created PalaceTests subdirectories (Chaos, Security, Property, Fuzz)
into Palace.xcodeproj. Modeled after add_files_to_pbxproj.py.

- Adds .swift files to the PalaceTests Sources build phase
- Adds the Fuzz/Corpus folder as a folder-reference in the PalaceTests Resources phase
- Creates new PBXGroup entries under the PalaceTests group for Chaos/Security/Property/Fuzz
"""

import hashlib
import os

PBXPROJ_PATH = "/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj/project.pbxproj"
REPO_ROOT = "/Users/mauricework/PalaceProject/ios-core"

TESTS_SOURCES_ID = "2D2B476E1D08F807007F7764"
TESTS_RESOURCES_ID = "2D2B47701D08F807007F7764"
PALACETESTS_GROUP_ID = "A823D82F192BABA400B55DE2"

# (subdirectory under PalaceTests/, group display name)
NEW_GROUPS = [
    ("Chaos", "Chaos"),
    ("Security", "Security"),
    ("Property", "Property"),
    ("Fuzz", "Fuzz"),
]

# Resource entries (folder references): (relative path under PalaceTests/, group it lives in)
FOLDER_REFS = [
    ("Fuzz/Corpus", "Fuzz"),
]


def gen_id(seed: str) -> str:
    return hashlib.sha256(seed.encode()).hexdigest()[:24].upper()


def fname(p: str) -> str:
    return os.path.basename(p)


def discover_swift_files():
    """Walk PalaceTests/{Chaos,Security,Property,Fuzz} and return list of (relpath, subgroup)."""
    out = []
    for sub, _ in NEW_GROUPS:
        d = os.path.join(REPO_ROOT, "PalaceTests", sub)
        if not os.path.isdir(d):
            continue
        for entry in sorted(os.listdir(d)):
            if entry.endswith(".swift"):
                out.append((f"PalaceTests/{sub}/{entry}", sub))
    return out


def find_children_open_paren(lines, group_id):
    group_start = None
    for i, line in enumerate(lines):
        if group_id in line and "= {" in line:
            for j in range(i + 1, min(i + 5, len(lines))):
                if "isa = PBXGroup" in lines[j]:
                    group_start = i
                    break
            if group_start is not None:
                break
    if group_start is None:
        return None
    for i in range(group_start, min(group_start + 10, len(lines))):
        if "children = (" in lines[i]:
            return i + 1
    return None


def find_files_open_paren(lines, phase_id):
    phase_start = None
    for i, line in enumerate(lines):
        if phase_id in line and "= {" in line:
            phase_start = i
            break
    if phase_start is None:
        return None
    for i in range(phase_start, min(phase_start + 10, len(lines))):
        if "files = (" in lines[i]:
            return i + 1
    return None


def main():
    with open(PBXPROJ_PATH, "r") as f:
        lines = f.readlines()

    swift_files = discover_swift_files()
    if not swift_files:
        print("No .swift files discovered. Nothing to do.")
        return

    # Idempotency: if any of these files are already referenced, abort.
    for relpath, _ in swift_files:
        fn = fname(relpath)
        if any(f"/* {fn} */ = {{isa = PBXFileReference" in line for line in lines):
            print(f"ALREADY PRESENT: {relpath} (skip the whole run)")
            return

    # Build groups: group_id per subdir
    group_ids = {}
    for sub, name in NEW_GROUPS:
        group_ids[sub] = gen_id(f"GROUP_PalaceTests/{sub}")

    file_ref_lines = []
    build_file_lines = []
    test_source_lines = []
    test_resource_lines = []

    # Track children per group: subdir -> [(file_ref_id, filename)]
    group_children = {sub: [] for sub, _ in NEW_GROUPS}

    # Process Swift files
    for relpath, sub in swift_files:
        fn = fname(relpath)
        file_ref_id = gen_id(f"FILEREF_{relpath}")
        bf_id = gen_id(f"BUILDFILE_TESTS_{relpath}")

        file_ref_lines.append(
            f'\t\t{file_ref_id} /* {fn} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fn}; sourceTree = "<group>"; }};\n'
        )
        build_file_lines.append(
            f'\t\t{bf_id} /* {fn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {fn} */; }};\n'
        )
        test_source_lines.append(f'\t\t\t\t{bf_id} /* {fn} in Sources */,\n')
        group_children[sub].append((file_ref_id, fn))

    # Process folder references (Fuzz/Corpus)
    for rel_under_tests, parent_sub in FOLDER_REFS:
        full_rel = f"PalaceTests/{rel_under_tests}"
        if not os.path.isdir(os.path.join(REPO_ROOT, full_rel)):
            print(f"Folder not found, skipping: {full_rel}")
            continue
        folder_name = os.path.basename(rel_under_tests)
        ref_id = gen_id(f"FOLDERREF_{full_rel}")
        bf_id = gen_id(f"BUILDFILE_RES_{full_rel}")
        file_ref_lines.append(
            f'\t\t{ref_id} /* {folder_name} */ = {{isa = PBXFileReference; lastKnownFileType = folder; path = {folder_name}; sourceTree = "<group>"; }};\n'
        )
        build_file_lines.append(
            f'\t\t{bf_id} /* {folder_name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {folder_name} */; }};\n'
        )
        test_resource_lines.append(f'\t\t\t\t{bf_id} /* {folder_name} in Resources */,\n')
        group_children[parent_sub].append((ref_id, folder_name))

    # Build new group entries
    group_entry_lines = []
    for sub, name in NEW_GROUPS:
        gid = group_ids[sub]
        children_lines = [f'\t\t\t\t{cid} /* {cn} */,\n' for cid, cn in group_children[sub]]
        entry = (
            f'\t\t{gid} /* {name} */ = {{\n'
            f'\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = (\n'
            + "".join(children_lines)
            + f'\t\t\t);\n'
            f'\t\t\tpath = {name};\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f'\t\t}};\n'
        )
        group_entry_lines.append(entry)

    # Insertion list (we apply bottom-to-top so indices remain valid)
    insertions = []

    # PBXBuildFile section
    for i, line in enumerate(lines):
        if "/* Begin PBXBuildFile section */" in line:
            insertions.append((i + 1, sorted(build_file_lines)))
            break

    # PBXFileReference section
    for i, line in enumerate(lines):
        if "/* Begin PBXFileReference section */" in line:
            insertions.append((i + 1, sorted(file_ref_lines)))
            break

    # PBXGroup section: insert new group entries before "End PBXGroup section"
    for i, line in enumerate(lines):
        if "/* End PBXGroup section */" in line:
            insertions.append((i, group_entry_lines))
            break

    # Add new group ids to the existing PalaceTests group's children
    idx = find_children_open_paren(lines, PALACETESTS_GROUP_ID)
    if idx is None:
        raise SystemExit("Could not locate PalaceTests group children list")
    new_parent_children = [
        f'\t\t\t\t{group_ids[sub]} /* {name} */,\n' for sub, name in NEW_GROUPS
    ]
    insertions.append((idx, new_parent_children))

    # Add to Sources build phase
    idx = find_files_open_paren(lines, TESTS_SOURCES_ID)
    if idx is None:
        raise SystemExit("Could not locate PalaceTests Sources files list")
    insertions.append((idx, test_source_lines))

    # Add to Resources build phase
    if test_resource_lines:
        idx = find_files_open_paren(lines, TESTS_RESOURCES_ID)
        if idx is None:
            raise SystemExit("Could not locate PalaceTests Resources files list")
        insertions.append((idx, test_resource_lines))

    # Apply insertions bottom-up
    insertions.sort(key=lambda x: x[0], reverse=True)
    for idx, new_lines in insertions:
        for j, nl in enumerate(new_lines):
            lines.insert(idx + j, nl)

    with open(PBXPROJ_PATH, "w") as f:
        f.writelines(lines)

    print(f"Added {len(swift_files)} Swift files across {len(NEW_GROUPS)} new groups.")
    print(f"Added {len(test_resource_lines)} folder references.")


if __name__ == "__main__":
    main()
