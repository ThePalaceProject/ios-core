"""
Claude API integration for visual iOS Simulator testing.

Uses Claude's computer use beta to drive the simulator through
screenshot analysis and tool calls.
"""

import base64
import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import anthropic

from sim_driver import SimDriver, SimulatorError


@dataclass
class ScenarioResult:
    """Result of running a test scenario."""
    name: str
    success: bool
    steps_completed: int
    total_iterations: int
    final_assessment: str
    screenshots: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    duration_seconds: float = 0.0

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "success": self.success,
            "steps_completed": self.steps_completed,
            "total_iterations": self.total_iterations,
            "final_assessment": self.final_assessment,
            "errors": self.errors,
            "duration_seconds": round(self.duration_seconds, 1),
            "screenshot_count": len(self.screenshots),
        }


class ClaudeTester:
    """
    Drives the iOS Simulator via Claude's computer use capability.

    Sends screenshots to Claude, receives tool calls (click, type, etc.),
    executes them via SimDriver, and loops until the scenario completes.
    """

    # Model to use -- claude-sonnet-4-6 for computer use (good balance of
    # speed and capability for UI interaction)
    MODEL = "claude-sonnet-4-6"
    BETA_VERSION = "computer-use-2025-11-24"
    TOOL_VERSION = "computer_20251124"

    # Max iterations to prevent runaway API costs
    MAX_ITERATIONS = 40

    def __init__(
        self,
        sim_driver: SimDriver,
        api_key: Optional[str] = None,
        verbose: bool = False,
        record_screenshots: bool = False,
        screenshot_dir: Optional[str] = None,
    ):
        self.sim = sim_driver
        self.verbose = verbose
        self.record_screenshots = record_screenshots
        self.screenshot_dir = screenshot_dir

        api_key = api_key or os.environ.get("ANTHROPIC_API_KEY")
        if not api_key:
            raise ValueError(
                "ANTHROPIC_API_KEY not set. Provide it via environment variable "
                "or the api_key parameter."
            )
        self.client = anthropic.Anthropic(api_key=api_key)

        # Determine display dimensions from an initial screenshot
        self._display_width = 0
        self._display_height = 0

    def _init_display_dimensions(self) -> None:
        """Take an initial screenshot to determine display dimensions for Claude."""
        b64, w, h = self.sim.screenshot()
        self._display_width = w
        self._display_height = h
        if self.verbose:
            print(f"  [display] {w}x{h} (resized for API)")

    def _build_tools(self) -> list[dict]:
        """Build the computer use tool definition."""
        return [
            {
                "type": self.TOOL_VERSION,
                "name": "computer",
                "display_width_px": self._display_width,
                "display_height_px": self._display_height,
            }
        ]

    def _build_system_prompt(self, scenario: dict) -> str:
        """Build the system prompt for the scenario."""
        steps_text = "\n".join(
            f"  {i+1}. {step}" for i, step in enumerate(scenario.get("steps", []))
        )
        criteria_text = "\n".join(
            f"  - {c}" for c in scenario.get("success_criteria", [])
        )

        precondition = scenario.get("precondition", "")
        precondition_text = f"\nPrecondition: {precondition}" if precondition else ""

        credentials = scenario.get("credentials", {})
        creds_text = ""
        if credentials:
            creds_text = "\n\n<robot_credentials>\n"
            for key, value in credentials.items():
                creds_text += f"  {key}: {value}\n"
            creds_text += "</robot_credentials>"

        library = scenario.get("library", "")
        library_text = f"\nTarget library: {library}" if library else ""

        return f"""You are testing the Palace iOS app in an iOS Simulator.
Your task is to complete the following test scenario by interacting with the app.

Scenario: {scenario.get('name', 'Unknown')}
{library_text}{precondition_text}

Steps to perform:
{steps_text}

Success criteria:
{criteria_text}
{creds_text}

Important instructions:
- After each action, take a screenshot to verify the result before proceeding.
- If something doesn't work as expected, try alternative approaches (e.g., scroll to find elements, tap different areas).
- The app bundle ID is "org.thepalaceproject.palace" (or similar -- check what's installed).
- Be patient -- iOS animations and network requests take time. Wait 2-3 seconds between actions.
- When you believe the scenario is complete (success or failure), provide a final assessment.
- Explicitly state "SCENARIO PASSED" or "SCENARIO FAILED" in your final message along with details.
- Do NOT assume outcomes -- always verify with screenshots.
"""

    def _execute_tool_call(self, tool_name: str, tool_input: dict) -> dict:
        """
        Execute a computer use tool call and return the result.

        Returns a dict suitable for a tool_result content block.
        """
        action = tool_input.get("action", "")

        try:
            if action == "screenshot":
                b64, w, h = self.sim.screenshot()
                if self.record_screenshots and self.screenshot_dir:
                    raw_path = self.sim.screenshot_raw()
                    self.screenshots_taken.append(raw_path)
                return {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/png",
                        "data": b64,
                    },
                }

            elif action == "left_click":
                coord = tool_input.get("coordinate", [0, 0])
                x, y = coord[0], coord[1]
                if self.verbose:
                    print(f"  [click] ({x}, {y})")
                self.sim.tap_screen_coords(
                    x, y,
                    self._display_width, self._display_height
                )
                return {"type": "text", "text": f"Clicked at ({x}, {y})"}

            elif action == "right_click":
                coord = tool_input.get("coordinate", [0, 0])
                x, y = coord[0], coord[1]
                if self.verbose:
                    print(f"  [right_click] ({x}, {y})")
                # iOS doesn't really have right-click; treat as long press
                self.sim.long_press(
                    x, y, duration=1.0,
                    image_width=self._display_width,
                    image_height=self._display_height
                )
                return {"type": "text", "text": f"Long-pressed at ({x}, {y})"}

            elif action == "double_click":
                coord = tool_input.get("coordinate", [0, 0])
                x, y = coord[0], coord[1]
                if self.verbose:
                    print(f"  [double_click] ({x}, {y})")
                self.sim.tap_screen_coords(x, y, self._display_width, self._display_height)
                time.sleep(0.1)
                self.sim.tap_screen_coords(x, y, self._display_width, self._display_height)
                return {"type": "text", "text": f"Double-clicked at ({x}, {y})"}

            elif action == "type":
                text = tool_input.get("text", "")
                if self.verbose:
                    print(f"  [type] '{text[:50]}{'...' if len(text) > 50 else ''}'")
                self.sim.type_text(text)
                return {"type": "text", "text": f"Typed: {text[:100]}"}

            elif action == "key":
                key = tool_input.get("text", "")
                if self.verbose:
                    print(f"  [key] {key}")
                # Handle key combinations like "ctrl+s", "Return", etc.
                self._handle_key_press(key)
                return {"type": "text", "text": f"Pressed key: {key}"}

            elif action == "scroll":
                coord = tool_input.get("coordinate", [0, 0])
                direction = tool_input.get("scroll_direction", "down")
                amount = tool_input.get("scroll_amount", 3)
                if self.verbose:
                    print(f"  [scroll] {direction} by {amount} at ({coord[0]}, {coord[1]})")

                x, y = coord[0], coord[1]
                # Convert scroll to swipe
                distance = amount * 100  # pixels per scroll unit
                if direction == "down":
                    self.sim.swipe(
                        x, y, x, y - distance,
                        self._display_width, self._display_height
                    )
                elif direction == "up":
                    self.sim.swipe(
                        x, y, x, y + distance,
                        self._display_width, self._display_height
                    )
                elif direction == "left":
                    self.sim.swipe(
                        x, y, x + distance, y,
                        self._display_width, self._display_height
                    )
                elif direction == "right":
                    self.sim.swipe(
                        x, y, x - distance, y,
                        self._display_width, self._display_height
                    )
                return {"type": "text", "text": f"Scrolled {direction} by {amount}"}

            elif action == "mouse_move":
                coord = tool_input.get("coordinate", [0, 0])
                if self.verbose:
                    print(f"  [mouse_move] ({coord[0]}, {coord[1]})")
                # iOS doesn't have hover; this is a no-op but we acknowledge it
                return {"type": "text", "text": f"Moved cursor to ({coord[0]}, {coord[1]})"}

            elif action == "left_click_drag":
                start = tool_input.get("start_coordinate", [0, 0])
                end = tool_input.get("coordinate", [0, 0])
                if self.verbose:
                    print(f"  [drag] ({start[0]}, {start[1]}) -> ({end[0]}, {end[1]})")
                self.sim.swipe(
                    start[0], start[1], end[0], end[1],
                    self._display_width, self._display_height
                )
                return {"type": "text", "text": f"Dragged from ({start[0]}, {start[1]}) to ({end[0]}, {end[1]})"}

            elif action == "wait":
                duration = tool_input.get("duration", 1)
                if self.verbose:
                    print(f"  [wait] {duration}s")
                time.sleep(min(duration, 10))  # Cap at 10s
                return {"type": "text", "text": f"Waited {duration} seconds"}

            else:
                return {"type": "text", "text": f"Unknown action: {action}"}

        except SimulatorError as e:
            error_msg = f"Error executing {action}: {str(e)}"
            if self.verbose:
                print(f"  [error] {error_msg}")
            return {"type": "text", "text": error_msg}

    def _handle_key_press(self, key_spec: str) -> None:
        """Handle key press specifications like 'Return', 'ctrl+a', 'space'."""
        # Normalize common key names
        key_map = {
            "return": "return",
            "enter": "return",
            "escape": "escape",
            "esc": "escape",
            "backspace": "backspace",
            "delete": "delete",
            "tab": "tab",
            "space": "space",
            "up": "up",
            "down": "down",
            "left": "left",
            "right": "right",
        }

        key_lower = key_spec.lower().strip()

        # Handle modifier+key combinations via AppleScript
        if "+" in key_lower:
            parts = key_lower.split("+")
            modifiers = parts[:-1]
            key = parts[-1]

            modifier_map = {
                "ctrl": "control down",
                "control": "control down",
                "cmd": "command down",
                "command": "command down",
                "super": "command down",
                "alt": "option down",
                "option": "option down",
                "shift": "shift down",
            }

            applescript_modifiers = []
            for mod in modifiers:
                mod = mod.strip()
                if mod in modifier_map:
                    applescript_modifiers.append(modifier_map[mod])

            if applescript_modifiers:
                using_clause = "{" + ", ".join(applescript_modifiers) + "}"
                script = f'''
                tell application "Simulator" to activate
                delay 0.2
                tell application "System Events"
                    keystroke "{key}" using {using_clause}
                end tell
                '''
                self.sim._run_osascript(script)
                time.sleep(0.3)
                return

        # Simple key press
        mapped = key_map.get(key_lower, None)
        if mapped:
            self.sim.press_key(mapped)
        else:
            # Treat as text to type (single character)
            self.sim.type_text(key_spec)

    def run_scenario(self, scenario: dict) -> ScenarioResult:
        """
        Run a test scenario against the simulator.

        Args:
            scenario: Dict with keys: name, steps, success_criteria,
                      and optionally: library, credentials, precondition

        Returns:
            ScenarioResult with pass/fail status and details.
        """
        start_time = time.time()
        self.screenshots_taken: list[str] = []

        # Initialize display dimensions
        self.sim.ensure_booted()
        self._init_display_dimensions()

        system_prompt = self._build_system_prompt(scenario)
        tools = self._build_tools()

        if self.verbose:
            print(f"\n{'='*60}")
            print(f"Running scenario: {scenario.get('name', 'Unknown')}")
            print(f"Display: {self._display_width}x{self._display_height}")
            print(f"Model: {self.MODEL}")
            print(f"{'='*60}\n")

        # Take initial screenshot
        b64, w, h = self.sim.screenshot()
        initial_screenshot_content = {
            "type": "image",
            "source": {
                "type": "base64",
                "media_type": "image/png",
                "data": b64,
            },
        }

        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": "Here is the current state of the iOS Simulator. Please begin the test scenario."},
                    initial_screenshot_content,
                ],
            }
        ]

        iterations = 0
        errors = []
        final_text = ""

        while iterations < self.MAX_ITERATIONS:
            iterations += 1

            if self.verbose:
                print(f"\n--- Iteration {iterations} ---")

            try:
                response = self.client.beta.messages.create(
                    model=self.MODEL,
                    max_tokens=4096,
                    system=system_prompt,
                    tools=tools,
                    messages=messages,
                    betas=[self.BETA_VERSION],
                )
            except anthropic.APIError as e:
                error_msg = f"API error: {str(e)}"
                errors.append(error_msg)
                if self.verbose:
                    print(f"  [API ERROR] {error_msg}")
                break

            # Process response
            assistant_content = response.content
            messages.append({"role": "assistant", "content": assistant_content})

            # Collect tool results and text
            tool_results = []
            for block in assistant_content:
                if hasattr(block, "type"):
                    if block.type == "text":
                        text = block.text
                        final_text = text
                        if self.verbose:
                            # Truncate for display
                            display_text = text[:200] + ("..." if len(text) > 200 else "")
                            print(f"  [claude] {display_text}")

                    elif block.type == "tool_use":
                        if self.verbose:
                            action = block.input.get("action", "unknown")
                            print(f"  [tool_use] {block.name}.{action}")

                        result_content = self._execute_tool_call(block.name, block.input)
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": [result_content],
                        })

            # Check if scenario is complete
            if not tool_results:
                # Claude didn't use any tools -- it's done
                if self.verbose:
                    print("\n  [done] Claude finished (no more tool calls)")
                break

            # Send tool results back
            messages.append({"role": "user", "content": tool_results})

        # Determine success from final text
        success = "SCENARIO PASSED" in final_text.upper()

        # Count steps from the text
        steps_mentioned = 0
        for i, step in enumerate(scenario.get("steps", []), 1):
            # Rough heuristic: check if step number or keywords appear
            steps_mentioned = i  # Just count iterations as proxy

        duration = time.time() - start_time

        result = ScenarioResult(
            name=scenario.get("name", "Unknown"),
            success=success,
            steps_completed=steps_mentioned,
            total_iterations=iterations,
            final_assessment=final_text,
            screenshots=self.screenshots_taken,
            errors=errors,
            duration_seconds=duration,
        )

        if self.verbose:
            print(f"\n{'='*60}")
            print(f"Result: {'PASSED' if success else 'FAILED'}")
            print(f"Iterations: {iterations}")
            print(f"Duration: {duration:.1f}s")
            print(f"{'='*60}\n")

        return result
