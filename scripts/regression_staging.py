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
import subprocess
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

    def tap_until(self, tap_label: str, expect_label: str,
                  retries: int = 4, timeout: float = 8.0) -> None:
        """Tap `tap_label` and CONFIRM the resulting screen contains
        `expect_label`; retry the tap if not. Fixes the order-dependence root
        cause: a nav tap (e.g. the Settings tab) racing a heavy screen load (the
        Palace Bookshelf DPLA catalog) lands on nothing, so the next check sees
        the wrong screen and the journey fails purely by timing/position."""
        for _ in range(retries):
            try:
                self.tap_text(tap_label, timeout=timeout)
            except StagingError:
                time.sleep(1.0)
                continue
            if self.find(expect_label):
                return
            time.sleep(1.0)  # settle a still-loading screen, then retry the tap
        if not self.find(expect_label):
            raise StagingError(
                f"tap '{tap_label}' did not reach '{expect_label}' after {retries} tries"
            )

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


_FIRST_LAUNCH_LABELS = ("Allow", "Continue", "OK", "Don't Allow", "Not Now")
_FIRST_LAUNCH_LC = {l.lower() for l in _FIRST_LAUNCH_LABELS}


def _find_exact(d: Driver, label: str, marks: Optional[list[_Mark]] = None) -> Optional[_Mark]:
    """Find a mark whose text EXACTLY equals `label` (case-insensitive). Use for short
    alert-button labels where substring matching is dangerous: find('OK') substring-
    matches 'eBooks'/'Bookshelf' and find('Allow') is fine but 'OK'/'Continue' are
    not — tapping a catalog promo instead of an alert button drove the app into the
    marketing webview."""
    marks = marks if marks is not None else d.observe()
    ll = label.strip().lower()
    return next((m for m in marks if m.text.strip().lower() == ll), None)


def dismiss_first_launch(d: Driver) -> None:
    """Clear clean-install first-launch dialogs (notification-permission, etc.) so
    step-0 text_subset matches the recording. Loops because a fresh install can stack
    more than one alert. EXACT-match the button labels — a substring find('OK') hits
    'eBooks'/'Book' in the catalog feed and taps a promo (opening the marketing
    webview) instead of an alert."""
    for _ in range(3):
        marks = d.observe()
        hit = next((_find_exact(d, l, marks) for l in _FIRST_LAUNCH_LABELS
                    if _find_exact(d, l, marks)), None)
        if hit is None:
            return
        w, h = d._dims
        d._act.tap(hit.cx, hit.cy, w, h, d.udid)
        time.sleep(0.5)


_SAVE_PW_LABELS = ("Not Now", "Save", "Save Password")
# Title tokens that confirm the alert is the Save-Password keychain prompt. OCR
# renders the SpringBoard alert title inconsistently run-to-run ("Save Password?",
# "Save Password", sometimes just the body "...would you like to save this
# password..."), so we match ANY of these as substrings rather than requiring the
# exact "Save Password" mark — that single-string requirement is why the prior
# dismiss missed it intermittently and the modal survived into step-0.
_SAVE_PW_TITLE_TOKENS = ("save password", "save this password", "passwords")


def dismiss_save_password(d: Driver, timeout: float = 20.0, poll: float = 0.6) -> bool:
    """Dismiss the iOS 'Save Password?' keychain alert that pops AFTER a successful
    sign-in. It is a SpringBoard alert that renders OVER the app, covering the My
    Books book rows — so the reader2 replays' step-0 observe saw the modal, not the
    book list (state_contract_mismatch). The alert appears ASYNCHRONOUSLY and can
    land a beat after staging navigates away from the Account screen, so a single
    dismissal at sign-in time misses it; poll for it and tap 'Not Now' (don't save —
    keeps the fixture keychain clean) when it surfaces. Returns True if dismissed.
    No-op (returns False) if it never appears, so it's safe on every signed-in
    recipe.

    RELIABILITY (reader2 fix): the alert can pop LATE and OCR the title variably,
    so (1) we poll the full `timeout` even after a first observe is clean — a clean
    observe just means it hasn't appeared YET, not that it won't; (2) we accept ANY
    Save-Password title token (not the single exact 'Save Password' mark); (3) when
    'Not Now' is present alongside a Save-Password title we tap it and KEEP polling
    a couple more cycles in case a second confirmation alert stacks. A bare 'Not
    Now' with no Save-Password title is NOT tapped (could be the first-launch
    notifications prompt, handled by dismiss_first_launch) — we only act on the
    confirmed keychain alert."""
    deadline = time.time() + timeout
    dismissed = False
    while time.time() < deadline:
        marks = d.observe()
        live = [m.text.lower() for m in marks]
        is_save_pw = any(tok in lt for lt in live for tok in _SAVE_PW_TITLE_TOKENS)
        nn = _find_exact(d, "Not Now", marks)
        if is_save_pw and nn:
            w, h = d._dims
            d._act.tap(nn.cx, nn.cy, w, h, d.udid)
            time.sleep(1.0)
            dismissed = True
            continue                      # re-observe; a stacked alert may remain
        if dismissed and not is_save_pw:
            return True                   # cleared and stayed clear
        time.sleep(poll)
    return dismissed


def add_library(d: Driver, display_name: str) -> None:
    """Idempotently add a library by display name (sims are reused across
    journeys, so this must no-op if already added). Handles both the clean-install
    forced "Add Library" picker (no tab bar yet) and the Settings → + ADD LIBRARY
    path. Hidden/test libraries assumed enabled by sim setup (Settings → Testing →
    Enable Hidden Libraries)."""
    # Forced first-run picker ONLY (chrome-keyed: exact 'Add Library' title, no real
    # Settings 'LIBRARIES' header) — guards against the Settings '+ADD LIBRARY' button
    # substring-matching 'Add Library' and misfiring a library-row tap.
    if _on_forced_picker(d):
        _picker_search_add(d, display_name)
        return
    # tab bar exists: robustly reach Settings (tap_until: the Settings tab tap can
    # race a still-loading catalog), then skip if already added, else add it.
    d.tap_until("Settings", "LIBRARIES")
    if d.has(display_name):
        return
    d.tap_text("ADD LIBRARY")
    d.tap_text(display_name)
    time.sleep(1.5)
    # Adding a REAL library (e.g. Addison Public Library) switches to its catalog and
    # loads async, leaving a transient screen. Settle back onto a stable Settings
    # libraries list with the new library present before returning, so a recipe's
    # downstream replay-precondition observe doesn't catch the transition (the
    # palace-bookshelf-anonymous slot-3 order-dependence).
    try:
        wait_until_ready(d, lib=display_name, timeout=20.0)
    except StagingError:
        pass


def open_account(d: Driver, library: str = "A1QA Test Library") -> None:
    """Open a library's Account screen (the sign-in form when signed out, the
    Sign-out screen when signed in).

    Tapping a library ROW in Settings→Libraries behaves two ways: if the library is
    the ACTIVE one, the row opens its Account directly; if it is NOT active, the row
    pops a 'Would you like to switch to X?' confirm dialog and (on Yes) lands on that
    library's CATALOG — not its Account. So when we hit the switch dialog we confirm
    it, then re-open Settings and tap the row again (now active → opens Account).
    Idempotent: an already-active library opens Account on the first tap; an
    already-signed-in account short-circuits on 'Sign out'."""
    d.tap_until("Settings", "LIBRARIES")
    d.tap_text(library)
    if d.find("Library Card") or d.find("Sign out"):
        return  # row opened Account directly (library was active)
    if d.find("Would you like to switch"):
        d.tap_text("Yes")            # confirm switch → lands on the library's catalog
        time.sleep(1.0)
        d.tap_until("Settings", "LIBRARIES")
        d.tap_text(library)          # now active → opens Account
        if d.find("Sign out"):
            return
    d.wait_for("Library Card", timeout=15)  # the auth-doc sign-in form (signed out)


def download_book(d: Driver, title: str, ready_label: str = "Read",
                  timeout: float = 180.0) -> None:
    """Download an ALREADY-BORROWED book on the A1QA standing fixture so its row
    flips from 'Download' to the open affordance (`ready_label`: 'Read' for EPUB,
    'Listen' for audiobook). The fixture is borrowed server-side (Return is
    present) but a FRESH per-shard sim has not fetched the asset locally — so the
    My Books row shows 'Download', while the reader2/audiobook recordings'
    precondition needs 'Read'/'Listen'. This is a DOWNLOAD of an already-borrowed
    book (it taps the row's Download button, never a Borrow), so it does NOT
    mutate the fixture's loan state — it only materializes the local copy the
    recording was captured against.

    Idempotent: if the row already shows `ready_label` (asset cached from a prior
    journey on a reused sim), returns immediately. Resolves the Download button on
    the SAME row as the title (nearest-by-y) so a multi-book My Books list taps the
    right one. Polls until the asset finishes downloading."""
    navigate_to(d, "my_books")
    dismiss_save_password(d, timeout=4.0)         # post-sign-in keychain alert may linger
    # Already downloaded?
    row = d.find(title)
    if row is not None and d.find(ready_label):
        # confirm the ready affordance is on this title's row (not another book's)
        marks = d.observe()
        rb = next((m for m in marks if m.text.strip().lower() == ready_label.lower()
                   and abs(m.cy - row.cy) < 160), None)
        if rb is not None:
            return
    # Find the Download button on the title's row and tap it.
    deadline = time.time() + timeout
    tapped = False
    while time.time() < deadline:
        marks = d.observe()
        row = next((m for m in marks if title.lower() in m.text.lower()), None)
        if row is None:
            # title not visible yet (list still loading) — settle and retry
            time.sleep(2.0)
            continue
        # ready already? (download completed)
        rb = next((m for m in marks if m.text.strip().lower() == ready_label.lower()
                   and abs(m.cy - row.cy) < 160), None)
        if rb is not None:
            return
        if not tapped:
            dl = next((m for m in marks if m.text.strip().lower() == "download"
                       and abs(m.cy - row.cy) < 160), None)
            if dl is not None:
                w, h = d._dims
                d._act.tap(dl.cx, dl.cy, w, h, d.udid)
                tapped = True
                time.sleep(2.0)
        time.sleep(2.0)
    raise StagingError(
        f"download_book: '{title}' did not reach '{ready_label}' within {timeout:.0f}s")


# The EPUB the reader2 recordings open: 'Advanced Accessibility Tests: Mathematics'
# (the 'Mathematics Test Book' DAISY EPUB). Its My Books row OCRs the distinctive
# 'Mathematics' token; download it so the row flips Download -> Read (the reader2
# precondition token).
_READER2_FIXTURE_TITLE = "Mathematics"


def download_fixture(d: Driver, title: str = _READER2_FIXTURE_TITLE,
                     ready_label: str = "Read") -> None:
    """Recipe primitive: download the reader2 standing-fixture EPUB (Mathematics
    Test Book) so its My Books row shows 'Read' for the recording's step-0
    precondition. Thin wrapper over download_book with the fixture defaults."""
    download_book(d, title, ready_label)


def navigate_to(d: Driver, screen: str) -> None:
    """Drive to a named screen. screen ∈ catalog | my_books | holds | settings |
    account_signin | account_signedin (the last two open the A1QA Account)."""
    if screen == "settings":
        d.tap_until("Settings", "LIBRARIES")
        return
    tab = {"catalog": "Catalog", "my_books": "My Books", "holds": "Holds"}.get(screen)
    if tab:
        d.tap_text(tab)
        return
    if screen in ("account_signin", "account_signedin"):
        open_account(d, "A1QA Test Library")
        return
    raise StagingError(f"unknown screen '{screen}'")


def relaunch_app(udid: str, app_bundle_id: str, settle: float = 3.0) -> None:
    """Fresh terminate+launch so each journey stages from a DETERMINISTIC
    app-open baseline — the order-independence fix. Without this, staging runs on
    whatever residual screen the previous journey left (mid-flow modal, a foreign
    catalog, etc.), so a journey could pass or fail purely by its position in the
    run (the a1qa-basic-signin PASS-slot1 / FAIL-slot2 bug). simctl terminate is a
    no-op if the app is not running."""
    subprocess.run(["xcrun", "simctl", "terminate", udid, app_bundle_id],
                   capture_output=True)
    time.sleep(1.0)
    subprocess.run(["xcrun", "simctl", "launch", udid, app_bundle_id],
                   capture_output=True)
    time.sleep(settle)


def switch_library(d: Driver, name: str) -> None:
    """Make `name` the ACTIVE library (so a 'goto catalog' lands on ITS catalog,
    not whatever library happens to be active). Uses the top-left library
    switcher on the Catalog. Needed for any journey whose precondition is a
    SPECIFIC library's catalog (e.g. library-picker-stateless = Palace Bookshelf
    DPLA feed). Idempotent: if already active, the picker re-selects it harmlessly."""
    d.tap_text("Catalog")
    # the library switcher is the top-left icon on the Catalog nav bar.
    d.tap_xy(110, 235)
    time.sleep(0.8)
    d.tap_text(name)
    time.sleep(1.5)


def _clear_field(d: Driver, taps: int = 40) -> None:
    """Clear the focused text field deterministically. A reused or half-staged
    field can carry residual text (the password-typed-into-the-username collision
    observed when the Password tap raced the keyboard layout shift), so every
    credential type starts from empty. Spam BOTH backspace (deletes left of caret)
    and delete (deletes right) so the field empties regardless of caret position;
    no 'end'/'home' key exists in simdrive's key map."""
    for _ in range(taps):
        try:
            d._act.press_key("backspace", d.udid)
            d._act.press_key("delete", d.udid)
        except Exception:
            break
    time.sleep(0.3)


def sign_in(d: Driver, slug: str = "a1qa", library: str = "A1QA Test Library") -> None:
    """Reach the Account sign-in form and authenticate. Leaves the patron
    SIGNED IN on the Account screen (which is sign-out's precondition).

    Hardened against the Password-field focus race: after the username is typed
    the form re-lays-out (keyboard up + barcode validation), so the previously
    resolved 'Password' mark coords go stale and a tap can land back on the
    username field — typing the password INTO the username field, leaving 'Sign
    in' disabled (observed: '<user><pw>' concatenated in the card field, password
    empty, button greyed, then a step-0 precondition halt downstream). Fix: clear
    each field before typing, RE-RESOLVE the Password mark AFTER the username is
    committed, and verify 'Sign in' enables before submitting — retry the whole
    credential entry once if it didn't take."""
    user, pw = _creds(slug)
    open_account(d, library)
    if d.has("Sign out"):
        return  # already signed in

    for attempt in range(2):
        card = d.wait_for("Library Card")
        d.tap_xy(card.cx, card.cy)
        _clear_field(d)                       # drop any residual / prior-attempt text
        d.type(user)
        time.sleep(0.6)                       # let barcode validation + relayout settle
        # RE-RESOLVE Password AFTER the username committed — its coords shift once the
        # field is filled and the keyboard is up; using the stale pre-type mark is the
        # focus-race root cause.
        pwm = d.wait_for("Password")
        d.tap_xy(pwm.cx, pwm.cy)
        _clear_field(d)                       # ensure we're in an empty Password field
        d.type(pw)
        time.sleep(0.4)
        # The 'Sign in' control is disabled until BOTH fields are populated; its
        # presence as a tappable mark is our deterministic "credentials took" gate.
        if d.find("Sign in"):
            d.tap_text("Sign in")
            # iOS pops a "Save Password?" keychain alert AFTER a successful sign-in.
            # It covers the Account/My Books screen, so 'Sign out' never surfaces.
            # Poll-and-dismiss it (it can land a beat after submit). Recipes ALSO
            # call dismiss_save_password after navigation, since the alert can pop
            # late, once staging has already moved to My Books.
            time.sleep(1.5)
            dismiss_save_password(d)
            try:
                d.wait_for("Sign out", timeout=20)
                return
            except StagingError:
                pass  # fall through to retry
        # entry didn't take (focus race / transient) — retry once from a clean form.
        time.sleep(1.0)
    # Final attempt's outcome gate — raise a clear error if still not signed in.
    dismiss_save_password(d)
    d.wait_for("Sign out", timeout=20)


def tap_dialog_button(d: Driver, button_text: str, anchor_text: str = "Cancel",
                      max_dy: int = 90) -> None:
    """Tap a confirm-dialog button by name, disambiguated from a same-named
    element elsewhere on screen (e.g. the Account "Sign out" ROW vs the confirm
    dialog "Sign out" BUTTON). Resolves the target as the matching mark on the
    SAME row as the dialog's anchor (default "Cancel"). This is the duplicate-
    text confirm-dialog fix — a plain find() grabs the topmost match (the row),
    not the button."""
    anchor = d.wait_for(anchor_text)
    marks = d.observe()
    bl = button_text.lower()
    cands = [m for m in marks if m.text.strip().lower() == bl and abs(m.cy - anchor.cy) < max_dy]
    if not cands:
        cands = [m for m in marks if bl in m.text.lower() and abs(m.cy - anchor.cy) < max_dy]
    if not cands:
        raise StagingError(f"dialog button '{button_text}' not found near '{anchor_text}'")
    btn = cands[0]
    w, h = d._dims
    d._act.tap(btn.cx, btn.cy, w, h, d.udid)
    time.sleep(d.settle)


def sign_out(d: Driver, library: str = "A1QA Test Library") -> None:
    open_account(d, library)
    if not d.has("Sign out"):
        return
    d.tap_text("Sign out")                    # row -> opens confirm dialog
    tap_dialog_button(d, "Sign out", "Cancel")  # the dialog button, not the row
    d.wait_for("Sign in", timeout=15)


def borrow_and_download(d: Driver, title: str, lane: Optional[str] = None) -> None:
    # Phase 2 — declared so recipes referencing it raise a clear "not yet" rather
    # than KeyError, and the dispatcher can report status="phase2".
    raise StagingError("borrow_and_download: Phase 2 (not yet implemented)")


PRIMITIVES = {
    "dismiss_first_launch": lambda d, *a: dismiss_first_launch(d),
    "add_library": lambda d, name: add_library(d, name),
    "switch_library": lambda d, name: switch_library(d, name),
    "sign_in": lambda d, *a: sign_in(d, *(a or ("a1qa",))),
    "dismiss_save_password": lambda d, *a: dismiss_save_password(d),
    "download_fixture": lambda d, *a: download_fixture(d),
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
        ("sign_out",),                       # converge to SIGNED-OUT (idempotent)
        ("goto", "account_signin"),          # land on the sign-in form
    ],
    "a1qa-sign-out": [
        ("dismiss_first_launch",),
        ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"),                 # staging-ORDER: leaves signed-IN
    ],
    "library-picker-stateless": [
        ("dismiss_first_launch",),
        ("add_library", "Palace Bookshelf"),
        ("switch_library", "Palace Bookshelf"),   # make it ACTIVE so catalog = its DPLA feed
        ("goto", "catalog"),
    ],
    # --- circulation (anonymous half; borrow halves are Phase 2) ---
    "palace-bookshelf-anonymous": [
        ("dismiss_first_launch",),
        ("add_library", "A1QA Test Library"),       # initial_state Settings shows all three libs:
        ("add_library", "Palace Bookshelf"),        #   Palace Bookshelf + A1QA + Addison Public Library
        ("add_library", "Addison Public Library"),  # the recording's 'PUBLIC LIBRARY' token is the
        ("goto", "settings"),                       #   Addison logo (confirmed from 001_pre.png)
    ],
    # --- ui-nav (stateless) ---
    "tab-bar-tour": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    # settings-tour was RECORDED from the Catalog (step-0 taps the Settings TAB from
    # the Palace Bookshelf catalog), so stage to CATALOG — not Settings. Routing to
    # 'settings' put the app on Settings while the recording's step-0 expects Catalog
    # chrome, halting 0/4. The recording's over-specified catalog content tokens
    # (DPLA Publications / More...) are relaxed to stable tab-bar chrome (see recording).
    "settings-tour-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    # --- catalog (stateless) ---
    "catalog-browse-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    "feed-refresh-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],
    "book-detail-stateless": [("dismiss_first_launch",), ("add_library", "Palace Bookshelf"), ("goto", "catalog")],

    # --- reading (Reader2, STANDING-FIXTURE) ---
    # The Mathematics/Extended-Description Test Book EPUBs are PRE-BORROWED on the
    # A1QA standing fixture (read-only — never returned by the campaign), so these
    # journeys need SIGN-IN ONLY, not a borrow. Staging converges to the signed-in
    # My Books list (the recording's start screen: each book row shows Read/Return);
    # the recording's step-0 then taps Read on the Mathematics row. (Was mis-routed
    # through borrow_and_download via PHASE2_JOURNEYS → clean-skipped every run.)
    # Recipe order matters: sign_in already dismisses the Save-Password alert, but we
    # dismiss again AFTER navigating to My Books (it can pop late, once we're already
    # on the list), THEN download_fixture taps the fixture's 'Download' and waits for
    # 'Read' so step-0's downloaded contract matches and step-1 can open the reader.
    "reader2-back-button": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",),
    ],
    "reader2-bookmark-toggle": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",),
    ],
    "reader2-page-forward": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",),
    ],
    "reader2-settings-sheet": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",),
    ],
    "reader2-toc-navigate": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",),
    ],

    # --- audiobook (STANDING-FIXTURE) ---
    # Animal Farm audiobook is PRE-BORROWED + downloaded on the A1QA standing
    # fixture → sign-in only. Start screen is the signed-in My Books list (Animal
    # Farm row shows Listen/Return); the recording's step-0 taps Listen.
    "audiobook-skip-forward": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
    ],
    "audiobook-toc-seek": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
    ],
    "audiobook-scrubber-drag": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
    ],
}

# Journeys whose recipe GENUINELY needs Phase 2 (borrow_and_download / a clean
# registry) — reported as "phase2" and clean-skipped until the foundation's
# borrow_and_download lands. Do NOT fake these:
#   read-return / book-return roundtrips  — borrow→read→RETURN the book (mutates
#       the fixture; can't run against the read-only standing fixture).
#   audiobook-download-indicator-stateful — asserts the in-flight DOWNLOAD UI, so
#       the book must NOT be pre-downloaded (standing fixture is already downloaded).
#   PP-4161-streaming-html-reader         — anonymous search→Borrow→Read; requires
#       a .unregistered registry (uninstall/reinstall), NOT a sign-in.
#   search-flow-stateful                  — no recording exists yet.
# The reader2 (5) + audiobook skip/toc/scrubber (3) journeys moved OUT of here into
# STAGING_RECIPES: they use the A1QA STANDING fixture (pre-borrowed, read-only) and
# need SIGN-IN ONLY — see the "reading"/"audiobook" recipes above.
PHASE2_JOURNEYS = {
    "read-return-from-mybooks-roundtrip", "book-return-from-mybooks",
    "PP-4161-streaming-html-reader",
    "audiobook-download-indicator-stateful",
    "search-flow-stateful",
}

# Chairman-blocked (creds/OTP) — recipes pending.
BLOCKED_JOURNEYS = {"danny-saml-signin-init", "icarus-oidc-signin"}

# Journeys DEMOTED from the determinism-gate must-pass set because their recording
# precondition is structurally over-specified / irreducibly variable (multi-library-
# logo + full scrolled pages, or exact catalog content/order). They STILL RUN and
# STILL emit a finding — demote != hide — but tagged so triage can distinguish a
# fragile-precondition flake from a genuine regression, and so a real failure here is
# not dismissed as "just the flake". Each is queued for content-independent re-record.
#   library-picker-stateless     — exact Palace Bookshelf DPLA catalog titles + order.
#   palace-bookshelf-anonymous   — 3 library logos + full scrolled Settings page; the
#       precondition-poll-settle helped 1/3 but timed out >15s 2/3 (irreducible). Likely
#       the only anonymous-DPLA-access coverage → NEAR-TERM re-record.
KNOWN_FRAGILE_PRECONDITIONS = {"library-picker-stateless", "palace-bookshelf-anonymous"}


def is_known_fragile(journey: str) -> bool:
    """True if `journey` is demoted from the must-pass gate for an over-specified /
    irreducibly-variable precondition. Callers TAG (never suppress) its finding."""
    return journey in KNOWN_FRAGILE_PRECONDITIONS


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


# ===========================================================================
# SETTLE GATE + PROVISION  (canonical readiness primitive — the #21 cold-start fix
# AND the per-cell entrypoint the campaign driver calls)
# ===========================================================================
def wait_until_ready(d: Driver, lib: str = "A1QA Test Library",
                     timeout: float = 60.0, poll: float = 2.0) -> float:
    """Canonical settle gate. Poll until the Settings→Libraries screen is rendered
    AND the test library is present-or-addable; return the elapsed seconds.

    This closes the cold-start window that produced the v4/v5/v6 uniform-fail
    ('timeout waiting for ADD LIBRARY'): right after terminate+launch the app is
    still restoring its last screen / refetching the QA registry, so staging that
    navigates against a blind fixed sleep lands on a half-rendered screen. Polling
    until the screen is real makes staging independent of launch timing and OCR
    mid-load splits. Idempotent — safe after every cold launch and inside
    enable_hidden_libraries. Raises StagingError on timeout.

    Ready ⇔ a 'LIBRARIES' header is on screen and either the library is already
    added (`lib` visible) or the add affordance is present. The button OCRs as
    '+ADD LIBRARY' (the '+' glyph merges in), so we substring-match 'add library'."""
    start = time.time()
    deadline = start + timeout
    last = "no-observe"
    while time.time() < deadline:
        marks = d.observe()
        low = [m.text.strip().lower() for m in marks]
        # a first-launch alert can pop mid-settle (notification prompt) and block
        # everything behind it — clear it before assessing readiness.
        if any(l.lower() in low for l in _FIRST_LAUNCH_LABELS):
            dismiss_first_launch(d)
            marks = d.observe()
            low = [m.text.strip().lower() for m in marks]
        on_libs = any(t == "libraries" for t in low)
        if not on_libs:
            # tab bar up but on another tab → reach Settings; else let the launch
            # transition finish and re-observe next poll.
            st = d.find("Settings", marks)
            if st:
                w, h = d._dims
                d._act.tap(st.cx, st.cy, w, h, d.udid)
                time.sleep(d.settle)
                marks = d.observe()
                low = [m.text.strip().lower() for m in marks]
                on_libs = any(t == "libraries" for t in low)
        has_lib = any(lib.lower() in t for t in low)
        has_add = any("add library" in t for t in low)
        last = f"libraries={on_libs} {lib!r}={has_lib} add_library={has_add}"
        if on_libs and (has_lib or has_add):
            return time.time() - start
        time.sleep(poll)
    raise StagingError(f"settle-gate timeout after {timeout:.0f}s ({last})")


def await_precondition(d: Driver, tokens: list[str], timeout: float = 15.0,
                       poll: float = 1.0) -> float:
    """Deterministic pre-replay SETTLE for the fresh-add transient. Poll until ALL
    `tokens` are present on screen (case-sensitive substring — exactly the recorder's
    precondition check), or `timeout`. Adding a REAL library loads its catalog and
    redraws, so a replay whose precondition observes immediately after staging can
    catch the screen MID-LOAD and 0-execute (the palace-bookshelf-anonymous slot-3
    flake — 1/3 in stability, tokens provably present once settled). Polling until the
    recording's OWN tokens render removes that false-red WITHOUT under-specifying (all
    tokens kept) and WITHOUT masking regressions: a genuinely wrong screen never
    surfaces the tokens → timeout → the caller still runs the replay → it reports the
    real precondition verdict (RED). Returns elapsed seconds; never raises."""
    if not tokens:
        return 0.0
    start = time.time()
    deadline = start + timeout
    while time.time() < deadline:
        texts = [m.text for m in d.observe()]
        if all(any(tok in t for t in texts) for tok in tokens):
            return time.time() - start
        time.sleep(poll)
    return time.time() - start


def enable_hidden_libraries(udid: str, app: str) -> None:
    """Ensure hidden/test libraries are reachable by writing NYPLUseBetaLibrariesKey
    via simctl (must precede launch — the app reads it at startup). Empirically this
    defaults-write alone surfaces the test library in the picker (verified: A1QA
    appears with the key set, no in-app toggle needed). The in-app Settings→Testing
    toggle was investigated but is fragile (below-fold, and toggling an already-on
    switch on a still-loading Settings screen corrupted provision); the defaults-write
    is the reliable mechanism and is done at provision start before relaunch."""
    for key in ("NYPLUseBetaLibrariesKey", "showDeveloperSettings"):
        subprocess.run(["xcrun", "simctl", "spawn", udid, "defaults", "write", app,
                        key, "-bool", "true"], capture_output=True)


def switch_to_active(d: Driver, library: str = "A1QA Test Library") -> None:
    """Make `library` the ACTIVE library so its Account/catalog is reachable
    directly. On a fresh cell the just-added test library is NOT active, so tapping
    its row in Settings→Libraries pops 'Would you like to switch to X?' — confirm it.
    Idempotent: if already active, the row opens Account instead of the dialog and we
    leave it (the trailing settle returns to a known screen). Folded into provision
    so every cell inherits an active A1QA without per-journey patching (recipes that
    need a DIFFERENT active library, e.g. library-picker → Palace Bookshelf, override
    via switch_library)."""
    d.tap_until("Settings", "LIBRARIES")
    d.tap_text(library)
    if d.find("Would you like to switch"):
        d.tap_text("Yes")            # confirm → library becomes active
        time.sleep(1.0)


def _on_real_settings(d: Driver, marks: Optional[list[_Mark]] = None) -> bool:
    """True ONLY on the actual Settings→Libraries screen — keyed on the EXACT
    'LIBRARIES' section header (all-caps), never a substring of 'libraries'. Two
    false-positives this guards against: (1) the fresh-install marketing catalog
    contains 'libraries' in prose; (2) the forced picker's 'Add Library' TITLE
    uppercases to contain 'ADD LIBRARY' — so an 'ADD LIBRARY' substring check would
    mistake the onboarding picker for Settings (which made onboarding a no-op and
    timed out provision). The 'LIBRARIES' header exists only on real Settings; the
    forced picker has 'Add Library' but no 'LIBRARIES' header."""
    marks = marks if marks is not None else d.observe()
    return any(m.text.strip().upper() == "LIBRARIES" for m in marks)


def _on_forced_picker(d: Driver, marks: Optional[list[_Mark]] = None) -> bool:
    """True on the fresh-install forced 'Add Library' picker: the exact 'Add Library'
    title is present AND we are not on the real Settings screen."""
    marks = marks if marks is not None else d.observe()
    title = any(m.text.strip() == "Add Library" for m in marks)
    return title and not _on_real_settings(d, marks)


def _picker_search_add(d: Driver, lib: str, timeout: float = 45.0) -> None:
    """In the forced first-run picker, search for `lib` and tap it to add + exit. The
    registry list is long and freshly fetched, so the library may be below the fold or
    not yet present — search by a distinctive prefix and poll until it surfaces
    (registry-wait). Raises StagingError if it never appears."""
    w, h = d._dims
    marks = d.observe()
    # focus the picker's search field: the 'Q' magnifier (exact), else below the title.
    q = _find_exact(d, "Q", marks)
    title = next((m for m in marks if m.text.strip() == "Add Library"), None)
    if q is not None:
        d.tap_xy(q.cx, q.cy)
    elif title is not None:
        d.tap_xy(title.cx, title.cy + 90)
    else:
        d.tap_xy(int(w * 0.5), int(h * 0.105))
    time.sleep(0.4)
    d.type(lib.split(" ")[0])                # distinctive prefix: 'A1QA' / 'Addison'
    deadline = time.time() + timeout
    while time.time() < deadline:
        m = d.find(lib)
        if m:
            d._act.tap(m.cx, m.cy, w, h, d.udid)
            time.sleep(2.0)                  # add + exit-picker transition
            return
        time.sleep(1.0)
    raise StagingError(f"forced-picker: '{lib}' never surfaced (registry not loaded?) in {timeout:.0f}s")


def onboard_fresh_install(d: Driver, lib: str = "A1QA Test Library",
                          timeout: float = 45.0) -> None:
    """Cross a FRESH install's onboarding into a usable app state. The driver's
    per-cell build-install leaves the app on: notification-permission alert →
    (the Palace Bookshelf catalog with marketing promo lanes) → the forced 'Add
    Library' picker. Clear the (persistent, possibly stacked) alerts, then if the
    forced picker is up, search-add the test library to exit onboarding. No-op once
    onboarded (already on Settings/catalog with a library). All state detection is
    chrome-keyed (exact tokens), never substring, so the marketing 'libraries' prose
    can't false-positive."""
    dismiss_first_launch(d)   # exact-match alert dismissal (no substring promo taps)
    if _on_forced_picker(d):
        _picker_search_add(d, lib, timeout=timeout)


def provision(udid: str, app: str = "org.thepalaceproject.palace",
              lib: str = "A1QA Test Library", timeout: float = 60.0) -> float:
    """Per-cell provisioning entrypoint (idempotent), called by the campaign driver
    AFTER build-install and BEFORE spawning the area-worker:
        python3 scripts/regression_staging.py provision --sim <udid>
    Self-contained readiness chain: enable hidden/test libraries (defaults-write) →
    relaunch so the key takes effect → cross fresh-install onboarding (dismiss alert +
    add the test library via the forced picker) → settle → switch the test library
    ACTIVE → settle. Returns the final settle seconds. This is the ONE provision
    primitive w-mutex calls, so every cell — including the FRESH clones the driver's
    build-install produces — inherits hidden-libs + an added+active test library + a
    rendered libraries screen."""
    enable_hidden_libraries(udid, app)               # defaults-write (pre-launch)
    subprocess.run(["xcrun", "simctl", "terminate", udid, app], capture_output=True)
    time.sleep(1.0)
    subprocess.run(["xcrun", "simctl", "launch", udid, app], capture_output=True)
    time.sleep(3.0)
    d = Driver(udid, app)
    onboard_fresh_install(d, lib=lib, timeout=timeout)   # dismiss alert + add A1QA
    wait_until_ready(d, lib=lib, timeout=timeout)        # settle on Settings/LIBRARIES
    switch_to_active(d, lib)                             # make A1QA active
    return wait_until_ready(d, lib=lib, timeout=timeout) # final settle


def _main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="regression_staging.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, helptext in (("provision", "enable hidden libraries + settle (idempotent)"),
                           ("settle", "wait until the libraries screen is ready (no toggle)")):
        sp = sub.add_parser(name, help=helptext)
        sp.add_argument("--sim", required=True, help="simulator UDID")
        sp.add_argument("--app", default="org.thepalaceproject.palace")
        sp.add_argument("--lib", default="A1QA Test Library")
        sp.add_argument("--timeout", type=float, default=60.0)
    a = p.parse_args(argv)
    try:
        if a.cmd == "provision":
            secs = provision(a.sim, a.app, a.lib, a.timeout)
        else:
            secs = wait_until_ready(Driver(a.sim, a.app), lib=a.lib, timeout=a.timeout)
        print(f"[{a.cmd}] ready in {secs:.1f}s")
        return 0
    except StagingError as e:
        print(f"[{a.cmd}] NOT READY: {e}", file=__import__("sys").stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(_main(__import__("sys").argv[1:]))
