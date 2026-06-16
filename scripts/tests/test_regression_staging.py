#!/usr/bin/env python3
"""
test_regression_staging.py — pytest for the RC-AREA staging layer (#21).

Covers the PURE, sim-free surface (the sim-driving primitives are exercised live
by the area-worker):
  1. Cross-build version normalize (regression_findings.normalized_requires_version_match).
  2. Staging recipe integrity: every recipe is well-formed; every referenced
     primitive exists; the staging-ORDER insight is honored (sign-out chains
     after a sign-in so the mutually-exclusive auth states are reachable).
  3. staging_status coverage: EVERY journey in the manifest is classified
     (ready | phase2 | blocked) — never "unknown" (so the runner always knows
     whether it can stage a journey).
  4. assert_outcome present/absent gate (the modal-ate-the-taps / wrong-book
     destructive guard).
  5. The worker still passes `bash -n` after the version-normalize wiring.

Stdlib-only (the tooling-integrity gate is stdlib-only; no numpy/pyyaml/Pillow).
Run: pytest scripts/tests/test_regression_staging.py
"""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SCRIPTS = _REPO_ROOT / "scripts"
_MANIFEST = _REPO_ROOT / ".simdrive" / "regression-areas.json"
_AREA_WORKER = _SCRIPTS / "regression-area-worker.sh"


def _load(name: str):
    spec = importlib.util.spec_from_file_location(name, _SCRIPTS / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # register before exec for @dataclass introspection
    spec.loader.exec_module(mod)
    return mod


rf = _load("regression_findings")
st = _load("regression_staging")


# ── 1. cross-build version normalize ──────────────────────────────────────────

def test_version_normalize_relaxes_minor_to_any():
    # the default pin that halts cross-build replay
    assert rf.normalized_requires_version_match("minor") == "any"
    assert rf.normalized_requires_version_match("exact") == "any"
    assert rf.normalized_requires_version_match("major") == "any"


def test_version_normalize_none_defaults_to_relax():
    # a recording with no explicit version_match defaults to "minor" -> relax
    assert rf.normalized_requires_version_match(None) == "any"


def test_version_normalize_already_any_is_noop():
    # already "any" => no rewrite needed
    assert rf.normalized_requires_version_match("any") is None


def test_version_normalize_is_independent_of_device_normalize():
    # the two helpers have the same Optional[str] shape so the worker wires them
    # identically; device-normalize untouched by version logic.
    assert rf.normalized_requires_device("iPhone 16 Pro (pool-3)", "iPhone 16 Pro") == "iPhone 16 Pro"
    assert rf.normalized_requires_device("iPad Pro", "iPhone 16 Pro") is None  # cross-model still halts


def test_device_strip_is_fail_safe_only_pool_fleet_unrecognized_kept():
    # FAIL-SAFE (anti-false-MATCH): strip ONLY the recognized pool/fleet clone tags;
    # an UNRECOGNIZED suffix is LEFT INTACT so it can never mask a real device mismatch
    # (a hand-named smoke sim must use fleet-N / _allocate_sim, not an arbitrary label).
    assert rf.strip_device_suffix("iPhone 16 Pro (pool-3)") == "iPhone 16 Pro"
    assert rf.strip_device_suffix("iPhone 16 Pro (fleet-2)") == "iPhone 16 Pro"
    assert rf.strip_device_suffix("iPhone 16 Pro (custom)") == "iPhone 16 Pro (custom)"   # unrecognized — KEPT
    assert rf.strip_device_suffix("iPad Pro (12.9-inch)") == "iPad Pro (12.9-inch)"        # model — kept
    assert rf.strip_device_suffix("iPad Pro (12.9-inch) (fleet-2)") == "iPad Pro (12.9-inch)"


def test_ios_version_normalize_relaxes_cross_minor_keeps_predicate():
    # the rc-smoke residual: a 26.0-captured recording must replay on a 26.2 sim
    assert rf.normalized_requires_ios_version("26.0", "26.2") == "26.2"
    assert rf.normalized_requires_ios_version("26.2", "26.2") is None       # already matches
    assert rf.normalized_requires_ios_version(">=26.0", "26.2") is None      # predicate — recorder evaluates
    assert rf.normalized_requires_ios_version(None, "26.2") is None
    assert rf.normalized_requires_ios_version("26.0", None) is None


# ── 1b. OCR-artifact text_subset normalize (corpus hardening) ─────────────────

def test_text_subset_strips_a1qa_logo_ocr_artifacts():
    # the A1QA logo glyph OCRs run-to-run as 'ga'/'al'/'qa' — strip it, keep the
    # stable real-text tokens that verify the same precondition deterministically.
    req = ["Settings", "Popular books free to download and", "ga",
           "A test library for A1QA.", "PUBLIC LIBRARY", "Download Only on Wi-Fi",
           "over Wi-Fi.", "SUPPORT", "Get Help", "ABOUT AND LEGAL"]
    out = rf.normalized_text_subset_required(req)
    assert out is not None
    assert "ga" not in out
    # every stable token survives
    for t in ("Settings", "A test library for A1QA.", "PUBLIC LIBRARY", "Get Help"):
        assert t in out


def test_text_subset_clean_precondition_is_noop():
    # no artifacts → None (no rewrite), same as the other normalizers
    assert rf.normalized_text_subset_required(
        ["Account", "Library Card", "Password", "Sign in"]) is None


def test_text_subset_floor_protects_against_under_specifying():
    # in A1QA context, stripping the logo glyphs would leave < 3 stable tokens →
    # keep as-is (None); an under-specified precondition could match the WRONG screen.
    assert rf.normalized_text_subset_required(["A1QA Test Library", "qa", "al"]) is None


def test_text_subset_keeps_real_short_words():
    # 'All'/'Read' are genuine UI labels, not glyph junk — never stripped; only the
    # A1QA logo glyph ('qa') goes, and only because the precondition is A1QA-context.
    out = rf.normalized_text_subset_required(
        ["A test library for A1QA.", "Get Help", "All", "Read", "qa"])
    assert out == ["A test library for A1QA.", "Get Help", "All", "Read"]


def test_is_ocr_artifact_classification():
    # logo glyphs are artifacts ONLY in A1QA context; punctuation always; reals never
    for junk in ("ga", "al", "qa", "a1", "a", "DAI"):
        assert rf._is_ocr_artifact(junk, a1qa_context=True), f"{junk!r} artifact in A1QA ctx"
    for punct in (":::", "•"):
        assert rf._is_ocr_artifact(punct), f"{punct!r} punctuation is always artifact"
    for real in ("Account", "Sign in", "PUBLIC LIBRARY", "Return", "Get Help", "All"):
        assert not rf._is_ocr_artifact(real, a1qa_context=True), f"{real!r} not an artifact"


def test_text_subset_state_code_collision_is_context_scoped():
    # THE false-pass guard: 'ga'/'al'/'qa' collide with US state abbreviations (GA/AL).
    # OUTSIDE A1QA context they are real discriminators and must be RETAINED — only
    # stripped when the precondition proves it's the A1QA screen (carries an 'A1QA'
    # marker). A loose denylist would strip a Georgia library's 'GA' → wrong-screen
    # false-pass.
    for code in ("ga", "GA", "al", "AL", "qa"):
        assert not rf._is_ocr_artifact(code, a1qa_context=False), f"{code!r} retained out-of-ctx"
        assert rf._is_ocr_artifact(code, a1qa_context=True), f"{code!r} stripped in A1QA ctx"
    # a non-A1QA Georgia-library precondition keeps 'GA' (no 'A1QA' marker → no strip)
    assert rf.normalized_text_subset_required(
        ["Atlanta Public Library", "serving GA", "GA", "Catalog", "Settings"]) is None
    # short meaningful tokens (lang/status/format) are never in the glyph set
    for meaningful in ("B6", "EN", "DUE", "PDF", "LCP", "v3"):
        assert not rf._is_ocr_artifact(meaningful, a1qa_context=True), f"{meaningful!r} retained"


# ── 2. staging recipe integrity ───────────────────────────────────────────────

def test_every_recipe_is_well_formed():
    for journey, recipe in st.STAGING_RECIPES.items():
        assert isinstance(recipe, list) and recipe, f"{journey}: empty/!list recipe"
        for step in recipe:
            assert isinstance(step, tuple) and step, f"{journey}: bad step {step!r}"
            prim = step[0]
            assert prim in st.PRIMITIVES, f"{journey}: unknown primitive '{prim}'"


def test_recipes_start_by_dismissing_first_launch():
    # step-0 text_subset only matches after the clean-install dialog is cleared
    for journey, recipe in st.STAGING_RECIPES.items():
        assert recipe[0][0] == "dismiss_first_launch", f"{journey} must dismiss first-launch first"


def test_staging_order_signout_chains_after_signin():
    # mutually-exclusive auth: sign-out needs SIGNED-IN, so its recipe signs in
    # (leaving signed-in) rather than expecting a static signed-in state.
    recipe = st.STAGING_RECIPES["a1qa-sign-out"]
    prims = [s[0] for s in recipe]
    assert "sign_in" in prims, "sign-out staging must sign in first (staging-ORDER)"


def test_basic_signin_recipe_leaves_signed_out_on_form():
    # sign-in journey must be staged to the sign-in FORM (signed out), not signed in
    recipe = st.STAGING_RECIPES["a1qa-basic-signin"]
    assert ("goto", "account_signin") in recipe
    assert not any(s[0] == "sign_in" for s in recipe)


# ── 3. staging_status coverage (no journey is "unknown") ──────────────────────

def test_every_manifest_journey_is_classified():
    manifest = json.loads(_MANIFEST.read_text())
    area_groups = manifest.get("area_groups", manifest)
    journeys = set()
    for k, v in area_groups.items():
        if k.startswith("_"):
            continue
        js = v.get("journeys") if isinstance(v, dict) else v
        journeys.update(js or [])
    unknown = sorted(j for j in journeys if st.staging_status(j) == "unknown")
    assert not unknown, f"journeys with no staging classification (ready/phase2/blocked): {unknown}"


def test_status_values_are_valid():
    for j in list(st.STAGING_RECIPES):
        assert st.staging_status(j) == "ready"
    for j in st.PHASE2_JOURNEYS:
        assert st.staging_status(j) == "phase2"
    for j in st.BLOCKED_JOURNEYS:
        assert st.staging_status(j) == "blocked"


def test_stage_for_journey_raises_on_phase2_and_unknown():
    # dispatcher must not silently no-op; it raises with the status.
    with pytest.raises(st.StagingError):
        st.stage_for_journey(None, "PP-4161-streaming-html-reader")  # phase2
    with pytest.raises(st.StagingError):
        st.stage_for_journey(None, "no-such-journey")  # unknown


# ── 4. assert_outcome (modal-ate-the-taps / wrong-book gate) ──────────────────

def test_assert_outcome_present_and_absent():
    texts = ["My Books", "Mathematics Test Book", "Animal Farm"]
    ok, _ = st.assert_outcome(texts, expect_present=["My Books"],
                              expect_absent=["What Remains After a Fire"])
    assert ok


def test_assert_outcome_absent_leak_fails():
    # the returned book's title still on screen => return did not happen
    texts = ["My Books", "What Remains After a Fire", "Kanza Javed"]
    ok, reason = st.assert_outcome(texts, expect_absent=["What Remains After a Fire"])
    assert not ok and "leak" in reason


def test_assert_outcome_missing_present_fails():
    ok, reason = st.assert_outcome(["Add Library"], expect_present=["Page 1 of"])
    assert not ok and "missing" in reason


def test_assert_outcome_is_case_insensitive_substring():
    ok, _ = st.assert_outcome(["page 1 of 8 (cover page)"], expect_present=["Page 1 of 8"])
    assert ok


# ── 5. settle gate (the cold-start v4/v5/v6 uniform-fail fix) ─────────────────

class _FakeDriver:
    """Minimal Driver stand-in for the settle gate's observe→find→tap loop.
    `before` is the screen seen on each observe; if Settings is tapped and
    `after` is set, subsequent observes return `after` (the tab transition).
    Each mark gets a distinct y so taps resolve back to a label in `tap_log`."""
    def __init__(self, before, after=None):
        self.before, self.after = before, after
        self.settle, self.udid, self._dims, self.tapped = 0.0, "FAKE", (1206, 2622), False
        self._act = self
        self.tap_log = []

    def _marks(self, scr):
        return [st._Mark(10, 100 + 50 * i, 100, 40, t) for i, t in enumerate(scr)]

    def tap(self, x, y, w, h, udid):  # _act.tap(...)
        cur = self.after if (self.tapped and self.after is not None) else self.before
        for m in self._marks(cur):  # log against the screen visible at tap-time
            if m.cx == x and m.cy == y:
                self.tap_log.append(m.text)
                break
        self.tapped = True

    def observe(self):
        scr = self.after if (self.tapped and self.after is not None) else self.before
        return self._marks(scr)

    def find(self, needle, marks=None):
        marks = marks if marks is not None else self.observe()
        nl = needle.lower()
        for m in marks:
            if m.text.strip().lower() == nl:
                return m
        for m in marks:
            if nl in m.text.lower():
                return m
        return None

    def has(self, needle):
        return self.find(needle) is not None

    def tap_text(self, needle, timeout=12.0):
        m = self.find(needle)
        if m is None:
            raise st.StagingError(f"timeout waiting for '{needle}'")
        self.tap(m.cx, m.cy, self._dims[0], self._dims[1], self.udid)

    def tap_until(self, tap_label, expect_label, retries=4, timeout=8.0):
        for _ in range(retries):
            m = self.find(tap_label)
            if m:
                self.tap(m.cx, m.cy, self._dims[0], self._dims[1], self.udid)
            if self.find(expect_label):
                return
        raise st.StagingError(f"tap '{tap_label}' did not reach '{expect_label}'")

    def tap_xy(self, px, py):  # search-field focus etc. — no mark resolution
        self.tapped = True

    def type(self, text):      # search typing — fake screen is static, no filtering
        pass


class _StaticDriver(_FakeDriver):
    """Single fixed screen (no transition) — for asserting add_library's
    forced-picker-vs-Settings disambiguation taps the right thing (or nothing)."""
    def tap(self, x, y, w, h, udid):
        self.tapped = True
        for m in self._marks(self.before):
            if m.cx == x and m.cy == y:
                self.tap_log.append(m.text)
                break

    def observe(self):
        return self._marks(self.before)


def test_settle_ready_when_libraries_and_lib_present():
    d = _FakeDriver(["Settings", "LIBRARIES", "A1QA Test Library"])
    assert st.wait_until_ready(d, timeout=2.0) >= 0.0
    assert not d.tapped  # already on the libraries screen → no Settings tap needed


def test_settle_matches_plus_add_library_ocr_merge():
    # the add button OCRs as '+ADD LIBRARY' (the '+' glyph merges in); the gate
    # must treat "addable" as ready even when the library isn't added yet.
    d = _FakeDriver(["Settings", "LIBRARIES", "+ADD LIBRARY"])
    assert st.wait_until_ready(d, timeout=2.0) >= 0.0


def test_settle_taps_settings_when_on_another_tab():
    # cold-start lands on the Catalog (app restores last screen); the gate must
    # reach Settings before LIBRARIES is visible. This is the v6 failure path.
    d = _FakeDriver(before=["Catalog", "My Books", "Holds", "Settings"],
                    after=["LIBRARIES", "A1QA Test Library"])
    assert st.wait_until_ready(d, timeout=2.0) >= 0.0
    assert d.tapped  # proves it navigated to Settings, not just got lucky


def test_settle_times_out_when_never_ready():
    d = _FakeDriver(["Catalog", "Settings"])  # Settings present, but never reaches LIBRARIES
    with pytest.raises(st.StagingError):
        st.wait_until_ready(d, timeout=0.4, poll=0.1)


def test_add_library_noops_when_already_present_on_settings():
    # Settings screen with '+ADD LIBRARY' button + the library already in the list.
    # The forced-picker branch must NOT fire (its "Add Library" substring would
    # otherwise match '+ADD LIBRARY' and tap a library row). Expected: reaches
    # Settings, sees the library present, no-ops — never taps 'ADD LIBRARY' or the row.
    d = _StaticDriver(["Settings", "LIBRARIES", "+ADD LIBRARY", "A1QA Test Library"])
    st.add_library(d, "A1QA Test Library")
    assert "A1QA Test Library" not in d.tap_log, f"misfired: tapped row ({d.tap_log})"
    assert not any("add library" in t.lower() for t in d.tap_log), f"tapped add ({d.tap_log})"


def test_add_library_uses_forced_picker_when_no_settings_chrome():
    # True clean-install picker: 'Add Library' title, NO 'LIBRARIES' header → tap the
    # library directly. This is the branch the Settings guard must still allow.
    d = _StaticDriver(["Add Library", "Find Your Library", "A1QA Test Library"])
    st.add_library(d, "A1QA Test Library")
    assert "A1QA Test Library" in d.tap_log


def test_await_precondition_returns_fast_when_tokens_present():
    d = _StaticDriver(["Settings", "LIBRARIES", "Addison Public Library", "PUBLIC LIBRARY"])
    secs = st.await_precondition(d, ["Settings", "PUBLIC LIBRARY"], timeout=2.0, poll=0.1)
    assert secs < 1.0  # satisfied on first observe


def test_await_precondition_timeout_does_not_raise_so_replay_still_gates():
    # THE load-bearing property: on timeout it RETURNS (doesn't raise) so the caller
    # still runs the replay → the recorder's own precondition check fails → RED. It
    # absorbs only render-delay, never a wrong-stays-wrong screen.
    d = _StaticDriver(["Some Other Screen"])
    secs = st.await_precondition(d, ["PUBLIC LIBRARY"], timeout=0.3, poll=0.1)
    assert secs >= 0.3  # waited the full timeout, then returned (no exception)


def test_await_precondition_empty_tokens_is_noop():
    d = _StaticDriver(["anything"])
    assert st.await_precondition(d, [], timeout=2.0) == 0.0


def test_await_precondition_is_case_sensitive_like_recorder():
    # the recorder's precondition check is case-sensitive substring; the settle must
    # match that exactly, else it would settle on a case it won't actually pass.
    d = _StaticDriver(["public library"])  # wrong case
    secs = st.await_precondition(d, ["PUBLIC LIBRARY"], timeout=0.3, poll=0.1)
    assert secs >= 0.3  # never matches lowercase → times out (then replay gates)


def test_provision_cli_requires_sim():
    # argparse wiring: provision without --sim is a usage error (exit), not a crash
    with pytest.raises(SystemExit):
        st._main(["provision"])
    with pytest.raises(SystemExit):
        st._main([])  # missing subcommand


# ── 6. worker still parses after the version-normalize wiring ─────────────────

def test_known_fragile_journeys_are_demoted_but_recognized():
    # demoted journeys must still be RECOGNIZED (so the worker can tag, not hide them)
    assert st.is_known_fragile("palace-bookshelf-anonymous")
    assert st.is_known_fragile("library-picker-stateless")
    # must-pass / critical-path journeys are NOT fragile-tagged
    assert not st.is_known_fragile("a1qa-basic-signin")
    assert not st.is_known_fragile("a1qa-sign-out")
    # the demoted set are real journeys with recipes that still RUN (demote != skip)
    for j in st.KNOWN_FRAGILE_PRECONDITIONS:
        assert st.staging_status(j) in ("ready", "phase2"), f"{j} must still run"


# ── 7. journey_drm Phase-A/B routing (gate-3 fan-out filter seam) ─────────────

def test_drm_for_journey_defaults_to_phase_a_when_untagged():
    # an untagged journey must default to Phase-A (adobe_irreducible False) — never
    # accidentally Phase-B
    m = {"area_groups": {}, "journey_drm": {}}
    d = rf.drm_for_journey(m, "anything")
    assert d["adobe_irreducible"] is False and d["drm_type"] == "none"


def test_journey_passes_drm_filter_exclude_and_only():
    m = {"area_groups": {}, "journey_drm": {
        "adobe-j": {"drm_type": "adobe", "adobe_irreducible": True},
        "lcp-j": {"drm_type": "lcp", "adobe_irreducible": False}}}
    assert not rf.journey_passes_drm_filter(m, "adobe-j", exclude_drm="adobe")
    assert rf.journey_passes_drm_filter(m, "lcp-j", exclude_drm="adobe")
    assert rf.journey_passes_drm_filter(m, "adobe-j", only_drm="adobe")
    assert not rf.journey_passes_drm_filter(m, "lcp-j", only_drm="adobe")
    assert rf.journey_passes_drm_filter(m, "lcp-j")  # no filters → runs


def test_current_matrix_is_entirely_phase_a():
    # gate-3 guard: EVERY tagged journey in the shipped manifest is Phase-A
    # (adobe_irreducible False). If a future edit flips one to Phase-B it must be
    # deliberate — this test forces that intent to be explicit.
    m = rf.load_manifest(_MANIFEST)
    jd = m.get("journey_drm", {})
    assert jd, "manifest must carry journey_drm tags"
    phase_b = [j for j, v in jd.items() if v.get("adobe_irreducible")]
    assert phase_b == [], f"unexpected Phase-B journeys (need explicit budget): {phase_b}"


def test_area_worker_bash_n():
    r = subprocess.run(["bash", "-n", str(_AREA_WORKER)], capture_output=True, text=True)
    assert r.returncode == 0, f"bash -n failed:\n{r.stderr}"
