#!/usr/bin/env python3
"""
Phase 2 ObjC Cutover — Add Swift ports to pbxproj WITHOUT removing ObjC .m files.
Both coexist since Swift types use "Swift" suffix names.
"""

import hashlib
import re

PBXPROJ = "Palace.xcodeproj/project.pbxproj"

PALACE_SOURCES = "A823D809192BABA400B55DE2"
NODRM_SOURCES = "73EB0A6425821DF4006BC997"

# (swift_filename, relative_dir, h_file_for_group_insertion)
PORTS = [
    ("TPPLocalization.swift", "Palace/Utilities/Localization", "TPPLocalization.h"),
    ("TPPJSON.swift", "Palace/Utilities/Parsing", "TPPJSON.h"),
    ("TPPNull.swift", "Palace/Utilities", "TPPNull.h"),
    ("TPPAsync.swift", "Palace/Utilities/Concurrency", "TPPAsync.h"),
    ("TPPAttributedString.swift", "Palace/Utilities/Localization", "TPPAttributedString.h"),
    ("Date+TPPDateAdditions.swift", "Palace/Utilities/Date-Time", "NSDate+NYPLDateAdditions.h"),
    ("String+TPPStringAdditions.swift", "Palace/Utilities/Localization", "NSString+TPPStringAdditions.h"),
    ("TPPKeychain.swift", "Palace/Keychain", "TPPKeychain.h"),
    ("TPPSession.swift", "Palace/Network", "TPPSession.h"),
    ("TPPXML.swift", "Palace/Utilities/Parsing", "TPPXML.h"),
    ("UIColor+TPPColorAdditions.swift", "Palace/Utilities/UI", "UIColor+TPPColorAdditions.h"),
    ("UILabel+NYPLAppearanceAdditions.swift", "Palace/Utilities/UI", "UILabel+NYPLAppearanceAdditions.h"),
    ("UIButton+NYPLAppearanceAdditions.swift", "Palace/Utilities/UI", "UIButton+NYPLAppearanceAdditions.h"),
    ("UIFont+TPPSystemFontOverride.swift", "Palace/Utilities/UI", "UIFont+TPPSystemFontOverride.h"),
    ("UIView+TPPViewAdditions.swift", "Palace/Utilities/UI", "UIView+TPPViewAdditions.h"),
    ("NSURL+NYPLURLAdditions.swift", "Palace/Utilities/Networking", "NSURL+NYPLURLAdditions.h"),
    ("NSURLRequest+NYPLURLRequestAdditions.swift", "Palace/Utilities/Networking", "NSURLRequest+NYPLURLRequestAdditions.h"),
    ("TPPOPDSAcquisition.swift", "Palace/OPDS", "TPPOPDSAcquisition.h"),
    ("TPPOPDSAcquisitionAvailability.swift", "Palace/OPDS", "TPPOPDSAcquisitionAvailability.h"),
    ("TPPOPDSAcquisitionPath.swift", "Palace/OPDS", "TPPOPDSAcquisitionPath.h"),
    ("TPPOPDSAttribute.swift", "Palace/OPDS", "TPPOPDSAttribute.h"),
    ("TPPOPDSCategory.swift", "Palace/OPDS", "TPPOPDSCategory.h"),
    ("TPPOPDSEntry.swift", "Palace/OPDS", "TPPOPDSEntry.h"),
    ("TPPOPDSEntryGroupAttributes.swift", "Palace/OPDS", "TPPOPDSEntryGroupAttributes.h"),
    ("TPPOPDSFeed.swift", "Palace/OPDS", "TPPOPDSFeed.h"),
    ("TPPOPDSGroup.swift", "Palace/OPDS", "TPPOPDSGroup.h"),
    ("TPPOPDSIndirectAcquisition.swift", "Palace/OPDS", "TPPOPDSIndirectAcquisition.h"),
    ("TPPOPDSLink.swift", "Palace/OPDS", "TPPOPDSLink.h"),
    ("TPPOPDSRelation.swift", "Palace/OPDS", "TPPOPDSRelation.h"),
    ("TPPOPDSType.swift", "Palace/OPDS", "TPPOPDSType.h"),
    ("TPPOpenSearchDescription.swift", "Palace/Catalog", "TPPOpenSearchDescription.h"),
]


def gen_id(seed):
    return hashlib.md5(seed.encode()).hexdigest()[:24].upper()


def escape_pbx(name):
    if any(c in name for c in ' +-()/'):
        return f'"{name}"'
    return name


def main():
    with open(PBXPROJ, 'r') as f:
        content = f.read()

    existing_ids = set(re.findall(r'\b([0-9A-F]{24})\b', content))

    entries = []
    for swift_file, rel_dir, h_file in PORTS:
        fr_id = gen_id(f"fileref_{swift_file}")
        pb_id = gen_id(f"build_palace_{swift_file}")
        nd_id = gen_id(f"build_nodrm_{swift_file}")
        for xid in [fr_id, pb_id, nd_id]:
            assert xid not in existing_ids, f"ID collision: {xid} for {swift_file}"
        existing_ids.update([fr_id, pb_id, nd_id])
        entries.append({
            'swift_file': swift_file,
            'rel_dir': rel_dir,
            'h_file': h_file,
            'file_ref_id': fr_id,
            'palace_build_id': pb_id,
            'nodrm_build_id': nd_id,
        })

    lines = content.split('\n')
    new_lines = []
    added_build = False
    added_refs = False
    i = 0

    while i < len(lines):
        line = lines[i]

        # Add PBXBuildFile entries before section end
        if '/* End PBXBuildFile section */' in line and not added_build:
            for e in entries:
                new_lines.append(f"\t\t{e['palace_build_id']} /* {e['swift_file']} in Sources */ = {{isa = PBXBuildFile; fileRef = {e['file_ref_id']} /* {e['swift_file']} */; }};")
                new_lines.append(f"\t\t{e['nodrm_build_id']} /* {e['swift_file']} in Sources */ = {{isa = PBXBuildFile; fileRef = {e['file_ref_id']} /* {e['swift_file']} */; }};")
            added_build = True

        # Add PBXFileReference entries before section end
        if '/* End PBXFileReference section */' in line and not added_refs:
            for e in entries:
                esc = escape_pbx(e['swift_file'])
                new_lines.append(f"\t\t{e['file_ref_id']} /* {e['swift_file']} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {esc}; sourceTree = \"<group>\"; }};")
            added_refs = True

        # Add to PBXGroup — insert Swift file ref after the .h file
        inserted = False
        for e in entries:
            if e['h_file'] and f"/* {e['h_file']} */" in line and 'fileRef' not in line and 'isa' not in line and 'in Sources' not in line:
                new_lines.append(line)
                new_lines.append(f"\t\t\t\t{e['file_ref_id']} /* {e['swift_file']} */,")
                inserted = True
                break

        if not inserted:
            # Add to Palace Sources phase
            if PALACE_SOURCES in line and '/* Sources */' in line and 'isa' not in line:
                new_lines.append(line)
                i += 1
                # Copy until files = (
                while i < len(lines) and 'files = (' not in lines[i]:
                    new_lines.append(lines[i])
                    i += 1
                new_lines.append(lines[i])  # files = (
                i += 1
                for e in entries:
                    new_lines.append(f"\t\t\t\t{e['palace_build_id']} /* {e['swift_file']} in Sources */,")
                continue

            # Add to Palace-noDRM Sources phase
            if NODRM_SOURCES in line and '/* Sources */' in line and 'isa' not in line:
                new_lines.append(line)
                i += 1
                while i < len(lines) and 'files = (' not in lines[i]:
                    new_lines.append(lines[i])
                    i += 1
                new_lines.append(lines[i])  # files = (
                i += 1
                for e in entries:
                    new_lines.append(f"\t\t\t\t{e['nodrm_build_id']} /* {e['swift_file']} in Sources */,")
                continue

            new_lines.append(line)
        i += 1

    with open(PBXPROJ, 'w') as f:
        f.write('\n'.join(new_lines))

    print(f"Added {len(entries)} Swift port files to pbxproj (coexisting with ObjC)")
    print(f"  {len(entries)} PBXFileReference entries")
    print(f"  {len(entries) * 2} PBXBuildFile entries (Palace + Palace-noDRM)")
    print(f"  {len(entries)} PBXGroup entries")
    print(f"  {len(entries) * 2} Sources build phase entries")


if __name__ == '__main__':
    main()
