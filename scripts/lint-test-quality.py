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
        # wait(for:) on an XCTestExpectation IS an assertion — it raises
        # XCTFail on timeout. Treating it the same as XCTAssert* fixes a
        # false-positive MISSING-001 on legitimate expectation-based tests.
        asserts = len(re.findall(r'XCTAssert|XCTFail|wait\(for:', body))
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

def lint_file(filepath: str) -> List[Violation]:
    """Lint a single test file for quality violations."""
    violations = []

    with open(filepath) as f:
        content = f.read()

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

        # Check: no assertions at all
        if method['assert_count'] == 0 and 'XCTSkip' not in body:
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

    # Summary by severity
    fluff = sum(1 for v in all_violations if v.rule.startswith('FLUFF'))
    shallow = sum(1 for v in all_violations if v.rule.startswith('SHALLOW'))
    missing = sum(1 for v in all_violations if v.rule.startswith('MISSING'))
    print(f"  Fluff (should replace):    {fluff}")
    print(f"  Shallow (should deepen):   {shallow}")
    print(f"  Missing asserts (broken):  {missing}")

    if fix_mode:
        print("\n--fix mode: review violations above and replace manually.")
        print("Each fluff test should be replaced 1:1 with a test that exercises")
        print("real logic in the same class (edge case, error path, state transition).")

    # Exit with error if there are MISSING assertion tests (those are actually broken)
    if missing > 0:
        sys.exit(1)

    sys.exit(0)

if __name__ == '__main__':
    main()
