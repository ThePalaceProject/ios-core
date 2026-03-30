# SpecterQA iOS Simulator Driver — Full Implementation Plan

> Target: Extend SpecterQA with a comprehensive iOS Simulator testing driver that provides visual UI testing, console log analysis, network traffic monitoring, performance profiling, state verification, and crash detection — all fed to Claude as unified context for intelligent test execution.

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                  SpecterQA Engine                    │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────┐ │
│  │  AI Decider  │  │  Orchestrator│  │  Reporter  │ │
│  │  (Claude)    │  │  (run loop)  │  │  (JUnit)   │ │
│  └──────┬───────┘  └──────┬───────┘  └───────────┘ │
│         │                  │                         │
│  ┌──────▼──────────────────▼───────────────────────┐ │
│  │           ActionExecutor Protocol                │ │
│  │  screenshot() | click() | type() | swipe()      │ │
│  │  scroll() | longPress() | launch() | terminate()│ │
│  └──────────────────┬──────────────────────────────┘ │
└─────────────────────┼───────────────────────────────┘
                      │
        ┌─────────────▼─────────────┐
        │    SimulatorDriver        │
        │  ┌─────────────────────┐  │
        │  │  InteractionLayer   │  │  ← Quartz CGEvents for tap/swipe/type
        │  │  (sim_interaction)  │  │
        │  ├─────────────────────┤  │
        │  │  ScreenCapture      │  │  ← xcrun simctl io screenshot
        │  │  (sim_capture)      │  │
        │  ├─────────────────────┤  │
        │  │  ConsoleMonitor     │  │  ← log stream + os_log parsing
        │  │  (sim_console)      │  │
        │  ├─────────────────────┤  │
        │  │  NetworkInspector   │  │  ← CFNetwork diagnostics + proxy
        │  │  (sim_network)      │  │
        │  ├─────────────────────┤  │
        │  │  PerfProfiler       │  │  ← memory, CPU, launch time, FPS
        │  │  (sim_perf)         │  │
        │  ├─────────────────────┤  │
        │  │  StateInspector     │  │  ← UserDefaults, keychain, files
        │  │  (sim_state)        │  │
        │  ├─────────────────────┤  │
        │  │  CrashDetector      │  │  ← DiagnosticReports monitoring
        │  │  (sim_crash)        │  │
        │  └─────────────────────┘  │
        └───────────────────────────┘
```

---

## Module 1: SimulatorDriver (Core)

### File: `specterqa/drivers/simulator/driver.py`

```python
class SimulatorDriver(ActionExecutor):
    """
    iOS Simulator driver implementing SpecterQA's ActionExecutor protocol.
    Coordinates all sub-modules and presents a unified interface to the engine.
    """

    def __init__(self, config: SimulatorConfig):
        self.interaction = InteractionLayer(config)
        self.capture = ScreenCapture(config)
        self.console = ConsoleMonitor(config)
        self.network = NetworkInspector(config)
        self.perf = PerfProfiler(config)
        self.state = StateInspector(config)
        self.crash = CrashDetector(config)

    # ActionExecutor protocol
    def screenshot(self) -> Screenshot
    def click(self, x, y) -> ActionResult
    def fill(self, text) -> ActionResult
    def scroll(self, direction, amount) -> ActionResult
    def navigate(self, url) -> ActionResult  # deep links
    def keyboard(self, key) -> ActionResult
    def wait(self, seconds) -> ActionResult
    def launch(self) -> ActionResult
    def terminate(self) -> ActionResult

    # Extended context (fed to Claude alongside screenshots)
    def get_context(self) -> DriverContext:
        """Returns enriched context for the AI decider."""
        return DriverContext(
            screenshot=self.capture.latest(),
            recent_logs=self.console.recent(seconds=5),
            active_requests=self.network.active_requests(),
            perf_snapshot=self.perf.snapshot(),
            app_state=self.state.snapshot(),
            crashes=self.crash.check(),
        )
```

### File: `specterqa/drivers/simulator/config.py`

```python
@dataclass
class SimulatorConfig:
    device_id: str = "booted"          # simctl device UUID or "booted"
    bundle_id: str = ""                 # app bundle identifier
    device_name: str = ""               # e.g. "iPhone 16 Pro"
    screenshot_resize_width: int = 1024 # resize for API
    title_bar_offset: int = 0           # auto-detected
    log_subsystem: str = ""             # os_log subsystem filter
    log_categories: list[str] = field(default_factory=list)
    network_proxy_port: int = 8899      # mitmproxy port
    enable_network_capture: bool = True
    enable_perf_monitoring: bool = True
    enable_crash_detection: bool = True
    launch_args: list[str] = field(default_factory=list)
    launch_env: dict[str, str] = field(default_factory=dict)
```

---

## Module 2: InteractionLayer

### File: `specterqa/drivers/simulator/interaction.py`

Uses macOS Quartz CoreGraphics for all input — no Accessibility permission required.

```python
class InteractionLayer:
    """Sends touch/keyboard input to the iOS Simulator via Quartz CGEvents."""

    def __init__(self, config: SimulatorConfig):
        self.config = config
        self._window_cache = None
        self._cache_time = 0

    # ── Window Management ──

    def _get_simulator_window(self) -> WindowBounds:
        """Find Simulator.app window via CGWindowListCopyWindowInfo.
        Cache for 2 seconds to avoid repeated queries."""

    def _image_to_screen(self, img_x, img_y, img_w, img_h) -> tuple[float, float]:
        """Convert Claude's image-space coordinates to absolute screen coordinates.

        Key calibration points:
        - Simulator window has a title bar (~28px standard, ~0px in full-screen)
        - The device bezel/notch area is PART of the screenshot
        - Status bar (time, battery) is in the screenshot at the top
        - Home indicator is in the screenshot at the bottom
        - Window may be scaled (Retina display)

        Formula:
            screen_x = window_x + (img_x / img_w) * window_content_width
            screen_y = window_y + title_bar + (img_y / img_h) * window_content_height
        """

    def _auto_detect_title_bar(self) -> int:
        """Detect title bar height by comparing window bounds to content bounds.
        macOS 15+: ~28px standard, 0px in full-screen mode."""

    # ── Touch Input ──

    def tap(self, img_x: int, img_y: int, img_w: int, img_h: int):
        """Single tap using CGEventCreateMouseEvent."""
        # 1. Activate Simulator (subprocess: open -a Simulator)
        # 2. Convert coordinates via _image_to_screen()
        # 3. Post kCGEventLeftMouseDown at point
        # 4. Sleep 100ms
        # 5. Post kCGEventLeftMouseUp at point
        # 6. Sleep 500ms for UI response

    def double_tap(self, img_x, img_y, img_w, img_h):
        """Double tap — two rapid taps with 100ms gap."""

    def long_press(self, img_x, img_y, img_w, img_h, duration=3.0):
        """Long press — mouse down, hold for duration, mouse up."""

    def swipe(self, x1, y1, x2, y2, img_w, img_h, duration=0.3):
        """Swipe gesture — mouse down, drag in 20 steps, mouse up.
        Uses kCGEventLeftMouseDragged for intermediate points."""

    def swipe_back(self):
        """iOS back gesture — swipe from left edge (x=5) to center."""

    # ── Keyboard Input ──

    def type_text(self, text: str):
        """Type text into the active field.
        Strategy (in order of preference):
        1. xcrun simctl io <device> keyboard input <text>  (Xcode 16+)
        2. Pasteboard: simctl pbcopy + Cmd-V paste via CGEvent
        3. Individual keystrokes via CGEventCreateKeyboardEvent
        """

    def press_key(self, key: str):
        """Press a special key (enter, escape, tab, delete, home).
        Maps key names to macOS keycodes for CGEventCreateKeyboardEvent."""
        KEY_MAP = {
            "enter": 36, "return": 36,
            "escape": 53,
            "tab": 48,
            "delete": 51, "backspace": 51,
            "space": 49,
            "up": 126, "down": 125, "left": 123, "right": 124,
        }

    def key_combo(self, modifiers: list[str], key: str):
        """Press a key combination (e.g. Cmd+V, Cmd+A).
        Uses CGEventSetFlags for modifier keys."""
```

### Coordinate Calibration Test

```python
def calibration_test(self) -> CalibrationResult:
    """Run an automated calibration by:
    1. Launch Settings.app (known UI layout)
    2. Screenshot and identify the 'General' row position
    3. Tap at that position
    4. Screenshot and verify we're on General screen
    5. Calculate offset correction if needed
    Returns a CalibrationResult with offset adjustments.
    """
```

---

## Module 3: ScreenCapture

### File: `specterqa/drivers/simulator/capture.py`

```python
class ScreenCapture:
    """Screenshot capture with annotation and comparison support."""

    def capture(self, resize_width=1024) -> Screenshot:
        """xcrun simctl io <device> screenshot --type=png <path>
        Returns Screenshot(base64, width, height, timestamp, raw_path)"""

    def capture_with_annotations(self, annotations: list[Annotation]) -> Screenshot:
        """Capture + draw red circles/arrows at annotation points.
        Used for test reports to show where Claude clicked."""

    def diff(self, a: Screenshot, b: Screenshot) -> ScreenDiff:
        """Pixel-diff two screenshots. Returns ScreenDiff with:
        - changed_percentage: float
        - changed_regions: list[Rect]
        - diff_image: base64 PNG with changes highlighted
        Useful for detecting if a tap actually changed the UI."""

    def wait_for_change(self, baseline: Screenshot, timeout=5.0) -> bool:
        """Poll screenshots until UI changes from baseline.
        Returns True if changed, False if timeout."""

    def element_appears(self, text: str, timeout=5.0) -> bool:
        """Use Claude vision to check if specific text/element appears.
        Polls every 500ms until timeout."""
```

---

## Module 4: ConsoleMonitor

### File: `specterqa/drivers/simulator/console.py`

This is where we get deep insight into what the app is doing internally.

```python
class ConsoleMonitor:
    """Captures and analyzes iOS Simulator console output in real-time."""

    def __init__(self, config: SimulatorConfig):
        self._process = None  # Background log stream process
        self._buffer = RingBuffer(max_entries=5000)
        self._error_buffer = RingBuffer(max_entries=500)
        self._watchers: list[LogWatcher] = []

    def start(self):
        """Start background log capture.

        Command: xcrun simctl spawn <device> log stream \
            --level debug \
            --predicate 'subsystem == "<bundle_id>" OR
                         subsystem BEGINSWITH "com.apple.network" OR
                         subsystem == "com.apple.WebKit" OR
                         subsystem == "com.apple.security"'
            --style json

        Parses JSON log entries into structured LogEntry objects.
        Runs in a background thread.
        """

    def stop(self):
        """Stop log capture and flush buffers."""

    def recent(self, seconds=5, level=None, category=None) -> list[LogEntry]:
        """Get recent log entries, optionally filtered."""

    def errors(self, seconds=30) -> list[LogEntry]:
        """Get recent error/fault level entries."""

    def search(self, pattern: str) -> list[LogEntry]:
        """Search logs by regex pattern."""

    def add_watcher(self, watcher: LogWatcher):
        """Add a real-time log watcher that triggers on patterns.

        Example watchers:
        - AuthWatcher: triggers on OIDC/SAML/OAuth log patterns
        - NetworkWatcher: triggers on HTTP error codes
        - CrashWatcher: triggers on assertion failures
        - PerformanceWatcher: triggers on slow operations
        """

    def summary(self) -> LogSummary:
        """Generate a summary of recent log activity.
        Returns LogSummary with:
        - total_entries: int
        - by_level: dict[str, int]  (debug/info/warning/error/fault)
        - top_subsystems: list[tuple[str, int]]
        - recent_errors: list[LogEntry]
        - auth_events: list[LogEntry]  (filtered for auth-related)
        - network_errors: list[LogEntry]
        """

@dataclass
class LogEntry:
    timestamp: datetime
    level: str          # debug, info, default, error, fault
    subsystem: str      # e.g. "org.thepalaceproject.palace"
    category: str       # e.g. "Network", "Auth", "UI"
    message: str
    process: str
    thread_id: int

    @property
    def is_error(self) -> bool:
        return self.level in ("error", "fault")

    @property
    def is_auth_related(self) -> bool:
        keywords = ["oauth", "oidc", "saml", "token", "auth", "credential",
                     "sign.in", "sign.out", "session", "bearer"]
        return any(k in self.message.lower() for k in keywords)

    @property
    def is_network_related(self) -> bool:
        keywords = ["http", "url", "request", "response", "status",
                     "timeout", "connection", "ssl", "certificate"]
        return any(k in self.message.lower() for k in keywords)

class LogWatcher:
    """Base class for real-time log pattern watchers."""
    def __init__(self, name: str, pattern: str, callback: Callable):
        self.name = name
        self.pattern = re.compile(pattern, re.IGNORECASE)
        self.callback = callback
        self.matches: list[LogEntry] = []

    def check(self, entry: LogEntry):
        if self.pattern.search(entry.message):
            self.matches.append(entry)
            self.callback(entry)
```

### Pre-built Watchers for Palace

```python
# Auth flow watcher — detects OIDC/SAML events
AUTH_WATCHER = LogWatcher(
    name="auth_flow",
    pattern=r"(oauth|oidc|saml|token.*(refresh|expir|invalid)|auth.*(fail|success|error)|credential|sign.*(in|out))",
    callback=lambda e: print(f"  [AUTH] {e.message[:100]}")
)

# Network error watcher — detects HTTP failures
NETWORK_ERROR_WATCHER = LogWatcher(
    name="network_errors",
    pattern=r"(HTTP\s*(4\d{2}|5\d{2})|NSURLError|timeout|connection.*(refused|reset|closed)|SSL)",
    callback=lambda e: print(f"  [NET ERROR] {e.message[:100]}")
)

# DRM watcher — detects DRM license issues
DRM_WATCHER = LogWatcher(
    name="drm",
    pattern=r"(adobe|lcp|drm|license|fulfillment|rights\.xml|RMSDK)",
    callback=lambda e: print(f"  [DRM] {e.message[:100]}")
)

# Crash precursor watcher — detects assertions and fatal errors
CRASH_WATCHER = LogWatcher(
    name="crash_precursor",
    pattern=r"(assertion.fail|fatal|EXC_BAD_ACCESS|SIGABRT|fatalError|precondition)",
    callback=lambda e: print(f"  [CRASH] {e.message[:100]}")
)
```

---

## Module 5: NetworkInspector

### File: `specterqa/drivers/simulator/network.py`

```python
class NetworkInspector:
    """Captures and analyzes network traffic from the simulator."""

    def __init__(self, config: SimulatorConfig):
        self._requests: list[NetworkRequest] = []
        self._active: dict[str, NetworkRequest] = {}  # request_id -> request

    # ── Capture Strategy ──
    #
    # Option A (recommended): CFNetwork diagnostics via environment variable
    #   Set CFNETWORK_DIAGNOSTICS=3 in app launch environment
    #   Captures all URLSession traffic to ~/Library/Logs/CrDiag/
    #   Parse the .plist diagnostic files
    #
    # Option B: Inject a custom URLProtocol via launch argument
    #   Requires app to support -NSURLProtocolClasses argument
    #   More detailed but requires app modification
    #
    # Option C: Parse os_log network subsystem entries
    #   Filter for subsystem "com.apple.network" and "com.apple.CFNetwork"
    #   Less detailed but zero-config
    #
    # Option D: mitmproxy (most detailed, requires cert install)
    #   Run mitmproxy on host, set simulator HTTP proxy
    #   Full request/response bodies, headers, timing
    #   Requires: mitmproxy installed, CA cert in simulator trust store

    def start(self):
        """Start network capture using best available method."""

    def stop(self):
        """Stop capture and finalize all pending requests."""

    def active_requests(self) -> list[NetworkRequest]:
        """Get currently in-flight requests."""

    def completed_requests(self, seconds=30) -> list[NetworkRequest]:
        """Get recently completed requests."""

    def failed_requests(self, seconds=60) -> list[NetworkRequest]:
        """Get failed requests (4xx, 5xx, timeouts)."""

    def auth_requests(self) -> list[NetworkRequest]:
        """Get requests related to authentication.
        Filters for: /oauth, /token, /saml, /authenticate, Authorization header."""

    def opds_requests(self) -> list[NetworkRequest]:
        """Get OPDS feed requests. Filters for application/opds+xml."""

    def summary(self) -> NetworkSummary:
        """Generate summary:
        - total_requests: int
        - by_status: dict[int, int]  (200: 45, 401: 2, etc.)
        - by_host: dict[str, int]
        - avg_latency_ms: float
        - slowest_requests: list[NetworkRequest]  (top 5)
        - failed_requests: list[NetworkRequest]
        - auth_flow_timeline: list[NetworkRequest]  (ordered auth requests)
        """

@dataclass
class NetworkRequest:
    request_id: str
    method: str          # GET, POST, etc.
    url: str
    host: str
    path: str
    status_code: int | None
    request_headers: dict[str, str]
    response_headers: dict[str, str]
    request_body_size: int
    response_body_size: int
    started_at: datetime
    completed_at: datetime | None
    duration_ms: float | None
    error: str | None

    @property
    def is_auth(self) -> bool:
        auth_paths = ["/oauth", "/token", "/saml", "/authenticate", "/authorize", "/login"]
        return any(p in self.path.lower() for p in auth_paths) or \
               "Authorization" in self.request_headers

    @property
    def is_failed(self) -> bool:
        return (self.status_code and self.status_code >= 400) or self.error is not None
```

---

## Module 6: PerfProfiler

### File: `specterqa/drivers/simulator/perf.py`

```python
class PerfProfiler:
    """Real-time performance monitoring of the simulated app."""

    def __init__(self, config: SimulatorConfig):
        self._samples: list[PerfSample] = []
        self._launch_time: float | None = None

    def start(self):
        """Start periodic performance sampling (every 2 seconds)."""

    def stop(self):
        """Stop sampling."""

    def snapshot(self) -> PerfSnapshot:
        """Get current performance state."""
        pid = self._get_app_pid()
        return PerfSnapshot(
            memory_mb=self._get_memory(pid),
            cpu_percent=self._get_cpu(pid),
            thread_count=self._get_thread_count(pid),
            disk_usage_mb=self._get_app_container_size(),
            fps_estimate=self._estimate_fps(),
        )

    def measure_launch_time(self) -> float:
        """Measure cold launch time.
        1. Terminate app
        2. Record timestamp
        3. Launch app
        4. Poll screenshots until UI renders (non-blank)
        5. Return elapsed time
        """

    def measure_action_time(self, action: Callable) -> float:
        """Measure time for a UI action to complete.
        Takes screenshot before, executes action, polls until UI changes."""

    # ── Data Collection Methods ──

    def _get_app_pid(self) -> int:
        """xcrun simctl spawn booted launchctl list | grep bundle_id"""

    def _get_memory(self, pid: int) -> float:
        """Parse output of: xcrun simctl spawn booted ps -o rss= -p <pid>
        Returns RSS in MB."""

    def _get_cpu(self, pid: int) -> float:
        """Parse output of: xcrun simctl spawn booted ps -o %cpu= -p <pid>"""

    def _get_thread_count(self, pid: int) -> int:
        """Count threads via: xcrun simctl spawn booted ls /proc/<pid>/task/
        Or parse ps output."""

    def _get_app_container_size(self) -> float:
        """Calculate app container size on disk.
        Path: ~/Library/Developer/CoreSimulator/Devices/<udid>/data/Containers/
        Bundle/<app_uuid>/"""

    def _estimate_fps(self) -> float:
        """Estimate frame rate by taking rapid screenshots and measuring
        how many are unique (different pixel content) per second.
        Rough but useful for detecting jank."""

    def summary(self) -> PerfSummary:
        """Performance summary over the test run.
        - peak_memory_mb, avg_memory_mb
        - peak_cpu_percent, avg_cpu_percent
        - launch_time_ms (if measured)
        - memory_trend: "stable" | "growing" | "leaking"
        - jank_events: list of timestamps where FPS dropped below 30
        """

@dataclass
class PerfSnapshot:
    memory_mb: float
    cpu_percent: float
    thread_count: int
    disk_usage_mb: float
    fps_estimate: float
    timestamp: datetime = field(default_factory=datetime.now)

@dataclass
class PerfSample:
    snapshot: PerfSnapshot
    screenshot_hash: str  # To correlate with UI state
```

---

## Module 7: StateInspector

### File: `specterqa/drivers/simulator/state.py`

```python
class StateInspector:
    """Inspects app internal state via simulator filesystem access."""

    def __init__(self, config: SimulatorConfig):
        self.config = config
        self._container_path: str | None = None

    def _get_container_path(self) -> str:
        """Get the app's data container path.
        xcrun simctl get_app_container <device> <bundle_id> data"""

    # ── UserDefaults ──

    def read_defaults(self) -> dict:
        """Read app's UserDefaults.
        xcrun simctl spawn <device> defaults read <bundle_id>
        Returns parsed plist as dict."""

    def read_default(self, key: str) -> Any:
        """Read a specific UserDefaults key."""

    def write_default(self, key: str, value: Any):
        """Write a UserDefaults value (for test setup).
        xcrun simctl spawn <device> defaults write <bundle_id> <key> <value>"""

    # ── Keychain ──

    def keychain_items(self) -> list[KeychainItem]:
        """List keychain items for the app.
        Uses security command or reads keychain database directly.
        Useful for verifying auth token presence/absence."""

    def has_auth_token(self) -> bool:
        """Check if an authentication token exists in keychain."""

    def clear_keychain(self):
        """Clear app's keychain items (for testing re-auth flows)."""

    # ── File System ──

    def list_documents(self) -> list[str]:
        """List files in the app's Documents directory."""

    def read_file(self, relative_path: str) -> bytes:
        """Read a file from the app container."""

    def file_exists(self, relative_path: str) -> bool:
        """Check if a file exists in the app container."""

    def app_database(self) -> dict:
        """Read the app's SQLite database (if any) and return table summaries.
        Useful for verifying book registry state."""

    # ── Book Registry State (Palace-specific) ──

    def book_registry(self) -> list[BookRecord]:
        """Read the Palace book registry plist/JSON.
        Returns list of books with their states (downloaded, borrowing, etc.)."""

    def borrowed_books(self) -> list[BookRecord]:
        """Filter registry for currently borrowed books."""

    # ── Snapshot ──

    def snapshot(self) -> StateSnapshot:
        """Full state snapshot.
        - user_defaults: key settings (current account, auth state, etc.)
        - has_auth_token: bool
        - book_count: int
        - storage_mb: float
        - current_library: str
        """
```

---

## Module 8: CrashDetector

### File: `specterqa/drivers/simulator/crash.py`

```python
class CrashDetector:
    """Monitors for app crashes and collects diagnostic information."""

    def __init__(self, config: SimulatorConfig):
        self._crash_dir = Path.home() / "Library/Logs/DiagnosticReports"
        self._baseline_crashes: set[str] = set()
        self._detected_crashes: list[CrashReport] = []

    def start(self):
        """Record baseline crash reports so we only detect new ones."""
        self._baseline_crashes = {f.name for f in self._crash_dir.glob("*.ips")}

    def check(self) -> list[CrashReport]:
        """Check for new crash reports since baseline.
        Also checks if the app process is still running."""
        # 1. Check if app is still running
        #    xcrun simctl spawn booted launchctl list | grep bundle_id
        #    If not found → app crashed
        #
        # 2. Check for new .ips files in DiagnosticReports
        #    Parse crash report for:
        #    - Exception type (EXC_BAD_ACCESS, SIGABRT, etc.)
        #    - Crashing thread backtrace
        #    - Last exception backtrace (for NSException)

    def is_app_running(self) -> bool:
        """Check if the app process is still alive."""

    def latest_crash(self) -> CrashReport | None:
        """Get the most recent crash report, if any."""

@dataclass
class CrashReport:
    timestamp: datetime
    exception_type: str      # EXC_BAD_ACCESS, SIGABRT, etc.
    exception_code: str
    crashing_thread: int
    backtrace: list[str]     # Symbolicated backtrace frames
    last_exception: str | None  # NSException reason
    app_version: str
    os_version: str
    device: str
    raw_path: str            # Path to .ips file
```

---

## Module 9: AI Decider Enhancements

### File: `specterqa/drivers/simulator/ai_context.py`

The key innovation: Claude sees not just the screenshot, but the full app context.

```python
class SimulatorAIContext:
    """Builds enriched context for Claude's decision-making."""

    @staticmethod
    def build_system_prompt(product: ProductConfig) -> str:
        return """You are testing an iOS app in the Simulator. You can see the screen
and will receive additional context about the app's internal state.

## iOS-Specific Interaction Rules
- Tap buttons and list items to navigate
- Swipe right from left edge (x < 20) = iOS back gesture
- Pull down on lists to refresh
- Keyboard appears when tapping text fields — may obscure content
- Alert dialogs are modal — must be dismissed before other actions
- Web views (for OIDC/SAML) have different UI patterns than native screens
- Tab bar at bottom: tap tabs to switch sections
- Long-press on elements may reveal context menus

## Context You Receive
Along with each screenshot, you'll see:
- **Console logs**: Recent app log output (errors, warnings, auth events)
- **Network**: Active/recent HTTP requests and their status codes
- **Performance**: Memory usage, CPU load
- **App state**: Current library, auth status, book count

## Decision Making
- If you see auth errors in logs, try signing in again
- If network requests are failing, note the error and try again
- If memory is growing rapidly, flag it as a performance issue
- If the app crashes, report it immediately with the crash context
- Always verify actions had an effect by taking a screenshot after

## Reporting
When you detect issues, categorize them:
- auth_flow: Authentication/authorization problems
- token_refresh: Token expiry/refresh failures
- network: HTTP errors, timeouts, connectivity
- performance: Memory leaks, slow responses, jank
- crash: App crashes or hangs
- ux: Confusing UI, missing feedback, accessibility issues
- data: Missing or incorrect content display
"""

    @staticmethod
    def format_context(context: DriverContext) -> str:
        """Format the driver context as a human-readable string
        to include in Claude's message alongside the screenshot."""
        sections = []

        # Console logs (last 5 seconds, errors highlighted)
        if context.recent_logs:
            log_lines = []
            for entry in context.recent_logs[-20:]:  # Last 20 entries
                prefix = "❌" if entry.is_error else "⚠️" if entry.level == "warning" else "  "
                log_lines.append(f"{prefix} [{entry.category}] {entry.message[:120]}")
            sections.append("## Recent Console Logs\n" + "\n".join(log_lines))

        # Network activity
        if context.active_requests:
            net_lines = [f"  {r.method} {r.url} → {r.status_code or 'pending'} ({r.duration_ms or '?'}ms)"
                        for r in context.active_requests[-10:]]
            sections.append("## Network Activity\n" + "\n".join(net_lines))

        # Performance
        if context.perf_snapshot:
            p = context.perf_snapshot
            sections.append(f"## Performance\nMemory: {p.memory_mb:.1f}MB | CPU: {p.cpu_percent:.1f}% | Threads: {p.thread_count}")

        # App state
        if context.app_state:
            s = context.app_state
            sections.append(f"## App State\nLibrary: {s.current_library} | Auth: {s.has_auth_token} | Books: {s.book_count}")

        # Crashes
        if context.crashes:
            for c in context.crashes:
                sections.append(f"## ⚠️ CRASH DETECTED\n{c.exception_type}: {c.last_exception}\n{chr(10).join(c.backtrace[:5])}")

        return "\n\n".join(sections) if sections else ""
```

---

## Module 10: Product & Persona YAML for iOS

### Product Definition

```yaml
# .specterqa/products/palace-ios.yaml
name: Palace iOS
platform: ios_simulator
bundle_id: org.thepalaceproject.palace
device: "iPhone 16 Pro"
simulator_id: "DF4A2A27-9888-429D-A749-2E157A049A37"

viewport:
  width: 393
  height: 852

launch_args:
  - "-UITesting"

launch_env:
  CFNETWORK_DIAGNOSTICS: "3"

log_subsystem: "org.thepalaceproject.palace"

cost_limit_per_run: 5.00
max_iterations: 50

# App-specific context for the AI
app_context: |
  Palace is a library reading app. Users can:
  - Browse library catalogs (OPDS feeds)
  - Borrow and download ebooks (EPUB, PDF) and audiobooks
  - Read/listen to borrowed content
  - Manage holds/reservations
  - Switch between multiple library accounts

  Authentication methods vary by library:
  - Basic (barcode + PIN)
  - OIDC (redirect to web login)
  - SAML (redirect to institution login)
  - Clever (educational SSO)

  Key screens: Catalog, My Books, Reservations, Settings
  Debug mode: Long-press version in Settings for 5 seconds
```

### Persona Definitions

```yaml
# .specterqa/personas/new-patron.yaml
name: Maria
role: New library patron
age: 28
tech_comfort: moderate
patience: low
goals:
  - Find and borrow an ebook for the first time
  - Figure out how to read downloaded books
  - Manage library card credentials
frustrations:
  - Confusing sign-in flows
  - Not knowing if a book is available
  - DRM errors she doesn't understand
credentials:
  lyrasis_email: "${LYRASIS_EMAIL}"
  lyrasis_password: "${LYRASIS_PASSWORD}"
  a1qa_barcode: "${A1QA_BARCODE}"
  a1qa_pin: "${A1QA_PIN}"
```

```yaml
# .specterqa/personas/power-reader.yaml
name: James
role: Heavy library user with 3 library cards
age: 45
tech_comfort: high
patience: high
goals:
  - Switch between libraries efficiently
  - Download books for offline reading
  - Manage holds across multiple libraries
  - Use audiobook features during commute
frustrations:
  - Having to re-authenticate frequently
  - Losing reading position
  - Slow catalog loading
```

### Journey Definitions

```yaml
# .specterqa/journeys/oidc-full-lifecycle.yaml
name: OIDC Authentication Full Lifecycle
product: palace-ios
persona: new-patron
level: thorough

preconditions:
  - "App is freshly installed"

steps:
  - goal: "Launch the app and select a library"
    timeout: 15

  - goal: "Enable hidden libraries via debug settings (long-press version in Settings for 5 seconds)"
    checkpoint: "Hidden libraries toggle is visible and enabled"

  - goal: "Add the iCarus library"
    checkpoint: "iCarus appears in the library list"

  - goal: "Sign in to iCarus using OIDC (email: ${lyrasis_email}, password: ${lyrasis_password})"
    checkpoint: "User is signed in — My Books or catalog visible"
    monitor:
      - console: "auth|oauth|oidc|token"
      - network: "*/oauth/*|*/token*|*/authenticate*"

  - goal: "Browse the catalog and borrow any available ebook"
    checkpoint: "Book shows as borrowed or downloading"
    monitor:
      - network: "*/loans*|*/borrow*"

  - goal: "Open My Books and verify the borrowed book appears"
    checkpoint: "Borrowed book is visible in My Books"

  - goal: "Force-close the app to simulate session interruption"

  - goal: "Relaunch and navigate to My Books"
    checkpoint: "Previously borrowed book is still visible"
    monitor:
      - console: "token|refresh|auth|session"
      - network: "*/token*|*/loans*"

  - goal: "Try to borrow another book"
    checkpoint: "Either succeeds or prompts for re-auth gracefully"

  - goal: "Sign out from Settings"
    checkpoint: "User is signed out, sign-in button visible"
    monitor:
      - console: "sign.out|logout|clear|credential"
      - network: "*/logout*|*/revoke*"

findings_categories:
  - auth_flow
  - token_refresh
  - error_ux
  - navigation
  - performance
  - data_integrity
```

```yaml
# .specterqa/journeys/multi-library-switching.yaml
name: Multi-Library Account Switching
product: palace-ios
persona: power-reader
level: thorough

steps:
  - goal: "Sign in to A1QA library using barcode ${a1qa_barcode} and PIN ${a1qa_pin}"
    checkpoint: "Signed in to A1QA, catalog visible"

  - goal: "Borrow a book from A1QA"
    checkpoint: "Book appears in My Books"

  - goal: "Switch to iCarus library"
    checkpoint: "iCarus catalog loads"
    monitor:
      - console: "account.*switch|current.*account|catalog.*load"
      - performance: memory  # Watch for memory spikes during switch

  - goal: "Sign in to iCarus with OIDC"
    checkpoint: "Signed in successfully"

  - goal: "Switch back to A1QA"
    checkpoint: "A1QA catalog loads, previously borrowed book still in My Books"
    monitor:
      - console: "account|registry|book.*state"

  - goal: "Rapidly switch between libraries 5 times"
    checkpoint: "No crashes, no auth errors, catalog loads each time"
    monitor:
      - crash: true
      - performance: memory
      - console: "error|crash|exception|fatal"
```

```yaml
# .specterqa/journeys/saml-expiry-recovery.yaml
name: SAML Token Expiry and Recovery
product: palace-ios
persona: new-patron
level: thorough

setup:
  - action: "clear_keychain"  # Force re-authentication
  - action: "set_default"
    key: "lastAuthDate"
    value: "2024-01-01T00:00:00Z"  # Force token to appear expired

steps:
  - goal: "Launch the app"
    monitor:
      - console: "token|expir|refresh|auth"

  - goal: "Navigate to My Books"
    checkpoint: "Either shows books or prompts for re-auth"
    monitor:
      - network: "*/token*|*/authenticate*"
      - console: "401|403|unauthorized|expired"

  - goal: "If prompted, complete re-authentication"
    checkpoint: "Authentication succeeds"

  - goal: "Verify all previously borrowed books are accessible"
    checkpoint: "Books load and can be opened"

findings_categories:
  - token_refresh
  - auth_flow
  - error_ux
  - data_integrity
```

---

## Module 11: Report Generation

### File: `specterqa/drivers/simulator/report.py`

```python
class SimulatorTestReport:
    """Generates comprehensive test reports with all collected data."""

    def generate(self, run_result: RunResult) -> TestReport:
        return TestReport(
            # Standard SpecterQA fields
            scenario_name=run_result.scenario_name,
            persona=run_result.persona,
            result=run_result.status,  # passed/failed
            duration_seconds=run_result.duration,
            iterations=run_result.iterations,
            findings=run_result.findings,
            cost_usd=run_result.cost,

            # iOS-specific enrichment
            screenshots=run_result.screenshots,  # Annotated with click positions
            console_summary=run_result.console_summary,
            network_summary=run_result.network_summary,
            perf_summary=run_result.perf_summary,
            crash_reports=run_result.crashes,
            state_before=run_result.state_before,
            state_after=run_result.state_after,

            # Timeline (interleaved events)
            timeline=self._build_timeline(run_result),
        )

    def _build_timeline(self, run: RunResult) -> list[TimelineEvent]:
        """Merge all events into a single chronological timeline.
        Each event: timestamp, type (ui_action, log, network, perf, crash), data.
        This gives a complete picture of what happened during the test."""

    def to_junit_xml(self, report: TestReport) -> str:
        """Standard JUnit XML for CI/CD integration."""

    def to_html(self, report: TestReport) -> str:
        """Rich HTML report with:
        - Screenshot gallery with annotations
        - Console log viewer with filtering
        - Network waterfall chart
        - Performance graphs (memory/CPU over time)
        - Timeline view
        """

    def to_forgeos_evidence(self, report: TestReport) -> dict:
        """Format as ForgeOS evidence for auto-submission.
        Maps to unit_test evidence type with pass/fail counts."""
```

---

## Module 12: Engine Integration

### Changes to SpecterQA core engine

```python
# specterqa/engine/orchestrator.py — Add driver routing

def _create_driver(self, product: ProductConfig) -> ActionExecutor:
    if product.platform == "ios_simulator":
        from specterqa.drivers.simulator import SimulatorDriver, SimulatorConfig
        config = SimulatorConfig(
            device_id=product.simulator_id or "booted",
            bundle_id=product.bundle_id,
            device_name=product.device,
            log_subsystem=product.log_subsystem,
            launch_args=product.launch_args,
            launch_env=product.launch_env,
        )
        return SimulatorDriver(config)
    elif product.platform == "macos":
        from specterqa.drivers.macos import MacOSDriver
        return MacOSDriver(...)
    else:
        from specterqa.drivers.playwright import PlaywrightDriver
        return PlaywrightDriver(...)

# specterqa/engine/ai_decider.py — Add context injection

def decide(self, goal: str, screenshot: Screenshot,
           driver_context: DriverContext | None = None) -> Decision:
    """Enhanced decide() that includes driver context."""
    messages = [{"role": "user", "content": []}]

    # Screenshot
    messages[0]["content"].append({
        "type": "image",
        "source": {"type": "base64", "media_type": "image/png", "data": screenshot.data}
    })

    # Goal
    messages[0]["content"].append({
        "type": "text",
        "text": f"Goal: {goal}"
    })

    # Enriched context from driver (logs, network, perf, state)
    if driver_context:
        context_text = SimulatorAIContext.format_context(driver_context)
        if context_text:
            messages[0]["content"].append({
                "type": "text",
                "text": f"\n---\n{context_text}"
            })

    return self._call_model(messages)
```

---

## Implementation Priority

| Phase | Module | Effort | Value |
|-------|--------|--------|-------|
| 1 | InteractionLayer (Quartz) | 2 days | Critical — everything depends on this |
| 1 | ScreenCapture | 1 day | Critical — AI needs to see |
| 1 | Engine integration | 1 day | Critical — driver routing + context |
| 2 | ConsoleMonitor | 2 days | High — deepest insight into app behavior |
| 2 | CrashDetector | 1 day | High — must detect crashes immediately |
| 3 | NetworkInspector | 2 days | High — essential for auth flow testing |
| 3 | StateInspector | 1 day | Medium — useful for setup/verification |
| 4 | PerfProfiler | 2 days | Medium — performance regression detection |
| 4 | Report generation | 2 days | Medium — HTML reports, ForgeOS integration |
| 5 | Calibration test | 1 day | Nice-to-have — auto-fixes coordinate issues |
| 5 | Palace-specific watchers | 1 day | Nice-to-have — pre-built for our app |

**Total estimate: ~16 days of focused development**

---

## Dependencies

```
# requirements.txt additions
pyobjc-framework-Quartz>=10.0     # CGEvent for touch input
pyobjc-framework-CoreGraphics>=10.0
mitmproxy>=10.0                    # Optional: network capture
```

## Testing the Driver

```bash
# Run a quick calibration test
specterqa calibrate --product palace-ios

# Run OIDC lifecycle test
specterqa run --product palace-ios --journey oidc-full-lifecycle --verbose

# Run with full observability
specterqa run --product palace-ios --journey multi-library-switching \
  --enable-console --enable-network --enable-perf --html-report

# CI mode
specterqa run --product palace-ios --level smoke --output junit \
  > test-results/specterqa-ios.xml
```
