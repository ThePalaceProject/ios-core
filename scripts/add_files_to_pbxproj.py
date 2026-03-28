#!/usr/bin/env python3
"""
Add 76 new Swift files to Palace.xcodeproj/project.pbxproj.
Adds PBXFileReference, PBXBuildFile, PBXGroup entries, and
wires them into the correct PBXSourcesBuildPhase sections.
"""

import hashlib
import os

PBXPROJ_PATH = "/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj/project.pbxproj"

# Target source build phase IDs
PALACE_SOURCES_ID = "A823D809192BABA400B55DE2"
NODERM_SOURCES_ID = "73EB0A6425821DF4006BC997"
TESTS_SOURCES_ID  = "2D2B476E1D08F807007F7764"

# Parent group IDs
AUDIOBOOKS_GROUP_ID = "21E7E07424FEA7C100189224"  # Palace/Audiobooks
READER2_GROUP_ID    = "73A22980240F26C6006B9EAD"  # Palace/Reader2
PALACE_GROUP_ID     = "A823D816192BABA400B55DE2"  # Palace/
PALACETESTS_GROUP_ID = "A823D82F192BABA400B55DE2"  # PalaceTests/
READER2_TESTS_GROUP_ID = "4850933FCAED50067CAF87EB"  # PalaceTests/Reader2

# Files for Palace + Palace-noDRM targets
MAIN_FILES = [
    "Palace/Audiobooks/CarMode/BluetoothCarModeDetector.swift",
    "Palace/Audiobooks/CarMode/CarModeChapterList.swift",
    "Palace/Audiobooks/CarMode/CarModeEntryButton.swift",
    "Palace/Audiobooks/CarMode/CarModeService.swift",
    "Palace/Audiobooks/CarMode/CarModeServiceProtocol.swift",
    "Palace/Audiobooks/CarMode/CarModeSleepTimerPicker.swift",
    "Palace/Audiobooks/CarMode/CarModeSpeedPicker.swift",
    "Palace/Audiobooks/CarMode/CarModeState.swift",
    "Palace/Audiobooks/CarMode/CarModeView.swift",
    "Palace/Audiobooks/CarMode/CarModeViewModel.swift",
    "Palace/Audiobooks/CarMode/PlaybackSpeed.swift",
    "Palace/Audiobooks/CarMode/SleepTimerOption.swift",
    "Palace/Discovery/DiscoveryTab.swift",
    "Palace/Discovery/Models/CrossLibrarySearchResponse.swift",
    "Palace/Discovery/Models/DiscoveryPrompt.swift",
    "Palace/Discovery/Models/DiscoveryRecommendation.swift",
    "Palace/Discovery/Models/LibrarySearchResult.swift",
    "Palace/Discovery/Services/ClaudeDiscoveryService.swift",
    "Palace/Discovery/Services/CrossLibrarySearchService.swift",
    "Palace/Discovery/Services/DiscoveryConfiguration.swift",
    "Palace/Discovery/Services/DiscoveryServiceProtocol.swift",
    "Palace/Discovery/Services/LocalDiscoveryFallback.swift",
    "Palace/Discovery/ViewModels/DiscoveryViewModel.swift",
    "Palace/Discovery/ViewModels/SearchResultsViewModel.swift",
    "Palace/Discovery/Views/CrossLibraryAvailabilityView.swift",
    "Palace/Discovery/Views/DiscoveryView.swift",
    "Palace/Discovery/Views/RecommendationCard.swift",
    "Palace/Discovery/Views/SearchResultsView.swift",
    "Palace/Reader2/Typography/FontFamily.swift",
    "Palace/Reader2/Typography/FontManager.swift",
    "Palace/Reader2/Typography/FontPickerView.swift",
    "Palace/Reader2/Typography/PresetCard.swift",
    "Palace/Reader2/Typography/ReaderTheme.swift",
    "Palace/Reader2/Typography/ReaderTypographyButton.swift",
    "Palace/Reader2/Typography/ReadingRulerView.swift",
    "Palace/Reader2/Typography/ThemePickerView.swift",
    "Palace/Reader2/Typography/TypographyPreset.swift",
    "Palace/Reader2/Typography/TypographyService.swift",
    "Palace/Reader2/Typography/TypographyServiceProtocol.swift",
    "Palace/Reader2/Typography/TypographySettings.swift",
    "Palace/Reader2/Typography/TypographySettingsView.swift",
    "Palace/Reader2/Typography/TypographySettingsViewModel.swift",
    "Palace/Stats/Models/Badge.swift",
    "Palace/Stats/Models/BadgeDefinition.swift",
    "Palace/Stats/Models/ReadingSession.swift",
    "Palace/Stats/Models/ReadingStats.swift",
    "Palace/Stats/Models/ReadingStreak.swift",
    "Palace/Stats/Services/BadgeService.swift",
    "Palace/Stats/Services/BadgeServiceProtocol.swift",
    "Palace/Stats/Services/ReadingSessionTracker.swift",
    "Palace/Stats/Services/ReadingStatsService.swift",
    "Palace/Stats/Services/ReadingStatsServiceProtocol.swift",
    "Palace/Stats/Services/ReadingStatsStore.swift",
    "Palace/Stats/ViewModels/BadgesViewModel.swift",
    "Palace/Stats/ViewModels/StatsViewModel.swift",
    "Palace/Stats/Views/BadgeDetailView.swift",
    "Palace/Stats/Views/BadgesView.swift",
    "Palace/Stats/Views/ReadingChartView.swift",
    "Palace/Stats/Views/StatsCardView.swift",
    "Palace/Stats/Views/StatsTab.swift",
    "Palace/Stats/Views/StatsView.swift",
    "Palace/Stats/Views/StreakView.swift",
]

# Files for PalaceTests target
TEST_FILES = [
    "PalaceTests/Audiobooks/CarMode/CarModeServiceTests.swift",
    "PalaceTests/Audiobooks/CarMode/CarModeViewModelTests.swift",
    "PalaceTests/Audiobooks/CarMode/SleepTimerTests.swift",
    "PalaceTests/Discovery/ClaudeDiscoveryServiceTests.swift",
    "PalaceTests/Discovery/CrossLibrarySearchServiceTests.swift",
    "PalaceTests/Discovery/DiscoveryViewModelTests.swift",
    "PalaceTests/Reader2/Typography/FontManagerTests.swift",
    "PalaceTests/Reader2/Typography/TypographyPresetTests.swift",
    "PalaceTests/Reader2/Typography/TypographyServiceTests.swift",
    "PalaceTests/Reader2/Typography/TypographySettingsViewModelTests.swift",
    "PalaceTests/Stats/BadgeServiceTests.swift",
    "PalaceTests/Stats/ReadingStatsServiceTests.swift",
    "PalaceTests/Stats/ReadingStatsStoreTests.swift",
    "PalaceTests/Stats/StatsViewModelTests.swift",
]


def gen_id(seed: str) -> str:
    """Generate a 24-char uppercase hex ID from a seed string."""
    return hashlib.sha256(seed.encode()).hexdigest()[:24].upper()


def fname(path: str) -> str:
    return os.path.basename(path)


def find_insert_after_line(lines, search_id, search_text):
    """Find the line containing search_id and search_text, return the index after it."""
    for i, line in enumerate(lines):
        if search_id in line and search_text in line:
            return i + 1
    return None


def find_children_open_paren(lines, group_id):
    """Find the line after 'children = (' inside the group with given ID.
    Returns the line index right after the opening paren."""
    # First find the line with the group ID
    group_start = None
    for i, line in enumerate(lines):
        if group_id in line and '= {' in line:
            # Check if this is a PBXGroup (look ahead for isa = PBXGroup)
            for j in range(i+1, min(i+5, len(lines))):
                if 'isa = PBXGroup' in lines[j]:
                    group_start = i
                    break
            if group_start is not None:
                break
    if group_start is None:
        return None
    # Now find 'children = (' within this group
    for i in range(group_start, min(group_start + 10, len(lines))):
        if 'children = (' in lines[i]:
            return i + 1
    return None


def find_files_open_paren(lines, phase_id):
    """Find the line after 'files = (' inside the build phase with given ID."""
    phase_start = None
    for i, line in enumerate(lines):
        if phase_id in line and '= {' in line:
            phase_start = i
            break
    if phase_start is None:
        return None
    for i in range(phase_start, min(phase_start + 10, len(lines))):
        if 'files = (' in lines[i]:
            return i + 1
    return None


# Build ref ID map
_ref_id_to_path = {}
for fpath in MAIN_FILES + TEST_FILES:
    frid = gen_id(f"FILEREF_{fpath}")
    _ref_id_to_path[frid] = fpath


def main():
    with open(PBXPROJ_PATH, "r") as f:
        lines = f.readlines()

    # Collect all data first, then do insertions from bottom to top
    # (so line indices don't shift)

    file_ref_lines = []
    build_file_lines = []
    palace_source_lines = []
    nodrm_source_lines = []
    test_source_lines = []

    # Groups: key = (parent_id, subpath) -> {id, name, path, children[], parent_id}
    new_groups = {}

    def get_or_create_group(parent_id, subpath, group_name):
        key = (parent_id, subpath)
        if key not in new_groups:
            gid = gen_id(f"GROUP_{subpath}")
            new_groups[key] = {
                "id": gid, "name": group_name, "path": group_name,
                "children": [], "parent_id": parent_id
            }
        return new_groups[key]["id"]

    # Process main files
    for fpath in MAIN_FILES:
        fn = fname(fpath)
        file_ref_id = gen_id(f"FILEREF_{fpath}")
        palace_bf_id = gen_id(f"BUILDFILE_PALACE_{fpath}")
        nodrm_bf_id = gen_id(f"BUILDFILE_NODRM_{fpath}")

        file_ref_lines.append(
            f'\t\t{file_ref_id} /* {fn} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fn}; sourceTree = "<group>"; }};\n'
        )
        build_file_lines.append(
            f'\t\t{palace_bf_id} /* {fn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {fn} */; }};\n'
        )
        build_file_lines.append(
            f'\t\t{nodrm_bf_id} /* {fn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {fn} */; }};\n'
        )
        palace_source_lines.append(f'\t\t\t\t{palace_bf_id} /* {fn} in Sources */,\n')
        nodrm_source_lines.append(f'\t\t\t\t{nodrm_bf_id} /* {fn} in Sources */,\n')

        parts = fpath.split("/")
        if parts[1] == "Audiobooks" and parts[2] == "CarMode":
            gid = get_or_create_group(AUDIOBOOKS_GROUP_ID, "Palace/Audiobooks/CarMode", "CarMode")
            new_groups[(AUDIOBOOKS_GROUP_ID, "Palace/Audiobooks/CarMode")]["children"].append(file_ref_id)
        elif parts[1] == "Reader2" and parts[2] == "Typography":
            gid = get_or_create_group(READER2_GROUP_ID, "Palace/Reader2/Typography", "Typography")
            new_groups[(READER2_GROUP_ID, "Palace/Reader2/Typography")]["children"].append(file_ref_id)
        elif parts[1] == "Discovery":
            disc_gid = get_or_create_group(PALACE_GROUP_ID, "Palace/Discovery", "Discovery")
            if len(parts) == 3:
                new_groups[(PALACE_GROUP_ID, "Palace/Discovery")]["children"].append(file_ref_id)
            else:
                subdir = parts[2]
                get_or_create_group(disc_gid, f"Palace/Discovery/{subdir}", subdir)
                new_groups[(disc_gid, f"Palace/Discovery/{subdir}")]["children"].append(file_ref_id)
        elif parts[1] == "Stats":
            stats_gid = get_or_create_group(PALACE_GROUP_ID, "Palace/Stats", "Stats")
            if len(parts) == 3:
                new_groups[(PALACE_GROUP_ID, "Palace/Stats")]["children"].append(file_ref_id)
            else:
                subdir = parts[2]
                get_or_create_group(stats_gid, f"Palace/Stats/{subdir}", subdir)
                new_groups[(stats_gid, f"Palace/Stats/{subdir}")]["children"].append(file_ref_id)

    # Process test files
    for fpath in TEST_FILES:
        fn = fname(fpath)
        file_ref_id = gen_id(f"FILEREF_{fpath}")
        test_bf_id = gen_id(f"BUILDFILE_TESTS_{fpath}")

        file_ref_lines.append(
            f'\t\t{file_ref_id} /* {fn} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fn}; sourceTree = "<group>"; }};\n'
        )
        build_file_lines.append(
            f'\t\t{test_bf_id} /* {fn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {fn} */; }};\n'
        )
        test_source_lines.append(f'\t\t\t\t{test_bf_id} /* {fn} in Sources */,\n')

        parts = fpath.split("/")
        if parts[1] == "Audiobooks" and parts[2] == "CarMode":
            ab_gid = get_or_create_group(PALACETESTS_GROUP_ID, "PalaceTests/Audiobooks", "Audiobooks")
            cm_gid = get_or_create_group(ab_gid, "PalaceTests/Audiobooks/CarMode", "CarMode")
            new_groups[(ab_gid, "PalaceTests/Audiobooks/CarMode")]["children"].append(file_ref_id)
        elif parts[1] == "Discovery":
            get_or_create_group(PALACETESTS_GROUP_ID, "PalaceTests/Discovery", "Discovery")
            new_groups[(PALACETESTS_GROUP_ID, "PalaceTests/Discovery")]["children"].append(file_ref_id)
        elif parts[1] == "Reader2" and parts[2] == "Typography":
            get_or_create_group(READER2_TESTS_GROUP_ID, "PalaceTests/Reader2/Typography", "Typography")
            new_groups[(READER2_TESTS_GROUP_ID, "PalaceTests/Reader2/Typography")]["children"].append(file_ref_id)
        elif parts[1] == "Stats":
            get_or_create_group(PALACETESTS_GROUP_ID, "PalaceTests/Stats", "Stats")
            new_groups[(PALACETESTS_GROUP_ID, "PalaceTests/Stats")]["children"].append(file_ref_id)

    # Build group entry lines
    group_entry_lines = []
    for key, ginfo in new_groups.items():
        # Collect sub-groups that are children of this group
        sub_groups = []
        for k2, g2 in new_groups.items():
            if g2["parent_id"] == ginfo["id"]:
                sub_groups.append((g2["id"], g2["name"]))

        children_lines = []
        for sg_id, sg_name in sub_groups:
            children_lines.append(f'\t\t\t\t{sg_id} /* {sg_name} */,\n')
        for cid in ginfo["children"]:
            cpath = _ref_id_to_path.get(cid, "")
            cn = os.path.basename(cpath) if cpath else cid
            children_lines.append(f'\t\t\t\t{cid} /* {cn} */,\n')

        entry = (
            f'\t\t{ginfo["id"]} /* {ginfo["name"]} */ = {{\n'
            f'\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = (\n'
            + ''.join(children_lines) +
            f'\t\t\t);\n'
            f'\t\t\tpath = {ginfo["path"]};\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f'\t\t}};\n'
        )
        group_entry_lines.append(entry)

    # Collect parent additions (new groups to add to existing parent groups' children)
    existing_parents = {AUDIOBOOKS_GROUP_ID, READER2_GROUP_ID, PALACE_GROUP_ID,
                        PALACETESTS_GROUP_ID, READER2_TESTS_GROUP_ID}
    parent_additions = {}
    for key, ginfo in new_groups.items():
        pid = ginfo["parent_id"]
        if pid in existing_parents:
            if pid not in parent_additions:
                parent_additions[pid] = []
            parent_additions[pid].append((ginfo["id"], ginfo["name"]))

    # Now perform all insertions. We work from bottom to top so indices stay valid.
    # Gather all insertion points first.

    insertions = []  # (line_index, lines_to_insert)

    # 1. PBXBuildFile section - insert after "/* Begin PBXBuildFile section */"
    for i, line in enumerate(lines):
        if '/* Begin PBXBuildFile section */' in line:
            insertions.append((i + 1, sorted(build_file_lines)))
            break

    # 2. PBXFileReference section
    for i, line in enumerate(lines):
        if '/* Begin PBXFileReference section */' in line:
            insertions.append((i + 1, sorted(file_ref_lines)))
            break

    # 3. PBXGroup section - insert new groups before "/* End PBXGroup section */"
    for i, line in enumerate(lines):
        if '/* End PBXGroup section */' in line:
            insertions.append((i, group_entry_lines))
            break

    # 4. Add group refs to existing parent groups' children
    for pid, children in parent_additions.items():
        idx = find_children_open_paren(lines, pid)
        if idx is not None:
            new_lines = [f'\t\t\t\t{cid} /* {cn} */,\n' for cid, cn in children]
            insertions.append((idx, new_lines))
        else:
            print(f"WARNING: Could not find children for parent group {pid}")

    # 5. Add to Sources build phases
    for phase_id, src_lines in [
        (PALACE_SOURCES_ID, palace_source_lines),
        (NODERM_SOURCES_ID, nodrm_source_lines),
        (TESTS_SOURCES_ID, test_source_lines),
    ]:
        idx = find_files_open_paren(lines, phase_id)
        if idx is not None:
            insertions.append((idx, src_lines))
        else:
            print(f"WARNING: Could not find Sources build phase {phase_id}")

    # Sort insertions by line index descending so we don't shift indices
    insertions.sort(key=lambda x: x[0], reverse=True)

    for idx, new_lines in insertions:
        for j, nl in enumerate(new_lines):
            lines.insert(idx + j, nl)

    with open(PBXPROJ_PATH, "w") as f:
        f.writelines(lines)

    print(f"Successfully added {len(MAIN_FILES)} main files and {len(TEST_FILES)} test files.")
    print(f"Created {len(new_groups)} new groups.")
    print(f"Performed {len(insertions)} insertion operations.")


if __name__ == "__main__":
    main()
