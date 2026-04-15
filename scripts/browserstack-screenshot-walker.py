#!/usr/bin/env python3
"""
BrowserStack Screenshot Walker for Palace iOS

Automates taking screenshots of every major screen in the Palace iOS app
on BrowserStack App Automate using Appium. Used for side-by-side regression
testing (PP-4020) comparing different app versions.

Onboarding is handled automatically: the script dismisses the walkthrough,
adds Addison Public Library, and optionally signs in before walking screens.

Navigation patterns derived from SpecterQA replay YAMLs in .specterqa/replays/.

Usage:
    python3 browserstack-screenshot-walker.py --ipa ~/Downloads/Palace-1.2.8.ipa --version 1.2.8
    python3 browserstack-screenshot-walker.py --app-url bs://abc123 --version 2.2.5

Requirements:
    pip3 install Appium-Python-Client requests
"""

import argparse
import os
import sys
import time
from pathlib import Path

import requests

try:
    from appium import webdriver
    from appium.options.common import AppiumOptions
    from appium.webdriver.common.appiumby import AppiumBy
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.common.exceptions import (
        TimeoutException,
        NoSuchElementException,
        WebDriverException,
    )
except ImportError:
    print("ERROR: Appium Python client not installed.")
    print("Install with: pip3 install Appium-Python-Client")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BROWSERSTACK_USER = "servers@lyrasistechnology.org"
BROWSERSTACK_KEY = "o59nLNYtSu34sJuBpDqN"
BROWSERSTACK_UPLOAD_URL = "https://api-cloud.browserstack.com/app-automate/upload"
BROWSERSTACK_HUB_URL = "https://hub-cloud.browserstack.com/wd/hub"
BUNDLE_ID = "org.thepalaceproject.palace"

DEFAULT_DEVICE = "iPhone 16"
DEFAULT_OS_VERSION = "18"
DEFAULT_OUTPUT_DIR = os.path.expanduser("~/Desktop/regression-PP-4020/screenshots")

ELEMENT_WAIT = 15
SETTLE_PAUSE = 2.5

# Tab bar Y coordinate (from SpecterQA replays — consistent across devices)
TAB_BAR_Y = 786


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def upload_ipa(ipa_path: str) -> str:
    """Upload an IPA to BrowserStack and return the app_url."""
    ipa_path = os.path.expanduser(ipa_path)
    if not os.path.isfile(ipa_path):
        print(f"ERROR: IPA not found at {ipa_path}")
        sys.exit(1)

    file_size_mb = os.path.getsize(ipa_path) / (1024 * 1024)
    print(f"Uploading IPA ({file_size_mb:.1f} MB) to BrowserStack...")

    with open(ipa_path, "rb") as f:
        resp = requests.post(
            BROWSERSTACK_UPLOAD_URL,
            auth=(BROWSERSTACK_USER, BROWSERSTACK_KEY),
            files={"file": (os.path.basename(ipa_path), f)},
            timeout=600,
        )

    if resp.status_code != 200:
        print(f"ERROR: Upload failed ({resp.status_code}): {resp.text}")
        sys.exit(1)

    app_url = resp.json().get("app_url")
    if not app_url:
        print(f"ERROR: No app_url in response: {resp.json()}")
        sys.exit(1)

    print(f"Upload complete. app_url: {app_url}")
    return app_url


def create_driver(app_url: str, version: str, device: str, os_version: str):
    """Create and return an Appium WebDriver connected to BrowserStack."""
    options = AppiumOptions()
    options.set_capability("bstack:options", {
        "userName": BROWSERSTACK_USER,
        "accessKey": BROWSERSTACK_KEY,
        "deviceName": device,
        "osVersion": os_version,
        "projectName": "PP-4020 Regression",
        "buildName": f"U1-{version}",
        "sessionName": f"Screenshot Walker - {version}",
        "appiumVersion": "2.0.0",
    })
    options.set_capability("appium:app", app_url)
    options.set_capability("appium:automationName", "XCUITest")
    options.set_capability("appium:bundleId", BUNDLE_ID)
    options.set_capability("appium:newCommandTimeout", 300)
    options.set_capability("appium:wdaLaunchTimeout", 120000)

    print(f"Starting Appium session on {device} (iOS {os_version})...")
    driver = webdriver.Remote(BROWSERSTACK_HUB_URL, options=options)
    print(f"Session started: {driver.session_id}")
    return driver


def settle(driver, seconds=None):
    """Wait for the screen to settle after a navigation action."""
    time.sleep(seconds if seconds is not None else SETTLE_PAUSE)


def find_el(driver, by, value, timeout=None):
    """Find an element with a wait, returning None on failure."""
    timeout = timeout or ELEMENT_WAIT
    try:
        return WebDriverWait(driver, timeout).until(
            EC.presence_of_element_located((by, value))
        )
    except (TimeoutException, NoSuchElementException):
        return None


def tap(driver, by, value, timeout=None):
    """Find and tap an element. Returns True on success."""
    el = find_el(driver, by, value, timeout)
    if el:
        try:
            el.click()
            settle(driver)
            return True
        except WebDriverException:
            return False
    return False


def tap_by_label(driver, label, timeout=None):
    """Tap an element by its accessibility label, with predicate fallback."""
    timeout = timeout or 8
    if tap(driver, AppiumBy.ACCESSIBILITY_ID, label, timeout=timeout):
        return True
    # Fallback: match by label on any tappable element type
    predicate = (f'(type == "XCUIElementTypeButton" OR type == "XCUIElementTypeCell" '
                 f'OR type == "XCUIElementTypeOther" OR type == "XCUIElementTypeStaticText") '
                 f'AND label == "{label}" AND visible == true')
    return tap(driver, AppiumBy.IOS_PREDICATE, predicate, timeout=3)


def tap_by_predicate(driver, predicate, timeout=None):
    """Tap an element by iOS predicate string."""
    return tap(driver, AppiumBy.IOS_PREDICATE, predicate, timeout or 8)


def tap_coordinates(driver, x, y):
    """Tap at absolute coordinates (from SpecterQA replays)."""
    try:
        driver.execute_script("mobile: tap", {"x": x, "y": y})
        settle(driver)
        return True
    except WebDriverException:
        return False


def tap_tab(driver, label):
    """Tap a tab bar item. Tries label first, then coordinates from replays."""
    # Map labels to X coordinates from SpecterQA replays
    tab_coords = {
        "Catalog": 49.0,
        "My Books": 146.5,
        "Reservations": 244.0,
        "Holds": 244.0,
        "Settings": 341.5,
    }
    if tap_by_label(driver, label, timeout=5):
        return True
    # Coordinate fallback
    x = tab_coords.get(label)
    if x:
        return tap_coordinates(driver, x, TAB_BAR_Y)
    return False


def scroll_down(driver):
    """Scroll down on the current view."""
    try:
        driver.execute_script("mobile: scroll", {"direction": "down"})
        settle(driver)
    except WebDriverException:
        pass


def screenshot(driver, output_dir, version, name):
    """Save a screenshot. Returns True on success."""
    filename = f"U1-{version}-{name}.png"
    filepath = os.path.join(output_dir, filename)
    try:
        driver.save_screenshot(filepath)
        print(f"  [OK] {filename}")
        return True
    except WebDriverException as e:
        print(f"  [FAIL] {filename}: {e}")
        return False


def has_element(driver, label, timeout=3):
    """Check if an element with the given label exists."""
    return find_el(driver, AppiumBy.ACCESSIBILITY_ID, label, timeout) is not None


# ---------------------------------------------------------------------------
# Onboarding handler
# ---------------------------------------------------------------------------


def dismiss_alerts(driver):
    """Dismiss any system alerts (notification permissions, tracking, etc)."""
    for _ in range(3):
        for label in ["Allow", "OK", "Continue", "Not Now", "Allow While Using App",
                       "Don't Allow"]:
            try:
                alert_btn = driver.find_element(AppiumBy.ACCESSIBILITY_ID, label)
                alert_btn.click()
                settle(driver, 1)
            except (NoSuchElementException, WebDriverException):
                pass


def add_a1qa_library(driver):
    """Search for and add Addison Public Library from the library picker."""
    print("  Searching for Addison Public Library...")

    # We should be on the "Add Library" screen or library picker
    search = find_el(driver, AppiumBy.IOS_PREDICATE,
                     'type == "XCUIElementTypeSearchField"', timeout=8)
    if search:
        try:
            search.clear()
            search.send_keys("Addison")
            settle(driver, 4)
        except WebDriverException:
            pass

    # Tap on Addison Public Library in results
    if tap_by_predicate(driver,
                        'label CONTAINS "Addison"',
                        timeout=8):
        print("  Selected Addison Public Library")
        settle(driver, 5)
        return True

    print("  WARNING: Could not find Addison Public Library")
    return False


def ensure_a1qa_is_current(driver):
    """Make sure Addison Public Library is the active library, not some random one."""
    # Check if we're already on A1QA
    if has_element(driver, "Addison Public Library", timeout=3):
        print("  Addison Public Library is already active")
        return True

    # Try Switch Library button (top-left on catalog, from SpecterQA replays)
    if tap_by_label(driver, "Switch Library", timeout=5):
        settle(driver, 2)
        # Check if A1QA is in the list
        if tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=5):
            print("  Switched to Addison Public Library")
            settle(driver, 5)
            return True
        # A1QA not in list — add it via "Add Library"
        if tap_by_label(driver, "Add Library", timeout=3):
            settle(driver, 2)
            return add_a1qa_library(driver)
        # Dismiss the picker if we can't find it
        tap_by_label(driver, "Cancel", timeout=3)

    return False


def handle_onboarding(driver):
    """Dismiss onboarding, add Addison Public Library, and ensure it's the active library."""
    print("Checking for onboarding screen...")
    settle(driver, 5)

    dismiss_alerts(driver)

    # Scenario -1: Onboarding image screen with Close button (1.2.8 fresh install)
    # 1.2.8 shows a full-screen onboarding image with only a Close button
    # Keep dismissing until it's gone (there may be multiple pages)
    for _ in range(5):
        close_btn = find_el(driver, AppiumBy.ACCESSIBILITY_ID, "Close", timeout=3)
        if not close_btn:
            break
        # Verify we're on an onboarding screen (very few elements visible)
        try:
            all_els = driver.find_elements(AppiumBy.IOS_PREDICATE, 'visible == true')
            if len(all_els) < 10:
                print(f"  Onboarding screen detected ({len(all_els)} elements) -- tapping Close...")
                close_btn.click()
                settle(driver, 2)
            else:
                break  # Not onboarding, probably a real screen with a Close button
        except WebDriverException:
            break

    # Scenario 0: On the "Add Library" screen (2.2.5 fresh install opens here directly)
    add_library_title = find_el(driver, AppiumBy.IOS_PREDICATE,
                                'label == "Add Library" AND type == "XCUIElementTypeStaticText"',
                                timeout=5)
    if add_library_title:
        print("  On Add Library screen -- selecting Addison Public Library...")
        # Tap Addison directly from the visible list
        if tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=5):
            print("  Selected Addison Public Library")
            settle(driver, 8)  # wait for catalog to load
            return True
        # Scroll down to find it
        scroll_down(driver)
        if tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=5):
            print("  Selected Addison Public Library (after scroll)")
            settle(driver, 8)
            return True

    # Scenario 1: Already on a catalog with tab bar visible
    if has_element(driver, "Catalog", timeout=5) or has_element(driver, "My Books", timeout=3):
        print("  App launched with library configured")
        ensure_a1qa_is_current(driver)
        return True

    # Scenario 2: Onboarding walkthrough ("Getting Started with Palace")
    onboarding = find_el(driver, AppiumBy.IOS_PREDICATE,
                         'label CONTAINS "Getting Started" OR label CONTAINS "Find Your Library" OR label CONTAINS "Step 1"',
                         timeout=5)
    if onboarding:
        print("  Onboarding walkthrough detected -- dismissing...")
        # Try close/X button
        for label in ["Close", "Skip", "Dismiss"]:
            if tap_by_label(driver, label, timeout=3):
                print(f"    Dismissed via {label}")
                break
        else:
            # Try unnamed close button (X in top-right)
            tap_by_predicate(driver, 'type == "XCUIElementTypeButton" AND label == ""', timeout=3)
            # Swipe through pages
            for _ in range(5):
                try:
                    driver.execute_script("mobile: swipe", {"direction": "left"})
                    settle(driver, 1)
                except WebDriverException:
                    break
            for label in ["Get Started", "Done", "Continue", "Find Your Library"]:
                if tap_by_label(driver, label, timeout=3):
                    break
        settle(driver, 3)

    # Scenario 3: "Add Library" screen (fresh install or post-onboarding)
    add_library = find_el(driver, AppiumBy.IOS_PREDICATE,
                          'label == "Add Library" AND type == "XCUIElementTypeStaticText"',
                          timeout=5)
    if add_library:
        print("  On Add Library screen")
        add_a1qa_library(driver)
        settle(driver, 5)
        # After adding, we should land on the catalog
        if has_element(driver, "Catalog", timeout=8):
            print("  Catalog loaded with A1QA")
            return True

    # Scenario 4: Library picker half-sheet
    if has_element(driver, "Add Library", timeout=3):
        print("  Library picker visible -- adding A1QA...")
        tap_by_label(driver, "Add Library", timeout=3)
        settle(driver, 2)
        add_a1qa_library(driver)
        settle(driver, 5)
        if has_element(driver, "Catalog", timeout=8):
            return True

    # Final check — make sure A1QA is active
    if has_element(driver, "Catalog", timeout=5):
        ensure_a1qa_is_current(driver)
        return True

    print("  WARNING: Could not complete setup -- screenshots may be limited")
    return False


# ---------------------------------------------------------------------------
# Screen capture functions
# ---------------------------------------------------------------------------


def ensure_a1qa_active(driver):
    """First-run setup: make sure Addison Public Library is the active library.
    Call once before walking screens."""
    print("  Ensuring Addison Public Library is active...")
    tap_tab(driver, "Catalog")
    settle(driver, 3)

    # Already on A1QA?
    if has_element(driver, "Addison Public Library", timeout=3):
        print("    A1QA already active")
        return True

    # Open Switch Library
    if tap_by_label(driver, "Switch Library", timeout=5):
        settle(driver, 2)

        # A1QA already in list?
        if tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=3):
            print("    Switched to A1QA")
            settle(driver, 5)
            return True

        # Not in list — add it
        if tap_by_label(driver, "Add Library", timeout=3):
            settle(driver, 2)
            add_a1qa_library(driver)
            settle(driver, 5)

            # Now switch to it
            if tap_by_label(driver, "Switch Library", timeout=5):
                settle(driver, 2)
                if tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=5):
                    print("    Switched to A1QA after adding")
                    settle(driver, 5)
                    return True
                tap_by_label(driver, "Cancel", timeout=3)
        else:
            tap_by_label(driver, "Cancel", timeout=3)

    # Check if we're on the Add Library screen (2.2.5 fresh install)
    add_library = find_el(driver, AppiumBy.IOS_PREDICATE,
                          'label == "Add Library" AND type == "XCUIElementTypeStaticText"',
                          timeout=3)
    if add_library:
        add_a1qa_library(driver)
        settle(driver, 5)
        return has_element(driver, "Addison Public Library", timeout=5)

    print("    WARNING: Could not switch to A1QA")
    return False


def verify_screen(driver, expect_any=None, expect_none=None, debug=True):
    """Verify we landed on the right screen by checking for expected elements.
    Returns True if at least one expected element is found and no forbidden elements are found."""
    if expect_any:
        found = any(has_element(driver, label, timeout=3) for label in expect_any)
        if not found:
            # Also check by label on any visible element type (SwiftUI uses XCUIElementTypeOther)
            for label in expect_any:
                if "==" in label or "CONTAINS" in label:
                    if find_el(driver, AppiumBy.IOS_PREDICATE, label, timeout=2):
                        found = True
                        break
                else:
                    pred = f'label == "{label}" AND visible == true'
                    if find_el(driver, AppiumBy.IOS_PREDICATE, pred, timeout=2):
                        found = True
                        break
        if not found:
            print(f"    VERIFY FAIL: none of {expect_any} found")
            if debug:
                dump_visible_labels(driver)
            return False
    if expect_none:
        for label in expect_none:
            if has_element(driver, label, timeout=2):
                print(f"    VERIFY FAIL: unexpected element '{label}' found")
                return False
    return True


def dump_visible_labels(driver):
    """Print the labels of all visible elements for debugging navigation failures."""
    try:
        els = driver.find_elements(AppiumBy.IOS_PREDICATE,
                                   'visible == true AND label.length > 0')
        labels = []
        for el in els[:40]:
            try:
                lbl = el.get_attribute("label")
                typ = el.get_attribute("type")
                if lbl:
                    labels.append(f"{typ}: {lbl}")
            except WebDriverException:
                pass
        if labels:
            print("    DEBUG visible elements:")
            for l in labels:
                print(f"      {l}")
    except WebDriverException:
        print("    DEBUG: could not dump elements")


def reset_to_catalog(driver):
    """Reset to a known state: Catalog tab."""
    # Dismiss any modals/search
    tap_by_label(driver, "Cancel", timeout=2)
    tap_by_label(driver, "Back", timeout=2)
    tap_by_label(driver, "Cancel", timeout=2)
    tap_tab(driver, "Catalog")
    settle(driver, 3)


def capture_catalog(driver, output_dir, version):
    print("  [1/15] Catalog home")
    tap_tab(driver, "Catalog")
    settle(driver, 3)
    if not verify_screen(driver, expect_any=["Newly Added Titles", "More...", "All", "Ebooks"],
                         expect_none=["Add Library"]):
        print("    Navigation failed -- not on catalog")
        return False
    return screenshot(driver, output_dir, version, "catalog-home")


def capture_catalog_ebooks(driver, output_dir, version):
    print("  [2/15] Catalog - Ebooks filter")
    tap_by_label(driver, "Ebooks", timeout=5)
    settle(driver, 2)
    if not verify_screen(driver, expect_any=["Ebooks"]):
        return False
    return screenshot(driver, output_dir, version, "catalog-ebooks")


def capture_catalog_audiobooks(driver, output_dir, version):
    print("  [3/15] Catalog - Audiobooks filter")
    tap_by_label(driver, "Audiobooks", timeout=5)
    settle(driver, 2)
    if not verify_screen(driver, expect_any=["Audiobooks"]):
        return False
    ok = screenshot(driver, output_dir, version, "catalog-audiobooks")
    tap_by_label(driver, "All", timeout=3)
    settle(driver, 1)
    return ok


def capture_search_empty(driver, output_dir, version):
    print("  [4/15] Search (empty)")
    # Make sure we're on catalog first
    tap_tab(driver, "Catalog")
    settle(driver, 2)
    # Try multiple ways to open search
    if not tap_by_label(driver, "Search Catalog", timeout=3):
        # Try magnifying glass icon (coordinate from SpecterQA replays)
        tap_coordinates(driver, 358.0, 69.0)
    settle(driver, 2)
    # Also try tapping a search field directly
    search = find_el(driver, AppiumBy.IOS_PREDICATE,
                     'type == "XCUIElementTypeSearchField"', timeout=3)
    if search:
        try:
            search.click()
            settle(driver, 1)
        except WebDriverException:
            pass
    # Verify: search field or Cancel button
    if not verify_screen(driver, expect_any=["Cancel", "Clear search"]):
        print("    Search screen not reached")
        return False
    return screenshot(driver, output_dir, version, "search-empty")


def capture_search_results(driver, output_dir, version):
    print("  [5/15] Search results")
    # If search empty failed, try opening search fresh
    search = find_el(driver, AppiumBy.IOS_PREDICATE,
                     'type == "XCUIElementTypeSearchField"', timeout=5)
    if not search:
        # Try to open search again
        tap_tab(driver, "Catalog")
        settle(driver, 2)
        tap_by_label(driver, "Search Catalog", timeout=3) or tap_coordinates(driver, 358.0, 69.0)
        settle(driver, 2)
        search = find_el(driver, AppiumBy.IOS_PREDICATE,
                         'type == "XCUIElementTypeSearchField"', timeout=5)
    if search:
        try:
            search.click()
            settle(driver, 0.5)
            search.clear()
            search.send_keys("jane")
            settle(driver, 4)
        except WebDriverException as e:
            print(f"    Could not type: {e}")
    # Verify: should see results, not "Add Library"
    if has_element(driver, "Add Library", timeout=2):
        print("    VERIFY FAIL: on Add Library, not search results")
        reset_to_catalog(driver)
        return False
    return screenshot(driver, output_dir, version, "search-results")


def capture_book_detail(driver, output_dir, version):
    print("  [6/15] Book detail")
    # 2.2.5 search results are XCUIElementTypeOther with "Title, by Author" labels
    # 1.2.8 uses XCUIElementTypeCell
    tapped = tap_by_predicate(driver,
                              'type == "XCUIElementTypeCell" AND visible == true',
                              timeout=3)
    if not tapped:
        # 2.2.5 SwiftUI: books are XCUIElementTypeOther with ", by " in label
        tapped = tap_by_predicate(driver,
                                  'type == "XCUIElementTypeOther" AND label CONTAINS ", by " AND visible == true',
                                  timeout=3)
    if not tapped:
        # Last resort: tap first book lane item
        tapped = tap_by_predicate(driver,
                                  'type == "XCUIElementTypeButton" AND visible == true AND label.length > 5',
                                  timeout=3)
    settle(driver, 3)
    # Verify: should see DESCRIPTION or Borrow/Preview or Go back
    if verify_screen(driver, expect_any=["DESCRIPTION", "Borrow", "Preview", "Back",
                                          "Go back", "MORE", "INFORMATION"]):
        return screenshot(driver, output_dir, version, "book-detail")
    print("    Not on book detail screen")
    return False


def capture_book_detail_scrolled(driver, output_dir, version):
    print("  [7/15] Book detail (scrolled)")
    # Only scroll if we're actually on a detail screen
    if not verify_screen(driver, expect_any=["DESCRIPTION", "Borrow", "Preview", "Back",
                                              "INFORMATION"]):
        print("    Not on book detail -- skipping scroll")
        return False
    scroll_down(driver)
    ok = screenshot(driver, output_dir, version, "book-detail-scrolled")
    # Navigate back to catalog
    tap_by_label(driver, "Go back", timeout=2)
    tap_by_label(driver, "Back", timeout=2)
    tap_by_label(driver, "Cancel", timeout=2)
    settle(driver, 1)
    tap_by_label(driver, "Cancel", timeout=2)
    return ok


def capture_my_books(driver, output_dir, version):
    print("  [8/15] My Books")
    tap_tab(driver, "My Books")
    settle(driver, 3)
    # Verify: should see My Books content (empty state or book list), not catalog
    if not verify_screen(driver, expect_any=["Visit the Catalog", "Sort", "My Books",
                                              "Title", "Search Books"]):
        print("    Not on My Books screen")
        return False
    return screenshot(driver, output_dir, version, "my-books")


def capture_holds(driver, output_dir, version):
    print("  [9/15] Holds / Reservations")
    # Try both labels, then coordinate fallback
    # 1.2.8 has 3 tabs: Catalog(49) / My Books(146.5) / Settings(341.5)
    #   — Reservations is NOT a tab in 1.2.8, it's a segment in My Books for some libraries
    # 2.2.5 has 4 tabs: Catalog(49) / My Books(107) / Holds(195) / Settings(292)
    if not tap_tab(driver, "Holds"):
        if not tap_tab(driver, "Reservations"):
            # Try 4-tab coordinate for Holds position
            tap_coordinates(driver, 195.0, TAB_BAR_Y)
    settle(driver, 3)
    # Verify: should see holds/reservations content or the empty state message
    if not verify_screen(driver, expect_any=["When you reserve", "When you place a hold",
                                              "Holds", "Search Reservations",
                                              "Search Holds", "available to download"]):
        # 1.2.8 with 3-tab bar: Reservations might be a segment within My Books
        # Try tapping "Reservations" segment/button within My Books
        tap_tab(driver, "My Books")
        settle(driver, 2)
        if tap_by_label(driver, "Reservations", timeout=3):
            settle(driver, 2)
            return screenshot(driver, output_dir, version, "holds")
        print("    Not on Holds/Reservations screen")
        return False
    return screenshot(driver, output_dir, version, "holds")


def capture_settings(driver, output_dir, version):
    print("  [10/15] Settings")
    tap_tab(driver, "Settings")
    settle(driver, 3)
    if not verify_screen(driver, expect_any=["Libraries", "About App", "Software Licenses",
                                              "Privacy Policy"]):
        print("    Not on Settings screen")
        return False
    return screenshot(driver, output_dir, version, "settings")


def capture_libraries_list(driver, output_dir, version):
    print("  [11/15] Libraries list")
    # Ensure we're on Settings first
    tap_tab(driver, "Settings")
    settle(driver, 2)
    # Try tapping "Libraries" — in 2.2.5 SwiftUI it may be a NavigationLink cell
    if not tap_by_label(driver, "Libraries", timeout=5):
        # Try predicate for cell containing "Libraries"
        tap_by_predicate(driver,
                         'type == "XCUIElementTypeCell" AND label CONTAINS "Libraries"',
                         timeout=3)
        if not tap_by_predicate(driver,
                                'label == "Libraries" AND type == "XCUIElementTypeButton"',
                                timeout=3):
            # Coordinate fallback — Libraries is first row below header
            tap_coordinates(driver, 195.0, 165.0)
    settle(driver, 2)
    # Verify
    if not verify_screen(driver, expect_any=["Addison Public Library", "Addison",
                                              "Add Library"]):
        print("    Not on Libraries list")
        return False
    return screenshot(driver, output_dir, version, "libraries-list")


def capture_account_detail(driver, output_dir, version):
    print("  [12/15] Account detail")
    tap_by_predicate(driver, 'label CONTAINS "Addison"', timeout=5)
    settle(driver, 2)
    # Verify: should see account fields (Barcode/PIN/Sign in or Sign out)
    if not verify_screen(driver, expect_any=["Barcode", "PIN", "Sign in", "Sign out",
                                              "Report an Issue", "Content Licenses"]):
        print("    Not on Account detail")
        return False
    return screenshot(driver, output_dir, version, "account-detail")


def capture_account_scrolled(driver, output_dir, version):
    print("  [13/15] Account detail (scrolled)")
    if not verify_screen(driver, expect_any=["Barcode", "PIN", "Sign in", "Sign out",
                                              "Report an Issue", "Content Licenses"]):
        print("    Not on Account detail -- skipping scroll")
        return False
    scroll_down(driver)
    ok = screenshot(driver, output_dir, version, "account-detail-scrolled")
    # Navigate back to settings
    tap_by_label(driver, "Libraries", timeout=3) or tap_by_label(driver, "Back", timeout=3)
    settle(driver, 1)
    tap_by_label(driver, "Settings", timeout=3) or tap_by_label(driver, "Back", timeout=3)
    return ok


def capture_software_licenses(driver, output_dir, version):
    print("  [14/15] Software Licenses")
    tap_tab(driver, "Settings")
    settle(driver, 2)
    scroll_down(driver)
    if tap_by_label(driver, "Software Licenses", timeout=5):
        settle(driver, 2)
        if not verify_screen(driver, expect_any=["Software Licenses"]):
            return False
        ok = screenshot(driver, output_dir, version, "software-licenses")
        tap_by_label(driver, "Settings", timeout=3) or tap_by_label(driver, "Back", timeout=3)
        return ok
    print("    Software Licenses not found")
    return False


def capture_about(driver, output_dir, version):
    print("  [15/15] About App")
    tap_tab(driver, "Settings")
    settle(driver, 2)
    if tap_by_label(driver, "About App", timeout=5):
        settle(driver, 2)
        ok = screenshot(driver, output_dir, version, "about-app")
        tap_by_label(driver, "Settings", timeout=3) or tap_by_label(driver, "Back", timeout=3)
        return ok
    print("    About App not found")
    return False


# ---------------------------------------------------------------------------
# Screen list and main
# ---------------------------------------------------------------------------

SCREENS = [
    ("Catalog (home)", capture_catalog),
    ("Catalog (Ebooks)", capture_catalog_ebooks),
    ("Catalog (Audiobooks)", capture_catalog_audiobooks),
    ("Search (empty)", capture_search_empty),
    ("Search results", capture_search_results),
    ("Book detail", capture_book_detail),
    ("Book detail (scrolled)", capture_book_detail_scrolled),
    ("My Books", capture_my_books),
    ("Holds/Reservations", capture_holds),
    ("Settings", capture_settings),
    ("Libraries list", capture_libraries_list),
    ("Account detail", capture_account_detail),
    ("Account detail (scrolled)", capture_account_scrolled),
    ("Software Licenses", capture_software_licenses),
    ("About App", capture_about),
]


def main():
    parser = argparse.ArgumentParser(
        description="BrowserStack Screenshot Walker for Palace iOS",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Capture screenshots of Palace 1.2.8
  %(prog)s --ipa ~/Downloads/Palace-1.2.8-resigned.ipa --version 1.2.8

  # Reuse previously uploaded build
  %(prog)s --app-url bs://58f1aa5e3ea... --version 1.2.8

  # Capture screenshots of Palace 2.2.5 on a different device
  %(prog)s --ipa ~/Downloads/Palace-2.2.5.ipa --version 2.2.5 \\
           --device "iPhone 15 Pro" --os-version "17"
        """,
    )
    parser.add_argument("--ipa", help="Path to IPA file to upload")
    parser.add_argument("--app-url", help="BrowserStack app_url (bs://...) to skip upload")
    parser.add_argument("--version", required=True, help="Version label for filenames")
    parser.add_argument("--device", default=DEFAULT_DEVICE, help=f"Device (default: {DEFAULT_DEVICE})")
    parser.add_argument("--os-version", default=DEFAULT_OS_VERSION, help=f"iOS version (default: {DEFAULT_OS_VERSION})")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR, help="Output directory")

    args = parser.parse_args()

    if not args.ipa and not args.app_url:
        parser.error("Either --ipa or --app-url is required")

    output_dir = os.path.expanduser(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    app_url = args.app_url if args.app_url else upload_ipa(args.ipa)

    driver = None
    try:
        driver = create_driver(app_url, args.version, args.device, args.os_version)
        settle(driver, 5)

        # Handle onboarding / fresh install
        handle_onboarding(driver)

        # Ensure A1QA is the active library before walking
        ensure_a1qa_active(driver)

        # Walk screens
        print(f"\nCapturing {len(SCREENS)} screens for version {args.version}...\n")
        results = {}

        for name, fn in SCREENS:
            try:
                ok = fn(driver, output_dir, args.version)
                results[name] = "OK" if ok else "SKIP"
            except WebDriverException as e:
                print(f"  [ERROR] {name}: {e}")
                results[name] = "ERROR"
            except Exception as e:
                print(f"  [ERROR] {name}: {e}")
                results[name] = "ERROR"

        # Summary
        ok = sum(1 for v in results.values() if v == "OK")
        skip = sum(1 for v in results.values() if v == "SKIP")
        err = sum(1 for v in results.values() if v == "ERROR")

        print("\n" + "=" * 60)
        print(f"SUMMARY - Palace iOS {args.version}")
        print("=" * 60)
        for name, status in results.items():
            marker = {"OK": "[OK]", "SKIP": "[SKIP]", "ERROR": "[ERR]"}[status]
            print(f"  {marker:8s} {name}")
        print(f"\nCaptured: {ok}/{len(SCREENS)}  Skipped: {skip}  Errors: {err}")
        print(f"Screenshots saved to: {output_dir}")

        # Check for duplicate screenshots (indicates navigation failure)
        import hashlib
        hashes = {}
        dupes = []
        for name, st in results.items():
            if st != "OK":
                continue
            screen_key = name.lower().replace(" ", "-").replace("/", "-").replace("(", "").replace(")", "")
            filepath = os.path.join(output_dir, f"U1-{args.version}-{screen_key}.png")
            if not os.path.exists(filepath):
                # Try the actual filenames used
                continue
            h = hashlib.md5(open(filepath, 'rb').read()).hexdigest()
            if h in hashes:
                dupes.append((name, hashes[h]))
            hashes[h] = name

        if dupes:
            print("\nWARNING: Duplicate screenshots detected (navigation may have failed):")
            for dup, orig in dupes:
                print(f"  {dup} == {orig}")

        status = "passed" if err == 0 else "failed"
        try:
            driver.execute_script(
                f'browserstack_executor: {{"action": "setSessionStatus", '
                f'"arguments": {{"status": "{status}", '
                f'"reason": "Captured {ok}/{len(SCREENS)} screens"}}}}'
            )
        except WebDriverException:
            pass

    except WebDriverException as e:
        print(f"\nFATAL: {e}")
        sys.exit(1)
    finally:
        if driver:
            print("\nEnding session...")
            try:
                driver.quit()
            except WebDriverException:
                pass
            print("Done.")


if __name__ == "__main__":
    main()
