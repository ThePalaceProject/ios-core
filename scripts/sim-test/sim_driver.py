"""
Simulator interaction layer for iOS Simulator testing.

Provides screenshot capture, tap, swipe, text input, and device info
by orchestrating xcrun simctl and AppleScript commands.
"""

import base64
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

from PIL import Image


@dataclass
class DeviceInfo:
    udid: str
    name: str
    os_version: str
    screen_width: int
    screen_height: int
    scale: int  # Retina scale factor


class SimulatorError(Exception):
    """Raised when a simulator operation fails."""
    pass


class SimDriver:
    """Controls the iOS Simulator via xcrun simctl and AppleScript."""

    # Default device UDID from CLAUDE.md
    DEFAULT_UDID = "DF4A2A27-9888-429D-A749-2E157A049A37"

    def __init__(self, udid: Optional[str] = None, verbose: bool = False):
        self.udid = udid or self.DEFAULT_UDID
        self.verbose = verbose
        self._device_info: Optional[DeviceInfo] = None
        self._screenshot_dir = tempfile.mkdtemp(prefix="sim_test_")
        self._display_width = 1024   # Updated after first screenshot
        self._display_height = 2226  # Updated after first screenshot

    def _run(self, cmd: list[str], check: bool = True, timeout: int = 30) -> subprocess.CompletedProcess:
        """Run a shell command and return the result."""
        if self.verbose:
            print(f"  [cmd] {' '.join(cmd)}")
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            if check and result.returncode != 0:
                raise SimulatorError(
                    f"Command failed (rc={result.returncode}): {' '.join(cmd)}\n"
                    f"stderr: {result.stderr.strip()}"
                )
            return result
        except subprocess.TimeoutExpired:
            raise SimulatorError(f"Command timed out after {timeout}s: {' '.join(cmd)}")

    def _run_osascript(self, script: str) -> str:
        """Run an AppleScript and return stdout."""
        result = self._run(["osascript", "-e", script], check=False)
        if result.returncode != 0 and self.verbose:
            print(f"  [osascript warning] {result.stderr.strip()}")
        return result.stdout.strip()

    def ensure_booted(self) -> None:
        """Ensure the target simulator is booted."""
        result = self._run(["xcrun", "simctl", "list", "devices", "-j"], check=True)
        devices = json.loads(result.stdout)
        for runtime, device_list in devices.get("devices", {}).items():
            for device in device_list:
                if device["udid"] == self.udid:
                    if device["state"] == "Booted":
                        return
                    # Boot it
                    print(f"Booting simulator {device['name']} ({self.udid})...")
                    self._run(["xcrun", "simctl", "boot", self.udid])
                    # Wait for it to finish booting
                    time.sleep(3)
                    return
        raise SimulatorError(f"Simulator with UDID {self.udid} not found")

    def device_info(self) -> DeviceInfo:
        """Get device information including screen dimensions."""
        if self._device_info:
            return self._device_info

        result = self._run(["xcrun", "simctl", "list", "devices", "-j"])
        devices = json.loads(result.stdout)

        name = "Unknown"
        os_version = "Unknown"
        for runtime, device_list in devices.get("devices", {}).items():
            for device in device_list:
                if device["udid"] == self.udid:
                    name = device["name"]
                    # Extract OS version from runtime string
                    # e.g. "com.apple.CoreSimulator.SimRuntime.iOS-18-4"
                    m = re.search(r"iOS[- ](\d+)[- ](\d+)", runtime)
                    if m:
                        os_version = f"{m.group(1)}.{m.group(2)}"
                    break

        # Take a screenshot to determine actual pixel dimensions
        screenshot_path = os.path.join(self._screenshot_dir, "info_shot.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", screenshot_path
        ])
        img = Image.open(screenshot_path)
        pixel_w, pixel_h = img.size

        # iPhone 16 Pro: 1179x2556 at 3x scale -> 393x852 logical points
        # Detect scale factor from known device dimensions
        scale = 3  # Most modern iPhones are 3x
        if "Plus" in name or "Max" in name:
            scale = 3
        elif "SE" in name:
            scale = 2

        self._device_info = DeviceInfo(
            udid=self.udid,
            name=name,
            os_version=os_version,
            screen_width=pixel_w,
            screen_height=pixel_h,
            scale=scale,
        )
        return self._device_info

    def screenshot(self, resize_width: int = 1024) -> Tuple[str, int, int]:
        """
        Capture a screenshot of the simulator.

        Returns:
            Tuple of (base64_encoded_png, width, height) after resizing.
        """
        screenshot_path = os.path.join(self._screenshot_dir, f"shot_{int(time.time() * 1000)}.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", screenshot_path
        ])

        img = Image.open(screenshot_path)
        orig_w, orig_h = img.size

        # Resize to reasonable dimensions for the API
        if orig_w > resize_width:
            ratio = resize_width / orig_w
            new_h = int(orig_h * ratio)
            img = img.resize((resize_width, new_h), Image.LANCZOS)

        # Save resized version
        resized_path = screenshot_path.replace(".png", "_resized.png")
        img.save(resized_path, "PNG")

        with open(resized_path, "rb") as f:
            b64 = base64.standard_b64encode(f.read()).decode("ascii")

        self._display_width = img.width
        self._display_height = img.height
        return b64, img.width, img.height

    def screenshot_raw(self) -> str:
        """Capture screenshot and return the file path (for recording)."""
        screenshot_path = os.path.join(self._screenshot_dir, f"shot_{int(time.time() * 1000)}.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", screenshot_path
        ])
        return screenshot_path

    def _get_simulator_window(self):
        """Find the Simulator window bounds using Quartz."""
        from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID
        windows = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID)
        for w in windows:
            if 'Simulator' in w.get('kCGWindowOwnerName', ''):
                b = w.get('kCGWindowBounds', {})
                return float(b['X']), float(b['Y']), float(b['Width']), float(b['Height'])
        raise SimulatorError("Simulator window not found on screen")

    def _image_to_screen_coords(self, img_x: int, img_y: int,
                                 image_width: int, image_height: int):
        """Convert Claude's image coordinates to absolute screen coordinates."""
        win_x, win_y, win_w, win_h = self._get_simulator_window()
        # Title bar is ~28px on macOS
        title_bar = 28
        content_h = win_h - title_bar
        scale_x = win_w / image_width
        scale_y = content_h / image_height
        screen_x = win_x + img_x * scale_x
        screen_y = win_y + title_bar + img_y * scale_y
        return screen_x, screen_y

    def tap(self, x: int, y: int) -> None:
        """
        Tap at coordinates in Claude's image space using Quartz CGEvents.
        No Accessibility permission needed.
        """
        # Activate Simulator first
        subprocess.run(["open", "-a", "Simulator"], check=False)
        time.sleep(0.2)

        from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGHIDEventTap
        screen_x, screen_y = self._image_to_screen_coords(
            x, y, self._display_width, self._display_height)
        point = (screen_x, screen_y)
        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, point, 0)
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, point, 0)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.1)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.5)

    def tap_screen_coords(self, screen_x: int, screen_y: int,
                           image_width: int, image_height: int) -> None:
        """Tap at coordinates from Claude's image space."""
        self._display_width = image_width
        self._display_height = image_height
        self.tap(screen_x, screen_y)

    def swipe(self, x1: int, y1: int, x2: int, y2: int,
              image_width: int = 0, image_height: int = 0,
              duration: float = 0.5) -> None:
        """Swipe from (x1,y1) to (x2,y2) using Quartz CGEvents."""
        subprocess.run(["open", "-a", "Simulator"], check=False)
        time.sleep(0.2)

        from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGEventLeftMouseDragged, kCGHIDEventTap

        iw = image_width or self._display_width
        ih = image_height or self._display_height
        sx1, sy1 = self._image_to_screen_coords(x1, y1, iw, ih)
        sx2, sy2 = self._image_to_screen_coords(x2, y2, iw, ih)

        # Mouse down at start
        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (sx1, sy1), 0)
        CGEventPost(kCGHIDEventTap, down)

        # Drag in steps
        steps = 20
        for i in range(1, steps + 1):
            t = i / steps
            cx = sx1 + (sx2 - sx1) * t
            cy = sy1 + (sy2 - sy1) * t
            drag = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (cx, cy), 0)
            CGEventPost(kCGHIDEventTap, drag)
            time.sleep(duration / steps)

        # Mouse up at end
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (sx2, sy2), 0)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.3)

    def type_text(self, text: str) -> None:
        """Type text into the simulator using simctl pbcopy + paste, or keystrokes."""
        # For simple ASCII, use simctl keyboard (available in newer Xcode)
        # Fall back to pasteboard approach for reliability
        try:
            # Try the direct keyboard input first (Xcode 16+)
            self._run([
                "xcrun", "simctl", "io", self.udid,
                "keyboard", "input", text
            ], check=True)
        except SimulatorError:
            # Fallback: copy to pasteboard then paste
            if self.verbose:
                print("  [type] Falling back to pasteboard approach")
            # Copy text to simulator pasteboard
            proc = subprocess.run(
                ["xcrun", "simctl", "pbcopy", self.udid],
                input=text,
                capture_output=True,
                text=True,
            )
            if proc.returncode != 0:
                raise SimulatorError(f"pbcopy failed: {proc.stderr}")

            # Cmd+V to paste in the Simulator
            time.sleep(0.2)
            self._run_osascript('''
            tell application "Simulator" to activate
            delay 0.2
            tell application "System Events"
                keystroke "v" using command down
            end tell
            ''')
            time.sleep(0.3)

    def press_key(self, key: str) -> None:
        """Press a special key (return, escape, delete, etc.)."""
        key_map = {
            "return": 'key code 36',
            "enter": 'key code 36',
            "escape": 'key code 53',
            "delete": 'key code 51',
            "backspace": 'key code 51',
            "tab": 'key code 48',
            "space": 'key code 49',
            "up": 'key code 126',
            "down": 'key code 125',
            "left": 'key code 123',
            "right": 'key code 124',
        }
        keystroke = key_map.get(key.lower())
        if not keystroke:
            raise SimulatorError(f"Unknown key: {key}")

        self._run_osascript(f'''
        tell application "Simulator" to activate
        delay 0.2
        tell application "System Events"
            {keystroke}
        end tell
        ''')
        time.sleep(0.3)

    def press_home(self) -> None:
        """Press the home button."""
        self._run(["xcrun", "simctl", "io", self.udid, "button", "home"], check=False)
        # Fallback via keychain
        self._run_osascript('''
        tell application "Simulator" to activate
        delay 0.2
        tell application "System Events"
            keystroke "h" using {command down, shift down}
        end tell
        ''')
        time.sleep(0.5)

    def launch_app(self, bundle_id: str) -> None:
        """Launch an app on the simulator."""
        self._run(["xcrun", "simctl", "launch", self.udid, bundle_id])
        time.sleep(2)  # Wait for app to launch

    def terminate_app(self, bundle_id: str) -> None:
        """Terminate an app on the simulator."""
        self._run(["xcrun", "simctl", "terminate", self.udid, bundle_id], check=False)
        time.sleep(0.5)

    def open_url(self, url: str) -> None:
        """Open a URL on the simulator."""
        self._run(["xcrun", "simctl", "openurl", self.udid, url])
        time.sleep(1)

    def long_press(self, x: int, y: int, duration: float = 3.0,
                   image_width: int = 0, image_height: int = 0) -> None:
        """Long press at coordinates using Quartz CGEvents."""
        subprocess.run(["open", "-a", "Simulator"], check=False)
        time.sleep(0.2)

        from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGHIDEventTap

        iw = image_width or self._display_width
        ih = image_height or self._display_height
        screen_x, screen_y = self._image_to_screen_coords(x, y, iw, ih)

        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (screen_x, screen_y), 0)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(duration)
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (screen_x, screen_y), 0)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.5)
