#!/usr/bin/env python3
"""
Parse xcresult bundle to extract comprehensive test metrics.
Usage: python3 parse-xcresult.py <path-to-xcresult> [--json <output.json>]

Outputs:
  - GitHub Actions format to GITHUB_OUTPUT
  - Detailed JSON file with all test data
  - Human-readable summary to stderr
"""
import json
import subprocess
import sys
import os
from collections import defaultdict
from typing import Dict, List, Any, Optional

def run_xcresulttool(xcresult_path: str, ref_id: str = None) -> Optional[Dict]:
    """Run xcresulttool and return parsed JSON."""
    # Build command - use legacy flag for newer Xcode
    cmd = ['xcrun', 'xcresulttool', 'get', '--legacy', '--path', xcresult_path, '--format', 'json']
    if ref_id:
        cmd.extend(['--id', ref_id])
    
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
        
        # If legacy failed with deprecation, try without
        if 'deprecated' in result.stderr.lower() or 'legacy' in result.stderr.lower():
            cmd = ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--format', 'json']
            if ref_id:
                cmd.extend(['--id', ref_id])
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            if result.returncode == 0 and result.stdout.strip():
                return json.loads(result.stdout)
        
        print(f"xcresulttool stderr: {result.stderr[:200]}", file=sys.stderr)
    except json.JSONDecodeError as e:
        print(f"JSON parse error: {e}", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("xcresulttool timed out", file=sys.stderr)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
    return None

def extract_value(obj: Any) -> Any:
    """Extract _value from xcresult typed object."""
    if isinstance(obj, dict):
        if '_value' in obj:
            return obj['_value']
        if '_values' in obj:
            return obj['_values']
    return obj

def parse_duration(duration_obj: Any) -> float:
    """Parse duration to seconds."""
    val = extract_value(duration_obj)
    try:
        return float(val) if val else 0.0
    except (ValueError, TypeError):
        return 0.0

def format_duration(seconds: float) -> str:
    """Format duration for display."""
    if seconds < 0.001:
        return "<1ms"
    elif seconds < 1:
        return f"{seconds*1000:.0f}ms"
    elif seconds < 60:
        return f"{seconds:.2f}s"
    else:
        mins = int(seconds // 60)
        secs = seconds % 60
        return f"{mins}m {secs:.0f}s"

def find_tests_in_subtests(obj: Any, tests: List[Dict], parent_class: str = ""):
    """Recursively find individual tests in subtests hierarchy."""
    if not isinstance(obj, dict):
        return
    
    obj_type = obj.get('_type', {})
    type_name = obj_type.get('_name', '') if isinstance(obj_type, dict) else ''
    
    # ActionTestMetadata is an individual test
    if type_name == 'ActionTestMetadata':
        test_name = extract_value(obj.get('name', {}))
        test_status = extract_value(obj.get('testStatus', {}))
        identifier = extract_value(obj.get('identifier', {}))
        duration = parse_duration(obj.get('duration', {}))
        
        if test_name and test_status:
            # Parse identifier: "ClassName/testMethod()"
            test_id = identifier or test_name
            parts = test_id.replace('()', '').split('/')
            
            test_method = parts[-1] if parts else test_name.replace('()', '')
            test_class = parts[-2] if len(parts) >= 2 else parent_class or "UnknownClass"
            
            tests.append({
                'name': test_name.replace('()', ''),
                'method': test_method,
                'class': test_class,
                'identifier': test_id,
                'status': test_status,
                'duration': duration,
                'duration_formatted': format_duration(duration),
                'failures': []  # Would need to query summaryRef for details
            })
        return
    
    # ActionTestSummaryGroup is a container (class or test bundle)
    if type_name == 'ActionTestSummaryGroup':
        group_name = extract_value(obj.get('name', {})) or extract_value(obj.get('identifier', {}))
        # Recurse into subtests
        subtests = obj.get('subtests', {})
        subtest_values = extract_value(subtests)
        if isinstance(subtest_values, list):
            for subtest in subtest_values:
                find_tests_in_subtests(subtest, tests, group_name)
        return
    
    # Recurse into any subtests
    subtests = obj.get('subtests', {})
    subtest_values = extract_value(subtests)
    if isinstance(subtest_values, list):
        for subtest in subtest_values:
            find_tests_in_subtests(subtest, tests, parent_class)

def get_tests_from_xcresult(xcresult_path: str) -> List[Dict]:
    """Extract all tests from xcresult bundle."""
    tests = []
    
    # Get main xcresult data
    print("Loading xcresult main data...", file=sys.stderr)
    main_data = run_xcresulttool(xcresult_path)
    if not main_data:
        print("Failed to load xcresult", file=sys.stderr)
        return tests
    
    # Get testsRef from actions
    actions = main_data.get('actions', {}).get('_values', [])
    if not actions:
        print("No actions found", file=sys.stderr)
        return tests
    
    for action in actions:
        action_result = action.get('actionResult', {})
        tests_ref = action_result.get('testsRef', {})
        tests_ref_id = extract_value(tests_ref.get('id', {}))
        
        if not tests_ref_id:
            print("No testsRef found in action", file=sys.stderr)
            continue
        
        print(f"Querying testsRef: {tests_ref_id[:50]}...", file=sys.stderr)
        
        # Get detailed test results
        tests_data = run_xcresulttool(xcresult_path, tests_ref_id)
        if not tests_data:
            print("Failed to load tests data", file=sys.stderr)
            continue
        
        # Parse test plan run summaries
        summaries = tests_data.get('summaries', {}).get('_values', [])
        for summary in summaries:
            testable_summaries = summary.get('testableSummaries', {}).get('_values', [])
            for testable in testable_summaries:
                test_values = testable.get('tests', {}).get('_values', [])
                for test_group in test_values:
                    find_tests_in_subtests(test_group, tests)
    
    return tests

def deduplicate_tests(tests: List[Dict]) -> List[Dict]:
    """Remove duplicate tests."""
    seen = set()
    unique = []
    for test in tests:
        key = (test.get('identifier', ''), test.get('status', ''))
        if key not in seen and test.get('name'):
            seen.add(key)
            unique.append(test)
    return unique

def group_tests_by_class(tests: List[Dict]) -> Dict[str, Dict]:
    """Group tests by class with statistics."""
    grouped = defaultdict(lambda: {'tests': [], 'stats': {}})
    
    for test in tests:
        class_name = test.get('class', 'Unknown')
        grouped[class_name]['tests'].append(test)
    
    for class_name, class_data in grouped.items():
        class_tests = class_data['tests']
        total = len(class_tests)
        passed = sum(1 for t in class_tests if t['status'] == 'Success')
        failed = sum(1 for t in class_tests if t['status'] == 'Failure')
        skipped = sum(1 for t in class_tests if t['status'] == 'Skipped')
        total_duration = sum(t['duration'] for t in class_tests)
        
        class_data['stats'] = {
            'total': total,
            'passed': passed,
            'failed': failed,
            'skipped': skipped,
            'duration': total_duration,
            'duration_formatted': format_duration(total_duration)
        }
    
    return dict(sorted(grouped.items()))

def generate_report(xcresult_path: str) -> Dict:
    """Generate comprehensive test report."""
    print(f"Parsing: {xcresult_path}", file=sys.stderr)
    
    tests = get_tests_from_xcresult(xcresult_path)
    tests = deduplicate_tests(tests)
    
    print(f"Found {len(tests)} tests", file=sys.stderr)
    
    total = len(tests)
    passed = sum(1 for t in tests if t['status'] == 'Success')
    failed = sum(1 for t in tests if t['status'] == 'Failure')
    skipped = sum(1 for t in tests if t['status'] == 'Skipped')
    total_duration = sum(t['duration'] for t in tests)
    
    classes = group_tests_by_class(tests)
    failed_tests = [t for t in tests if t['status'] == 'Failure']
    
    return {
        'success': True,
        'xcresult_path': xcresult_path,
        'summary': {
            'tests': total,
            'passed': passed,
            'failed': failed,
            'skipped': skipped,
            'duration': total_duration,
            'duration_formatted': format_duration(total_duration),
            'pass_rate': f"{(passed/total*100):.1f}%" if total > 0 else "N/A"
        },
        'tests': sorted(tests, key=lambda t: (t.get('class', ''), t.get('name', ''))),
        'classes': classes,
        'failed_tests': failed_tests
    }

def output_github_actions(report: Dict, output_file: str):
    """Write results in GitHub Actions output format."""
    summary = report['summary']
    failed_tests = report.get('failed_tests', [])
    classes = report.get('classes', {})
    
    with open(output_file, 'a') as f:
        f.write(f"tests={summary['tests']}\n")
        f.write(f"passed={summary['passed']}\n")
        f.write(f"failed={summary['failed']}\n")
        f.write(f"skipped={summary['skipped']}\n")
        f.write(f"duration={summary.get('duration_formatted', 'unknown')}\n")
        f.write(f"pass_rate={summary.get('pass_rate', 'N/A')}\n")
        
        if failed_tests:
            f.write("failed_tests<<ENDOFFAILEDTESTS\n")
            for test in failed_tests[:30]:
                f.write(f"{test['class']}.{test['method']}\n")
            f.write("ENDOFFAILEDTESTS\n")
        
        if classes:
            f.write("class_summary<<ENDOFCLASSSUMMARY\n")
            for class_name, class_data in sorted(classes.items()):
                stats = class_data['stats']
                f.write(f"{class_name}|{stats['total']}|{stats['passed']}|{stats['failed']}|{stats['duration_formatted']}\n")
            f.write("ENDOFCLASSSUMMARY\n")

def print_summary(report: Dict):
    """Print human-readable summary."""
    summary = report['summary']
    
    print("\n" + "=" * 60, file=sys.stderr)
    print("TEST RESULTS SUMMARY", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"Total Tests:  {summary['tests']}", file=sys.stderr)
    print(f"Passed:       {summary['passed']} ✓", file=sys.stderr)
    print(f"Failed:       {summary['failed']} ✗", file=sys.stderr)
    print(f"Skipped:      {summary['skipped']} ⊘", file=sys.stderr)
    print(f"Duration:     {summary.get('duration_formatted', 'unknown')}", file=sys.stderr)
    print(f"Pass Rate:    {summary.get('pass_rate', 'N/A')}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    
    if report.get('failed_tests'):
        print("\nFAILED TESTS:", file=sys.stderr)
        for test in report['failed_tests'][:10]:
            print(f"  ✗ {test['class']}.{test['method']}", file=sys.stderr)
    
    classes = report.get('classes', {})
    if classes:
        print("\nTESTS BY CLASS:", file=sys.stderr)
        for class_name, class_data in sorted(classes.items()):
            stats = class_data['stats']
            icon = "✓" if stats['failed'] == 0 else "✗"
            print(f"  {icon} {class_name}: {stats['passed']}/{stats['total']} ({stats['duration_formatted']})", file=sys.stderr)
    
    print("", file=sys.stderr)

def main():
    if len(sys.argv) < 2:
        print("Usage: parse-xcresult.py <path-to-xcresult> [--json <output.json>]", file=sys.stderr)
        sys.exit(1)
    
    xcresult_path = sys.argv[1]
    json_output_path = 'test-data.json'
    
    if '--json' in sys.argv:
        idx = sys.argv.index('--json')
        if idx + 1 < len(sys.argv):
            json_output_path = sys.argv[idx + 1]
    
    if not os.path.exists(xcresult_path):
        print(f"Error: {xcresult_path} not found", file=sys.stderr)
        sys.exit(1)
    
    report = generate_report(xcresult_path)
    print_summary(report)
    
    github_output = os.environ.get('GITHUB_OUTPUT', '')
    if github_output:
        output_github_actions(report, github_output)
        print(f"Wrote GitHub Actions output", file=sys.stderr)
    
    with open(json_output_path, 'w') as f:
        json.dump(report, f, indent=2)
    print(f"Wrote JSON: {json_output_path}", file=sys.stderr)

if __name__ == '__main__':
    main()
