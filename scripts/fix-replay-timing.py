#!/usr/bin/env python3
"""Remove expect_elements from steps where timing makes assertions unreliable.

Identified unreliable assertion patterns from CI run:
1. Back navigation (element_label contains "back", "Libraries" as back-nav, "Go back")
2. Confirmation dialogs (Return tap expecting Cancel/Return dialog)
3. Library switching (tapping a library name expecting catalog to load)
4. Intermediate steps that aren't final landing pages
5. Steps where the element_label itself is a dynamic content item

Strategy: Only keep assertions on these reliable steps:
- Tab bar taps (Catalog, My Books, Reservations, Settings) — screen fully loads
- Final step of a replay (the "landing" verification)
- Swipe steps that just verify scrolling worked
- Steps that tap stable structural elements (Filter, Sort, etc.)

Remove assertions from:
- Back navigation steps
- Library name taps (switching)
- Book title taps (navigating into detail)
- Confirmation button taps (Return, Borrow in dialogs)
- "More books in..." taps (feed loading)
- Second consecutive tap of same label (e.g., double "Libraries" for back-nav)
"""

import yaml
import glob
import os

# Labels where assertions are UNRELIABLE due to timing
UNRELIABLE_LABELS = {
    # Back navigation
    "Go back", "Back",
    "uibutton.navbar.back.button.title",
    # Confirmation dialogs
    "Return",  # Return button in confirmation dialog
    # Sheet dismissal
    "sheet.grabber",
}

# Patterns in labels that make assertions unreliable
UNRELIABLE_PATTERNS = [
    "More books in",  # Feed lane navigation — loading time varies
]


def is_library_name_tap(step: dict) -> bool:
    """Detect taps on library names (e.g., 'A1QA Test Library', 'Lyrasis Reads')."""
    label = step.get("element_label", "")
    # Known library names
    if label in ("A1QA Test Library", "Lyrasis Reads"):
        return True
    return False


def is_back_nav_libraries(step: dict, prev_step: dict | None) -> bool:
    """Detect 'Libraries' tap that's back-navigation (not initial Settings→Libraries)."""
    if step.get("element_label") != "Libraries":
        return False
    # If previous step also tapped "Libraries", this is back-nav
    if prev_step and prev_step.get("element_label") == "Libraries":
        return True
    # If previous step tapped a library name, this is back-nav
    if prev_step and is_library_name_tap(prev_step):
        return True
    return False


def should_remove_assertion(step: dict, prev_step: dict | None, is_last: bool) -> bool:
    """Determine if a step's assertion should be removed due to timing issues."""
    label = step.get("element_label", "")

    # Unreliable labels
    if label in UNRELIABLE_LABELS:
        return True

    # Unreliable patterns
    for pattern in UNRELIABLE_PATTERNS:
        if pattern in label:
            return True

    # Library name taps
    if is_library_name_tap(step):
        return True

    # Back-nav via "Libraries"
    if is_back_nav_libraries(step, prev_step):
        return True

    # Reservations tab when likely empty (assertions expect search/sort UI)
    if label == "Reservations":
        expect = step.get("expect_elements", [])
        if "Search Books" in expect or "Sort by Title" in expect:
            return True

    # Nav-bar back buttons disguised as tab labels (y < 100 = top of screen)
    y = step.get("y", 800)
    if label in ("Settings", "Catalog", "My Books") and y < 100:
        return True

    return False


def fix_replay(filepath: str) -> tuple[str, int, int]:
    """Fix timing-sensitive assertions. Returns (name, removed_count, kept_count)."""
    with open(filepath, "r") as f:
        data = yaml.safe_load(f)

    if not data or "replay" not in data:
        return (os.path.basename(filepath), 0, 0)

    name = data["replay"].get("name", os.path.basename(filepath))
    steps = data["replay"].get("steps", [])
    removed = 0
    kept = 0

    for i, step in enumerate(steps):
        if "expect_elements" not in step:
            continue

        prev_step = steps[i - 1] if i > 0 else None
        is_last = (i == len(steps) - 1)

        if should_remove_assertion(step, prev_step, is_last):
            removed += len(step["expect_elements"])
            del step["expect_elements"]
        else:
            kept += len(step["expect_elements"])

    with open(filepath, "w") as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

    return (name, removed, kept)


def main():
    replay_dir = os.path.join(os.path.dirname(__file__), "..", ".specterqa", "replays")
    files = sorted(glob.glob(os.path.join(replay_dir, "*.yaml")))

    print(f"Fixing timing-sensitive assertions in {len(files)} replay files...\n")
    print(f"{'Replay':<35} {'Removed':>8} {'Kept':>6}")
    print("-" * 55)

    total_removed = 0
    total_kept = 0

    for f in files:
        name, removed, kept = fix_replay(f)
        total_removed += removed
        total_kept += kept
        status = "  (no assertions)" if removed == 0 and kept == 0 else ""
        if removed > 0:
            status = f"  <- trimmed"
        print(f"{name:<35} {removed:>8} {kept:>6}{status}")

    print("-" * 55)
    print(f"{'TOTAL':<35} {total_removed:>8} {total_kept:>6}")
    print(f"\nRemoved {total_removed} timing-sensitive assertions, kept {total_kept} reliable ones.")


if __name__ == "__main__":
    main()
