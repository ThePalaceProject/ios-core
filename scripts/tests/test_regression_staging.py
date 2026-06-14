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
        st.stage_for_journey(None, "read-return-from-mybooks-roundtrip")  # phase2
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


# ── 5. worker still parses after the version-normalize wiring ──────────────────

def test_area_worker_bash_n():
    r = subprocess.run(["bash", "-n", str(_AREA_WORKER)], capture_output=True, text=True)
    assert r.returncode == 0, f"bash -n failed:\n{r.stderr}"
