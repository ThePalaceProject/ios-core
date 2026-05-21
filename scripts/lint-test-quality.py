#!/usr/bin/env python3
"""
Test quality linter for Palace iOS.

Scans test files for common fluff patterns and reports them.
Run as a pre-commit check or CI gate to prevent low-quality tests.

Usage:
    python3 scripts/lint-test-quality.py [--fix] [--file PATH]

    --fix   Show suggested replacements (does not auto-apply)
    --file  Lint a single file instead of all PalaceTests/
"""

import re
import os
import sys
from dataclasses import dataclass
from typing import List

@dataclass
class Violation:
    file: str
    line: int
    method: str
    rule: str
    detail: str

FLUFF_PATTERNS = [
    # Pattern: set property then assert it
    (r'(\w+)\.(\w+)\s*=\s*(.+)\n\s*XCTAssert\w+\(\1\.\2',
     "FLUFF-001: Property set-then-assert. Tests Swift's property system, not your code."),

    # Pattern: toggle bool then assert
    (r'(\w+)\.(\w+)\s*=\s*true\n\s*XCTAssertTrue\(\1\.\2\)',
     "FLUFF-002: Bool toggle assertion. Will never fail unless Swift breaks."),

    # Pattern: assert non-nil on constructor
    (r'let \w+ = \w+\([^)]*\)\s*\n\s*XCTAssertNotNil\(',
     "FLUFF-003: Constructor non-nil check. Swift guarantees non-optional init returns non-nil."),

    # Pattern: enum raw value assertion
    (r'XCTAssertEqual\(\w+\.\w+\.rawValue,\s*["\d]',
     "FLUFF-004: Enum raw value assertion. Tests the enum definition, not behavior."),
]

# Methods/calls that act as assertions (raise XCTFail on failure). The linter
# treats any of these the same as a direct XCTAssert call when counting whether
# a test has *any* failable expectations. Keeping this in one place avoids
# false MISSING-001 on tests that fail via helpers (ContractSnapshot, the
# drainMainQueue family) instead of bare XCTAssert calls.
ASSERTION_EQUIVALENT_PATTERN = re.compile(
    r'XCTAssert'                       # All XCTAssert* variants
    r'|XCTFail\b'                      # Direct fail
    r'|wait\(for:'                     # Expectation wait (fails on timeout)
    r'|fulfillment\(of:'               # async-aware expectation wait
    r'|ContractSnapshot\.assert'       # CallLog + JSON snapshot (Contract/)
    r'|drainMainQueue\b'               # XCTestCase+drainMainQueue helper
    r'|awaitCondition\b'               # Sync-predicate poll helper
    r'|awaitConditionAsync\b'          # Async-predicate poll helper
    # Custom assertion helpers — any `assert<Word>(` (capitalized first
    # letter after the prefix) or `.assert<Word>(` method call. Catches
    # `assertValidationSuccess(...)`, `f.assertText(...)`,
    # `f.assertContainsText(...)`, etc. without also matching Swift's
    # bare `assert(condition, _:)` (lowercase next char). Misses tests
    # that route through helpers with no `assert` prefix — those should
    # rename their helper to `assertX` or add the helper here.
    r'|(?<![\w])assert[A-Z]\w*\('
    r'|\.assert[A-Z]\w*\('
)

# Flake patterns. Hard-blocking in verify-pr.sh. Each entry is
# (regex, rule_text, dotall_flag). Allow-listing is per-line via a
# `// FLAKE-NNN-OK: <reason>` comment on the matched line — keeps rare
# legitimate cases (integration tests, large-corpus loads) explicit instead
# of relying on a global SKIP list.
FLAKE_PATTERNS = [
    # Raw sleep in test bodies. Thread.sleep / usleep / nanosleep / bare sleep().
    # Fixed-delay waits — first thing that breaks under CI contention.
    (r'\b(Thread\.sleep|usleep|nanosleep)\b|(?<![\w.])sleep\(\s*\d',
     "FLAKE-001: Raw sleep in test. Use XCTestExpectation, drainMainQueue, or awaitCondition.",
     False),

    # asyncAfter used as sleep-disguised-as-expectation. Matches an
    # `asyncAfter` whose closure body is *only* `<expectation>.fulfill()`.
    # That's the banned pattern from CLAUDE.md — fixed delay that fails
    # under load. CLAUDE.md: "never use sleep/delay waits, always use
    # XCTestExpectation". XCTestCase+drainMainQueue.swift is the migration.
    # `.*?` (non-greedy) is needed because the deadline arg contains nested
    # parens — `.now() + 0.5` — and `[^)]+` chokes on the inner `.now()`.
    (r'asyncAfter\(deadline:.*?\)\s*\{\s*\w+\.fulfill\(\s*\)\s*\}',
     "FLAKE-002: asyncAfter used as sleep-disguised-as-expectation. Use drainMainQueue or awaitCondition.",
     True),

    # Timeouts >= 15s. Almost always symptomatic of FLAKE-002 or hidden
    # real-I/O. The 15s floor is empirical: large-corpus tests, integration
    # tests, and a few coldstart paths legitimately need >=15s — allow-list
    # those with `// FLAKE-003-OK: <reason>` on the same line.
    (r'timeout:\s*(\d{2,}\.?\d*)',
     "FLAKE-003: Timeout >= 15s. Symptomatic of FLAKE-002 or real-I/O leak. "
     "Allow with `// FLAKE-003-OK: <reason>` if integration-test scoped.",
     False),
]

# Per-rule allow-list comment regex. A line carrying its rule's comment
# suppresses the violation on that line only (or, for MISSING-001, anywhere
# in the test body). Keep the allow-list comment self-documenting:
#
#     // FLAKE-001-OK: NetworkRetryTests exercises real retry-backoff timing;
#     //               the 50ms Thread.sleep is intentional, not a flake.
#     // MISSING-001-OK: crash-guard — passes if `setProblemDocument(nil:)`
#     //                 doesn't deref-nil. No state to assert on.
ALLOWLIST_COMMENT_RE = {
    'FLAKE-001': re.compile(r'//\s*FLAKE-001-OK'),
    'FLAKE-002': re.compile(r'//\s*FLAKE-002-OK'),
    'FLAKE-003': re.compile(r'//\s*FLAKE-003-OK'),
    'MISSING-001': re.compile(r'//\s*MISSING-001-OK'),
}

# File-level patterns — scanned across the whole file, not just inside
# `func test*` bodies. Helper functions (private) live outside test
# methods but harbor structural test-infrastructure bugs that show up as
# misleading assertion failures inside the tests that call them.

# Files exempt from TIMEOUT-001. Each entry needs a written reason so a
# future reader understands WHY this file is allowlisted instead of
# silently filtering it out.
#
# Keep this list small. Prefer fixing the rule's heuristic (below) to
# catch a loud-via-X pattern over hardcoding an allowlist entry.
# CatalogDomain helpers used to live here — removed once the
# `is_loud_via_xctfail` heuristic was confirmed to catch them.
SILENT_TIMEOUT_ALLOWLIST = {
    "PalaceTests/XCTestCase+drainMainQueue.swift":
        "Canonical implementation — `awaitConditionAsync` is the helper this rule recommends.",
    "PalaceTests/Logging/LogTests.swift":
        "pollForLog returns the polled value; caller asserts on its contents — informative downstream failure.",
}

def lint_silent_timeout(content: str, filepath: str) -> List["Violation"]:
    """
    TIMEOUT-001: silent `while Date() < deadline` polling loops in tests.

    The disease: a polling helper that silently `return`s on timeout
    causes the next assertion to read stale values and surface as a
    misleading downstream-assertion failure ("0 != 1") instead of a
    clear "the poll timed out" message. See PR #983 for the rationale +
    PalaceTests/XCTestCase+drainMainQueue.swift `awaitConditionAsync`
    for the recommended replacement.

    Heuristic: flag any `while Date() < deadline` whose enclosing
    function neither (a) ends with an explicit `XCTFail`, nor
    (b) returns Bool back to a loud caller, nor (c) is in the
    allowlist above with a documented reason.
    """
    if filepath in SILENT_TIMEOUT_ALLOWLIST:
        return []

    findings: List[Violation] = []
    # Use a multi-line regex anchored to line start (with optional
    # leading whitespace) to skip the same pattern appearing inside
    # `///` doc comments that describe the anti-pattern. Skipping doc-
    # comments via a separate strip pass risks shifting line numbers in
    # the reported violation — anchoring is simpler.
    for m in re.finditer(r'^\s*while Date\(\) < deadline', content, re.MULTILINE):
        # Look at the surrounding window for indicators of "this helper
        # is actually loud." The pre-window (~300 chars before the
        # match) catches the function signature + any `expectation`
        # declarations that precede the while loop; the post-window
        # (~600 chars after) catches XCTFail/return-condition at the
        # end of the helper body.
        window_start = max(0, m.start() - 300)
        window_end = min(len(content), m.end() + 600)
        window = content[window_start:window_end]

        is_loud_via_xctfail = 'XCTFail(' in window
        # Bool-returning helpers end with `return condition()` or
        # `return predicate()` — caller checks the bool to surface the
        # timeout (XCTAssertTrue(waitForCondition...)) so the loop
        # itself doesn't need XCTFail.
        is_loud_via_bool_return = bool(re.search(r'return\s+(?:condition|predicate)\(\)', window))
        # An outer XCTestExpectation + wait(for:) makes the surrounding
        # test loud even if the inline loop is silent — the expectation
        # never fulfills and the outer wait fires.
        is_loud_via_expectation = ('XCTestExpectation' in window or 'expectation(description:' in window) and 'wait(for:' in window

        if is_loud_via_xctfail or is_loud_via_bool_return or is_loud_via_expectation:
            continue

        line_no = content[:m.start()].count('\n') + 1
        findings.append(Violation(
            file=filepath,
            line=line_no,
            method='<file scope>',
            rule="TIMEOUT-001",
            detail="TIMEOUT-001: silent `while Date() < deadline` polling loop. "
                   "Use `awaitConditionAsync` from PalaceTests/XCTestCase+drainMainQueue.swift — "
                   "fails the test loudly on timeout with accurate file/line attribution. "
                   "If this loop IS intentionally silent, add the file to "
                   "SILENT_TIMEOUT_ALLOWLIST in scripts/lint-test-quality.py with a written reason.",
        ))
    return findings

def find_test_methods(content: str) -> List[dict]:
    """Extract test methods with their bodies and line numbers."""
    methods = []
    for m in re.finditer(r'(func (test\w+)\([^)]*\)[^{]*\{)', content):
        name = m.group(2)
        start_line = content[:m.start()].count('\n') + 1
        start = m.end()

        depth = 1
        i = start
        while i < len(content) and depth > 0:
            if content[i] == '{': depth += 1
            elif content[i] == '}': depth -= 1
            i += 1
        body = content[start:i-1]

        lines = [l.strip() for l in body.split('\n') if l.strip() and not l.strip().startswith('//')]
        # Count assertion-equivalents — XCTAssert*, XCTFail, wait/fulfillment,
        # ContractSnapshot.assert, drainMainQueue, awaitCondition*. Routed
        # through ASSERTION_EQUIVALENT_PATTERN (top of file) so the helper set
        # lives in one place; missing any of these used to flag legitimate
        # helper-based tests as MISSING-001.
        asserts = len(ASSERTION_EQUIVALENT_PATTERN.findall(body))
        has_mock = bool(re.search(r'Mock|mock|stub|Stub', body))
        has_async = bool(re.search(r'await |expectation|fulfillment', body))

        methods.append({
            'name': name,
            'body': body,
            'line': start_line,
            'lines_count': len(lines),
            'assert_count': asserts,
            'has_mock': has_mock,
            'has_async': has_async,
        })
    return methods

def lint_flake_patterns(content: str, filepath: str) -> List[Violation]:
    """
    Scan whole file for FLAKE-* patterns. File-scope (not method-scope) so
    private setup helpers, fixture builders, and async closures captured by
    `Task { ... }` blocks are caught alongside test bodies. The matched-line
    text is checked for the per-rule allow-list comment.
    """
    findings: List[Violation] = []
    file_lines = content.split('\n')
    for pattern, rule_text, dotall in FLAKE_PATTERNS:
        flags = re.MULTILINE | (re.DOTALL if dotall else 0)
        for m in re.finditer(pattern, content, flags):
            rule_id = rule_text.split(':')[0]
            line_no = content[:m.start()].count('\n') + 1
            # Skip if the matched line carries the allow-list comment.
            matched_line = file_lines[line_no - 1] if 1 <= line_no <= len(file_lines) else ''
            if ALLOWLIST_COMMENT_RE[rule_id].search(matched_line):
                continue
            # FLAKE-003 floor: rule fires only at >= 15s. The regex grabs
            # 2+ digit timeouts (10..); filter the 10..14 second cases out
            # here. Below 10s legitimately means tight expectation, no flake.
            if rule_id == 'FLAKE-003':
                try:
                    val = float(m.group(1))
                    if val < 15.0:
                        continue
                except (IndexError, ValueError):
                    continue
            findings.append(Violation(
                file=filepath,
                line=line_no,
                method='<file scope>',
                rule=rule_id,
                detail=rule_text,
            ))
    return findings

def lint_file(filepath: str) -> List[Violation]:
    """Lint a single test file for quality violations."""
    violations = []

    with open(filepath) as f:
        content = f.read()

    # File-level checks (scan the whole file body, not just inside test
    # methods — covers private helpers + inline patterns).
    violations.extend(lint_silent_timeout(content, filepath))
    violations.extend(lint_flake_patterns(content, filepath))

    methods = find_test_methods(content)

    for method in methods:
        body = method['body']

        # Check fluff patterns
        for pattern, rule in FLUFF_PATTERNS:
            if re.search(pattern, body):
                violations.append(Violation(
                    file=filepath,
                    line=method['line'],
                    method=method['name'],
                    rule=rule.split(':')[0],
                    detail=rule,
                ))

        # Check: test with only 1 assertion and < 4 lines of real code
        if method['assert_count'] <= 1 and method['lines_count'] <= 4:
            if not method['has_mock'] and not method['has_async']:
                violations.append(Violation(
                    file=filepath,
                    line=method['line'],
                    method=method['name'],
                    rule="SHALLOW-001",
                    detail="SHALLOW-001: Test has 1 assertion, <4 lines, no mocks/async. Likely too shallow to catch regressions.",
                ))

        # Check: no assertions at all. Authors can opt-out with a
        # `// MISSING-001-OK: <reason>` comment in the test body for
        # legitimate crash-guard tests (where the assertion IS "did not
        # crash"). Forces the reason to be documented inline rather than
        # silently allowed.
        if method['assert_count'] == 0 and 'XCTSkip' not in body:
            if not ALLOWLIST_COMMENT_RE['MISSING-001'].search(body):
                violations.append(Violation(
                    file=filepath,
                    line=method['line'],
                    method=method['name'],
                    rule="MISSING-001",
                    detail="MISSING-001: Test has no assertions. It can never fail.",
                ))

    return violations

def main():
    fix_mode = '--fix' in sys.argv
    # `--per-file` emits one line per violation: <relpath>:<line>:<rule>
    # That gives verify-pr.sh a machine-parseable per-file view so it can
    # distinguish blocking rules (FLAKE/FLUFF/MISSING/TIMEOUT) from
    # advisory (SHALLOW) when deciding whether to fail this PR.
    per_file_mode = '--per-file' in sys.argv
    single_file = None
    if '--file' in sys.argv:
        idx = sys.argv.index('--file')
        if idx + 1 < len(sys.argv):
            single_file = sys.argv[idx + 1]

    if single_file:
        files = [single_file]
    else:
        files = []
        for root, dirs, fnames in os.walk('PalaceTests'):
            dirs[:] = [d for d in dirs if d not in ('__Snapshots__', '.build')]
            for f in fnames:
                if f.endswith('.swift'):
                    files.append(os.path.join(root, f))

    all_violations = []
    for filepath in sorted(files):
        violations = lint_file(filepath)
        all_violations.extend(violations)

    if per_file_mode:
        # One line per violation. Format: `<relpath>:<line>:<rule>`
        # Designed for `grep` in CI — verify-pr.sh greps for blocking
        # rule prefixes within the changed-file list.
        for v in all_violations:
            print(f"{os.path.relpath(v.file)}:{v.line}:{v.rule}")
        # Exit code mirrors the human-mode exit code so callers can use
        # both modes interchangeably for the pass/fail signal.
        missing = sum(1 for v in all_violations if v.rule.startswith('MISSING'))
        timeout = sum(1 for v in all_violations if v.rule.startswith('TIMEOUT'))
        flake = sum(1 for v in all_violations if v.rule.startswith('FLAKE'))
        sys.exit(1 if (missing or timeout or flake) else 0)

    # Group by rule
    by_rule = {}
    for v in all_violations:
        by_rule.setdefault(v.rule, []).append(v)

    # Report
    if not all_violations:
        print("No test quality violations found.")
        sys.exit(0)

    print(f"Test Quality Report: {len(all_violations)} violations in {len(files)} files")
    print("=" * 70)

    for rule, violations in sorted(by_rule.items()):
        print(f"\n{violations[0].detail}")
        print(f"  Count: {len(violations)}")
        for v in violations[:5]:
            rel_path = os.path.relpath(v.file)
            print(f"    {rel_path}:{v.line} — {v.method}")
        if len(violations) > 5:
            print(f"    ... and {len(violations) - 5} more")

    print(f"\n{'=' * 70}")
    print(f"Total: {len(all_violations)} violations across {len(set(v.file for v in all_violations))} files")

    # Summary by family
    fluff = sum(1 for v in all_violations if v.rule.startswith('FLUFF'))
    shallow = sum(1 for v in all_violations if v.rule.startswith('SHALLOW'))
    missing = sum(1 for v in all_violations if v.rule.startswith('MISSING'))
    timeout = sum(1 for v in all_violations if v.rule.startswith('TIMEOUT'))
    flake = sum(1 for v in all_violations if v.rule.startswith('FLAKE'))
    print(f"  Flake   (blocking — CI-fragile):   {flake}")
    print(f"  Fluff   (should replace):          {fluff}")
    print(f"  Shallow (should deepen):           {shallow}")
    print(f"  Missing (broken — no assertion):   {missing}")
    print(f"  Silent timeouts (CI-flake fuel):   {timeout}")

    if fix_mode:
        print("\n--fix mode: review violations above and replace manually.")
        print("Each fluff test should be replaced 1:1 with a test that exercises")
        print("real logic in the same class (edge case, error path, state transition).")

    # Exit with error on MISSING (broken tests that can never fail), TIMEOUT
    # (silent-timeout polling — PR #983), and FLAKE (raw sleep / asyncAfter
    # as expectation / pathological >=15s timeouts — the actual flake driver
    # behind the CI-flake pandemic this sweep addresses). All three are
    # structural CI-fragility patterns gated against reintroduction.
    if missing > 0 or timeout > 0 or flake > 0:
        sys.exit(1)

    sys.exit(0)

if __name__ == '__main__':
    main()
