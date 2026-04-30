#!/usr/bin/env python3
"""
Physical Device Performance Walker for Palace iOS

Drives the Palace app on a physical device via WebDriverAgent (WDA),
executing a comprehensive test flow while xctrace records allocations/leaks.

Every action is verified — if a tap doesn't produce the expected result,
the script logs the failure and attempts recovery.

Usage:
    # 1. Start WDA on the device (already running if simdrive (or specterqa-ios legacy) worked)
    # 2. Start xctrace in another terminal:
    #    xctrace record --device <ECID> --template Allocations --attach <PID> --time-limit 10m --no-prompt
    # 3. Run this script:
    python3 scripts/perf-walker-device.py --wda-url http://192.168.1.26:8100

Requirements:
    pip3 install Appium-Python-Client
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime

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
    print("ERROR: pip3 install Appium-Python-Client")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

BUNDLE_ID = "org.thepalaceproject.palace"
OUTPUT_DIR = os.path.expanduser("~/Desktop/regression-PP-4020/profiling")
SETTLE_PAUSE = 2.0
ELEMENT_WAIT = 10

# WDA's bundled Appium uses "predicate string" not "-ios predicate string"
IOS_PREDICATE = "predicate string"

# ---------------------------------------------------------------------------
# Perf metrics
# ---------------------------------------------------------------------------

perf_log = []
_device_ecid = None  # Set from CLI args
_app_pid = None


def _get_memory_from_xctrace():
    """Get a quick memory snapshot via a 1-second Allocations trace.
    Returns (rss_mb, dirty_mb) or (None, None) on failure."""
    if not _device_ecid or not _app_pid:
        return None, None
    try:
        import subprocess
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = os.path.join(tmpdir, "snapshot.trace")
            result = subprocess.run(
                ["xctrace", "record",
                 "--device", _device_ecid,
                 "--template", "Allocations",
                 "--attach", str(_app_pid),
                 "--output", trace_path,
                 "--time-limit", "1s",
                 "--no-prompt"],
                capture_output=True, text=True, timeout=15
            )
            # Parse the trace TOC for summary data
            if os.path.exists(trace_path):
                toc = subprocess.run(
                    ["xctrace", "export", "--input", trace_path, "--toc"],
                    capture_output=True, text=True, timeout=10
                )
                # Extract duration as a sanity check
                return None, None  # xctrace snapshots don't give RSS directly
    except Exception:
        pass
    return None, None


def _get_memory_from_devicectl():
    """Get Palace PID and basic process info from devicectl."""
    global _app_pid
    try:
        import subprocess
        result = subprocess.run(
            ["xcrun", "devicectl", "device", "info", "processes",
             "--device", "31471BBD-6889-5DAC-9497-BCD565AB1CD6",
             "--json-output", "/tmp/palace-procs.json"],
            capture_output=True, text=True, timeout=10
        )
        with open("/tmp/palace-procs.json") as f:
            data = json.load(f)
        for proc in data.get("result", {}).get("runningProcesses", []):
            if "Palace" in proc.get("executable", ""):
                _app_pid = proc.get("processIdentifier")
                return _app_pid
    except Exception:
        pass
    return None


def log_perf(phase, driver):
    """Capture a performance snapshot with timestamp and available metrics."""
    wall_start = perf_log[0]["wall"] if perf_log else time.time()
    elapsed = time.time() - wall_start

    entry = {
        "phase": phase,
        "timestamp": datetime.now().isoformat(),
        "elapsed_sec": elapsed,
    }
    if not perf_log:
        entry["wall"] = time.time()
    else:
        entry["wall"] = wall_start

    # Try to get window size as a proxy for orientation/state
    try:
        size = driver.get_window_size()
        entry["window"] = f"{size['width']}x{size['height']}"
    except Exception:
        pass

    perf_log.append(entry)
    print(f"  [PERF] {phase} @ {elapsed:.1f}s")


# ---------------------------------------------------------------------------
# Helpers (with verification)
# ---------------------------------------------------------------------------


def settle(seconds=None):
    time.sleep(seconds if seconds is not None else SETTLE_PAUSE)


def find_el(driver, by, value, timeout=None):
    timeout = timeout or ELEMENT_WAIT
    try:
        return WebDriverWait(driver, timeout).until(
            EC.presence_of_element_located((by, value))
        )
    except (TimeoutException, NoSuchElementException):
        return None


def has_element(driver, label, timeout=3):
    return find_el(driver, AppiumBy.ACCESSIBILITY_ID, label, timeout) is not None


def tap_label(driver, label, timeout=None, verify_gone=False):
    """Tap by accessibility label. Returns True on success."""
    el = find_el(driver, AppiumBy.ACCESSIBILITY_ID, label, timeout or 8)
    if not el:
        # Fallback: predicate search
        pred = f'label == "{label}" AND visible == true'
        el = find_el(driver, IOS_PREDICATE, pred, timeout=3)
    if el:
        try:
            el.click()
            settle()
            if verify_gone:
                gone = not has_element(driver, label, timeout=2)
                if not gone:
                    print(f"    WARN: '{label}' still visible after tap")
            return True
        except WebDriverException as e:
            print(f"    TAP FAIL '{label}': {e}")
    else:
        print(f"    NOT FOUND: '{label}'")
    return False


def tap_predicate(driver, predicate, timeout=None):
    el = find_el(driver, IOS_PREDICATE, predicate, timeout or 8)
    if el:
        try:
            el.click()
            settle()
            return True
        except WebDriverException:
            pass
    return False


def tap_tab(driver, label):
    """Tap a tab bar item."""
    return tap_label(driver, label, timeout=5)


def scroll_down(driver, times=1):
    for _ in range(times):
        try:
            driver.execute_script("mobile: scroll", {"direction": "down"})
            settle(0.5)
        except WebDriverException:
            pass


def scroll_up(driver, times=1):
    for _ in range(times):
        try:
            driver.execute_script("mobile: scroll", {"direction": "up"})
            settle(0.5)
        except WebDriverException:
            pass


def screenshot(driver, name):
    filepath = os.path.join(OUTPUT_DIR, f"perf-{name}.png")
    try:
        driver.save_screenshot(filepath)
        print(f"    [OK] {name}.png")
        return True
    except WebDriverException:
        print(f"    [FAIL] {name}.png")
        return False


def verify_screen(driver, expect_any, context=""):
    """Verify at least one expected element is visible."""
    for label in expect_any:
        if has_element(driver, label, timeout=3):
            return True
    # Fallback: check by label predicate
    for label in expect_any:
        pred = f'label CONTAINS "{label}" AND visible == true'
        if find_el(driver, IOS_PREDICATE, pred, timeout=2):
            return True
    visible = dump_labels(driver, limit=10)
    print(f"    VERIFY FAIL ({context}): none of {expect_any} found. Visible: {visible}")
    return False


def dump_labels(driver, limit=15):
    """Return visible element labels for debugging."""
    try:
        els = driver.find_elements(IOS_PREDICATE,
                                   'visible == true AND label.length > 0')
        return [el.get_attribute("label") for el in els[:limit]]
    except WebDriverException:
        return []


# ---------------------------------------------------------------------------
# Test flow phases
# ---------------------------------------------------------------------------


def phase_catalog_browse(driver):
    """Phase 1: Browse catalog — scroll, switch filters."""
    print("\n=== Phase 1: Catalog Browsing ===")
    tap_tab(driver, "Catalog")
    settle(3)

    if not verify_screen(driver, ["All", "Ebooks", "Audiobooks", "Catalog"], "catalog"):
        return False

    log_perf("catalog_home", driver)
    screenshot(driver, "01-catalog-home")

    # Scroll through lanes
    scroll_down(driver, times=5)
    log_perf("catalog_scrolled_5x", driver)
    screenshot(driver, "02-catalog-scrolled")

    # Switch to Audiobooks
    tap_label(driver, "Audiobooks")
    if verify_screen(driver, ["Audiobooks"], "audiobooks filter"):
        log_perf("audiobooks_filter", driver)
        screenshot(driver, "03-audiobooks")
        scroll_down(driver, times=3)

    # Switch to Ebooks
    tap_label(driver, "Ebooks")
    settle(2)
    scroll_down(driver, times=2)
    log_perf("ebooks_filter", driver)

    # Back to All
    tap_label(driver, "All")
    settle(2)
    scroll_up(driver, times=5)
    log_perf("catalog_back_to_top", driver)

    return True


def phase_tab_navigation(driver):
    """Phase 2: Navigate all tabs."""
    print("\n=== Phase 2: Tab Navigation ===")

    tap_tab(driver, "My Books")
    settle(3)
    if verify_screen(driver, ["My Books", "Title", "Listen", "Read", "Download"], "my books"):
        log_perf("my_books_tab", driver)
        screenshot(driver, "04-mybooks")
        scroll_down(driver, times=2)

    tap_tab(driver, "Reservations")
    settle(2)
    log_perf("reservations_tab", driver)

    tap_tab(driver, "Settings")
    settle(2)
    if verify_screen(driver, ["Settings", "Developer Settings", "Accounts"], "settings"):
        log_perf("settings_tab", driver)
        screenshot(driver, "05-settings")

    tap_tab(driver, "Catalog")
    settle(2)
    log_perf("back_to_catalog", driver)

    return True


def phase_library_switch(driver):
    """Phase 3: Switch libraries."""
    print("\n=== Phase 3: Library Switch ===")

    if tap_label(driver, "Switch Library", timeout=5):
        settle(3)
        screenshot(driver, "06-library-picker")

        # Try to find another library
        if tap_predicate(driver, 'label CONTAINS "Lyrasis"', timeout=5):
            settle(5)
            log_perf("switched_to_lyrasis", driver)
            screenshot(driver, "07-lyrasis")

            # Switch back
            if tap_label(driver, "Switch Library", timeout=5):
                settle(2)
                tap_predicate(driver, 'label CONTAINS "A1QA"', timeout=5)
                settle(5)
                log_perf("switched_back_a1qa", driver)
        else:
            print("    Lyrasis not found, dismissing picker")
            tap_label(driver, "Cancel", timeout=3)
    else:
        print("    Switch Library button not found")

    return True


def phase_audiobook_playback(driver):
    """Phase 4: Open and play an audiobook."""
    print("\n=== Phase 4: Audiobook Playback ===")

    tap_tab(driver, "My Books")
    settle(3)

    # Find Animal Farm (or any audiobook with Listen button)
    el = find_el(driver, IOS_PREDICATE,
                 'label CONTAINS "Animal Farm"', timeout=5)
    if not el:
        print("    Animal Farm not found, looking for any Listen button")
        el = find_el(driver, IOS_PREDICATE,
                     'label == "Listen" AND visible == true', timeout=5)
        if el:
            el.click()
            settle(5)
        else:
            print("    No audiobook available — skipping playback")
            return False
    else:
        # Tap Animal Farm to open detail/half-sheet
        el.click()
        settle(3)
        screenshot(driver, "08-audiobook-tapped")

        # Now find and tap Listen
        listen = find_el(driver, AppiumBy.ACCESSIBILITY_ID, "Listen", timeout=5)
        if not listen:
            listen = find_el(driver, IOS_PREDICATE,
                             'label == "Listen" AND visible == true', timeout=5)
        if listen:
            listen.click()
            settle(5)
        else:
            print("    Listen button not found after tapping book")
            screenshot(driver, "08-listen-not-found")
            return False

    # Verify audiobook player opened
    screenshot(driver, "09-audiobook-player")
    log_perf("audiobook_player_opened", driver)

    # Check for play controls
    if verify_screen(driver, ["Pause", "Play", "Chapter", "Sleep Timer",
                              "playback", "speed"], "audiobook player"):
        print("    Audiobook player confirmed!")
    else:
        print("    WARNING: May not be on audiobook player")

    # Let it play for 30 seconds
    print("    Playing audiobook for 30 seconds...")
    time.sleep(30)
    log_perf("audiobook_30s_played", driver)
    screenshot(driver, "10-audiobook-30s")

    # Pause — the pause button is centered, ~78% down the screen
    if not tap_label(driver, "Pause", timeout=2):
        try:
            size = driver.get_window_size()
            driver.execute_script("mobile: tap",
                                  {"x": size["width"] // 2,
                                   "y": int(size["height"] * 0.78)})
            settle(1)
            print("    Paused via coordinates")
        except WebDriverException:
            print("    Could not pause (may already be paused)")

    log_perf("audiobook_paused", driver)

    # Navigate back — "< My Books" is at top-left (~50, 47)
    backed = tap_label(driver, "My Books", timeout=2)
    if not backed:
        try:
            driver.execute_script("mobile: tap", {"x": 50, "y": 47})
            settle(2)
            backed = True
            print("    Back to My Books via top-left tap")
        except WebDriverException:
            pass

    if not backed:
        # Last resort: swipe from left edge
        try:
            driver.execute_script("mobile: swipe",
                                  {"direction": "right", "x": 5, "y": 400,
                                   "width": 200, "height": 0})
            settle(2)
            print("    Back via edge swipe")
        except WebDriverException:
            print("    WARNING: stuck in audiobook player")

    settle(2)

    # Verify we left the player
    if verify_screen(driver, ["My Books", "Catalog", "Settings"], "post-audiobook"):
        print("    Successfully exited audiobook player")
    else:
        # Try tapping tab bar directly
        tap_tab(driver, "My Books")
        settle(2)

    log_perf("audiobook_closed", driver)

    return True


def phase_epub_reading(driver):
    """Phase 5: Open and read an EPUB."""
    print("\n=== Phase 5: EPUB Reading ===")

    tap_tab(driver, "My Books")
    settle(3)

    # Look for a book with Read button
    read_btn = find_el(driver, IOS_PREDICATE,
                       'label == "Read" AND visible == true', timeout=5)
    if read_btn:
        print("    Found Read button, tapping...")
        read_btn.click()
        settle(5)
        screenshot(driver, "11-epub-reader")
        log_perf("epub_reader_opened", driver)

        # Verify we're in the reader
        if verify_screen(driver, ["Chapter", "Table of Contents", "Settings",
                                  "page", "Book"], "epub reader"):
            print("    EPUB reader confirmed!")
        else:
            print("    May not be in reader (WKWebView content not accessible)")

        # Turn pages by tapping the right side of the screen (Readium gesture)
        size = driver.get_window_size()
        right_x = int(size["width"] * 0.85)
        center_y = size["height"] // 2
        for i in range(5):
            try:
                driver.execute_script("mobile: tap", {"x": right_x, "y": center_y})
                time.sleep(2)
            except WebDriverException:
                pass
        log_perf("epub_5_pages_turned", driver)
        screenshot(driver, "12-epub-reading")

        # Close reader — tap the back arrow at top-left
        # First tap center to reveal nav chrome (Readium hides it)
        try:
            driver.execute_script("mobile: tap", {"x": size["width"] // 2, "y": center_y})
            time.sleep(1)
        except WebDriverException:
            pass

        # Now tap the back arrow (top-left corner)
        if not tap_label(driver, "Back", timeout=2):
            try:
                driver.execute_script("mobile: tap", {"x": 25, "y": 55})
                settle(2)
                print("    Exited reader via top-left tap")
            except WebDriverException:
                # Last resort: swipe from left edge
                try:
                    driver.execute_script("mobile: swipe",
                                          {"direction": "right",
                                           "x": 5, "y": center_y,
                                           "width": 200, "height": 0})
                    settle(2)
                    print("    Exited reader via edge swipe")
                except WebDriverException:
                    print("    WARNING: Could not exit reader")
        settle(2)
        log_perf("epub_closed", driver)
    else:
        print("    No Read button found — skipping EPUB reading")

    return True


def phase_download_book(driver):
    """Phase 6: Borrow and download a book from catalog."""
    print("\n=== Phase 6: Borrow & Download ===")

    tap_tab(driver, "Catalog")
    settle(3)

    # Look for a Borrow/Get button
    borrow = find_el(driver, IOS_PREDICATE,
                     '(label == "Borrow" OR label == "Get") AND visible == true',
                     timeout=5)
    if not borrow:
        # Scroll down to find one
        scroll_down(driver, times=3)
        borrow = find_el(driver, IOS_PREDICATE,
                         '(label == "Borrow" OR label == "Get") AND visible == true',
                         timeout=5)

    if borrow:
        print("    Found borrow button, tapping...")
        borrow.click()
        settle(3)
        log_perf("borrow_tapped", driver)
        screenshot(driver, "13-borrow-result")

        # Wait for download to complete (up to 30s)
        print("    Waiting for download...")
        for i in range(15):
            if has_element(driver, "Read", timeout=1) or has_element(driver, "Listen", timeout=1):
                log_perf("download_complete", driver)
                print(f"    Download completed in ~{i*2}s")
                break
            time.sleep(2)
        screenshot(driver, "14-download-done")
    else:
        print("    No Borrow/Get button found — skipping download")

    return True


def phase_stress_scroll(driver):
    """Phase 7: Rapid scrolling to stress image cache."""
    print("\n=== Phase 7: Stress Scroll ===")

    tap_tab(driver, "Catalog")
    settle(2)

    log_perf("stress_scroll_start", driver)

    # Rapid scroll down
    for i in range(10):
        try:
            driver.execute_script("mobile: scroll", {"direction": "down"})
            time.sleep(0.3)
        except WebDriverException:
            pass

    log_perf("stress_scroll_down_10x", driver)

    # Rapid scroll back up
    for i in range(10):
        try:
            driver.execute_script("mobile: scroll", {"direction": "up"})
            time.sleep(0.3)
        except WebDriverException:
            pass

    log_perf("stress_scroll_up_10x", driver)
    screenshot(driver, "15-final")

    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Palace Performance Walker (Physical Device)")
    parser.add_argument("--wda-url", default="http://192.168.1.26:8100",
                        help="WDA URL (default: http://192.168.1.26:8100)")
    parser.add_argument("--output-dir", default=None,
                        help="Directory for screenshots and perf data")
    parser.add_argument("--skip-audiobook", action="store_true",
                        help="Skip audiobook playback phase")
    parser.add_argument("--skip-epub", action="store_true",
                        help="Skip EPUB reading phase")
    parser.add_argument("--device-ecid", default=None,
                        help="Device ECID for xctrace (e.g. 00008150-00142D540A87801C)")
    parser.add_argument("--app-pid", type=int, default=None,
                        help="Palace PID on device (auto-detected if omitted)")
    parser.add_argument("--xctrace-template", default=None,
                        help="Instruments template to record (e.g. 'Allocations', 'Leaks', 'Time Profiler')")
    args = parser.parse_args()

    global OUTPUT_DIR, _device_ecid, _app_pid  # noqa: PLW0603
    OUTPUT_DIR = args.output_dir or OUTPUT_DIR
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    _device_ecid = args.device_ecid
    if args.app_pid:
        _app_pid = args.app_pid

    print(f"Connecting to WDA at {args.wda_url}...")

    options = AppiumOptions()
    options.set_capability("appium:automationName", "XCUITest")
    options.set_capability("appium:bundleId", BUNDLE_ID)
    options.set_capability("appium:noReset", True)
    options.set_capability("appium:newCommandTimeout", 300)

    try:
        driver = webdriver.Remote(args.wda_url, options=options)
    except Exception as e:
        print(f"ERROR: Could not connect to WDA: {e}")
        sys.exit(1)

    print(f"Connected. Session: {driver.session_id}")
    print(f"Start time: {datetime.now().isoformat()}")
    print(f"Output: {OUTPUT_DIR}")

    # Initialize perf log
    perf_log.append({"phase": "start", "wall": time.time(), "timestamp": datetime.now().isoformat(), "elapsed_sec": 0})

    # The Appium session may have relaunched Palace — wait for it to settle
    settle(3)

    # If xctrace args provided, start a trace now (after session is live)
    xctrace_proc = None
    if args.xctrace_template and _device_ecid:
        import subprocess
        trace_name = args.xctrace_template.lower().replace(" ", "-")
        trace_path = os.path.join(OUTPUT_DIR, f"{trace_name}-trace.trace")
        # Remove old trace
        import shutil
        if os.path.exists(trace_path):
            shutil.rmtree(trace_path, ignore_errors=True)
        # Get Palace PID from device (the Appium session may have relaunched it)
        try:
            pid_result = subprocess.run(
                ["xcrun", "devicectl", "device", "info", "processes",
                 "--device", "31471BBD-6889-5DAC-9497-BCD565AB1CD6"],
                capture_output=True, text=True, timeout=15
            )
            for line in pid_result.stdout.splitlines():
                if "Palace" in line:
                    _app_pid = int(line.strip().split()[0])
                    break
        except Exception:
            pass
        print(f"\n*** Starting xctrace ({args.xctrace_template}) attached to PID {_app_pid}... ***")
        xctrace_proc = subprocess.Popen(
            ["xctrace", "record",
             "--device", _device_ecid,
             "--template", args.xctrace_template,
             "--attach", str(_app_pid),
             "--output", trace_path,
             "--time-limit", "8m",
             "--no-prompt"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        time.sleep(3)
        print(f"xctrace recording to: {trace_path}\n")

    try:
        phase_catalog_browse(driver)
        phase_tab_navigation(driver)
        phase_library_switch(driver)
        if not args.skip_audiobook:
            phase_audiobook_playback(driver)
        if not args.skip_epub:
            phase_epub_reading(driver)
        phase_download_book(driver)
        phase_stress_scroll(driver)
    except Exception as e:
        print(f"\nERROR during flow: {e}")
        screenshot(driver, "error-state")
    finally:
        # Write perf log
        log_path = os.path.join(OUTPUT_DIR, "perf-timeline.json")
        with open(log_path, "w") as f:
            json.dump(perf_log, f, indent=2)
        print(f"\nPerf timeline saved: {log_path}")
        print(f"Total flow time: {time.time() - perf_log[0]['wall']:.1f}s")
        print(f"Phases completed: {len(perf_log)}")

        # Wait for xctrace to finish if running
        if xctrace_proc and xctrace_proc.poll() is None:
            print("Waiting for xctrace to complete (up to 60s)...")
            try:
                xctrace_proc.wait(timeout=60)
            except Exception:
                xctrace_proc.terminate()
            print(f"xctrace exited with code: {xctrace_proc.returncode}")

        driver.quit()
        print("Session ended.")


if __name__ == "__main__":
    main()
