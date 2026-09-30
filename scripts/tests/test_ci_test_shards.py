"""Tests for scripts/ci-test-shards.py — the CI test-shard planner and checks.

prior-art-checked: follows the scripts/tests/ pytest convention for a new script.

The failure this tooling must never have is a test class that runs in NO
shard. xcodebuild ignores an `-only-testing:` name that matches nothing, so a
class the split drops produces a green shard and simply never executes. Most
of this file pins that property from each side: the plan partitions the
classes, the per-shard check sees a class that did not run, and the gate's
union check sees a class that ran nowhere or twice. Each check also has a
clean-path assertion, because a check that fails everything is as useless as
one that passes everything.
"""
from __future__ import annotations

import importlib.util
import json
import random
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "ci-test-shards.py"
spec = importlib.util.spec_from_file_location("ci_test_shards", SCRIPT)
shards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shards)

TIMINGS = json.loads((REPO / "scripts" / "ci-test-timings.json").read_text())
ISOLATED = shards.read_isolated(REPO / "scripts" / "ci-isolated-serial-tests.txt")


def _realistic_classes() -> list[str]:
    """Every class the committed timings know, as PalaceTests, plus TenPrint."""
    names = sorted(TIMINGS["classes"])
    out = [f"PalaceTests/{n}" for n in names if n != "C64ConversionTests"]
    out.append("TenPrintCoverTests/C64ConversionTests")
    return out


def _enumeration(classes, methods=2, extra_ids=()):
    ids = [f"{c}/test{i}()" for c in classes for i in range(methods)]
    return {"errors": [], "values": [{"testPlan": "Palace", "disabledTests": [],
                                      "enabledTests": [{"identifier": i} for i in [*ids, *extra_ids]]}]}


def _plan(n, classes=None, timings=TIMINGS):
    return shards.build_plan(classes or _realistic_classes(), timings, n, ISOLATED)


# --------------------------------------------------------------------------
# Partition: every class exactly once
# --------------------------------------------------------------------------

@pytest.mark.parametrize("n", [1, 2, 3, 4, 5, 7])
def test_every_class_lands_in_exactly_one_shard(n):
    classes = _realistic_classes()
    plan = _plan(n, classes)
    union = []
    for k in range(n):
        union += shards.shard_classes(plan, k, "parallel")
        union += shards.shard_classes(plan, k, "serial")
    assert sorted(union) == sorted(classes)
    assert len(union) == len(set(union))


def test_isolated_classes_run_only_in_the_serial_pass():
    plan = _plan(3)
    for k in range(3):
        par = set(shards.shard_classes(plan, k, "parallel"))
        ser = set(shards.shard_classes(plan, k, "serial"))
        assert not par & set(ISOLATED)
        assert ser <= set(ISOLATED)
    placed = [c for k in range(3) for c in shards.shard_classes(plan, k, "serial")]
    assert sorted(placed) == sorted(ISOLATED)


def test_every_extra_is_placed_on_a_real_shard():
    for n in (1, 2, 4):
        plan = _plan(n)
        assert set(plan["extras"]) == set(shards.EXTRAS)
        assert all(0 <= k < n for k in plan["extras"].values())


def test_check_plan_rejects_a_dropped_class():
    classes = _realistic_classes()
    plan = _plan(3, classes)
    del plan["classes"][classes[10]]
    with pytest.raises(shards.PlanError, match="missing"):
        shards.check_plan(plan, classes)


def test_check_plan_rejects_an_out_of_range_shard():
    classes = _realistic_classes()
    plan = _plan(3, classes)
    plan["classes"][classes[0]] = 3
    with pytest.raises(shards.PlanError, match="out-of-range"):
        shards.check_plan(plan, classes)


def test_a_duplicated_class_in_the_enumeration_is_refused():
    classes = _realistic_classes()
    with pytest.raises(shards.PlanError, match="twice"):
        shards.build_plan(classes + classes[:1], TIMINGS, 2, ISOLATED)


def test_an_isolated_name_that_matches_nothing_is_refused():
    """A misspelt isolated class would be skipped by the parallel pass AND
    unmatched by the serial one — it would run in neither."""
    with pytest.raises(shards.PlanError, match="match no enumerated class"):
        shards.build_plan(_realistic_classes(), TIMINGS, 2, ISOLATED + ["PalaceTests/NoSuchTests"])


def test_an_empty_isolated_list_is_refused(tmp_path):
    f = tmp_path / "iso.txt"
    f.write_text("# only comments\n\n")
    with pytest.raises(shards.PlanError):
        shards.read_isolated(f)


# --------------------------------------------------------------------------
# Determinism
# --------------------------------------------------------------------------

def test_the_same_inputs_give_the_same_plan_whatever_their_order():
    classes = _realistic_classes()
    shuffled = classes[:]
    random.Random(7).shuffle(shuffled)
    assert _plan(4, classes) == _plan(4, shuffled)


def test_a_new_class_without_timing_does_not_move_any_other_class():
    classes = _realistic_classes()
    before = _plan(4, classes)
    after = _plan(4, classes + ["PalaceTests/BrandNewFeatureTests"])
    moved = {c for c in classes if before["classes"][c] != after["classes"][c]}
    assert moved == set()
    assert after["classes"]["PalaceTests/BrandNewFeatureTests"] == \
        shards.stable_shard("PalaceTests/BrandNewFeatureTests", 4)
    assert "PalaceTests/BrandNewFeatureTests" in after["hashed"]


def test_stable_shard_does_not_use_the_salted_builtin_hash():
    """hash() of a str changes per interpreter; the placement must not."""
    code = ("import importlib.util,sys;"
            f"s=importlib.util.spec_from_file_location('m',{str(SCRIPT)!r});"
            "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
            "print(m.stable_shard('PalaceTests/SomeTests', 7))")
    outs = {subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                           env={"PYTHONHASHSEED": seed}).stdout for seed in ("1", "2", "3")}
    assert len(outs) == 1 and outs != {""}


# --------------------------------------------------------------------------
# Balance
# --------------------------------------------------------------------------

@pytest.mark.parametrize("n", [2, 3, 4])
def test_shards_are_balanced_on_the_committed_timings(n):
    plan = _plan(n)
    load = plan["estimated_seconds"]
    # Longest-first can miss the optimum by at most the largest single unit.
    scale = TIMINGS["class_scale"]
    biggest = max(max(TIMINGS["classes"].values()) * scale, *TIMINGS["extras"].values())
    assert max(load) - min(load) <= biggest
    assert max(load) <= 1.10 * (sum(load) / n)


def test_balance_uses_the_timings_rather_than_the_hash():
    """Mutating the assignment to hash-only must visibly unbalance the shards."""
    classes = [f"PalaceTests/C{i}" for i in range(40)]
    timings = {"class_scale": 1.0, "extras": {"streaming-on": 1, "packages": 1},
               "classes": {f"C{i}": (100.0 if i < 4 else 1.0) for i in range(40)}}
    plan = shards.build_plan(classes + ["TenPrintCoverTests/T"], timings, 4, ["PalaceTests/C39"])
    heavy = {plan["classes"][f"PalaceTests/C{i}"] for i in range(4)}
    assert heavy == {0, 1, 2, 3}, "the four heavy classes must be spread one per shard"


def test_class_scale_converts_class_seconds_before_extras_are_weighed():
    classes = ["PalaceTests/A", "PalaceTests/B", "TenPrintCoverTests/T"]
    t = {"classes": {"A": 10.0, "B": 10.0, "T": 0.0},
         "extras": {"streaming-on": 25.0, "packages": 0.0}}
    unscaled = shards.build_plan(classes, {**t, "class_scale": 1.0}, 2, ["PalaceTests/B"])
    scaled = shards.build_plan(classes, {**t, "class_scale": 3.0}, 2, ["PalaceTests/B"])
    # Unscaled, the 25 s ON leg outweighs either class and gets a shard to
    # itself; at 3x the classes are the heavy units and it rides with one.
    assert unscaled["estimated_seconds"] == [25.0, 20.0]
    assert scaled["estimated_seconds"] == [55.0, 30.0]


# --------------------------------------------------------------------------
# Enumeration parsing
# --------------------------------------------------------------------------

def test_enumeration_yields_target_slash_class():
    doc = _enumeration(["PalaceTests/A", "TenPrintCoverTests/T"])
    assert shards.classes_from_enumeration(doc) == ["PalaceTests/A", "TenPrintCoverTests/T"]


def test_a_class_with_no_test_methods_is_not_planned():
    """PalaceTestCase and friends enumerate as bare "Target/Class"; they run
    nothing, so requiring a shard to show them running would fail every run."""
    doc = _enumeration(["PalaceTests/A"], extra_ids=["PalaceTests/PalaceTestCase"])
    assert shards.classes_from_enumeration(doc) == ["PalaceTests/A"]


def test_enumeration_errors_are_refused():
    doc = _enumeration(["PalaceTests/A"])
    doc["errors"] = ["could not launch"]
    with pytest.raises(shards.PlanError, match="errors"):
        shards.classes_from_enumeration(doc)


def test_enumeration_without_values_is_refused():
    with pytest.raises(shards.PlanError, match="values"):
        shards.classes_from_enumeration({"errors": []})


def test_a_missing_test_bundle_is_refused():
    with pytest.raises(shards.PlanError, match="TenPrintCoverTests"):
        shards.check_targets(["PalaceTests/A"])


def test_an_unknown_test_bundle_is_refused():
    with pytest.raises(shards.PlanError, match="does not know"):
        shards.check_targets(["PalaceTests/A", "TenPrintCoverTests/T", "PalaceUITests/U"])


# --------------------------------------------------------------------------
# Result bundles: per-shard and union checks
# --------------------------------------------------------------------------

def _tests_doc(classes_to_results: dict[str, list[str]]) -> dict:
    bundles: dict[str, list] = {}
    for c, results in classes_to_results.items():
        target, cls = c.split("/")
        cases = [{"nodeType": "Test Case", "name": f"t{i}()", "result": r}
                 for i, r in enumerate(results)]
        bundles.setdefault(target, []).append(
            {"nodeType": "Test Suite", "name": cls, "children": cases})
    return {"testNodes": [{"nodeType": "Test Plan", "name": "Palace", "children": [
        {"nodeType": "Unit test bundle", "name": b, "children": suites}
        for b, suites in bundles.items()]}]}


def _small_plan():
    classes = ["PalaceTests/A", "PalaceTests/B", "PalaceTests/C", "TenPrintCoverTests/T"]
    timings = {"class_scale": 1.0, "extras": {"streaming-on": 1.0, "packages": 1.0},
               "classes": {"A": 5.0, "B": 4.0, "C": 3.0, "T": 1.0}}
    return shards.build_plan(classes, timings, 2, ["PalaceTests/C"])


def _report(plan, shard, drop=(), add=(), results=None):
    mine = [c for c in shards.shard_classes(plan, shard, "all") if c not in drop] + list(add)
    doc = _tests_doc({c: (results or {}).get(c, ["Passed"]) for c in mine})
    return shards.verify_shard(plan, shard, doc)


def test_verify_shard_clean_path():
    plan = _small_plan()
    for k in range(2):
        r = _report(plan, k)
        assert r["missing"] == [] and r["foreign"] == []
        assert sorted(r["executed"]) == shards.shard_classes(plan, k, "all")


def test_verify_shard_reports_a_class_that_did_not_run():
    plan = _small_plan()
    victim = shards.shard_classes(plan, 0, "all")[0]
    assert _report(plan, 0, drop=[victim])["missing"] == [victim]


def test_verify_shard_reports_a_class_from_another_shard():
    plan = _small_plan()
    other = shards.shard_classes(plan, 1, "all")[0]
    assert _report(plan, 0, add=[other])["foreign"] == [other]


def test_an_all_skipped_class_is_not_missing_but_is_not_executed_either():
    plan = _small_plan()
    c = shards.shard_classes(plan, 0, "all")[0]
    r = _report(plan, 0, results={c: ["Skipped", "Skipped"]})
    assert r["missing"] == []
    assert c in r["skipped_only"] and c not in r["executed"]


def test_a_failed_class_still_counts_as_run():
    plan = _small_plan()
    c = shards.shard_classes(plan, 0, "all")[0]
    r = _report(plan, 0, results={c: ["Failed", "Passed"]})
    assert c in r["executed"] and r["missing"] == []


def test_verify_union_clean_path():
    plan = _small_plan()
    assert shards.verify_union(plan, [_report(plan, 0), _report(plan, 1)]) == []


def test_verify_union_catches_a_missing_shard_report():
    plan = _small_plan()
    problems = shards.verify_union(plan, [_report(plan, 0)])
    assert any("expected one report" in p for p in problems)
    assert any("ran in no shard" in p for p in problems)


def test_verify_union_catches_a_class_run_twice():
    plan = _small_plan()
    dup = shards.shard_classes(plan, 1, "all")[0]
    problems = shards.verify_union(plan, [_report(plan, 0, add=[dup]), _report(plan, 1)])
    assert any("more than one shard" in p and dup in p for p in problems)


def test_verify_union_catches_a_class_dropped_inside_a_shard():
    plan = _small_plan()
    victim = shards.shard_classes(plan, 1, "all")[0]
    problems = shards.verify_union(plan, [_report(plan, 0), _report(plan, 1, drop=[victim])])
    assert any(victim in p for p in problems)


def test_verify_union_catches_a_class_the_plan_does_not_name():
    plan = _small_plan()
    problems = shards.verify_union(plan, [_report(plan, 0, add=["PalaceTests/Ghost"]),
                                          _report(plan, 1)])
    assert any("does not name" in p for p in problems)


# --------------------------------------------------------------------------
# Timings from CI logs
# --------------------------------------------------------------------------

LOG = "\n".join([
    "test (shard 0)\tRun test shard\t2026-09-30T20:31:14Z Test case 'FooTests.testA()' passed on 'Clone 1 of iPhone 16 Pro - Palace (1)' (1.500 seconds)",
    "test (shard 0)\tRun test shard\t2026-09-30T20:31:15Z Test case 'FooTests.testB()' failed on 'Clone 1 of iPhone 16 Pro - Palace (1)' (0.500 seconds)",
    "test (shard 0)\tRun test shard\t2026-09-30T20:31:16Z Test Case '-[PalaceTests.BarTests testC]' passed (2.000 seconds).",
    "test (shard 0)\tRun LCP-streaming flag consumers' suites with the flag ON\t2026 Test Case '-[PalaceTests.FooTests testA]' passed (9.000 seconds).",
])


def test_class_seconds_sum_both_log_forms_and_skip_the_on_leg():
    secs, depth = shards.class_seconds_from_log(LOG)
    assert secs == {"FooTests": 2.0, "BarTests": 2.0}
    assert depth == 1.0


def test_a_retried_run_reports_its_depth():
    retried = LOG + "\n" + LOG.splitlines()[1].replace("failed", "passed")
    _, depth = shards.class_seconds_from_log(retried)
    assert depth == pytest.approx(4 / 3)


def test_a_retried_or_thin_run_is_not_used_for_timings():
    big = {f"C{i}": 1.0 for i in range(shards.MIN_CLASSES_PER_RUN)}
    assert shards.usable_run(big, 1.0)
    assert not shards.usable_run(big, 1.3)
    assert not shards.usable_run({"C": 1.0}, 1.0)


def test_timings_doc_takes_the_median_and_scales_to_a_typical_run():
    runs = [{"A": 1.0, "B": 10.0}, {"A": 3.0, "B": 10.0}, {"A": 2.0, "B": 40.0}]
    doc = shards.timings_doc(runs, [1, 2, 3], {})
    assert doc["classes"] == {"A": 2.0, "B": 10.0}
    # run totals 11, 13, 42 against a median sum of 12 -> median ratio 13/12
    assert doc["class_scale"] == pytest.approx(13 / 12, abs=1e-3)


def test_the_committed_timings_file_is_well_formed():
    assert TIMINGS["class_scale"] > 0
    assert set(TIMINGS["extras"]) == set(shards.EXTRAS)
    assert len(TIMINGS["classes"]) > 500
    assert len(TIMINGS["runs"]) >= shards.MIN_RUNS


# --------------------------------------------------------------------------
# Allowance kills (the shard's second chance)
# --------------------------------------------------------------------------

KILL = "Test exceeded execution time allowance of 2 minutes"


def _case(ident, result, messages=(), repetitions=None):
    node = {"nodeType": "Test Case", "name": ident.split("/")[1], "nodeIdentifier": ident,
            "result": result,
            "children": [{"nodeType": "Failure Message", "name": m} for m in messages]}
    if repetitions:
        node["children"] = [{"nodeType": "Repetition", "name": f"R{i}", "result": r,
                             "children": [{"nodeType": "Failure Message", "name": m} for m in ms]}
                            for i, (r, ms) in enumerate(repetitions)]
    return node


def _doc(*cases, bundle="PalaceTests"):
    return {"testNodes": [{"nodeType": "Test Plan", "children": [
        {"nodeType": "Unit test bundle", "name": bundle, "children": [
            {"nodeType": "Test Suite", "name": "S", "children": list(cases)}]}]}]}


def test_kills_only_gets_a_second_chance_with_method_level_ids():
    doc = _doc(_case("S/testA()", "Failed", [KILL]), _case("S/testB()", "Passed"))
    status, ids = shards.kill_rerun_candidates(doc)
    assert status == shards.KILLS_ONLY
    assert ids == ["PalaceTests/S/testA"]


def test_any_ordinary_failure_withholds_the_second_chance():
    doc = _doc(_case("S/testA()", "Failed", [KILL]),
               _case("S/testB()", "Failed", ["XCTAssertTrue failed"]))
    assert shards.kill_rerun_candidates(doc) == (shards.KILLS_MIXED, [])


def test_a_test_that_failed_an_assertion_and_was_then_killed_is_not_a_kill():
    doc = _doc(_case("S/testA()", "Failed", repetitions=[
        ("Failed", ["S.swift:9: XCTAssertEqual failed"]), ("Failed", [KILL])]))
    assert shards.kill_rerun_candidates(doc)[0] == shards.KILLS_MIXED


def test_a_test_that_passed_after_retry_is_not_a_failure():
    doc = _doc(_case("S/testA()", "Passed", repetitions=[("Failed", ["boom"]), ("Passed", [])]))
    assert shards.kill_rerun_candidates(doc) == (shards.KILLS_NONE, [])


def test_the_real_ci_bundle_shape_is_recognised():
    """Run 36769109335: an allowance kill and a retried-then-passed test, in the
    shape `xcresulttool get test-results tests` printed them."""
    doc = {"testNodes": [{"nodeType": "Test Plan", "name": "Palace", "children": [
        {"nodeType": "Unit test bundle", "name": "PalaceTests", "children": [
            {"nodeType": "Test Suite", "name": "TPPBookRegistryLargeCorpusTests", "children": [
                {"children": [{"name": KILL, "nodeType": "Failure Message"}], "duration": "2m",
                 "durationInSeconds": 120, "name": "testRoundTrip_5000Books_AllFieldsPreserved()",
                 "nodeIdentifier": "TPPBookRegistryLargeCorpusTests/testRoundTrip_5000Books_AllFieldsPreserved()",
                 "nodeType": "Test Case", "result": "Failed"}]},
            {"nodeType": "Test Suite", "name": "BookReturnServiceTests", "children": [
                {"children": [
                    {"children": [{"name": "BookReturnServiceTests.swift:591: failed",
                                   "nodeType": "Failure Message"}],
                     "name": "First Run", "nodeType": "Repetition", "result": "Failed"},
                    {"name": "Retry 1", "nodeType": "Repetition", "result": "Passed"}],
                 "details": "Passed after 1 retry", "name": "testReturnService()",
                 "nodeIdentifier": "BookReturnServiceTests/testReturnService()",
                 "nodeType": "Test Case", "result": "Passed"}]}]}]}]}
    status, ids = shards.kill_rerun_candidates(doc)
    assert status == shards.KILLS_ONLY
    assert ids == ["PalaceTests/TPPBookRegistryLargeCorpusTests/"
                   "testRoundTrip_5000Books_AllFieldsPreserved"]


def test_rerun_outcome_requires_every_id_to_have_run_and_passed():
    ids = ["PalaceTests/S/testA", "PalaceTests/S/testB"]
    both = _doc(_case("S/testA()", "Passed"), _case("S/testB()", "Passed"))
    assert shards.rerun_outcome(ids, both) == []
    only_a = _doc(_case("S/testA()", "Passed"))
    assert shards.rerun_outcome(ids, only_a) == ["PalaceTests/S/testB did not run on the second chance"]
    a_killed = _doc(_case("S/testA()", "Failed", [KILL]), _case("S/testB()", "Passed"))
    assert shards.rerun_outcome(ids, a_killed) == ["PalaceTests/S/testA failed on the second chance"]


# --------------------------------------------------------------------------
# CLI wiring: plan -> args covers the enumeration exactly
# --------------------------------------------------------------------------

def _cli(*args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


def test_cli_plan_then_args_cover_every_enumerated_class_once(tmp_path):
    classes = _realistic_classes()
    enum = tmp_path / "enum.json"
    enum.write_text(json.dumps(_enumeration(classes, extra_ids=["PalaceTests/PalaceTestCase"])))
    plan = tmp_path / "plan.json"
    r = _cli("plan", "--enumeration", str(enum), "--shards", "3", "--out", str(plan))
    assert r.returncode == 0, r.stdout + r.stderr
    got = []
    for k in range(3):
        for kind in ("parallel", "serial"):
            out = _cli("args", "--plan", str(plan), "--shard", str(k), "--kind", kind)
            assert out.returncode == 0
            got += [ln.removeprefix("-only-testing:") for ln in out.stdout.splitlines()]
    assert sorted(got) == sorted(classes)
    assert len(got) == len(set(got))


def test_cli_plan_fails_closed_on_a_bad_isolated_name(tmp_path):
    enum = tmp_path / "enum.json"
    enum.write_text(json.dumps(_enumeration(["PalaceTests/A", "TenPrintCoverTests/T"])))
    iso = tmp_path / "iso.txt"
    iso.write_text("PalaceTests/Misspelt\n")
    r = _cli("plan", "--enumeration", str(enum), "--shards", "2", "--isolated", str(iso),
             "--out", str(tmp_path / "p.json"))
    assert r.returncode == 1
    assert "::error::" in r.stdout


def test_cli_verify_union_exit_codes(tmp_path):
    plan = _small_plan()
    (tmp_path / "plan.json").write_text(json.dumps(plan))
    for k in range(2):
        (tmp_path / f"r{k}.json").write_text(json.dumps(_report(plan, k)))
    ok = _cli("verify-union", "--plan", str(tmp_path / "plan.json"),
              str(tmp_path / "r0.json"), str(tmp_path / "r1.json"))
    assert ok.returncode == 0, ok.stdout
    missing = _cli("verify-union", "--plan", str(tmp_path / "plan.json"), str(tmp_path / "r0.json"))
    assert missing.returncode == 1
    none = _cli("verify-union", "--plan", str(tmp_path / "plan.json"))
    assert none.returncode == 1, "no reports at all must fail, not pass vacuously"
