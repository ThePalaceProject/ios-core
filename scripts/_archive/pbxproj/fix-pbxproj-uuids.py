#!/usr/bin/env python3
"""Fix non-hexadecimal UUIDs in pbxproj file.

Xcode requires 24-character hexadecimal UUIDs (0-9, A-F only).
This script finds all 24-char IDs containing non-hex characters
and replaces them with proper random hex UUIDs.
"""

import re
import random
import sys

PBXPROJ = "Palace.xcodeproj/project.pbxproj"
HEX_CHARS = "0123456789ABCDEF"

def is_valid_hex(s):
    return all(c in HEX_CHARS for c in s)

def generate_hex_uuid(existing):
    """Generate a unique 24-char hex UUID not in existing set."""
    while True:
        uuid = ''.join(random.choice(HEX_CHARS) for _ in range(24))
        if uuid not in existing:
            return uuid

def main():
    with open(PBXPROJ, 'r') as f:
        content = f.read()

    # Find all 24-char alphanumeric tokens used as pbxproj IDs.
    # In pbxproj, IDs appear at word boundaries surrounded by spaces,
    # tabs, or specific punctuation (= { , ;)
    all_ids = set(re.findall(r'\b([A-Z0-9]{24})\b', content))

    valid_ids = {uid for uid in all_ids if is_valid_hex(uid)}
    invalid_ids = {uid for uid in all_ids if not is_valid_hex(uid)}

    print(f"Total 24-char IDs found: {len(all_ids)}")
    print(f"Valid hex IDs: {len(valid_ids)}")
    print(f"Invalid IDs to fix: {len(invalid_ids)}")

    if not invalid_ids:
        print("Nothing to fix!")
        return

    # Build replacement map
    all_existing = set(valid_ids)
    replacements = {}
    for old_id in sorted(invalid_ids):
        new_id = generate_hex_uuid(all_existing)
        all_existing.add(new_id)
        replacements[old_id] = new_id

    # Replace all occurrences using word boundaries
    for old_id, new_id in sorted(replacements.items()):
        # Use word boundary to avoid partial matches
        content = re.sub(r'\b' + re.escape(old_id) + r'\b', new_id, content)
        count = len(re.findall(r'\b' + re.escape(new_id) + r'\b', content))
        print(f"  {old_id} -> {new_id} ({count} occurrences)")

    with open(PBXPROJ, 'w') as f:
        f.write(content)

    print(f"\nDone! Replaced {len(replacements)} invalid UUIDs.")

if __name__ == '__main__':
    main()
