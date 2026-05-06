#!/usr/bin/env python3
"""
Phase 2 ObjC Cutover — pbxproj modifier

Adds Swift port files to pbxproj (Palace + Palace-noDRM targets)
and removes corresponding ObjC .m files from compilation.

Strategy:
1. For each Swift port: create PBXFileReference, 2x PBXBuildFile, add to group, add to both Sources phases
2. For each ObjC .m: remove PBXBuildFile entries from Sources phases (keep FileReference and group for now)
"""

import hashlib
import os
import re
import sys

PBXPROJ = "Palace.xcodeproj/project.pbxproj"

# Palace Sources phase ID and Palace-noDRM Sources phase ID
PALACE_SOURCES = "A823D809192BABA400B55DE2"
NODRM_SOURCES = "73EB0A6425821DF4006BC997"

# Swift port files and their paths relative to project root
# Format: (swift_filename, relative_dir, objc_m_filename, objc_h_filename)
PORTS = [
    # C2: Trivial utilities
    ("TPPLocalization.swift", "Palace/Utilities/Localization", "TPPLocalization.m", "TPPLocalization.h"),
    ("TPPJSON.swift", "Palace/Utilities/Parsing", "TPPJSON.m", "TPPJSON.h"),
    ("TPPNull.swift", "Palace/Utilities", "TPPNull.m", "TPPNull.h"),
    ("TPPAsync.swift", "Palace/Utilities/Concurrency", "TPPAsync.m", "TPPAsync.h"),
    ("TPPAttributedString.swift", "Palace/Utilities/Localization", "TPPAttributedString.m", "TPPAttributedString.h"),
    ("Date+TPPDateAdditions.swift", "Palace/Utilities/Date-Time", "NSDate+NYPLDateAdditions.m", "NSDate+NYPLDateAdditions.h"),
    ("String+TPPStringAdditions.swift", "Palace/Utilities/Localization", "NSString+TPPStringAdditions.m", "NSString+TPPStringAdditions.h"),
    # C3: Infrastructure
    ("TPPKeychain.swift", "Palace/Keychain", "TPPKeychain.m", "TPPKeychain.h"),
    ("TPPSession.swift", "Palace/Network", "TPPSession.m", "TPPSession.h"),
    ("TPPXML.swift", "Palace/Utilities/Parsing", "TPPXML.m", "TPPXML.h"),
    ("UIColor+TPPColorAdditions.swift", "Palace/Utilities/UI", "UIColor+TPPColorAdditions.m", "UIColor+TPPColorAdditions.h"),
    ("UILabel+NYPLAppearanceAdditions.swift", "Palace/Utilities/UI", "UILabel+NYPLAppearanceAdditions.m", "UILabel+NYPLAppearanceAdditions.h"),
    ("UIButton+NYPLAppearanceAdditions.swift", "Palace/Utilities/UI", "UIButton+NYPLAppearanceAdditions.m", "UIButton+NYPLAppearanceAdditions.h"),
    ("UIFont+TPPSystemFontOverride.swift", "Palace/Utilities/UI", "UIFont+TPPSystemFontOverride.m", "UIFont+TPPSystemFontOverride.h"),
    ("UIView+TPPViewAdditions.swift", "Palace/Utilities/UI", "UIView+TPPViewAdditions.m", "UIView+TPPViewAdditions.h"),
    ("NSURL+NYPLURLAdditions.swift", "Palace/Utilities/Networking", "NSURL+NYPLURLAdditions.m", "NSURL+NYPLURLAdditions.h"),
    ("NSURLRequest+NYPLURLRequestAdditions.swift", "Palace/Utilities/Networking", "NSURLRequest+NYPLURLRequestAdditions.m", "NSURLRequest+NYPLURLRequestAdditions.h"),
    # C4: OPDS parsing
    ("TPPOPDSAcquisition.swift", "Palace/OPDS", "TPPOPDSAcquisition.m", "TPPOPDSAcquisition.h"),
    ("TPPOPDSAcquisitionAvailability.swift", "Palace/OPDS", "TPPOPDSAcquisitionAvailability.m", "TPPOPDSAcquisitionAvailability.h"),
    ("TPPOPDSAcquisitionPath.swift", "Palace/OPDS", "TPPOPDSAcquisitionPath.m", "TPPOPDSAcquisitionPath.h"),
    ("TPPOPDSAttribute.swift", "Palace/OPDS", "TPPOPDSAttribute.m", "TPPOPDSAttribute.h"),
    ("TPPOPDSCategory.swift", "Palace/OPDS", "TPPOPDSCategory.m", "TPPOPDSCategory.h"),
    ("TPPOPDSEntry.swift", "Palace/OPDS", "TPPOPDSEntry.m", "TPPOPDSEntry.h"),
    ("TPPOPDSEntryGroupAttributes.swift", "Palace/OPDS", "TPPOPDSEntryGroupAttributes.m", "TPPOPDSEntryGroupAttributes.h"),
    ("TPPOPDSFeed.swift", "Palace/OPDS", "TPPOPDSFeed.m", "TPPOPDSFeed.h"),
    ("TPPOPDSGroup.swift", "Palace/OPDS", "TPPOPDSGroup.m", "TPPOPDSGroup.h"),
    ("TPPOPDSIndirectAcquisition.swift", "Palace/OPDS", "TPPOPDSIndirectAcquisition.m", "TPPOPDSIndirectAcquisition.h"),
    ("TPPOPDSLink.swift", "Palace/OPDS", "TPPOPDSLink.m", "TPPOPDSLink.h"),
    ("TPPOPDSRelation.swift", "Palace/OPDS", None, "TPPOPDSRelation.h"),  # Swift-only, no .m
    ("TPPOPDSType.swift", "Palace/OPDS", "TPPOPDSType.m", "TPPOPDSType.h"),
    ("TPPOpenSearchDescription.swift", "Palace/Catalog", "TPPOpenSearchDescription.m", "TPPOpenSearchDescription.h"),
]


def gen_id(seed: str) -> str:
    """Generate a deterministic 24-char hex ID from a seed string."""
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def escape_pbx(name: str) -> str:
    """Escape filename for pbxproj if it contains special chars."""
    if any(c in name for c in ' +-()/'):
        return f'"{name}"'
    return name


def main():
    with open(PBXPROJ, 'r') as f:
        content = f.read()

    lines = content.split('\n')

    # Collect all existing IDs to avoid collisions
    existing_ids = set(re.findall(r'\b([0-9A-F]{24})\b', content))

    # --- Step 1: Find ObjC .m build file IDs to remove from Sources phases ---
    objc_build_file_ids = {}  # m_filename -> list of build file IDs
    objc_file_ref_ids = {}    # m_filename -> file ref ID

    for port in PORTS:
        m_file = port[2]
        if m_file is None:
            continue

        # Find PBXBuildFile entries for this .m file
        pattern = rf'^\s+([0-9A-F]{{24}}) /\* {re.escape(m_file)} in Sources \*/ = \{{isa = PBXBuildFile;'
        build_ids = []
        for line in lines:
            match = re.match(pattern, line)
            if match:
                build_ids.append(match.group(1))
        objc_build_file_ids[m_file] = build_ids

        # Find PBXFileReference for this .m file
        pattern = rf'^\s+([0-9A-F]{{24}}) /\* {re.escape(m_file)} \*/ = \{{isa = PBXFileReference;'
        for line in lines:
            match = re.match(pattern, line)
            if match:
                objc_file_ref_ids[m_file] = match.group(1)
                break

    # --- Step 2: Generate IDs for Swift files ---
    swift_entries = []
    for swift_file, rel_dir, m_file, h_file in PORTS:
        file_ref_id = gen_id(f"fileref_{swift_file}")
        palace_build_id = gen_id(f"build_palace_{swift_file}")
        nodrm_build_id = gen_id(f"build_nodrm_{swift_file}")

        # Ensure no collisions
        while file_ref_id in existing_ids:
            file_ref_id = gen_id(f"fileref_{swift_file}_x")
        while palace_build_id in existing_ids:
            palace_build_id = gen_id(f"build_palace_{swift_file}_x")
        while nodrm_build_id in existing_ids:
            nodrm_build_id = gen_id(f"build_nodrm_{swift_file}_x")

        existing_ids.update([file_ref_id, palace_build_id, nodrm_build_id])

        swift_entries.append({
            'swift_file': swift_file,
            'rel_dir': rel_dir,
            'file_ref_id': file_ref_id,
            'palace_build_id': palace_build_id,
            'nodrm_build_id': nodrm_build_id,
            'm_file': m_file,
            'h_file': h_file,
        })

    # --- Step 3: Find group entries for each directory ---
    # We need to find the PBXGroup for each directory and add the Swift file there
    # Also find where the ObjC .h file is in the group to insert nearby

    # --- Now modify the content ---
    new_lines = []
    i = 0

    # Track what sections we're in
    in_build_file_section = False
    in_file_ref_section = False
    build_file_section_end = None
    file_ref_section_end = None
    added_build_files = False
    added_file_refs = False

    # IDs to remove from Sources build phases
    remove_from_sources = set()
    for m_file, build_ids in objc_build_file_ids.items():
        for bid in build_ids:
            remove_from_sources.add(bid)

    # Build file lines to remove (ObjC .m in Sources PBXBuildFile entries)
    remove_build_lines = set()
    for m_file, build_ids in objc_build_file_ids.items():
        for bid in build_ids:
            remove_build_lines.add(bid)

    while i < len(lines):
        line = lines[i]

        # Track sections
        if '/* Begin PBXBuildFile section */' in line:
            in_build_file_section = True
            new_lines.append(line)
            i += 1
            continue
        elif '/* End PBXBuildFile section */' in line:
            in_build_file_section = False
            if not added_build_files:
                # Add Swift build file entries before section end
                for entry in swift_entries:
                    esc = escape_pbx(entry['swift_file'])
                    new_lines.append(f"\t\t{entry['palace_build_id']} /* {entry['swift_file']} in Sources */ = {{isa = PBXBuildFile; fileRef = {entry['file_ref_id']} /* {entry['swift_file']} */; }};")
                    new_lines.append(f"\t\t{entry['nodrm_build_id']} /* {entry['swift_file']} in Sources */ = {{isa = PBXBuildFile; fileRef = {entry['file_ref_id']} /* {entry['swift_file']} */; }};")
                added_build_files = True
            new_lines.append(line)
            i += 1
            continue

        # Remove ObjC .m build file entries
        if in_build_file_section:
            skip = False
            for bid in remove_build_lines:
                if bid in line and 'in Sources' in line:
                    skip = True
                    break
            if skip:
                i += 1
                continue

        # File references section
        if '/* Begin PBXFileReference section */' in line:
            in_file_ref_section = True
            new_lines.append(line)
            i += 1
            continue
        elif '/* End PBXFileReference section */' in line:
            in_file_ref_section = False
            if not added_file_refs:
                for entry in swift_entries:
                    esc = escape_pbx(entry['swift_file'])
                    new_lines.append(f"\t\t{entry['file_ref_id']} /* {entry['swift_file']} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {esc}; sourceTree = \"<group>\"; }};")
                added_file_refs = True
            new_lines.append(line)
            i += 1
            continue

        # Sources build phases — add Swift entries and remove ObjC entries
        if PALACE_SOURCES in line and 'Sources' in line and 'isa' not in line:
            # We're at the start of Palace Sources phase
            new_lines.append(line)
            i += 1
            # Copy through to 'files = ('
            while i < len(lines) and 'files = (' not in lines[i]:
                new_lines.append(lines[i])
                i += 1
            new_lines.append(lines[i])  # files = (
            i += 1
            # Add Swift entries at top of files list
            for entry in swift_entries:
                new_lines.append(f"\t\t\t\t{entry['palace_build_id']} /* {entry['swift_file']} in Sources */,")
            # Copy existing entries, removing ObjC ones
            while i < len(lines) and ');' not in lines[i]:
                skip = False
                for bid in remove_from_sources:
                    if bid in lines[i]:
                        skip = True
                        break
                if not skip:
                    new_lines.append(lines[i])
                i += 1
            new_lines.append(lines[i])  # );
            i += 1
            continue

        if NODRM_SOURCES in line and 'Sources' in line and 'isa' not in line:
            # Palace-noDRM Sources phase
            new_lines.append(line)
            i += 1
            while i < len(lines) and 'files = (' not in lines[i]:
                new_lines.append(lines[i])
                i += 1
            new_lines.append(lines[i])  # files = (
            i += 1
            # Add Swift entries
            for entry in swift_entries:
                new_lines.append(f"\t\t\t\t{entry['nodrm_build_id']} /* {entry['swift_file']} in Sources */,")
            # Copy existing, removing ObjC
            while i < len(lines) and ');' not in lines[i]:
                skip = False
                for bid in remove_from_sources:
                    if bid in lines[i]:
                        skip = True
                        break
                if not skip:
                    new_lines.append(lines[i])
                i += 1
            new_lines.append(lines[i])  # );
            i += 1
            continue

        # Add Swift files to their PBXGroup entries
        # For each group, when we see the ObjC .h file, add the Swift file after it
        added_here = False
        for entry in swift_entries:
            h_file = entry['h_file']
            m_file = entry['m_file']
            swift_file = entry['swift_file']
            # Check if this line references the .h file in a group
            if h_file and f'/* {h_file} */' in line and 'fileRef' not in line and 'isa' not in line and 'in Sources' not in line:
                new_lines.append(line)
                # Add Swift file ref after .h
                esc_ref = entry['file_ref_id']
                new_lines.append(f"\t\t\t\t{esc_ref} /* {swift_file} */,")
                added_here = True
                break

        if not added_here:
            new_lines.append(line)

        i += 1

    # Write modified pbxproj
    with open(PBXPROJ, 'w') as f:
        f.write('\n'.join(new_lines))

    print(f"Modified {PBXPROJ}:")
    print(f"  Added {len(swift_entries)} Swift port file references")
    print(f"  Added {len(swift_entries) * 2} build file entries (Palace + Palace-noDRM)")
    print(f"  Removed {len(remove_from_sources)} ObjC .m build entries from Sources phases")
    print(f"  Added Swift files to {len(swift_entries)} PBXGroup entries")

    # Summary of ObjC files that can now be deleted
    print("\nObjC .m files removed from build (can delete from disk):")
    for m_file, build_ids in sorted(objc_build_file_ids.items()):
        print(f"  {m_file} ({len(build_ids)} build refs removed)")


if __name__ == '__main__':
    main()
