#!/usr/bin/env python3
"""
mutate_coverage.py — coverage-gating + equivalent-mutant suppression support
for palace_mutate.py.

Why this exists:
    palace_mutate.py mutates EVERY discovered line and runs the full resolved
    test class for each mutant. Two wastes follow:
      1. Mutating a line NO test executes is pure cost — the mutant is
         guaranteed to SURVIVE (no test runs the code, so nothing can fail),
         which both burns an xcodebuild cycle AND deflates the kill rate with
         a mutant that says nothing about test quality.
      2. Some surviving mutants are provably EQUIVALENT (e.g. a `>` vs `>=`
         on a loop bound that can never hit the boundary value). Re-flagging
         them every run is noise; humans should be able to suppress them once.

    This module gives palace_mutate.py two opt-in capabilities, both designed
    to DEGRADE GRACEFULLY to today's behavior on any failure:

      - covered_lines(): which lines a prior test run actually executed, so
        the caller can skip mutating dead lines. Returns None on ANY failure
        → caller mutates everything (today's behavior). This graceful
        degradation is the safety property that makes coverage-gating low-risk.

      - load_suppressions()/is_suppressed(): human-curated equivalent-mutant
        list, so a once-reviewed equivalent mutant stops being re-reported.

Xcode 26 coverage incantation (validated against a real .xcresult on this host):

    The .xcresult bundle embeds a coverage ARCHIVE. Two relevant forms:

      xcrun xccov view --archive --file-list <bundle.xcresult>
          → newline-delimited list of the ABSOLUTE source paths recorded in
            the archive. CRUCIAL: these are the paths *as they existed at build
            time* — on a worktree/CI build they will NOT match the current
            repo_root (we observed `.../.claude/worktrees/swarm_.../Palace/...`).
            So we never pass repo_root's path directly; we suffix-match the
            file-list against source_relpath to recover the recorded path.

      xcrun xccov view --archive --file <recorded-abs-path> --json <bundle.xcresult>
          → JSON dict keyed by that path → list of per-line entries:
              {"isExecutable": false, "line": 1}
              {"isExecutable": true,  "line": 86, "executionCount": 4}
            A line is COVERED iff isExecutable == true AND executionCount > 0.

    Passing a path that isn't in the archive yields a non-zero exit with
    "Failed to find coverage lines for ..." — which we treat as None.

Per-test attribution (tests_for_lines) is genuinely hard in Xcode 26: the
coverage archive aggregates execution counts across the WHOLE test run and
does not segment counts per-test. xcresulttool can enumerate test results but
does not expose per-test line coverage in a stable, documented form. Rather
than ship a wrong attribution map (which would cause palace_mutate to run the
WRONG narrowed test subset and grade mutants against tests that never touch the
line), this function returns None — the honest "unavailable" signal that makes
the caller fall back to running the whole resolved test class. See the function
docstring for the full rationale.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

# Storage for human-curated equivalent-mutant suppressions, keyed by source
# file leaf (basename without the .swift extension). Documented in the README
# committed alongside this module.
SUPPRESSIONS_DIRNAME = os.path.join(".forgeos", "mutation-suppressions")

# Bound the xccov subprocess so a wedged invocation can never hang a mutation
# run. Coverage extraction on a single file is sub-second in practice; a
# generous ceiling still protects against a stuck process.
_XCCOV_TIMEOUT_SEC = 120


# ---------------------------------------------------------------------------
# Coverage extraction — line-level
# ---------------------------------------------------------------------------

def _run_xccov(args: list[str]) -> str | None:
    """Run `xcrun xccov <args>` and return stdout, or None on ANY failure.

    Isolated so the parsing functions stay pure (they take already-captured
    text and are unit-testable without a real bundle). Every failure mode —
    xcrun missing, non-zero exit, timeout, OS error — collapses to None, which
    upstream means "coverage unknown, mutate everything."
    """
    try:
        result = subprocess.run(
            ["xcrun", "xccov"] + args,
            capture_output=True, text=True,
            timeout=_XCCOV_TIMEOUT_SEC, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return None
    return result.stdout


def _recorded_path_for(file_list_text: str, source_relpath: str) -> str | None:
    """Find the archive's recorded absolute path whose tail matches
    source_relpath.

    The archive records build-time paths (possibly a worktree/CI path that
    differs from the current repo_root), so we cannot reconstruct the recorded
    path — we have to discover it by suffix-matching the file-list. Pure
    function over the file-list text; unit-tested with synthetic input.

    Match rule: a recorded path matches if it ends with source_relpath at a
    path-component boundary (so `Palace/Book/Foo.swift` matches
    `/a/b/Palace/Book/Foo.swift` but `OtherFoo.swift` does NOT match `Foo.swift`).
    Returns the first match in file order, or None.
    """
    rel = source_relpath.lstrip("/")
    suffix = "/" + rel
    for line in file_list_text.splitlines():
        candidate = line.strip()
        if not candidate:
            continue
        # Exact equality OR ends with /<relpath> (component boundary).
        if candidate == rel or candidate.endswith(suffix):
            return candidate
    return None


def parse_archive_covered_lines(archive_json_text: str) -> set[int] | None:
    """Parse `xccov view --archive --file ... --json` output into the set of
    1-indexed COVERED line numbers.

    Covered := isExecutable is True AND executionCount > 0.

    Pure function over the captured text — this is the unit-tested core. Returns
    None on malformed/empty/unexpected JSON so callers fall back to no-gating.
    """
    if not archive_json_text or not archive_json_text.strip():
        return None
    try:
        data = json.loads(archive_json_text)
    except (json.JSONDecodeError, ValueError):
        return None
    # Shape: { "<recorded-abs-path>": [ {isExecutable, line, executionCount?}, ... ] }
    if not isinstance(data, dict) or not data:
        return None
    # There is exactly one key (the file we asked for); take the first list value.
    entries = None
    for value in data.values():
        if isinstance(value, list):
            entries = value
            break
    if entries is None:
        return None

    covered: set[int] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            return None  # unexpected shape — treat the whole parse as unknown
        if not entry.get("isExecutable"):
            continue
        line = entry.get("line")
        count = entry.get("executionCount", 0)
        if not isinstance(line, int):
            continue
        if isinstance(count, int) and count > 0:
            covered.add(line)
    return covered


def covered_lines(xcresult_path: str, source_relpath: str, repo_root: str) -> set[int] | None:
    """Return a set[int] of 1-indexed line numbers in source_relpath that were
    EXECUTED by the tests recorded in the xcresult bundle. Return None on ANY
    failure (bundle missing, parse error, unsupported Xcode version, file not in
    coverage). None means 'coverage unknown' and the caller MUST fall back to
    NOT gating (i.e. behave exactly as today: mutate every discovered line).
    This graceful degradation is the safety property that makes coverage-gating
    low-risk.

    repo_root is accepted for interface symmetry / future path-equivalence use;
    suffix-matching the recorded file-list against source_relpath already makes
    us robust to a build-time path that differs from repo_root, so we do not
    currently need it to locate the file.
    """
    if not xcresult_path or not os.path.exists(xcresult_path):
        return None

    file_list = _run_xccov(["view", "--archive", "--file-list", xcresult_path])
    if file_list is None:
        return None
    recorded = _recorded_path_for(file_list, source_relpath)
    if recorded is None:
        return None

    archive_json = _run_xccov(
        ["view", "--archive", "--file", recorded, "--json", xcresult_path]
    )
    if archive_json is None:
        return None
    return parse_archive_covered_lines(archive_json)


# ---------------------------------------------------------------------------
# Per-test attribution — intentionally stubbed to None (see module docstring)
# ---------------------------------------------------------------------------

def tests_for_lines(xcresult_path: str, source_relpath: str, lines, repo_root: str):
    """Best-effort per-test attribution for TEST SELECTION. Given a set[int] of
    lines, return dict[int, list[str]] mapping each line to the
    'PalaceTests/<Class>/<method>' selectors whose execution covered it. Return
    None if per-test coverage is unavailable in this xcresult (then the caller
    falls back to running the whole resolved test class — today's behavior).
    Partial maps are fine: a line absent from the dict means 'unknown, run the
    full class'.

    IMPLEMENTATION NOTE — this returns None by design.

    Xcode 26's coverage archive aggregates execution counts across the ENTIRE
    test run; it does not segment counts per individual test. There is no stable,
    documented xcresulttool form that yields per-test LINE coverage. The only way
    to get true per-test attribution would be to run each test in isolation with
    coverage on and diff the archives — which is exactly the expensive thing this
    tooling exists to avoid.

    Returning a WRONG map is actively harmful: the caller would narrow the test
    selection to a subset that does NOT actually exercise the mutated line, then
    grade the mutant as SURVIVED against tests that could never kill it —
    silently deflating the kill rate and lying about coverage. Returning None is
    the honest, safe signal: "attribution unavailable, run the full class."

    The signature is kept stable so a future Xcode that exposes per-test
    coverage (or an isolation-based implementation behind a flag) can fill this
    in without touching the caller.
    """
    return None


# ---------------------------------------------------------------------------
# Equivalent-mutant suppressions
# ---------------------------------------------------------------------------

def _suppressions_path(repo_root: str, source_relpath: str) -> str:
    leaf = os.path.basename(source_relpath)
    if leaf.endswith(".swift"):
        leaf = leaf[: -len(".swift")]
    return os.path.join(repo_root, SUPPRESSIONS_DIRNAME, f"{leaf}.json")


def load_suppressions(repo_root: str, source_relpath: str) -> list:
    """Load human-curated equivalent-mutant suppressions for this source file.

    Storage: .forgeos/mutation-suppressions/<file-leaf-without-.swift>.json,
    a JSON list of objects:
        {"line_text": "...", "original": ">=", "mutated": ">",
         "reason": "loop bound is provably equivalent"}
    line_text is compared STRIPPED of leading/trailing whitespace (matching is
    done in is_suppressed). Returns [] if the file is absent OR malformed — a
    broken suppressions file must never crash a mutation run, it just suppresses
    nothing.
    """
    path = _suppressions_path(repo_root, source_relpath)
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError, ValueError):
        return []
    if not isinstance(data, list):
        return []
    # Keep only well-formed entries (dicts carrying the three match keys);
    # tolerate extra keys like "reason".
    clean = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        if "line_text" in entry and "original" in entry and "mutated" in entry:
            clean.append(entry)
    return clean


def is_suppressed(suppressions: list, line_text: str, original: str, mutated: str) -> bool:
    """True iff (line_text.strip(), original, mutated) matches a suppression
    entry. Pure function, trivially unit-testable without any xcresult.

    line_text comparison is whitespace-insensitive on BOTH sides (the stored
    entry and the live line are each stripped) so a re-indent doesn't silently
    un-suppress a reviewed equivalent mutant. original/mutated must match exactly
    (they are operator tokens, not free text).
    """
    if not suppressions:
        return False
    target_line = (line_text or "").strip()
    for entry in suppressions:
        if not isinstance(entry, dict):
            continue
        if (str(entry.get("line_text", "")).strip() == target_line
                and entry.get("original") == original
                and entry.get("mutated") == mutated):
            return True
    return False


if __name__ == "__main__":
    # Minimal CLI for manual inspection: print covered lines for a file given an
    # xcresult bundle. Not used by palace_mutate (it imports the callables) — this
    # is purely a debugging aid.
    if len(sys.argv) != 3:
        print("usage: mutate_coverage.py <bundle.xcresult> <source-relpath>", file=sys.stderr)
        sys.exit(2)
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    cov = covered_lines(sys.argv[1], sys.argv[2], repo_root)
    if cov is None:
        print("coverage unknown (None) — caller would mutate every line")
        sys.exit(1)
    print(f"{len(cov)} covered line(s): {sorted(cov)}")
