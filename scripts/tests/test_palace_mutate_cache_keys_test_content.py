"""Mutation-cache keys must be sensitive to TEST CONTENT, not just test names.

Both cache keys in `palace_mutate.py` hashed the `--tests` *names* and never the
test *bodies*. Editing a test therefore did not invalidate anything, and a stored
verdict was replayed against a suite that no longer produced it.

The harmless direction is a stale `survived` after tests are strengthened — that
is how this was found: a real run reported `DownloadTaskPersistence` at
2 killed / 1 survived on a tip where the survivor was already dead.

The dangerous direction is a stale **`killed`** after a test is weakened or
deleted while the production file is untouched. Mutation then reports a kill it
never measured, which is the same class of lie as counting a compile failure as a
kill — the thing this tool exists to prevent.

The per-mutant cache is the worse of the two: it persists individual verdicts
across runs, so a deleted test leaves `killed` in place indefinitely.
"""

import hashlib
import importlib.util
import os
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parents[1]


def _load():
    spec = importlib.util.spec_from_file_location(
        "palace_mutate_under_test", SCRIPTS / "palace_mutate.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


pm = _load()


# --------------------------------------------------------------------------
# A throwaway repo shaped like the real one
# --------------------------------------------------------------------------

def _repo(tmp_path: Path, test_body: str, *, class_name: str = "FooTests",
          mocks: dict[str, str] | None = None) -> str:
    root = tmp_path / "repo"
    (root / "PalaceTests" / "MyBooks").mkdir(parents=True)
    (root / "PalaceTests" / "MyBooks" / f"{class_name}.swift").write_text(
        f"import XCTest\n\nfinal class {class_name}: XCTestCase {{\n{test_body}\n}}\n")
    if mocks:
        (root / "PalaceTests" / "Mocks").mkdir(parents=True)
        for name, body in mocks.items():
            (root / "PalaceTests" / "Mocks" / name).write_text(body)
    return str(root)


# --------------------------------------------------------------------------
# resolve_test_sources
# --------------------------------------------------------------------------

def test_resolves_a_class_to_its_file(tmp_path):
    root = _repo(tmp_path, "  func testA() {}")
    found = pm.resolve_test_sources(["PalaceTests/FooTests"], root)
    assert found is not None and len(found) == 1
    assert found[0].endswith("FooTests.swift")


def test_bare_class_name_without_bundle_prefix_also_resolves(tmp_path):
    root = _repo(tmp_path, "  func testA() {}")
    assert pm.resolve_test_sources(["FooTests"], root) is not None


def test_unresolvable_class_returns_none(tmp_path):
    """None is the signal that disables caching. It must not be an empty list."""
    root = _repo(tmp_path, "  func testA() {}")
    assert pm.resolve_test_sources(["PalaceTests/NotPresentTests"], root) is None


def test_one_unresolvable_among_several_poisons_the_whole_set(tmp_path):
    """Partial resolution must fail closed — a half-fingerprint is not a fingerprint."""
    root = _repo(tmp_path, "  func testA() {}")
    assert pm.resolve_test_sources(["PalaceTests/FooTests", "PalaceTests/GhostTests"], root) is None


def test_empty_test_selection_returns_none(tmp_path):
    root = _repo(tmp_path, "  func testA() {}")
    assert pm.resolve_test_sources([], root) is None


def test_class_name_matching_is_word_bounded(tmp_path):
    """`FooTests` must not resolve against a declaration of `FooTestsExtra`."""
    root = _repo(tmp_path, "  func testA() {}", class_name="FooTestsExtra")
    assert pm.resolve_test_sources(["PalaceTests/FooTests"], root) is None


# --------------------------------------------------------------------------
# test_fingerprint — the load-bearing behaviour
# --------------------------------------------------------------------------

def test_fingerprint_changes_when_a_test_body_changes(tmp_path):
    a = pm.test_fingerprint(["PalaceTests/FooTests"],
                            _repo(tmp_path / "a", "  func testA() { XCTAssertTrue(x) }"))
    b = pm.test_fingerprint(["PalaceTests/FooTests"],
                            _repo(tmp_path / "b", "  func testA() { XCTAssertTrue(y) }"))
    assert a is not None and b is not None
    assert a != b, "an edited assertion must change the fingerprint"


def test_fingerprint_changes_when_a_test_is_DELETED(tmp_path):
    """THE false-green case. Deleting a test must not leave `killed` cached."""
    before = pm.test_fingerprint(
        ["PalaceTests/FooTests"],
        _repo(tmp_path / "before", "  func testA() {}\n  func testB() {}"))
    after = pm.test_fingerprint(
        ["PalaceTests/FooTests"],
        _repo(tmp_path / "after", "  func testA() {}"))
    assert before is not None and after is not None
    assert before != after, "deleting a test MUST invalidate the cache"


def test_fingerprint_is_stable_for_identical_content(tmp_path):
    body = "  func testA() { XCTAssertEqual(1, 1) }"
    a = pm.test_fingerprint(["PalaceTests/FooTests"], _repo(tmp_path / "a", body))
    b = pm.test_fingerprint(["PalaceTests/FooTests"], _repo(tmp_path / "b", body))
    assert a == b, "identical tests must reuse cache — otherwise the cache is useless"


def test_fingerprint_changes_when_a_shared_mock_changes(tmp_path):
    """A mock edit can flip a verdict, so it must invalidate."""
    a = pm.test_fingerprint(["PalaceTests/FooTests"], _repo(
        tmp_path / "a", "  func testA() {}", mocks={"M.swift": "class M { let v = 1 }"}))
    b = pm.test_fingerprint(["PalaceTests/FooTests"], _repo(
        tmp_path / "b", "  func testA() {}", mocks={"M.swift": "class M { let v = 2 }"}))
    assert a != b


def test_fingerprint_is_none_when_unresolvable(tmp_path):
    root = _repo(tmp_path, "  func testA() {}")
    assert pm.test_fingerprint(["PalaceTests/GhostTests"], root) is None


# --------------------------------------------------------------------------
# Both keys must consume the fingerprint
# --------------------------------------------------------------------------

def test_cache_key_changes_with_the_fingerprint():
    common = dict(file_content="let x = 1", tests=["PalaceTests/FooTests"],
                  seed=1, max_mutations=5)
    assert (pm.cache_key(**common, tests_fingerprint="aaaa")
            != pm.cache_key(**common, tests_fingerprint="bbbb"))


def test_mutant_key_changes_with_the_fingerprint():
    common = dict(tests=["PalaceTests/FooTests"], context_before="a", line_text="b",
                  context_after="c", original="==", mutated="!=")
    assert (pm.compute_mutant_key(**common, tests_fingerprint="aaaa")
            != pm.compute_mutant_key(**common, tests_fingerprint="bbbb"))


def test_unresolved_fingerprint_does_not_collide_with_a_real_one():
    """None must not hash the same as any resolvable fingerprint."""
    common = dict(tests=["PalaceTests/FooTests"], context_before="a", line_text="b",
                  context_after="c", original="==", mutated="!=")
    unresolved = pm.compute_mutant_key(**common, tests_fingerprint=None)
    assert unresolved != pm.compute_mutant_key(**common, tests_fingerprint="aaaa")


def test_keys_still_disambiguate_and_stay_local():
    """The pre-existing properties must survive the change."""
    base = dict(tests=["T"], original="==", mutated="!=", tests_fingerprint="fp")
    same = pm.compute_mutant_key(context_before="a", line_text="b", context_after="c", **base)
    assert same == pm.compute_mutant_key(context_before="a", line_text="b",
                                         context_after="c", **base)
    assert same != pm.compute_mutant_key(context_before="x", line_text="b",
                                         context_after="c", **base)


def test_cache_version_was_bumped_to_discard_poisoned_entries():
    """Entries written under the name-only scheme are untrustworthy by construction.

    Bumping the version is what evicts them; without it the fix would leave every
    already-stored verdict in play.
    """
    assert pm.CACHE_VERSION >= 2


# --------------------------------------------------------------------------
# Test-root discovery — found, not hardcoded
# --------------------------------------------------------------------------

def test_discovers_test_roots_by_suffix(tmp_path):
    root = tmp_path / "repo"
    (root / "PalaceTests").mkdir(parents=True)
    (root / "TenPrintCoverTests").mkdir()
    (root / "Palace").mkdir()                      # source, not tests
    (root / "notes.txt").write_text("x")           # a file ending in nothing
    assert pm.discover_test_roots(str(root)) == ["PalaceTests", "TenPrintCoverTests"]


def test_discovers_a_sibling_repos_test_root(tmp_path):
    """The gap this closes: the toolkit's tests are not called PalaceTests.

    `--repo-root` supports mutating a sibling checkout. With the roots hardcoded,
    resolution against the audiobook toolkit found nothing, the fingerprint came
    back None, and caching switched off silently for every toolkit run.
    """
    root = tmp_path / "toolkit"
    (root / "PalaceAudiobookToolkitTests" / "Sub").mkdir(parents=True)
    (root / "PalaceAudiobookToolkitTests" / "Sub" / "FooTests.swift").write_text(
        "final class FooTests: XCTestCase {}")
    assert pm.discover_test_roots(str(root)) == ["PalaceAudiobookToolkitTests"]
    assert pm.resolve_test_sources(["PalaceAudiobookToolkitTests/FooTests"], str(root)) is not None
    assert pm.test_fingerprint(["PalaceAudiobookToolkitTests/FooTests"], str(root)) is not None


def test_discovery_on_a_missing_directory_returns_empty_not_raise(tmp_path):
    assert pm.discover_test_roots(str(tmp_path / "nope")) == []


# --------------------------------------------------------------------------
# A failed baseline must record the ABSENCE of a measurement
# --------------------------------------------------------------------------

def test_baseline_failure_report_has_no_summary_to_misread():
    """`baseline: FAIL` is a silent-success shape unless the artifact says so.

    When the unmutated suite does not pass, no mutant runs and nothing is
    learned. The process exits 2 — but anything reading the REPORT rather than
    the exit code would otherwise find the previous run's numbers still on disk
    and believe them.

    The report written in that case deliberately omits `summary`. Zeroing it
    would be worse than omitting it: `killed: 0, survived: 0` reads as a clean
    sheet to a naive consumer, which is exactly the confusion being prevented.
    """
    import json as _json
    src = (SCRIPTS / "palace_mutate.py").read_text()
    start = src.index('"error": "baseline-failed"')
    block = src[max(0, start - 800):start + 400]
    assert '"measured": False' in block, "the report must state that nothing was measured"
    assert '"summary"' not in block, (
        "summary must be OMITTED on a failed baseline — a zeroed one reads as 'measured clean'")


def test_baseline_failure_names_the_common_environmental_cause():
    """A failing baseline is usually the environment, not the suite.

    Observed in practice: a parallel toolkit build invalidated the shared
    DerivedData precompiled header, the baseline failed, and the obvious reading
    was 'the tests are broken'. The message points at the real cause first so the
    next person does not go hunting in the code.
    """
    src = (SCRIPTS / "palace_mutate.py").read_text()
    assert "PALACE_MUTATE_DERIVED_DATA_PATH" in src
    assert "could not measure" in src.lower()
