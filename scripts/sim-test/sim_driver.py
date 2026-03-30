"""
iOS Simulator Interaction Driver — Reference Implementation for SpecterQA

Provides pixel-accurate touch input via Quartz CGEvents (no Accessibility
permission required), screenshot capture via xcrun simctl, and keyboard input.

Key design decisions:
  - Quartz CGEvents for all touch input (tap, swipe, long-press)
  - Auto-detected title bar offset via CGWindowListCopyWindowInfo
  - Coordinate debug logging for diagnosing mapping issues
  - No AppleScript System Events dependency (fails without Accessibility)

Tested on: macOS 15 / Xcode 26.3 / iPhone 16 Pro Simulator (iOS 18.4)
"""

import base64
import json
import os
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from typing import Optional, Tuple

from PIL import Image

# ---------------------------------------------------------------------------
# Quartz imports — required for touch input
# ---------------------------------------------------------------------------

try:
    from Quartz import (
        CGEventCreateMouseEvent,
        CGEventPost,
        CGWindowListCopyWindowInfo,
        kCGEventLeftMouseDown,
        kCGEventLeftMouseUp,
        kCGEventLeftMouseDragged,
        kCGHIDEventTap,
        kCGWindowListOptionOnScreenOnly,
        kCGNullWindowID,
    )
    QUARTZ_AVAILABLE = True
except ImportError:
    QUARTZ_AVAILABLE = False


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class DeviceInfo:
    udid: str
    name: str
    os_version: str
    screen_width: int   # raw pixel width
    screen_height: int  # raw pixel height
    scale: int          # Retina scale factor


@dataclass
class WindowBounds:
    x: float
    y: float
    width: float
    height: float
    title_bar_height: float  # auto-detected


class SimulatorError(Exception):
    """Raised when a simulator operation fails."""
    pass


# ---------------------------------------------------------------------------
# SimDriver
# ---------------------------------------------------------------------------

class SimDriver:
    """Controls the iOS Simulator via Quartz CGEvents and xcrun simctl.

    This is the reference implementation for SpecterQA's iOS InteractionLayer.
    All touch input uses Quartz CGEventCreateMouseEvent which does NOT require
    macOS Accessibility permission — unlike AppleScript System Events.

    Coordinate mapping:
        Claude sees a resized screenshot (e.g. 1024x2226).
        We map those coordinates to absolute screen coordinates by:
        1. Finding the Simulator.app window bounds via CGWindowListCopyWindowInfo
        2. Auto-detecting the title bar height (window height - content height)
        3. Scaling image coords to window content area
        4. Adding window position + title bar offset

    Usage:
        driver = SimDriver(udid="DF4A2A27-...", verbose=True)
        driver.device_info()  # initializes screen dimensions
        b64, w, h = driver.screenshot()  # capture + resize
        driver.tap(x, y)  # tap in image coordinates
    """

    DEFAULT_UDID = "booted"

    def __init__(self, udid: Optional[str] = None, verbose: bool = False):
        self.udid = udid or self.DEFAULT_UDID
        self.verbose = verbose
        self._device_info: Optional[DeviceInfo] = None
        self._screenshot_dir = tempfile.mkdtemp(prefix="sim_test_")
        self._display_width = 1024
        self._display_height = 2226
        self._window_cache: Optional[WindowBounds] = None
        self._window_cache_time: float = 0
        self._calibration_offset_x: float = 0.0
        self._calibration_offset_y: float = 0.0

        if not QUARTZ_AVAILABLE:
            raise SimulatorError(
                "Quartz framework not available. Install pyobjc-framework-Quartz:\n"
                "  pip install pyobjc-framework-Quartz"
            )

    # ------------------------------------------------------------------
    # Shell helpers
    # ------------------------------------------------------------------

    def _run(self, cmd: list[str], check: bool = True, timeout: int = 30) -> subprocess.CompletedProcess:
        if self.verbose:
            print(f"  [cmd] {' '.join(cmd)}")
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            if check and result.returncode != 0:
                raise SimulatorError(
                    f"Command failed (rc={result.returncode}): {' '.join(cmd)}\n"
                    f"stderr: {result.stderr.strip()}"
                )
            return result
        except subprocess.TimeoutExpired:
            raise SimulatorError(f"Command timed out after {timeout}s: {' '.join(cmd)}")

    # ------------------------------------------------------------------
    # Window detection and coordinate mapping
    # ------------------------------------------------------------------

    def _get_simulator_window(self) -> WindowBounds:
        """Find Simulator.app window bounds via Quartz CGWindowListCopyWindowInfo.

        Caches result for 2 seconds to avoid excessive queries.
        Auto-detects title bar height by examining window properties.
        """
        now = time.time()
        if self._window_cache and (now - self._window_cache_time) < 2.0:
            return self._window_cache

        windows = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID
        )
        if windows is None:
            raise SimulatorError("CGWindowListCopyWindowInfo returned None")

        # Find the main Simulator window (not helper windows)
        sim_windows = []
        for w in windows:
            owner = w.get('kCGWindowOwnerName', '')
            if 'Simulator' in owner:
                bounds = w.get('kCGWindowBounds', {})
                layer = w.get('kCGWindowLayer', 0)
                alpha = w.get('kCGWindowAlpha', 1.0)
                height = float(bounds.get('Height', 0))
                # Main window is layer 0, has alpha 1.0, and is tall (device screen)
                if layer == 0 and alpha >= 1.0 and height > 200:
                    sim_windows.append({
                        'bounds': bounds,
                        'name': w.get('kCGWindowName', ''),
                        'height': height,
                    })

        if not sim_windows:
            raise SimulatorError(
                "Simulator window not found. Is Simulator.app open and visible?"
            )

        # Use the tallest window (the device window, not toolbar/panel)
        best = max(sim_windows, key=lambda w: w['height'])
        b = best['bounds']

        # Auto-detect title bar height
        # macOS standard title bar: 28px
        # Full-screen: 0px
        # With toolbar: 52px
        # We detect by checking if the window name contains the device name
        # (titled windows have title bars, untitled ones are full-screen)
        title_bar = 0.0
        win_name = best.get('name', '')
        if win_name:
            # Has a title bar (window is titled)
            title_bar = 28.0
        # In full-screen mode, kCGWindowName is often empty

        result = WindowBounds(
            x=float(b['X']),
            y=float(b['Y']),
            width=float(b['Width']),
            height=float(b['Height']),
            title_bar_height=title_bar,
        )

        if self.verbose:
            print(f"  [window] pos=({result.x:.0f},{result.y:.0f}) "
                  f"size={result.width:.0f}x{result.height:.0f} "
                  f"titlebar={result.title_bar_height:.0f} "
                  f"name='{win_name}'")

        self._window_cache = result
        self._window_cache_time = now
        return result

    def _image_to_screen(self, img_x: float, img_y: float,
                          img_w: float = 0, img_h: float = 0) -> Tuple[float, float]:
        """Convert image coordinates to absolute screen coordinates.

        Args:
            img_x, img_y: coordinates in the resized screenshot space
            img_w, img_h: dimensions of the resized screenshot

        Returns:
            (screen_x, screen_y): absolute macOS screen coordinates
        """
        iw = img_w or self._display_width
        ih = img_h or self._display_height
        win = self._get_simulator_window()

        content_h = win.height - win.title_bar_height
        scale_x = win.width / iw
        scale_y = content_h / ih

        screen_x = win.x + img_x * scale_x + self._calibration_offset_x
        screen_y = win.y + win.title_bar_height + img_y * scale_y + self._calibration_offset_y

        if self.verbose:
            print(f"  [coords] img=({img_x:.0f},{img_y:.0f})/{iw:.0f}x{ih:.0f} "
                  f"-> screen=({screen_x:.1f},{screen_y:.1f}) "
                  f"scale=({scale_x:.3f},{scale_y:.3f})")

        return screen_x, screen_y

    # ------------------------------------------------------------------
    # Calibration
    # ------------------------------------------------------------------

    def calibrate(self) -> Tuple[float, float]:
        """Auto-calibrate coordinate mapping by tapping a known position.

        Takes a screenshot, identifies the center point, taps it, takes another
        screenshot, and checks if the tap registered. Adjusts offsets if needed.

        Returns:
            (offset_x, offset_y): calibration offsets applied
        """
        if self.verbose:
            print("  [calibrate] Running auto-calibration...")

        # Take baseline screenshot
        b64_before, w, h = self.screenshot()

        # Tap dead center — this should always hit something
        center_x, center_y = w // 2, h // 2
        self.tap(center_x, center_y)
        time.sleep(0.5)

        # Take after screenshot
        b64_after, _, _ = self.screenshot()

        # If screenshots differ, center tap is working
        if b64_before != b64_after:
            if self.verbose:
                print("  [calibrate] Center tap registers — calibration OK")
            return (0.0, 0.0)

        # If center didn't register, try small offsets
        for dx, dy in [(0, -10), (0, 10), (-10, 0), (10, 0)]:
            self._calibration_offset_x = dx
            self._calibration_offset_y = dy
            self.tap(center_x, center_y)
            time.sleep(0.3)
            b64_test, _, _ = self.screenshot()
            if b64_test != b64_before:
                if self.verbose:
                    print(f"  [calibrate] Found working offset: ({dx}, {dy})")
                return (dx, dy)

        self._calibration_offset_x = 0
        self._calibration_offset_y = 0
        if self.verbose:
            print("  [calibrate] Could not auto-calibrate — using default mapping")
        return (0.0, 0.0)

    # ------------------------------------------------------------------
    # Device info
    # ------------------------------------------------------------------

    def device_info(self) -> DeviceInfo:
        """Get device name, OS version, and screen dimensions."""
        if self._device_info:
            return self._device_info

        result = self._run(["xcrun", "simctl", "list", "devices", "-j"])
        devices = json.loads(result.stdout)

        name = "Unknown"
        os_version = "Unknown"
        for runtime, device_list in devices.get("devices", {}).items():
            for device in device_list:
                if device["udid"] == self.udid or (self.udid == "booted" and device.get("state") == "Booted"):
                    name = device["name"]
                    if self.udid == "booted":
                        self.udid = device["udid"]
                    m = re.search(r"iOS[- ](\d+)[- ](\d+)", runtime)
                    if m:
                        os_version = f"{m.group(1)}.{m.group(2)}"
                    break

        # Get pixel dimensions from a screenshot
        screenshot_path = os.path.join(self._screenshot_dir, "info_shot.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", screenshot_path
        ])
        img = Image.open(screenshot_path)
        pixel_w, pixel_h = img.size

        scale = 3
        if "SE" in name:
            scale = 2

        self._device_info = DeviceInfo(
            udid=self.udid, name=name, os_version=os_version,
            screen_width=pixel_w, screen_height=pixel_h, scale=scale,
        )
        return self._device_info

    # ------------------------------------------------------------------
    # Screenshot
    # ------------------------------------------------------------------

    def screenshot(self, resize_width: int = 1024) -> Tuple[str, int, int]:
        """Capture screenshot, resize, return (base64_png, width, height)."""
        path = os.path.join(self._screenshot_dir, f"shot_{int(time.time() * 1000)}.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", path
        ])

        img = Image.open(path)
        if img.width > resize_width:
            ratio = resize_width / img.width
            img = img.resize((resize_width, int(img.height * ratio)), Image.LANCZOS)

        resized_path = path.replace(".png", "_resized.png")
        img.save(resized_path, "PNG")

        with open(resized_path, "rb") as f:
            b64 = base64.standard_b64encode(f.read()).decode("ascii")

        self._display_width = img.width
        self._display_height = img.height
        return b64, img.width, img.height

    def screenshot_raw(self) -> str:
        """Capture screenshot, return file path."""
        path = os.path.join(self._screenshot_dir, f"shot_{int(time.time() * 1000)}.png")
        self._run([
            "xcrun", "simctl", "io", self.udid,
            "screenshot", "--type=png", path
        ])
        return path

    # ------------------------------------------------------------------
    # Touch input — all via Quartz CGEvents
    # ------------------------------------------------------------------

    def _activate_simulator(self):
        """Bring Simulator.app to front."""
        subprocess.run(["open", "-a", "Simulator"], check=False)
        time.sleep(0.15)

    def tap(self, img_x: float, img_y: float) -> None:
        """Tap at image-space coordinates. No Accessibility permission needed."""
        self._activate_simulator()
        sx, sy = self._image_to_screen(img_x, img_y)

        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (sx, sy), 0)
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (sx, sy), 0)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.08)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.4)

    def double_tap(self, img_x: float, img_y: float) -> None:
        """Double-tap at image-space coordinates."""
        self._activate_simulator()
        sx, sy = self._image_to_screen(img_x, img_y)

        for _ in range(2):
            down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (sx, sy), 0)
            up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (sx, sy), 0)
            CGEventPost(kCGHIDEventTap, down)
            time.sleep(0.05)
            CGEventPost(kCGHIDEventTap, up)
            time.sleep(0.1)
        time.sleep(0.3)

    def long_press(self, img_x: float, img_y: float, duration: float = 3.0) -> None:
        """Long-press at image-space coordinates."""
        self._activate_simulator()
        sx, sy = self._image_to_screen(img_x, img_y)

        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (sx, sy), 0)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(duration)
        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (sx, sy), 0)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.5)

    def swipe(self, x1: float, y1: float, x2: float, y2: float,
              duration: float = 0.4) -> None:
        """Swipe gesture via Quartz mouse drag events."""
        self._activate_simulator()
        sx1, sy1 = self._image_to_screen(x1, y1)
        sx2, sy2 = self._image_to_screen(x2, y2)

        down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (sx1, sy1), 0)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.02)

        steps = 25
        for i in range(1, steps + 1):
            t = i / steps
            cx = sx1 + (sx2 - sx1) * t
            cy = sy1 + (sy2 - sy1) * t
            drag = CGEventCreateMouseEvent(None, kCGEventLeftMouseDragged, (cx, cy), 0)
            CGEventPost(kCGHIDEventTap, drag)
            time.sleep(duration / steps)

        up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (sx2, sy2), 0)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.3)

    def swipe_back(self) -> None:
        """iOS back gesture — swipe from left edge to center."""
        self.swipe(5, self._display_height // 2,
                   self._display_width // 2, self._display_height // 2,
                   duration=0.3)

    # ------------------------------------------------------------------
    # Keyboard input
    # ------------------------------------------------------------------

    def type_text(self, text: str) -> None:
        """Type text into the active field.

        Tries xcrun simctl keyboard first, falls back to pasteboard + Cmd-V.
        """
        try:
            self._run([
                "xcrun", "simctl", "io", self.udid, "keyboard", "input", text
            ], check=True)
        except SimulatorError:
            if self.verbose:
                print("  [type] Falling back to pasteboard paste")
            proc = subprocess.run(
                ["xcrun", "simctl", "pbcopy", self.udid],
                input=text, capture_output=True, text=True,
            )
            if proc.returncode != 0:
                raise SimulatorError(f"pbcopy failed: {proc.stderr}")
            time.sleep(0.2)
            # Cmd+V via Quartz keyboard event
            from Quartz import CGEventCreateKeyboardEvent, CGEventSetFlags, kCGEventFlagMaskCommand
            v_down = CGEventCreateKeyboardEvent(None, 9, True)  # 9 = 'v' keycode
            v_up = CGEventCreateKeyboardEvent(None, 9, False)
            CGEventSetFlags(v_down, kCGEventFlagMaskCommand)
            CGEventSetFlags(v_up, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, v_down)
            time.sleep(0.05)
            CGEventPost(kCGHIDEventTap, v_up)
            time.sleep(0.3)

    def press_key(self, key: str) -> None:
        """Press a special key via Quartz keyboard events."""
        KEY_CODES = {
            "return": 36, "enter": 36, "escape": 53, "delete": 51,
            "backspace": 51, "tab": 48, "space": 49,
            "up": 126, "down": 125, "left": 123, "right": 124,
        }
        code = KEY_CODES.get(key.lower())
        if code is None:
            raise SimulatorError(f"Unknown key: {key}")

        self._activate_simulator()
        from Quartz import CGEventCreateKeyboardEvent
        down = CGEventCreateKeyboardEvent(None, code, True)
        up = CGEventCreateKeyboardEvent(None, code, False)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.05)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.3)

    # ------------------------------------------------------------------
    # App lifecycle
    # ------------------------------------------------------------------

    def launch_app(self, bundle_id: str) -> None:
        self._run(["xcrun", "simctl", "launch", self.udid, bundle_id])
        time.sleep(2)

    def terminate_app(self, bundle_id: str) -> None:
        self._run(["xcrun", "simctl", "terminate", self.udid, bundle_id], check=False)
        time.sleep(0.5)

    def open_url(self, url: str) -> None:
        self._run(["xcrun", "simctl", "openurl", self.udid, url])
        time.sleep(1)

    def ensure_booted(self) -> None:
        result = self._run(["xcrun", "simctl", "list", "devices", "-j"])
        devices = json.loads(result.stdout)
        for runtime, device_list in devices.get("devices", {}).items():
            for device in device_list:
                if device["udid"] == self.udid:
                    if device["state"] == "Booted":
                        return
                    self._run(["xcrun", "simctl", "boot", self.udid])
                    time.sleep(3)
                    return
        raise SimulatorError(f"Simulator {self.udid} not found")

    # ------------------------------------------------------------------
    # ActionExecutor protocol (SpecterQA compatibility)
    # ------------------------------------------------------------------

    def execute(self, action: dict) -> dict:
        """Unified action dispatcher for SpecterQA IOSAIStepRunner.

        Maps computer_use tool actions to driver methods.
        Returns a result dict with screenshot or text confirmation.
        """
        action_type = action.get("action", "")

        if action_type == "screenshot":
            b64, w, h = self.screenshot()
            return {"type": "image", "base64": b64, "width": w, "height": h}

        elif action_type == "left_click":
            coord = action.get("coordinate", [0, 0])
            self.tap(coord[0], coord[1])
            return {"type": "text", "text": f"Tapped at ({coord[0]}, {coord[1]})"}

        elif action_type == "double_click":
            coord = action.get("coordinate", [0, 0])
            self.double_tap(coord[0], coord[1])
            return {"type": "text", "text": f"Double-tapped at ({coord[0]}, {coord[1]})"}

        elif action_type in ("right_click", "long_press"):
            coord = action.get("coordinate", [0, 0])
            dur = action.get("duration", 3.0)
            self.long_press(coord[0], coord[1], duration=dur)
            return {"type": "text", "text": f"Long-pressed at ({coord[0]}, {coord[1]}) for {dur}s"}

        elif action_type == "type":
            text = action.get("text", "")
            self.type_text(text)
            return {"type": "text", "text": f"Typed: {text[:50]}"}

        elif action_type == "key":
            key = action.get("key", "")
            self.press_key(key)
            return {"type": "text", "text": f"Pressed key: {key}"}

        elif action_type == "scroll":
            coord = action.get("coordinate", [self._display_width // 2, self._display_height // 2])
            direction = action.get("direction", "down")
            amount = action.get("amount", 3)
            distance = amount * 100
            x = coord[0]
            y = coord[1]
            if direction == "down":
                self.swipe(x, y, x, y - distance)
            elif direction == "up":
                self.swipe(x, y, x, y + distance)
            elif direction == "left":
                self.swipe(x, y, x - distance, y)
            elif direction == "right":
                self.swipe(x, y, x + distance, y)
            return {"type": "text", "text": f"Scrolled {direction} by {amount}"}

        elif action_type == "left_click_drag":
            start = action.get("start_coordinate", [0, 0])
            end = action.get("coordinate", [0, 0])
            self.swipe(start[0], start[1], end[0], end[1])
            return {"type": "text", "text": f"Dragged ({start}) -> ({end})"}

        elif action_type == "wait":
            secs = action.get("duration", 1)
            time.sleep(secs)
            return {"type": "text", "text": f"Waited {secs}s"}

        else:
            return {"type": "text", "text": f"Unknown action: {action_type}"}
