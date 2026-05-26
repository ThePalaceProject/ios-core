#!/usr/bin/env python3
"""Trim expect_elements in simdrive replay YAMLs to stable, screen-appropriate elements only.

Two-pass approach:
1. Filter to stable elements only (remove dynamic content like book titles, version numbers)
2. Validate elements belong to the correct screen context based on what was tapped
"""

import yaml
import glob
import os

# --- Screen context definitions ---
# Elements that are valid ONLY on specific screens

CATALOG_ELEMENTS = {
    "Switch Library", "Search Catalog", "Catalog",
    "All", "Ebooks", "Audiobooks",
}

MY_BOOKS_ELEMENTS = {
    "Switch Library", "Search Books", "Sort by Title", "Sort", "Title",
}

SETTINGS_ELEMENTS = {
    "Settings", "Libraries", "About App", "Privacy Policy",
    "User Agreement", "Software Licenses", "Testing",
}

RESERVATIONS_ELEMENTS = {
    "Switch Library", "Search Books", "Sort by Title", "Sort", "Title",
}

FEED_DETAIL_ELEMENTS = {
    "uibutton.navbar.back.button.title", "Filter", "Unread",
    "Audiobook", "Borrow",
}

BOOK_DETAIL_ELEMENTS = {
    "Go back", "Back", "Borrow", "Return",
    "INFORMATION", "FORMAT", "ePub", "PUBLISHED", "PUBLISHER", "CATEGORY",
}

SEARCH_ELEMENTS = {
    "Switch Library", "Cancel", "Clear search",
    "All", "Ebooks", "Audiobooks", "Unread",
}

# Tab bar elements visible on ALL screens
TAB_BAR = {"Catalog", "My Books", "Reservations", "Settings", "tab.bar.label"}

# Map element_label to the screen you land on
SCREEN_MAP = {
    "Catalog": "catalog",
    "My Books": "my_books",
    "Reservations": "reservations",
    "Settings": "settings",
}

# Elements valid per screen (screen-specific + tab bar)
VALID_PER_SCREEN = {
    "catalog": CATALOG_ELEMENTS | TAB_BAR,
    "my_books": MY_BOOKS_ELEMENTS | TAB_BAR,
    "reservations": RESERVATIONS_ELEMENTS | TAB_BAR,
    "settings": SETTINGS_ELEMENTS | TAB_BAR,
    "feed_detail": FEED_DETAIL_ELEMENTS | TAB_BAR,
    "book_detail": BOOK_DETAIL_ELEMENTS | TAB_BAR,
    "search": SEARCH_ELEMENTS | TAB_BAR,
}

# All stable elements (union of everything)
ALL_STABLE = set()
for s in VALID_PER_SCREEN.values():
    ALL_STABLE |= s


def detect_screen(step: dict) -> str | None:
    """Detect which screen a step navigates to based on element_label."""
    label = step.get("element_label", "")

    # Direct tab bar navigation
    if label in SCREEN_MAP:
        return SCREEN_MAP[label]

    # Back navigation to feed or catalog
    if label in ("uibutton.navbar.back.button.title", "Back", "Go back"):
        return None  # Can't determine - allow all stable elements

    # Cancel from search
    if label == "Cancel":
        return "catalog"

    # Feed lane taps (e.g., "More books in ...")
    if label.startswith("More books in"):
        return "feed_detail"

    return None  # Unknown - allow all stable elements


def fix_replay(filepath: str) -> tuple[str, int, int, int]:
    """Fix a single replay file. Returns (name, original, after_stable, after_context)."""
    with open(filepath, "r") as f:
        data = yaml.safe_load(f)

    if not data or "replay" not in data:
        return (os.path.basename(filepath), 0, 0, 0)

    name = data["replay"].get("name", os.path.basename(filepath))
    steps = data["replay"].get("steps", [])
    original_total = 0
    final_total = 0

    for step in steps:
        if "expect_elements" not in step:
            continue
        original = step["expect_elements"]
        original_total += len(original)

        # Pass 1: keep only globally stable elements
        filtered = [e for e in original if e in ALL_STABLE]

        # Pass 2: if we can detect the screen, filter to screen-appropriate elements
        screen = detect_screen(step)
        if screen and screen in VALID_PER_SCREEN:
            filtered = [e for e in filtered if e in VALID_PER_SCREEN[screen]]

        # Deduplicate while preserving order
        seen = set()
        deduped = []
        for e in filtered:
            if e not in seen:
                seen.add(e)
                deduped.append(e)
        filtered = deduped

        final_total += len(filtered)
        if filtered:
            step["expect_elements"] = filtered
        else:
            del step["expect_elements"]

    with open(filepath, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    return (name, original_total, final_total, 0)


def main():
    replay_dir = os.path.join(os.path.dirname(__file__), "..", ".simdrive", "_archive", "replays")
    files = sorted(glob.glob(os.path.join(replay_dir, "*.yaml")))

    print(f"Processing {len(files)} replay files...\n")
    print(f"{'Replay':<35} {'Before':>7} {'After':>7} {'Removed':>8}")
    print("-" * 60)

    total_before = 0
    total_after = 0

    for f in files:
        name, before, after, _ = fix_replay(f)
        removed = before - after
        total_before += before
        total_after += after
        status = "  (no change)" if removed == 0 else ""
        print(f"{name:<35} {before:>7} {after:>7} {removed:>8}{status}")

    print("-" * 60)
    print(f"{'TOTAL':<35} {total_before:>7} {total_after:>7} {total_before - total_after:>8}")
    print(f"\nKept {total_after} stable, screen-appropriate assertions.")


if __name__ == "__main__":
    main()
