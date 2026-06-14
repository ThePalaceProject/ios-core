#!/usr/bin/env python3
"""
regression_staging.py — the RC-AREA per-journey STAGING layer (#21).

The area-worker could replay recordings but could NOT stage a journey to its
recording's `requires.initial_state`: each recording pins a specific SCREEN, and
a clean install sits on "Add Library" — matching none. This module drives the
sim (via simdrive.act/observe) through each journey's scripted setup to reach
that start screen, so the campaign runs end-to-end automated.

  • Driver  — observe→resolve(by text)→act(tap/type/swipe) loop.
  • Primitives — dismiss_first_launch, add_library, sign_in/out,
    borrow_and_download (Phase 2), navigate_to.
  • STAGING_RECIPES + stage_for_journey() — declarative per-journey setup, using
    the staging-ORDER insight for mutually-exclusive auth states (a sign-in
    leaves the app SIGNED-IN, which is sign-out's precondition).
  • assert_outcome() — post-state OCR present/absent gate so a verdict reflects
    the journey's real OUTCOME, not just that taps executed (a modal can eat
    taps while every step "executes"); fed into the runner's classify in Phase 3.

NORMALIZE NOTE: device-suffix + cross-build version normalize live in
regression_findings.py (normalized_requires_device / normalized_requires_version_match)
and are wired in regression-area-worker.sh — NOT here. This module is staging-only.

The pure parts (recipe lookup/ordering, outcome assertion) are unit-tested in
scripts/tests/. The sim-driving primitives are exercised live by the area-worker
against a booted sim.
"""
from __future__ import annotations

import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ===========================================================================
# OUTCOME ASSERTION  (item 5 — pure, unit-tested; wired into classify in Phase 3)
# ===========================================================================
def assert_outcome(
    texts: list[str],
    expect_present: Optional[list[str]] = None,
    expect_absent: Optional[list[str]] = None,
) -> tuple[bool, str]:
    """Given the OCR texts of the post-replay screen, verify the journey's real
    OUTCOME — not merely that taps executed. Returns (ok, reason).

    expect_present: substrings that MUST appear (case-insensitive substring).
    expect_absent : substrings that must NOT appear — e.g. the returned book's
                    TITLE (the destructive-wrong-book / modal-ate-the-taps gate:
                    classify_replay can say PASS while a modal swallowed the taps
                    and nothing actually happened).
    """
    hay = " \n ".join(texts).lower()
    for want in expect_present or []:
        if want.lower() not in hay:
            return False, f"outcome-missing: expected '{want}' in post-state"
    for nope in expect_absent or []:
        if nope.lower() in hay:
            return False, f"outcome-leak: '{nope}' still present in post-state"
    return True, "outcome-ok"


# ===========================================================================
# DRIVER  (sim-driving; exercised live)
# ===========================================================================
@dataclass
class _Mark:
    x: int
    y: int
    w: int
    h: int
    text: str

    @property
    def cx(self) -> int:
        return int(self.x + self.w / 2)

    @property
    def cy(self) -> int:
        return int(self.y + self.h / 2)


class StagingError(RuntimeError):
    pass


class Driver:
    """Thin observe→resolve→act loop over simdrive. Imports simdrive lazily so
    the pure helpers in this module stay importable on a CI box without a sim."""

    def __init__(self, udid: str, app_bundle_id: str, settle: float = 0.8):
        self.udid = udid
        self.app = app_bundle_id
        self.settle = settle
        import tempfile

        from simdrive import act, observe

        self._act = act
        self._observe = observe
        self._tmp = Path(tempfile.mkdtemp(prefix="rc-stage-obs-"))
        self._last = None

    # -- observe ------------------------------------------------------------
    def observe(self) -> list[_Mark]:
        obs = self._observe.observe(self.udid, out_dir=self._tmp, annotate=False)
        self._last = obs
        return [
            _Mark(int(m.x), int(m.y), int(m.w), int(m.h), m.text or "")
            for m in obs.marks
        ]

    @property
    def _dims(self) -> tuple[int, int]:
        return (self._last.screenshot_w, self._last.screenshot_h)

    def texts(self) -> list[str]:
        return [m.text for m in self.observe()]

    # -- resolve ------------------------------------------------------------
    def find(self, needle: str, marks: Optional[list[_Mark]] = None) -> Optional[_Mark]:
        marks = marks if marks is not None else self.observe()
        nl = needle.lower()
        for m in marks:  # exact-ish first
            if m.text.strip().lower() == nl:
                return m
        for m in marks:  # then substring
            if nl in m.text.lower():
                return m
        return None

    def has(self, needle: str) -> bool:
        return self.find(needle) is not None

    def wait_for(self, needle: str, timeout: float = 12.0) -> _Mark:
        deadline = time.time() + timeout
        while time.time() < deadline:
            m = self.find(needle)
            if m:
                return m
            time.sleep(0.6)
        raise StagingError(f"timeout waiting for '{needle}'")

    # -- act ----------------------------------------------------------------
    def tap_text(self, needle: str, timeout: float = 12.0) -> None:
        m = self.wait_for(needle, timeout)
        w, h = self._dims
        self._act.tap(m.cx, m.cy, w, h, self.udid)
        time.sleep(self.settle)

    def tap_xy(self, px: int, py: int) -> None:
        if self._last is None:
            self.observe()
        w, h = self._dims
        self._act.tap(px, py, w, h, self.udid)
        time.sleep(self.settle)

    def type(self, text: str) -> None:
        self._act.type_text(text, self.udid)
        time.sleep(self.settle)

    def swipe(self, x1: int, y1: int, x2: int, y2: int, ms: int = 300) -> None:
        if self._last is None:
            self.observe()
        w, h = self._dims
        self._act.swipe(x1, y1, x2, y2, w, h, ms, self.udid)
        time.sleep(self.settle)


# ===========================================================================
# STAGING PRIMITIVES  (sim-driving)
# ===========================================================================
def _creds(slug: str) -> tuple[str, str]:
    """Creds from env (never hardcoded); the area-worker exports these from the
    harness vault before invoking staging."""
    user = os.environ.get(f"RC_{slug.upper()}_USER", "")
    pw = os.environ.get(f"RC_{slug.upper()}_PASS", "")
    if not user or not pw:
        raise StagingError(f"missing creds for '{slug}' (set RC_{slug.upper()}_USER/PASS)")
    return user, pw


def dismiss_first_launch(d: Driver) -> None:
    """Clear the clean-install notification-permission / first-launch dialog so
    step-0 text_subset matches the recording (item 3)."""
    for label in ("Allow", "Continue", "OK", "Don't Allow", "Not Now"):
        if d.find(label):
            d.tap_text(label)
            return


def add_library(d: Driver, display_name: str) -> None:
    """Idempotently add a library by display name (sims are reused across
    journeys, so this must no-op if already added). Handles both the clean-install
    forced "Add Library" picker (no tab bar yet) and the Settings → + ADD LIBRARY
    path. Hidden/test libraries assumed enabled by sim setup (Settings → Testing →
    Enable Hidden Libraries)."""
    if d.has("Add Library"):
        # forced first-run picker or the add-library sheet is already open
        d.tap_text(display_name)
        time.sleep(1.5)
        return
    # tab bar exists: skip if already under Settings → LIBRARIES, else add it
    d.tap_text("Settings")
    if d.has(display_name):
        return
    d.tap_text("ADD LIBRARY")
    d.tap_text(display_name)
    time.sleep(1.5)


def navigate_to(d: Driver, screen: str) -> None:
    """Drive to a named screen. screen ∈ catalog | my_books | holds | settings |
    account_signin | account_signedin (the last two open the A1QA Account)."""
    tab = {"catalog": "Catalog", "my_books": "My Books", "holds": "Holds",
           "settings": "Settings"}.get(screen)
    if tab:
        d.tap_text(tab)
        return
    if screen in ("account_signin", "account_signedin"):
        d.tap_text("Settings")
        d.tap_text("A1QA Test Library")
        return
    raise StagingError(f"unknown screen '{screen}'")


def sign_in(d: Driver, slug: str = "a1qa", library: str = "A1QA Test Library") -> None:
    """Reach the Account sign-in form and authenticate. Leaves the patron
    SIGNED IN on the Account screen (which is sign-out's precondition)."""
    user, pw = _creds(slug)
    d.tap_text("Settings")
    d.tap_text(library)
    if d.has("Sign out"):
        return  # already signed in
    card = d.wait_for("Library Card")
    d.tap_xy(card.cx, card.cy)
    d.type(user)
    pwm = d.wait_for("Password")
    d.tap_xy(pwm.cx, pwm.cy)
    d.type(pw)
    d.tap_text("Sign in")
    d.wait_for("Sign out", timeout=20)


def sign_out(d: Driver, library: str = "A1QA Test Library") -> None:
    d.tap_text("Settings")
    d.tap_text(library)
    if not d.has("Sign out"):
        return
    d.tap_text("Sign out")     # row
    d.tap_text("Sign out")     # confirm dialog (destructive button)
    d.wait_for("Sign in", timeout=15)


def borrow_and_download(d: Driver, title: str, lane: Optional[str] = None) -> None:
    # Phase 2 — declared so recipes referencing it raise a clear "not yet" rather
    # than KeyError, and the dispatcher can report status="phase2".
    raise StagingError("borrow_and_download: Phase 2 (not yet implemented)")


PRIMITIVES = {
    "dismiss_first_launch": lambda d, *a: dismiss_first_launch(d),
    "add_library": lambda d, name: add_library(d, name),
    "sign_in": lambda d, *a: sign_in(d, *(a or ("a1qa",))),
    "sign_out": lambda d, *a: sign_out(d),
    "borrow_download": lambda d, title: borrow_and_download(d, title),
    "goto": lambda d, screen: navigate_to(d, screen),
}


# ===========================================================================
# RECIPES  (data — unit-tested for shape/ordering)
# ===========================================================================
# Each recipe is an ordered list of (primitive, *args). Phase 1 covers the
# journeys reachable without borrow_and_download; Phase 2 fills the rest.
STAGING_RECIPES: dict[str, list[tuple]] = {
    # --- auth ---
    "a1qa-basic-signin": [
        ("dismiss_first_launch",),
        ("add_library", "A1QA Test Library"),
        ("goto", "account_signin"),          # signed OUT, on the sign-in form
    ],
    "a1qa-sign-out": [
        ("dismiss_first_launch",),
        ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"),                 # staging-ORDER: leaves signed-IN
    ],
    "library-picker-stateless": [
        ("dismiss_first_launch",),
        ("add_library", "Palace Bookshelf"),
        ("goto", "catalog"),
    ],
    # --- circulation (anonymous half; borrow halves are Phase 2) ---
    "palace-bookshelf-anonymous": [
        ("dismiss_first_launch",),
        ("add_library", "Palace Bookshelf"),
        ("goto", "settings"),
    ],
    # --- ui-nav (stateless) ---
    "tab-bar-tour": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    "settings-tour-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "settings")],
    # --- catalog (stateless) ---
    "catalog-browse-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    "feed-refresh-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    "book-detail-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
}

# Journeys whose recipe needs Phase 2 (borrow_and_download) — reported as
# "phase2" instead of "no recipe".
PHASE2_JOURNEYS = {
    "read-return-from-mybooks-roundtrip", "book-return-from-mybooks",
    "reader2-back-button", "reader2-bookmark-toggle", "reader2-page-forward",
    "reader2-settings-sheet", "reader2-toc-navigate", "PP-4161-streaming-html-reader",
    "audiobook-download-indicator-stateful", "audiobook-scrubber-drag",
    "audiobook-skip-forward", "audiobook-toc-seek", "search-flow-stateful",
}

# Chairman-blocked (creds/OTP) — recipes pending.
BLOCKED_JOURNEYS = {"danny-saml-signin-init", "icarus-oidc-signin"}


def recipe_for(journey: str) -> Optional[list[tuple]]:
    return STAGING_RECIPES.get(journey)


def staging_status(journey: str) -> str:
    if journey in STAGING_RECIPES:
        return "ready"
    if journey in PHASE2_JOURNEYS:
        return "phase2"
    if journey in BLOCKED_JOURNEYS:
        return "blocked"
    return "unknown"


def stage_for_journey(d: Driver, journey: str) -> None:
    """Run the journey's staging recipe to reach its recording's
    requires.initial_state. Raises StagingError if there is no ready recipe."""
    recipe = STAGING_RECIPES.get(journey)
    if recipe is None:
        raise StagingError(
            f"no staging recipe for '{journey}' (status={staging_status(journey)})"
        )
    for step in recipe:
        prim, args = step[0], step[1:]
        fn = PRIMITIVES.get(prim)
        if fn is None:
            raise StagingError(
                f"unknown staging primitive '{prim}' in recipe for '{journey}'"
            )
        fn(d, *args)
