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
    download_fixture/clear_sync_position (reader2 standing-fixture),
    borrow_and_download/return_book (returnable open-access loans), navigate_to.
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

    # The book card OCRs the title as MULTIPLE marks (the wrapped title line, e.g.
    # 'Tests: Mathematics', AND the cover caption 'Mathematics Test Book') at
    # different y-positions, and the action button ('Read'/'Download') sits between
    # them — so anchoring to the FIRST title mark and a tight 160px band missed the
    # button (the false 'did not reach Read' STAGE-ERR). Anchor to the WHOLE card:
    # take the y-span of every title-token mark, widen it by a card pad, and look
    # for the action button anywhere in that span. A My Books card is < ~360px tall.
    CARD_PAD = 200

    def _title_rows(marks):
        return [m for m in marks if title.lower() in m.text.lower()]

    def _btn_in_card(marks, label):
        rows = _title_rows(marks)
        if not rows:
            return None
        ys = [m.cy for m in rows]
        lo, hi = min(ys) - CARD_PAD, max(ys) + CARD_PAD
        return next((m for m in marks
                     if m.text.strip().lower() == label.lower() and lo <= m.cy <= hi), None)

    # Already downloaded? (asset cached from a prior journey / pre-seeded fixture)
    if _btn_in_card(d.observe(), ready_label) is not None:
        return

    deadline = time.time() + timeout
    tapped = False
    while time.time() < deadline:
        marks = d.observe()
        if not _title_rows(marks):
            time.sleep(2.0)                        # list still loading — settle, retry
            continue
        if _btn_in_card(marks, ready_label) is not None:
            return                                 # download completed
        if not tapped:
            dl = _btn_in_card(marks, "Download")
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


def clear_sync_position(d: Driver, title: str = _READER2_FIXTURE_TITLE) -> bool:
    """Pre-clear the reader's 'Sync Reading Position' (Stay / Move) dialog so the
    reader2 REPLAY opens the book clean.

    The A1QA fixture carries a SERVER-SIDE reading position, so the FIRST time the
    book opens after a fresh sign-in the reader pops 'Sync Reading Position — Do you
    want to move to the page on which you left off?' (Stay / Move). The reader2
    recordings tap 'Read' (step-1) then immediately swipe/tap (step-2); the dialog
    renders OVER the reader, so the recorded step fires into the modal and the reader
    'opens then stalls' — the failure the Chairman watched (and the real cause behind
    the earlier 'demote reader2' / 'device-suffix' red herrings). simdrive's replay
    has no interstitial hook, so we dismiss it HERE in staging: open the fixture once,
    tap 'Stay' (deterministic — keep the local position, no surprise re-pagination),
    which reconciles the position so the replay's open no longer prompts (verified
    live: the dialog does not reappear on a second open, even across an app relaunch).
    Then return to My Books for the recording's step-0 start screen.

    Idempotent + safe: on a reused sim where a prior journey already reconciled the
    position, the book just opens with no dialog and we back out. Returns True iff a
    sync dialog was actually dismissed."""
    CARD_PAD = 200
    navigate_to(d, "my_books")
    dismiss_save_password(d, timeout=2.0)

    # Open the fixture from its My Books row — card-scoped 'Read' anchor (same logic
    # as download_book) so a multi-book list opens the RIGHT book's reader.
    marks = d.observe()
    rows = [m for m in marks if title.lower() in m.text.lower()]
    if not rows:
        return False                      # fixture row absent — nothing to pre-clear
    ys = [m.cy for m in rows]
    lo, hi = min(ys) - CARD_PAD, max(ys) + CARD_PAD
    read_btn = next((m for m in marks
                     if m.text.strip().lower() == "read" and lo <= m.cy <= hi), None)
    if read_btn is None:
        return False                      # not in a downloaded ('Read') state
    w, h = d._dims
    d._act.tap(read_btn.cx, read_btn.cy, w, h, d.udid)
    time.sleep(3.0)

    # Dismiss the sync dialog if/when it renders (it can land a beat after the open).
    dismissed = False
    deadline = time.time() + 12.0
    while time.time() < deadline:
        m2 = d.observe()
        stay = _find_exact(d, "Stay", m2)
        is_sync = (any("sync reading position" in x.text.lower() for x in m2)
                   or _find_exact(d, "Move", m2) is not None)
        if stay and is_sync:
            d._act.tap(stay.cx, stay.cy, w, h, d.udid)
            time.sleep(1.5)
            dismissed = True
            break
        # reader content rendered with no dialog (already reconciled) -> done
        if any("page" in x.text.lower() and " of " in x.text.lower() for x in m2):
            break
        time.sleep(0.6)

    # Exit the reader back to My Books for the recording's step-0 contract. Reader
    # chrome auto-hides; tap CENTER to reveal it (center zone toggles chrome; edges
    # page), then the top-left back affordance. Fall back to a clean relaunch if the
    # back nav doesn't land on My Books.
    d._act.tap(w // 2, h // 2, w, h, d.udid)                  # toggle reader chrome
    time.sleep(1.0)
    d._act.tap(int(w * 0.06), int(h * 0.09), w, h, d.udid)    # back chevron (top-left)
    time.sleep(2.0)
    if not d.find("My Books"):
        relaunch_app(d.udid, d.app)
    navigate_to(d, "my_books")
    return dismissed


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
        # Generous waits: under a full-matrix fan-out (many shards on one machine) the
        # Account sign-in form can take >12s to render/relayout, which surfaced as a
        # false "timeout waiting for 'Password'" staging error (harness-contention
        # flake #15, not a product bug). 30s absorbs the contention without masking a
        # genuinely-broken form (a real break never renders the field at all).
        card = d.wait_for("Library Card", timeout=30)
        d.tap_xy(card.cx, card.cy)
        _clear_field(d)                       # drop any residual / prior-attempt text
        d.type(user)
        time.sleep(0.6)                       # let barcode validation + relayout settle
        # RE-RESOLVE Password AFTER the username committed — its coords shift once the
        # field is filled and the keyboard is up; using the stale pre-type mark is the
        # focus-race root cause.
        pwm = d.wait_for("Password", timeout=30)
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


def _open_book_detail(d: Driver, title: str) -> None:
    """Reach a book's detail screen (where Borrow/Get/Read/Return live) via SEARCH —
    deterministic where scrolling the catalog is not (the DPLA/OPDS feed order and
    cover-OCR vary per launch, so a specific book is not reliably tappable in the raw
    feed). Open Catalog → search → type a distinctive title query → tap the matching
    result. No-op if already on a detail screen."""
    if d.find("Borrow") or d.find("Read") or d.find("Listen") or d.find("Return"):
        return
    marks = d.observe()
    cats = sorted([m for m in marks if m.text.strip() == "Catalog"], key=lambda m: -m.cy)
    w, h = d._dims
    if cats:  # the bottom-most "Catalog" is the tab
        d._act.tap(cats[0].cx, cats[0].cy, w, h, d.udid)
        time.sleep(1.2)
    # open the catalog search (top-right magnifier), then filter by a distinctive query
    q = _find_exact(d, "Q") or d.find("Search")
    if q is not None:
        d.tap_xy(q.cx, q.cy)
    else:
        d.tap_xy(int(w * 0.92), int(h * 0.08))   # top-right magnifier fallback
    time.sleep(0.8)
    query = title.split(":")[0].strip()           # drop subtitle for a cleaner match
    d.type(query)
    time.sleep(1.5)
    d.tap_text(title)                              # tap the filtered result → detail
    time.sleep(1.5)


def borrow_and_download(d: Driver, title: str, lane: Optional[str] = None,
                        timeout: float = 90.0) -> None:
    """Borrow + download a book to the DOWNLOADED state (the precondition for the
    reader/audiobook/return journeys). Flow (mapped live): Catalog → tap book →
    Borrow/Get → poll until Read/Listen appears (download complete). Idempotent: a
    book already showing Read/Listen is left as-is. Raises StagingError on timeout
    (download never completed) so a Phase-2 recipe gates honestly rather than
    proceeding against a not-yet-downloaded book.

    Use a RETURNABLE open-access book (DPLA / Palace Bookshelf) for round-trip
    return journeys — NEVER the A1QA standing fixtures, which are read-only and must
    never be returned."""
    _open_book_detail(d, title)
    if d.find("Read") or d.find("Listen"):
        return                                   # already borrowed+downloaded
    if d.find("Borrow"):
        d.tap_text("Borrow")
    elif d.find("Get"):
        d.tap_text("Get")
    else:
        raise StagingError(f"borrow_and_download: no Borrow/Get on '{title}' detail")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if d.find("Read") or d.find("Listen"):
            return                               # download complete
        time.sleep(2.0)
    raise StagingError(f"borrow_and_download: '{title}' did not reach Read/Listen in {timeout:.0f}s")


def return_book(d: Driver, title: Optional[str] = None) -> None:
    """Return a borrowed loan — the idempotent RESET so a reused sim re-borrows
    cleanly. Flow (mapped LIVE on build 479): My Books row or book detail → Return →
    confirm dialog 'Are you sure you want to return "X"?' Cancel | Return → tap the
    dialog's Return. No-op if the book isn't currently borrowed.

    ONLY for returnable open-access loans — never an A1QA standing fixture."""
    if title is not None:
        _open_book_detail(d, title)
    if not d.find("Return"):
        return                                   # not borrowed
    d.tap_text("Return")                          # the row/detail Return → confirm dialog
    # The confirm button is literally 'Return' (NOT 'Return Loan'/'Yes', as an earlier
    # guess assumed); disambiguate it from the row's Return via the dialog's Cancel anchor.
    tap_dialog_button(d, "Return", "Cancel")
    try:
        d.wait_for("Borrow", timeout=30)          # detail path: Borrow reappears
    except StagingError:
        pass                                      # My-Books path: the row just leaves the list


def borrow_first(d: Driver, timeout: float = 90.0, max_try: int = 6) -> None:
    """Borrow the first AVAILABLE book from the active library's catalog and leave it
    in My Books as a genuine loan — book-AGNOSTIC and robust to DPLA catalog rotation
    (specific titles come and go). For the circulation round-trip journeys, which
    verify the GENERAL book-management functionality (a borrowed book can be removed
    from My Books), not a specific title or loan-type.

    BORROW vs HOLD (load-bearing distinction): an UNAVAILABLE book's detail offers
    'Reserve' / 'Place Hold' — tapping that places a HOLD, which lands in the HOLDS
    tab (never My Books) and never reaches a readable state. We must stage a real
    BORROW, so we SKIP any 'Reserve'/'Place Hold' book and only act on 'Borrow', then
    confirm the result reached Read/Listen (the borrowed-and-downloaded state; a hold
    would instead show 'Reserved'/'On Hold' and never become readable). Walks the
    first lanes' covers; lands on My Books with one borrowed book. Raises StagingError
    if no AVAILABLE (borrowable, not hold-only) book is found (honest gate)."""
    w, h = None, None
    spots = [(0.16, 0.30), (0.40, 0.30), (0.64, 0.30), (0.88, 0.30),
             (0.16, 0.55), (0.40, 0.55)]
    for fx, fy in spots[:max_try]:
        navigate_to(d, "catalog")                 # reset to the feed top for stable coords
        time.sleep(1.2)
        if w is None:
            w, h = d._dims
        d._act.tap(int(w * fx), int(h * fy), w, h, d.udid)   # open a cover's detail
        time.sleep(2.0)
        # HOLD-vs-BORROW: never place a hold — only borrow an AVAILABLE title.
        if (d.find("Reserve") or d.find("Place Hold")) and not d.find("Borrow"):
            continue                              # unavailable → would be a HOLD; skip
        if not d.find("Borrow"):                  # gap / already-owned / non-book → next
            continue
        d.tap_text("Borrow")
        deadline = time.time() + timeout
        while time.time() < deadline and not (d.find("Read") or d.find("Listen")):
            if d.find("Reserved") or d.find("On Hold") or d.find("Remove Hold"):
                break                             # landed as a HOLD, not a loan → try next
            time.sleep(2.0)
        if d.find("Back"):                        # leave the detail → tab bar visible
            d.tap_text("Back")
        navigate_to(d, "my_books")
        time.sleep(2.0)
        if d.find("Read") or d.find("Listen"):    # confirm BORROWED (in My Books), not a hold
            return
        # not a readable loan (hold/elsewhere) — clean up if removable, then try next
        if d.find("Remove"):
            d.tap_text("Remove")
            time.sleep(1.5)
    raise StagingError(f"borrow_first: no AVAILABLE (borrowable, non-hold) book in {max_try} covers")


_SEARCH_CHROME_WORDS = {
    "catalog", "settings", "holds", "books", "palace", "bookshelf", "borrow",
    "reserve", "more", "search", "cancel", "title", "read", "listen", "return",
    "remove", "library", "account", "preview", "sample", "description",
}


def _pick_title_word(marks: list[_Mark]) -> Optional[str]:
    """Pick a distinctive, searchable word from a book title CURRENTLY present in the
    catalog feed — the self-validating search target (no pinned title; DPLA content
    rotates). Prefers the longest alphabetic word (>=6 chars, fewer false matches)
    that is not nav/chrome, so the search query is unambiguous."""
    import re
    cands = []
    for m in marks:
        for word in re.findall(r"[A-Za-z]{6,}", m.text):
            if word.lower() not in _SEARCH_CHROME_WORDS:
                cands.append(word)
    cands.sort(key=len, reverse=True)
    return cands[0] if cands else None


def search_present_title(d: Driver) -> None:
    """Verify catalog SEARCH end-to-end with a self-validating, rotation-proof method:
    read a word from a title CURRENTLY in the catalog feed, search for it, and assert
    that title comes back in the results. No pinned title (DPLA content rotates) — the
    journey supplies its own known-present target each run. Raises StagingError if the
    known-present title does NOT return (the search-regression signal) — never a
    false-pass. Leaves the app on the search results for the recording to assert."""
    navigate_to(d, "catalog")
    time.sleep(1.5)
    word = _pick_title_word(d.observe())
    if not word:
        raise StagingError("search_present_title: no searchable title word in the catalog feed")
    w, h = d._dims
    d._act.tap(int(w * 0.90), int(h * 0.092), w, h, d.udid)   # top-right search magnifier
    time.sleep(1.0)
    d.tap_text("Search Catalog")                              # focus the field
    time.sleep(0.5)
    d._act.type_text(word, d.udid)
    time.sleep(0.5)
    d._act.press_key("return", d.udid)
    time.sleep(2.5)
    results = [m.text for m in d.observe()]
    if not any(word.lower() in t.lower() for t in results):
        # Search FAILED to return a KNOWN-PRESENT title. Staging exceptions don't
        # auto-fail the journey (the runner only logs them), so leave the app OFF the
        # search screen — the recording's 'Cancel' (search-active) contract token is
        # then absent and the journey FAILs honestly instead of false-passing.
        if d.find("Cancel"):
            d.tap_text("Cancel")
        navigate_to(d, "catalog")
        raise StagingError(
            f"search_present_title: '{word}' (a title present in the catalog) did not "
            f"return in search results — catalog search may be broken")
    # Success: the app is left on the search results (search field active → 'Cancel'
    # present) for the recording's contract. The result action buttons ('Borrow'/'Get')
    # are book-type-dependent, so the contract keys on 'Cancel', NOT on a result button.


# ===========================================================================
# DETERMINISTIC IN-FLIGHT-DOWNLOAD FORGE  (PP-4542/PP-4613 — unblocks cold-load)
# ===========================================================================
# The cold-load regression (PP-4613) only fires when a fresh-borrow LCP audiobook
# is opened while its .lcpa CONTENT is not yet local — the app then routes through
# the LCP STREAMING path, which Readium 3.9.0 broke (0-byte read → "Audiobook
# Unavailable"). Catching the live ~1.5s download window is non-deterministic, so
# instead we FORGE the state from the filesystem: a book is marked
# `.downloadSuccessful` the instant its tiny .lcpl license lands
# (LCPFulfillmentHandler), DECOUPLED from the .lcpa content landing. So deleting the
# .lcpa while keeping the .lcpl sibling leaves the registry saying "downloaded" but
# `AudiobookSessionManager.audiobookContentIsLocal` returning false — the exact
# streaming-path precondition, reproducibly, with no network timing.
PALACE_BUNDLE_ID = "org.thepalaceproject.palace"


def audiobook_content_files_under(root: Path) -> list[Path]:
    """All downloaded LCP audiobook CONTENT files (.lcpa) under an app-data
    container root. Pure (filesystem-only) so the path logic is unit-testable with
    a tmp tree. Content lives at `<root>/Library/Application Support/<bundle>/
    <account-uuid>/content/<sha256(bookId)>.lcpa`; we rglob so per-account subdirs
    are covered without resolving the account UUID."""
    support = root / "Library" / "Application Support"
    if not support.exists():
        return []
    return sorted(support.rglob("*.lcpa"))


def _app_data_container(udid: str) -> Path:
    out = subprocess.run(
        ["xcrun", "simctl", "get_app_container", udid, PALACE_BUNDLE_ID, "data"],
        capture_output=True, text=True,
    )
    path = out.stdout.strip()
    if out.returncode != 0 or not path:
        raise StagingError(
            f"forge_streaming_state: could not resolve Palace data container on sim "
            f"{udid} (installed?): {out.stderr.strip() or 'no output'}")
    return Path(path)


def forge_streaming_state(d: Driver) -> None:
    """SUPERSEDED (2026-07-08) — no longer used by the cold-load recipe. Kept only
    as a documented lesson; do NOT wire into a recipe.

    Original premise: delete each downloaded `.lcpa` CONTENT file (keeping its
    `.lcpl` license + registry `.downloadSuccessful`) so the next open routes
    through the LCP *streaming* path — the Readium-3.9.0 "Audiobook Unavailable"
    surface — without racing the live download.

    Why it's retired: the PP-4542 fix (#1094) REPLACED that streaming path. A
    fresh-borrow LCP audiobook whose `.lcpa` isn't local now goes through the
    download-gate (`AudiobookSessionManager.awaitAudiobookContentLocal`), which is
    a bounded (180s) *poll of the file* — "the download is already in flight … this
    is a wait, not a trigger." Deleting a COMPLETED `.lcpa` leaves NO active
    transfer, so the poll can only ever TIME OUT → "Audiobook Unavailable" after
    3 minutes — an artifact of an impossible state, not the real cold-load path.
    The correct stage is a GENUINE in-flight download (see
    `reborrow_audiobook_streaming`). The fixture assumption also drifted: the A1QA
    standing "Animal Farm" is now a BiblioBoard bearer-token audiobook (zero
    `.lcpa`), so this raised `StagingError` and could not even reach its
    precondition.

    Raises StagingError if no .lcpa is present."""
    container = _app_data_container(d.udid)
    lcpas = audiobook_content_files_under(container)
    if not lcpas:
        raise StagingError(
            "forge_streaming_state: no downloaded .lcpa audiobook content found to "
            "forge — sign in to a library with a downloaded LCP audiobook first")
    for f in lcpas:
        f.unlink()
    print(f"[staging] forge_streaming_state: deleted {len(lcpas)} .lcpa content "
          f"file(s) (kept .lcpl) → next open streams (PP-4613 path)")


# A LARGE, RETURNABLE LCP audiobook from the A1QA "Audible Titles" lane. Size is a
# FEATURE: the download window must comfortably outlast the journey's open so
# "tap Listen while still downloading" is reliable (small audiobooks race the
# ~1.5s window — the original PHASE2 flake). Swap this if the A1QA feed changes;
# it MUST be a true LCP audiobook (fulfills as "Listen", downloads a `.lcpa`) and
# returnable (so the recipe can reset + re-borrow to force a fresh in-flight
# download each run).
#
# Retitled 2026-07-08 (live validation): the prior pin "Carl's Doomsday Scenario"
# was DROPPED from the A1QA Audible lane — a "Carl" search returned Carl Seelig /
# Carl The Trailer / Dungeon Crawler Carl / "Carl: The Apocalypse..." but NO
# "Carl's Doomsday Scenario", so reborrow_audiobook_streaming could not find a
# Borrow/Get and raised StagingError. "Dungeon Crawler Carl" (Matt Dinniman, narr.
# Jeff Hays) is the replacement: same Audible lane, confirmed live to fulfill as
# "Listen" + offer "Return" (a returnable LCP audiobook), and it is a long
# (~15 hr, multi-hundred-MB) LitRPG audiobook, so its download window is wide.
_COLD_LOAD_LCP_AUDIOBOOK = "Dungeon Crawler Carl"


def reborrow_audiobook_streaming(d: Driver, title: str = _COLD_LOAD_LCP_AUDIOBOOK) -> None:
    """Leave `title` MID-DOWNLOAD in My Books so the journey's next 'Listen' tap
    exercises the REAL cold-open-during-download path (PP-4613 / the PP-4542
    await-gate) — the correct replacement for the retired forge_streaming_state.

    Flow: reach detail via search → if already borrowed, Return first (so the
    re-borrow triggers a FRESH download, not an instant open from a complete local
    cache) → Borrow → return IMMEDIATELY without waiting for completion. The book
    is large by design, so the `.lcpa` is still downloading when the journey opens
    it: the await-gate polls the genuine in-flight transfer, content lands, playback
    starts (fixed) or the 'Audiobook Unavailable' alert fires (regressed). A live
    download also renders real 'Downloading… %' UI, which the journey's
    required_text_any asserts as forward progress.

    Idempotent: the Return→re-Borrow reset makes each run start a fresh download.
    Raises StagingError if the book offers no Borrow/Get affordance."""
    _open_book_detail(d, title)
    # Reset a prior run's completed/partial download so the re-borrow re-downloads.
    if d.find("Return"):
        d.tap_text("Return")
        tap_dialog_button(d, "Return", "Cancel")
        time.sleep(2.5)
        _open_book_detail(d, title)
    if d.find("Borrow"):
        d.tap_text("Borrow")
    elif d.find("Get"):
        d.tap_text("Get")
    else:
        raise StagingError(
            f"reborrow_audiobook_streaming: no Borrow/Get on '{title}' detail — "
            f"is it still in the A1QA Audible lane? (update _COLD_LOAD_LCP_AUDIOBOOK)")
    # Do NOT poll for 'Listen'/completion — leaving it in flight IS the point.
    time.sleep(2.5)   # let the loan register + the download kick off


PRIMITIVES = {
    "dismiss_first_launch": lambda d, *a: dismiss_first_launch(d),
    "add_library": lambda d, name: add_library(d, name),
    "switch_library": lambda d, name: switch_library(d, name),
    "sign_in": lambda d, *a: sign_in(d, *(a or ("a1qa",))),
    "dismiss_save_password": lambda d, *a: dismiss_save_password(d),
    "download_fixture": lambda d, *a: download_fixture(d),
    "clear_sync_position": lambda d, *a: clear_sync_position(d),
    "sign_out": lambda d, *a: sign_out(d),
    "borrow_download": lambda d, title: borrow_and_download(d, title),
    "borrow_first": lambda d, *a: borrow_first(d),
    "search_present_title": lambda d, *a: search_present_title(d),
    "return_book": lambda d, *a: return_book(d, *(a or (None,))),
    "goto": lambda d, screen: navigate_to(d, screen),
    "forge_streaming_state": lambda d, *a: forge_streaming_state(d),  # SUPERSEDED — kept for the lesson; no recipe wires it
    "reborrow_audiobook_streaming": lambda d, *a: reborrow_audiobook_streaming(d, *(a or (_COLD_LOAD_LCP_AUDIOBOOK,))),
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

    # --- circulation (borrow ROUND-TRIP, returnable open-access) ---
    # General book-management coverage: stage ONE genuinely BORROWED book (never a
    # hold — see borrow_first) from a returnable Palace Bookshelf (DPLA) title, then
    # the recording removes it and asserts the OUTCOME (it leaves My Books). Book- and
    # loan-type-AGNOSTIC: no specific title, no Return-vs-Remove pinning — borrow_first
    # is robust to DPLA catalog rotation. NEVER the A1QA read-only standing fixtures.
    "book-return-from-mybooks": [
        ("dismiss_first_launch",), ("add_library", "Palace Bookshelf"),
        ("switch_library", "Palace Bookshelf"), ("borrow_first",), ("goto", "my_books"),
    ],
    "read-return-from-mybooks-roundtrip": [
        ("dismiss_first_launch",), ("add_library", "Palace Bookshelf"),
        ("switch_library", "Palace Bookshelf"), ("borrow_first",), ("goto", "my_books"),
    ],

    # --- catalog SEARCH (self-validating, rotation-proof) ---
    # Reads a title CURRENTLY present in the catalog and searches for it, asserting it
    # comes back — verifies general search functionality without pinning a volatile
    # title. Staging does the search + the round-trip assertion; the recording asserts
    # the search-results state.
    "search-flow-stateful": [
        ("dismiss_first_launch",), ("add_library", "Palace Bookshelf"),
        ("switch_library", "Palace Bookshelf"), ("search_present_title",),
    ],

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
        ("download_fixture",), ("dismiss_save_password",), ("clear_sync_position",),
    ],
    "reader2-bookmark-toggle": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",), ("clear_sync_position",),
    ],
    "reader2-page-forward": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",), ("clear_sync_position",),
    ],
    "reader2-settings-sheet": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",), ("clear_sync_position",),
    ],
    "reader2-toc-navigate": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("goto", "my_books"), ("dismiss_save_password",),
        ("download_fixture",), ("dismiss_save_password",), ("clear_sync_position",),
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

    # --- audiobook COLD-LOAD (PP-4613, real in-flight download) ---
    # Leave a LARGE LCP audiobook MID-DOWNLOAD, then the journey opens it before the
    # `.lcpa` content lands — the real cold-open-during-download path the PP-4542
    # download-gate handles (hold `.loading`, poll the in-flight transfer, open from
    # the local package when it lands; regressed = "Audiobook Unavailable").
    # Supersedes the old forge_streaming_state delete-premise: PP-4542 replaced the
    # LCP streaming path with a 180s file-poll of an ALREADY-in-flight download, so
    # deleting a COMPLETED `.lcpa` (no active transfer) can only time out — it no
    # longer reproduces the regression. A large title keeps the download window wide
    # enough that the open reliably lands mid-transfer. `reborrow_audiobook_streaming`
    # returns-then-re-borrows, so it re-downloads a FRESH copy each run (idempotent);
    # the Audible-lane title is a returnable loan, not the read-only standing fixture.
    "audiobook-cold-load-first-open": [
        ("dismiss_first_launch",), ("add_library", "A1QA Test Library"),
        ("sign_in", "a1qa"), ("dismiss_save_password",),
        ("reborrow_audiobook_streaming",), ("goto", "my_books"),
    ],
}

# Journeys whose recipe GENUINELY needs Phase 2 (borrow_and_download / a clean
# registry) — reported as "phase2" and clean-skipped until the foundation's
# borrow_and_download lands. Do NOT fake these:
#   read-return / book-return roundtrips  — borrow→read→RETURN the book (mutates
#       the fixture; can't run against the read-only standing fixture).
#   audiobook-download-indicator-stateful — STILL PHASE2. Asserts the in-flight
#       'Downloading… %' UI, which requires a genuinely ACTIVE download in progress.
#       The forge_streaming_state harness (below) does NOT help here: deleting the
#       .lcpa produces a content-ABSENT state with no active transfer, so no progress
#       % renders — it forges the cold-load (streaming) path, not a live-download
#       indicator. Empirically the Animal Farm LCP fixture downloads in ~1.5s on the
#       sim and the in-flight % is a TRANSIENT/varying state that flakes
#       screenshot-drift replay; there is no clean per-sim network throttle (only
#       invasive host-level NLC). Revisit only with a per-sim download throttle /
#       progress-injection seam — a different mechanism than the cold-load forge.
#   PP-4161-streaming-html-reader         — anonymous search→Borrow→Read; requires
#       a .unregistered registry (uninstall/reinstall), NOT a sign-in.
#   search-flow-stateful                  — no recording exists yet.
# The reader2 (5) + audiobook skip/toc/scrubber (3) journeys moved OUT of here into
# STAGING_RECIPES: they use the A1QA STANDING fixture (pre-borrowed, read-only) and
# need SIGN-IN ONLY — see the "reading"/"audiobook" recipes above.
# audiobook-cold-load-first-open was PHASE2 for the same ~1.5s-window reason, but
# is now PROMOTED to a STAGING_RECIPES entry (above) via the forge_streaming_state
# primitive — which forges the not-yet-local state from the filesystem instead of
# racing the live download. That IS the "in-flight-download harness" the old note
# called for (for the cold-load path specifically).
PHASE2_JOURNEYS = {
    "PP-4161-streaming-html-reader",
    "audiobook-download-indicator-stateful",
    # Adopted into area groups 2026-08-20 (they were on disk but claimed by NO
    # area group, so no cell ever fanned them — "recorded, committed, dormant").
    # Adoption makes them CLAIMED; it does not make them EXECUTABLE. Each still
    # needs a staging recipe, so they classify phase2 (recipe pending), NOT ready.
    # Do not read their presence in the manifest as coverage.
    "app-rating-sentiment-gate",          # needs the engagement trigger; the
                                          # Force-Rating-Eligible flag alone does
                                          # not raise the gate (verified on-device
                                          # 2026-08-20) — a recipe must borrow.
    "audiobook-sleep-timer-45",           # needs a PLAYING audiobook: borrow +
                                          # download + Listen, like the other
                                          # audiobook recipes.
    "holds-reservations-empty",           # needs sign-in + an account with no
                                          # holds; cheap recipe, just unwritten.
    "reader3-pdf-open-and-page",          # needs a downloaded PDF ("Comedias y
                                          # tragedias (PDF)" is on the A1QA shelf).
    "triage-bot-category-chip-rapid-tap", # Get Help is reachable without auth, so
    "triage-bot-redaction-adversarial-input",  # these two are the cheapest to
                                          # promote to ready once someone writes
                                          # the recipe.
}

# Chairman-blocked (creds/OTP) — recipes pending.
# PP-4529 is blocked on CAPABILITY, not credentials: the assertion is a VoiceOver
# rotor action, and rotor items are not in the accessibility tree the driver
# observes and do not appear in screenshots. No recipe can fix that; it needs a
# driver that can operate VoiceOver, or it stays manual.
BLOCKED_JOURNEYS = {
    "danny-saml-signin-init",
    "icarus-oidc-signin",
    "PP-4529-print-page-navigation-voiceover",
}

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
#   NOTE: the reader2 journeys were briefly demoted here on the theory that the
#       Mathematics EPUB download was Adobe-gated and never completed in the staging
#       window. That conclusion was an ARTIFACT of the old download_book detection
#       (a single-title-mark + 160px anchor that MISSED the 'Read' button on a card
#       whose title OCRs as two marks) — it raised a false 'did not reach Read' while
#       the book WAS downloaded. With the card-span detection fix, all 5 reader2
#       journeys STAGE + REPLAY deterministically to completion (validated end-to-end:
#       back-button 3/3, bookmark-toggle 4/4, page-forward 5/5, settings-sheet 5/5,
#       toc-navigate 6/6 — full step replay, no Adobe gate). So they are GATING, not
#       fragile, and are NOT listed below.
KNOWN_FRAGILE_PRECONDITIONS = {"library-picker-stateless", "palace-bookshelf-anonymous"}

# NOTE on a1qa-basic-signin perf-HIGH: deliberately NOT demoted (it is the core
# sign-in critical path and MUST stay gating — see test_known_fragile_journeys...).
# Its perf-HIGH is driven by the MEMORY axis: the worker snapshots the perf baseline
# after staging, which ends SIGNED-OUT on the sign-in form (minimal working set),
# then the replay SIGNS IN and loads the catalog/My Books → +~77MB of legitimate
# post-sign-in working set (threads confirm transient: +18→3→1, the worker's trend
# gate already demotes the thread axis). The principled fix is a baseline-timing one
# (warm the baseline to a signed-in state for sign-in journeys), addressed in the
# worker's perf-baseline block — NOT a blanket memory-threshold raise (which would
# mask real memory leaks) and NOT a demotion of the critical journey.


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
