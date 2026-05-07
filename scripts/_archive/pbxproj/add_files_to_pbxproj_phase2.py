#!/usr/bin/env python3
"""
Add 88 new Swift files (Social, Platform, and new test files) to Palace.xcodeproj/project.pbxproj.
Adds PBXFileReference, PBXBuildFile, PBXGroup entries, and
wires them into the correct PBXSourcesBuildPhase sections.
"""

import hashlib
import os
import re

PBXPROJ_PATH = "/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj/project.pbxproj"

# Target source build phase IDs
PALACE_SOURCES_ID = "A823D809192BABA400B55DE2"
NODERM_SOURCES_ID = "73EB0A6425821DF4006BC997"
TESTS_SOURCES_ID  = "2D2B476E1D08F807007F7764"

# Existing parent group IDs
PALACE_GROUP_ID      = "A823D816192BABA400B55DE2"  # Palace/
PALACETESTS_GROUP_ID = "A823D82F192BABA400B55DE2"  # PalaceTests/

# Existing test sub-group IDs
TESTS_AUDIOBOOKS_GROUP_ID = "78D761BECF1895ABCF338A3A"  # PalaceTests/Audiobooks
TESTS_CARMODE_GROUP_ID    = "00A47EFA42C356655C47CFAF"  # PalaceTests/Audiobooks/CarMode
TESTS_DISCOVERY_GROUP_ID  = "AB8405417D83EA32553756F8"  # PalaceTests/Discovery
TESTS_STATS_GROUP_ID      = "83FDAE786C460F0C949A083F"  # PalaceTests/Stats
TESTS_READER2_GROUP_ID    = "4850933FCAED50067CAF87EB"  # PalaceTests/Reader2
TESTS_TYPOGRAPHY_GROUP_ID = "CEA6C48C0DE6EFA7DA35EE74"  # PalaceTests/Reader2/Typography

# Files for Palace + Palace-noDRM targets
MAIN_FILES = [
    "Palace/Social/ViewModels/ActivityFeedViewModel.swift",
    "Palace/Social/ViewModels/BookReviewViewModel.swift",
    "Palace/Social/ViewModels/CollectionDetailViewModel.swift",
    "Palace/Social/ViewModels/CollectionsViewModel.swift",
    "Palace/Social/ViewModels/ShareViewModel.swift",
    "Palace/Social/CollectionsTab.swift",
    "Palace/Social/Models/BookCollection.swift",
    "Palace/Social/Models/ReadingActivity.swift",
    "Palace/Social/Models/BookRecommendation.swift",
    "Palace/Social/Models/BookReview.swift",
    "Palace/Social/Models/ShareableBookCard.swift",
    "Palace/Social/AddToCollectionButton.swift",
    "Palace/Social/ShareBookButton.swift",
    "Palace/Social/Views/CollectionsView.swift",
    "Palace/Social/Views/ActivityFeedView.swift",
    "Palace/Social/Views/BookReviewView.swift",
    "Palace/Social/Views/AddToCollectionSheet.swift",
    "Palace/Social/Views/CollectionDetailView.swift",
    "Palace/Social/Views/ShareSheet.swift",
    "Palace/Social/Views/ShareCardView.swift",
    "Palace/Social/Services/BookReviewServiceProtocol.swift",
    "Palace/Social/Services/BookCollectionService.swift",
    "Palace/Social/Services/ReadingActivityServiceProtocol.swift",
    "Palace/Social/Services/BookReviewService.swift",
    "Palace/Social/Services/ShareService.swift",
    "Palace/Social/Services/BookCollectionServiceProtocol.swift",
    "Palace/Social/Services/ShareServiceProtocol.swift",
    "Palace/Social/Services/ReadingActivityService.swift",
    "Palace/Platform/PositionSyncBanner.swift",
    "Palace/Platform/PositionSyncRecord.swift",
    "Palace/Platform/OfflineQueueService.swift",
    "Palace/Platform/ReadingPosition.swift",
    "Palace/Platform/AppLaunchTracker.swift",
    "Palace/Platform/AccessibilitySettingsView.swift",
    "Palace/Platform/AccessibilityPreferences.swift",
    "Palace/Platform/PerformanceReport.swift",
    "Palace/Platform/PerformanceMetric.swift",
    "Palace/Platform/AppHealthView.swift",
    "Palace/Platform/PositionSyncService.swift",
    "Palace/Platform/CrossFormatMapping.swift",
    "Palace/Platform/OfflineQueueBadge.swift",
    "Palace/Platform/OfflineQueueDetailView.swift",
    "Palace/Platform/PerformanceMonitorProtocol.swift",
    "Palace/Platform/PerformanceMonitor.swift",
    "Palace/Platform/AppHealthViewModel.swift",
    "Palace/Platform/OfflineQueueStatus.swift",
    "Palace/Platform/OfflineAction.swift",
    "Palace/Platform/AccessibilityServiceProtocol.swift",
    "Palace/Platform/PositionSyncServiceProtocol.swift",
    "Palace/Platform/OfflineQueueServiceProtocol.swift",
    "Palace/Platform/PlatformTab.swift",
    "Palace/Platform/AccessibilityService.swift",
    "Palace/Platform/OfflineQueueStatusView.swift",
]

# Files for PalaceTests target
TEST_FILES = [
    "PalaceTests/Social/BookCollectionServiceTests.swift",
    "PalaceTests/Social/ShareServiceTests.swift",
    "PalaceTests/Social/CollectionsViewModelTests.swift",
    "PalaceTests/Social/BookCollectionModelTests.swift",
    "PalaceTests/Social/ShareViewModelTests.swift",
    "PalaceTests/Social/ReadingActivityServiceTests.swift",
    "PalaceTests/Social/BookReviewServiceTests.swift",
    "PalaceTests/Social/ActivityFeedViewModelTests.swift",
    "PalaceTests/Social/CollectionDetailViewModelTests.swift",
    "PalaceTests/Social/ShareServiceExtendedTests.swift",
    "PalaceTests/Social/BookReviewViewModelTests.swift",
    "PalaceTests/Platform/ReadingPositionTests.swift",
    "PalaceTests/Platform/AppLaunchTrackerTests.swift",
    "PalaceTests/Platform/AccessibilityServiceTests.swift",
    "PalaceTests/Platform/CrossFormatMappingTests.swift",
    "PalaceTests/Platform/OfflineQueueServiceExtendedTests.swift",
    "PalaceTests/Platform/OfflineActionTests.swift",
    "PalaceTests/Platform/PerformanceReportTests.swift",
    "PalaceTests/Platform/PerformanceMonitorTests.swift",
    "PalaceTests/Platform/AccessibilityPreferencesTests.swift",
    "PalaceTests/Platform/AppHealthViewModelTests.swift",
    "PalaceTests/Platform/OfflineQueueServiceTests.swift",
    "PalaceTests/Platform/PositionSyncServiceTests.swift",
    "PalaceTests/Platform/AppLaunchTrackerExtendedTests.swift",
    "PalaceTests/Discovery/SearchResultsViewModelTests.swift",
    "PalaceTests/Discovery/DiscoveryModelTests.swift",
    "PalaceTests/Discovery/DiscoveryConfigurationTests.swift",
    "PalaceTests/Discovery/LocalDiscoveryFallbackTests.swift",
    "PalaceTests/Stats/ReadingSessionTrackerTests.swift",
    "PalaceTests/Stats/BadgeDefinitionTests.swift",
    "PalaceTests/Stats/BadgesViewModelTests.swift",
    "PalaceTests/Reader2/Typography/TypographyServiceIntegrationTests.swift",
    "PalaceTests/Reader2/Typography/TypographySettingsTests.swift",
    "PalaceTests/Reader2/Typography/ReaderThemeTests.swift",
    "PalaceTests/Audiobooks/CarMode/BluetoothCarModeDetectorTests.swift",
    "PalaceTests/Audiobooks/CarMode/PlaybackSpeedConversionTests.swift",
    "PalaceTests/Audiobooks/CarMode/CarModeServicePlaybackTests.swift",
]


def gen_id(seed: str, existing_ids: set) -> str:
    """Generate a 24-char uppercase hex ID from a seed string, avoiding collisions."""
    result = hashlib.sha256(seed.encode()).hexdigest()[:24].upper()
    attempt = 0
    while result in existing_ids:
        attempt += 1
        result = hashlib.sha256(f"{seed}_{attempt}".encode()).hexdigest()[:24].upper()
    existing_ids.add(result)
    return result


def fname(path: str) -> str:
    return os.path.basename(path)


def find_children_open_paren(lines, group_id):
    """Find the line after 'children = (' inside the group with given ID."""
    group_start = None
    for i, line in enumerate(lines):
        if group_id in line and '= {' in line:
            for j in range(i+1, min(i+5, len(lines))):
                if 'isa = PBXGroup' in lines[j]:
                    group_start = i
                    break
            if group_start is not None:
                break
    if group_start is None:
        return None
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


def collect_existing_ids(content):
    """Collect all 24-char hex IDs already in the pbxproj."""
    ids = set()
    for match in re.finditer(r'\b([0-9A-F]{24})\b', content):
        ids.add(match.group(1))
    # Also collect alphanumeric IDs that aren't pure hex
    for match in re.finditer(r'\b([0-9A-Za-z]{24})\b', content):
        ids.add(match.group(1).upper())
    return ids


def main():
    with open(PBXPROJ_PATH, "r") as f:
        content = f.read()

    existing_ids = collect_existing_ids(content)
    lines = content.splitlines(True)

    file_ref_lines = []
    build_file_lines = []
    palace_source_lines = []
    nodrm_source_lines = []
    test_source_lines = []

    # Track new groups: key = path_string -> {id, name, path, children_refs[], parent_group_id}
    # We need to create:
    # Palace/Social (+ ViewModels, Models, Views, Services)
    # Palace/Platform (flat, no subdirs)
    # PalaceTests/Social
    # PalaceTests/Platform

    # Pre-create group IDs
    social_group_id = gen_id("GROUP_Palace/Social", existing_ids)
    social_viewmodels_id = gen_id("GROUP_Palace/Social/ViewModels", existing_ids)
    social_models_id = gen_id("GROUP_Palace/Social/Models", existing_ids)
    social_views_id = gen_id("GROUP_Palace/Social/Views", existing_ids)
    social_services_id = gen_id("GROUP_Palace/Social/Services", existing_ids)
    platform_group_id = gen_id("GROUP_Palace/Platform", existing_ids)

    tests_social_group_id = gen_id("GROUP_PalaceTests/Social", existing_ids)
    tests_platform_group_id = gen_id("GROUP_PalaceTests/Platform", existing_ids)

    # Map: group_id -> list of (file_ref_id, filename)
    group_children = {
        social_group_id: [],
        social_viewmodels_id: [],
        social_models_id: [],
        social_views_id: [],
        social_services_id: [],
        platform_group_id: [],
        tests_social_group_id: [],
        tests_platform_group_id: [],
        # Existing groups we'll add to
        TESTS_DISCOVERY_GROUP_ID: [],
        TESTS_STATS_GROUP_ID: [],
        TESTS_TYPOGRAPHY_GROUP_ID: [],
        TESTS_CARMODE_GROUP_ID: [],
    }

    # Build ref ID map for looking up filenames
    _ref_id_to_fname = {}

    # Process main files
    for fpath in MAIN_FILES:
        fn = fname(fpath)
        file_ref_id = gen_id(f"FILEREF_{fpath}", existing_ids)
        palace_bf_id = gen_id(f"BUILDFILE_PALACE_{fpath}", existing_ids)
        nodrm_bf_id = gen_id(f"BUILDFILE_NODRM_{fpath}", existing_ids)

        _ref_id_to_fname[file_ref_id] = fn

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

        # Determine which group this file belongs to
        parts = fpath.split("/")
        if parts[1] == "Social":
            if len(parts) == 3:
                # Top-level Social file (CollectionsTab.swift, etc.)
                group_children[social_group_id].append((file_ref_id, fn))
            elif parts[2] == "ViewModels":
                group_children[social_viewmodels_id].append((file_ref_id, fn))
            elif parts[2] == "Models":
                group_children[social_models_id].append((file_ref_id, fn))
            elif parts[2] == "Views":
                group_children[social_views_id].append((file_ref_id, fn))
            elif parts[2] == "Services":
                group_children[social_services_id].append((file_ref_id, fn))
        elif parts[1] == "Platform":
            group_children[platform_group_id].append((file_ref_id, fn))

    # Process test files
    for fpath in TEST_FILES:
        fn = fname(fpath)
        file_ref_id = gen_id(f"FILEREF_{fpath}", existing_ids)
        test_bf_id = gen_id(f"BUILDFILE_TESTS_{fpath}", existing_ids)

        _ref_id_to_fname[file_ref_id] = fn

        file_ref_lines.append(
            f'\t\t{file_ref_id} /* {fn} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {fn}; sourceTree = "<group>"; }};\n'
        )
        build_file_lines.append(
            f'\t\t{test_bf_id} /* {fn} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* {fn} */; }};\n'
        )
        test_source_lines.append(f'\t\t\t\t{test_bf_id} /* {fn} in Sources */,\n')

        parts = fpath.split("/")
        if parts[1] == "Social":
            group_children[tests_social_group_id].append((file_ref_id, fn))
        elif parts[1] == "Platform":
            group_children[tests_platform_group_id].append((file_ref_id, fn))
        elif parts[1] == "Discovery":
            group_children[TESTS_DISCOVERY_GROUP_ID].append((file_ref_id, fn))
        elif parts[1] == "Stats":
            group_children[TESTS_STATS_GROUP_ID].append((file_ref_id, fn))
        elif parts[1] == "Reader2" and parts[2] == "Typography":
            group_children[TESTS_TYPOGRAPHY_GROUP_ID].append((file_ref_id, fn))
        elif parts[1] == "Audiobooks" and parts[2] == "CarMode":
            group_children[TESTS_CARMODE_GROUP_ID].append((file_ref_id, fn))

    # Build new group entries
    new_group_entries = []

    def make_group_entry(gid, name, path, sub_groups, file_children):
        children_lines = ""
        for sg_id, sg_name in sub_groups:
            children_lines += f'\t\t\t\t{sg_id} /* {sg_name} */,\n'
        for fid, fn in file_children:
            children_lines += f'\t\t\t\t{fid} /* {fn} */,\n'
        return (
            f'\t\t{gid} /* {name} */ = {{\n'
            f'\t\t\tisa = PBXGroup;\n'
            f'\t\t\tchildren = (\n'
            f'{children_lines}'
            f'\t\t\t);\n'
            f'\t\t\tpath = {path};\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f'\t\t}};\n'
        )

    # Palace/Social group with subgroups
    new_group_entries.append(make_group_entry(
        social_group_id, "Social", "Social",
        [(social_viewmodels_id, "ViewModels"), (social_models_id, "Models"),
         (social_views_id, "Views"), (social_services_id, "Services")],
        group_children[social_group_id]
    ))
    new_group_entries.append(make_group_entry(
        social_viewmodels_id, "ViewModels", "ViewModels", [],
        group_children[social_viewmodels_id]
    ))
    new_group_entries.append(make_group_entry(
        social_models_id, "Models", "Models", [],
        group_children[social_models_id]
    ))
    new_group_entries.append(make_group_entry(
        social_views_id, "Views", "Views", [],
        group_children[social_views_id]
    ))
    new_group_entries.append(make_group_entry(
        social_services_id, "Services", "Services", [],
        group_children[social_services_id]
    ))

    # Palace/Platform group (flat)
    new_group_entries.append(make_group_entry(
        platform_group_id, "Platform", "Platform", [],
        group_children[platform_group_id]
    ))

    # PalaceTests/Social group (flat)
    new_group_entries.append(make_group_entry(
        tests_social_group_id, "Social", "Social", [],
        group_children[tests_social_group_id]
    ))

    # PalaceTests/Platform group (flat)
    new_group_entries.append(make_group_entry(
        tests_platform_group_id, "Platform", "Platform", [],
        group_children[tests_platform_group_id]
    ))

    # Now perform all insertions
    insertions = []  # (line_index, lines_to_insert)

    # 1. PBXBuildFile section
    for i, line in enumerate(lines):
        if '/* Begin PBXBuildFile section */' in line:
            insertions.append((i + 1, sorted(build_file_lines)))
            break

    # 2. PBXFileReference section
    for i, line in enumerate(lines):
        if '/* Begin PBXFileReference section */' in line:
            insertions.append((i + 1, sorted(file_ref_lines)))
            break

    # 3. New groups before "/* End PBXGroup section */"
    for i, line in enumerate(lines):
        if '/* End PBXGroup section */' in line:
            insertions.append((i, new_group_entries))
            break

    # 4. Add Social and Platform to Palace/ group children
    idx = find_children_open_paren(lines, PALACE_GROUP_ID)
    if idx is not None:
        insertions.append((idx, [
            f'\t\t\t\t{social_group_id} /* Social */,\n',
            f'\t\t\t\t{platform_group_id} /* Platform */,\n',
        ]))
    else:
        print("WARNING: Could not find Palace group children")

    # 5. Add Social and Platform to PalaceTests/ group children
    idx = find_children_open_paren(lines, PALACETESTS_GROUP_ID)
    if idx is not None:
        insertions.append((idx, [
            f'\t\t\t\t{tests_social_group_id} /* Social */,\n',
            f'\t\t\t\t{tests_platform_group_id} /* Platform */,\n',
        ]))
    else:
        print("WARNING: Could not find PalaceTests group children")

    # 6. Add new test files to existing test groups
    for group_id, children in [
        (TESTS_DISCOVERY_GROUP_ID, group_children[TESTS_DISCOVERY_GROUP_ID]),
        (TESTS_STATS_GROUP_ID, group_children[TESTS_STATS_GROUP_ID]),
        (TESTS_TYPOGRAPHY_GROUP_ID, group_children[TESTS_TYPOGRAPHY_GROUP_ID]),
        (TESTS_CARMODE_GROUP_ID, group_children[TESTS_CARMODE_GROUP_ID]),
    ]:
        if children:
            idx = find_children_open_paren(lines, group_id)
            if idx is not None:
                new_lines = [f'\t\t\t\t{fid} /* {fn} */,\n' for fid, fn in children]
                insertions.append((idx, new_lines))
            else:
                print(f"WARNING: Could not find children for group {group_id}")

    # 7. Add to Sources build phases
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
    print(f"Created {len(new_group_entries)} new groups.")
    print(f"Performed {len(insertions)} insertion operations.")
    print(f"Total PBXBuildFile entries: {len(build_file_lines)}")
    print(f"Total PBXFileReference entries: {len(file_ref_lines)}")
    print(f"Palace build phase entries: {len(palace_source_lines)}")
    print(f"Palace-noDRM build phase entries: {len(nodrm_source_lines)}")
    print(f"PalaceTests build phase entries: {len(test_source_lines)}")


if __name__ == "__main__":
    main()
