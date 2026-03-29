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

        return b64, img.width, img.height

    def screenshot_raw(self) -> str:
        """Capture screenshot and return the file path (for recording)."""
        screenshot_path = os.path.join(self._screenshot_dir, f"shot_{int(time.time() * 1000)}.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", screenshot_path
        ])
        return screenshot_path

    def tap(self, x: int, y: int) -> None:
        """
        Tap at logical coordinates (x, y) using AppleScript.

        The coordinates should be in the coordinate space of the screenshot
        image that Claude sees (i.e., the resized image coordinates).
        We convert them to Simulator.app window coordinates.
        """
        # Use AppleScript to click in the Simulator window.
        # The Simulator app window contains the device screen plus chrome.
        # We need to click relative to the window content area.
        #
        # Strategy: Activate Simulator, find the window position, then use
        # System Events to click at the right offset.
        script = f'''
        tell application "Simulator" to activate
        delay 0.3
        tell application "System Events"
            tell process "Simulator"
                set frontWindow to front window
                set winPos to position of frontWindow
                set winSize to size of frontWindow
                -- Click at offset within the window
                -- The device screen starts after the title bar (~28px on macOS)
                set clickX to (item 1 of winPos) + {x}
                set clickY to (item 2 of winPos) + 28 + {y}
            end tell
            click at {{clickX, clickY}}
        end tell
        '''
        self._run_osascript(script)
        time.sleep(0.5)  # Wait for UI to respond

    def tap_screen_coords(self, screen_x: int, screen_y: int,
                           image_width: int, image_height: int) -> None:
        """
        Tap at coordinates from Claude's image space.

        Converts from the resized screenshot coordinate space to
        Simulator.app window coordinates.
        """
        # Get the Simulator window's content size via AppleScript
        script = '''
        tell application "System Events"
            tell process "Simulator"
                set winSize to size of front window
                return (item 1 of winSize) & "," & (item 2 of winSize)
            end tell
        end tell
        '''
        size_str = self._run_osascript(script)
        if "," in size_str:
            parts = size_str.split(",")
            win_w = int(parts[0].strip())
            win_h = int(parts[1].strip()) - 28  # Subtract title bar
        else:
            # Fallback: assume 1:1 mapping
            win_w = image_width
            win_h = image_height

        # Scale from image coords to window coords
        scale_x = win_w / image_width
        scale_y = win_h / image_height
        window_x = int(screen_x * scale_x)
        window_y = int(screen_y * scale_y)

        self.tap(window_x, window_y)

    def swipe(self, x1: int, y1: int, x2: int, y2: int,
              image_width: int = 0, image_height: int = 0,
              duration: float = 0.5) -> None:
        """
        Swipe from (x1,y1) to (x2,y2) using AppleScript mouse drag.
        Coordinates are in image space if image_width/height provided.
        """
        # Get window info for coordinate mapping
        script = '''
        tell application "System Events"
            tell process "Simulator"
                set winPos to position of front window
                set winSize to size of front window
                return (item 1 of winPos) & "," & (item 2 of winPos) & "," & (item 1 of winSize) & "," & (item 2 of winSize)
            end tell
        end tell
        '''
        info_str = self._run_osascript(script)
        if "," in info_str:
            parts = [int(p.strip()) for p in info_str.split(",")]
            win_x, win_y, win_w, win_h_with_title = parts
            win_h = win_h_with_title - 28
        else:
            win_x, win_y, win_w, win_h = 0, 0, image_width, image_height

        # Scale coordinates
        if image_width > 0 and image_height > 0:
            sx = win_w / image_width
            sy = win_h / image_height
        else:
            sx = sy = 1.0

        abs_x1 = win_x + int(x1 * sx)
        abs_y1 = win_y + 28 + int(y1 * sy)
        abs_x2 = win_x + int(x2 * sx)
        abs_y2 = win_y + 28 + int(y2 * sy)

        # AppleScript mouse drag via cliclick or System Events
        # Using Python's Quartz framework for precise mouse control
        try:
            self._mouse_drag(abs_x1, abs_y1, abs_x2, abs_y2, duration)
        except Exception:
            # Fallback: use two clicks (start and end) -- imprecise but better than nothing
            if self.verbose:
                print("  [swipe] Quartz unavailable, falling back to AppleScript")
            self._run_osascript(f'''
            tell application "Simulator" to activate
            delay 0.2
            tell application "System Events"
                click at {{{abs_x1}, {abs_y1}}}
                delay 0.1
                click at {{{abs_x2}, {abs_y2}}}
            end tell
            ''')

    def _mouse_drag(self, x1: int, y1: int, x2: int, y2: int, duration: float) -> None:
        """Perform a mouse drag using Quartz (CoreGraphics) events."""
        import Quartz

        # Move to start
        event = Quartz.CGEventCreateMouseEvent(
            None, Quartz.kCGEventMouseMoved,
            (x1, y1), Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)

        # Mouse down
        event = Quartz.CGEventCreateMouseEvent(
            None, Quartz.kCGEventLeftMouseDown,
            (x1, y1), Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        time.sleep(0.05)

        # Drag in steps
        steps = max(10, int(duration * 60))
        for i in range(1, steps + 1):
            t = i / steps
            cx = x1 + (x2 - x1) * t
            cy = y1 + (y2 - y1) * t
            event = Quartz.CGEventCreateMouseEvent(
                None, Quartz.kCGEventLeftMouseDragged,
                (cx, cy), Quartz.kCGMouseButtonLeft
            )
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            time.sleep(duration / steps)

        # Mouse up
        event = Quartz.CGEventCreateMouseEvent(
            None, Quartz.kCGEventLeftMouseUp,
            (x2, y2), Quartz.kCGMouseButtonLeft
        )
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
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
        """
        Long press at coordinates. Uses Quartz mouse events for precise timing.
        """
        # Get window position
        script = '''
        tell application "System Events"
            tell process "Simulator"
                set winPos to position of front window
                set winSize to size of front window
                return (item 1 of winPos) & "," & (item 2 of winPos) & "," & (item 1 of winSize) & "," & (item 2 of winSize)
            end tell
        end tell
        '''
        info_str = self._run_osascript(script)
        if "," in info_str:
            parts = [int(p.strip()) for p in info_str.split(",")]
            win_x, win_y, win_w, win_h_with_title = parts
            win_h = win_h_with_title - 28
        else:
            win_x, win_y = 0, 0
            win_w = image_width if image_width else x * 2
            win_h = image_height if image_height else y * 2

        if image_width > 0 and image_height > 0:
            sx = win_w / image_width
            sy = win_h / image_height
        else:
            sx = sy = 1.0

        abs_x = win_x + int(x * sx)
        abs_y = win_y + 28 + int(y * sy)

        # Activate Simulator first
        self._run_osascript('tell application "Simulator" to activate')
        time.sleep(0.3)

        try:
            import Quartz
            # Mouse down
            event = Quartz.CGEventCreateMouseEvent(
                None, Quartz.kCGEventLeftMouseDown,
                (abs_x, abs_y), Quartz.kCGMouseButtonLeft
            )
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
            # Hold for duration
            time.sleep(duration)
            # Mouse up
            event = Quartz.CGEventCreateMouseEvent(
                None, Quartz.kCGEventLeftMouseUp,
                (abs_x, abs_y), Quartz.kCGMouseButtonLeft
            )
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
        except ImportError:
            if self.verbose:
                print("  [long_press] Quartz unavailable, using AppleScript delay")
            self._run_osascript(f'''
            tell application "System Events"
                click at {{{abs_x}, {abs_y}}}
                delay {duration}
            end tell
            ''')
        time.sleep(0.5)
