"""The NonDRM Build workflow must run on pull requests and be able to build.

Palace-noDRM is how someone runs the app without Adobe DRM, on a simulator
included. It went unbuildable for months because the only workflow that builds
it was `workflow_dispatch`-only, and when dispatched it could not have built:
its checkout step fetched no submodules (PalaceAudiobookToolkit is one) and
passed no token. Each of those is a one-line edit that reads as harmless in a
diff, and the trigger has already been turned off once — so the wiring is
pinned here, parsed as YAML rather than grepped, step by step.

Three properties:

  1. the workflow triggers on pull_request (and stays dispatchable);
  2. its checkout fetches submodules with the CI token, like every other
     workflow that builds this project;
  3. after the build, the product is checked by
     scripts/check-nodrm-app-excludes-audioengine.sh, and the build was told
     where to put that product (NODRM_DERIVED_DATA_PATH) so the check can find
     it. A check pointed at a path the build never wrote exits 2 every time and
     would look like a failing build — which is at least not a false pass, but
     is a gate nobody would keep.

prior-art-checked: this pins a public GitHub workflow; no harness capability
inspects repository workflows, and the harness cannot be a dependency of a
test the tooling-checks workflow runs on a clean ubuntu runner.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

yaml = pytest.importorskip("yaml")

_REPO = Path(__file__).resolve().parents[2]
_WORKFLOW = _REPO / ".github/workflows/non-drm-build.yml"
_CHECK = "scripts/check-nodrm-app-excludes-audioengine.sh"
_BUILD = "scripts/xcode-build-nodrm.sh"
_DEPS = "scripts/build-3rd-party-dependencies.sh"


def _doc() -> dict:
    return yaml.safe_load(_WORKFLOW.read_text())


def _triggers() -> dict:
    doc = _doc()
    # PyYAML reads a bare `on:` key as the boolean True.
    on = doc.get("on", doc.get(True))
    assert on is not None, "workflow has no `on:` block"
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        return {k: None for k in on}
    return on


def _steps() -> list[dict]:
    jobs = _doc()["jobs"]
    assert len(jobs) == 1, f"expected one job, found {list(jobs)}"
    return next(iter(jobs.values()))["steps"]


def _step_running(fragment: str) -> dict:
    hits = [s for s in _steps() if fragment in str(s.get("run", ""))]
    assert hits, f"no step runs `{fragment}`"
    assert len(hits) == 1, f"`{fragment}` is run by {len(hits)} steps; expected one"
    return hits[0]


# --- 1. trigger -------------------------------------------------------------

def test_workflow_runs_on_pull_request():
    triggers = _triggers()
    assert "pull_request" in triggers, (
        f"NonDRM Build triggers are {sorted(triggers)}; without `pull_request` the "
        "noDRM target is built by nobody until someone remembers to dispatch it."
    )


def test_pull_request_trigger_is_scoped_to_build_inputs():
    pr = _triggers()["pull_request"] or {}
    paths = pr.get("paths") or []
    for required in ("Palace/**", "Palace.xcodeproj/**", "ios-audiobooktoolkit"):
        assert required in paths, f"pull_request.paths lacks {required!r}: {paths}"
    # The scripts the job runs are inputs too: a change that breaks them must
    # run the job that would show it.
    for script in (_BUILD, _DEPS, _CHECK, "scripts/build-carthage.sh",
                   "scripts/fetch-audioengine.sh", "scripts/setup-repo-nodrm.sh"):
        assert script in paths, f"pull_request.paths lacks {script!r}"
    assert ".github/workflows/non-drm-build.yml" in paths


def test_workflow_stays_manually_dispatchable():
    assert "workflow_dispatch" in _triggers()


# --- 2. checkout ------------------------------------------------------------

def _checkout_steps() -> list[dict]:
    return [s for s in _steps() if str(s.get("uses", "")).startswith("actions/checkout@")]


def test_checkout_fetches_submodules_with_the_ci_token():
    checkouts = _checkout_steps()
    assert len(checkouts) == 1, f"expected one checkout step, found {len(checkouts)}"
    with_ = checkouts[0].get("with") or {}
    assert with_.get("submodules") is True, (
        "checkout must set `submodules: true` — PalaceAudiobookToolkit is a "
        "submodule and the noDRM build links it"
    )
    assert with_.get("token") == "${{ secrets.CI_GITHUB_ACCESS_TOKEN }}", (
        "checkout must pass the CI token like every other workflow that builds "
        "this project; the submodule URLs are not anonymous"
    )


# --- 3. build → check -------------------------------------------------------

def test_dependencies_are_built_on_the_no_private_path():
    step = _step_running(_DEPS)
    assert "--no-private" in step["run"]


def test_build_and_check_share_the_derived_data_path():
    build = _step_running(_BUILD)
    check = _step_running(_CHECK)
    build_env = build.get("env") or {}
    assert "NODRM_DERIVED_DATA_PATH" in build_env, (
        "the build step must set NODRM_DERIVED_DATA_PATH so the product lands "
        "somewhere the check step can name"
    )
    dd = build_env["NODRM_DERIVED_DATA_PATH"]
    check_env = check.get("env") or {}
    assert check_env.get("NODRM_DERIVED_DATA_PATH") == dd, (
        "the check step must read the SAME NODRM_DERIVED_DATA_PATH the build wrote to"
    )
    assert "Palace-noDRM.app" in check["run"], "the check must be pointed at Palace-noDRM.app"


def test_check_runs_after_the_build_and_only_when_it_succeeded():
    steps = _steps()
    build_idx = next(i for i, s in enumerate(steps) if _BUILD in str(s.get("run", "")))
    check_idx = next(i for i, s in enumerate(steps) if _CHECK in str(s.get("run", "")))
    assert check_idx > build_idx, "the product check must follow the build"
    check = steps[check_idx]
    # `if: always()` would run the check against a product a failed build never
    # wrote, reporting exit 2 on top of the real failure.
    assert "always()" not in str(check.get("if", "")), (
        "the product check must not run with `if: always()` — a failed build has no product"
    )


def test_check_script_is_tracked_and_executable():
    path = _REPO / _CHECK
    assert path.is_file(), f"{_CHECK} is missing; the workflow step would exit 127"
    assert os.access(path, os.X_OK), f"{_CHECK} is not executable; the step would exit 126"
