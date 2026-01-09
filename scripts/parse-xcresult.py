#!/usr/bin/env python3
"""
Parse xcresult bundle to extract comprehensive test metrics.
Usage: python3 parse-xcresult.py <path-to-xcresult> [--json <output.json>]

Supports both new xcresulttool API (Xcode 16+) and legacy API.

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
from typing import Dict, List, Any, Optional, Tuple


def run_command(cmd: List[str], timeout: int = 120) -> Tuple[bool, str, str]:
    """Run command and return (success, stdout, stderr)."""
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return result.returncode == 0, result.stdout, result.stderr
    except subprocess.TimeoutExpired:
        return False, "", "Command timed out"
    except Exception as e:
        return False, "", str(e)


def get_test_results_new_api(xcresult_path: str) -> Optional[Dict]:
    """
    Use new xcresulttool API (Xcode 16+).
    Returns parsed summary data.
    """
    # Get summary
    success, stdout, stderr = run_command([
        'xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
        '--path', xcresult_path
    ])
    
    if not success or not stdout.strip():
        print(f"New API summary failed: {stderr[:200]}", file=sys.stderr)
        return None
    
    try:
        return json.loads(stdout)
    except json.JSONDecodeError as e:
        print(f"JSON parse error (new API summary): {e}", file=sys.stderr)
        return None


def get_all_tests_new_api(xcresult_path: str) -> List[Dict]:
    """
    Use new xcresulttool API to get all tests.
    """
    success, stdout, stderr = run_command([
        'xcrun', 'xcresulttool', 'get', 'test-results', 'tests',
        '--path', xcresult_path
    ])
    
    if not success or not stdout.strip():
        print(f"New API tests failed: {stderr[:200]}", file=sys.stderr)
        return []
    
    try:
        data = json.loads(stdout)
        tests = []
        
        # Debug: Show top-level structure
        if isinstance(data, dict):
            top_keys = list(data.keys())[:10]
            print(f"New API response keys: {top_keys}", file=sys.stderr)
        
        # The new API returns testNodes as root
        if isinstance(data, dict):
            # Try multiple possible container keys
            test_list = (
                data.get('testNodes') or
                data.get('tests') or
                data.get('children') or
                [data]  # The data itself might be a single node
            )
            if isinstance(test_list, list):
                for test in test_list:
                    tests.extend(parse_test_node_new_api(test))
            print(f"Parsed {len(tests)} tests from new API", file=sys.stderr)
        elif isinstance(data, list):
            for test in data:
                tests.extend(parse_test_node_new_api(test))
            print(f"Parsed {len(tests)} tests from new API (list format)", file=sys.stderr)
        
        return tests
    except json.JSONDecodeError as e:
        print(f"JSON parse error (new API tests): {e}", file=sys.stderr)
        return []


def parse_test_node_new_api(node: Dict, parent_name: str = "", class_name: str = "") -> List[Dict]:
    """Parse a test node from new API format (Xcode 16+).
    
    Node types hierarchy:
    - Test Plan -> Target -> Unit Test Bundle -> Test Suite -> Test Case
    """
    tests = []
    
    if not isinstance(node, dict):
        return tests
    
    node_type = node.get('nodeType', node.get('type', ''))
    name = node.get('name', node.get('identifier', node.get('nodeIdentifier', '')))
    result = node.get('result', node.get('status', ''))
    duration = node.get('durationInSeconds', node.get('duration', 0))
    
    # Track class name from Test Suite level
    current_class = class_name
    if node_type == 'Test Suite':
        current_class = name
    
    # Check if this is an actual test case
    is_test_case = (
        node_type in ['Test Case', 'Test', 'test', 'testCase'] or
        (result in ['Passed', 'Failed', 'Skipped', 'passed', 'failed', 'skipped'] and 
         node_type not in ['Test Plan', 'Target', 'Unit Test Bundle', 'Test Suite'])
    )
    
    if is_test_case:
        # Normalize result
        result_map = {
            'Passed': 'Success', 'passed': 'Success', 'success': 'Success',
            'Failed': 'Failure', 'failed': 'Failure', 'failure': 'Failure',
            'Skipped': 'Skipped', 'skipped': 'Skipped',
        }
        normalized_result = result_map.get(result, result if result else 'Unknown')
        
        # Extract test method name - remove () if present
        test_method = name.replace('()', '') if name else 'Unknown'
        
        # Use tracked class name or try to extract from identifier
        test_class = current_class or parent_name or 'Unknown'
        identifier = node.get('nodeIdentifier', node.get('identifier', f"{test_class}/{test_method}"))
        
        # Parse duration - handle formats like "0.93s", "1.234", or numeric
        parsed_duration = 0.0
        if duration:
            duration_str = str(duration).strip()
            # Remove trailing 's' if present (e.g., "0.93s" -> "0.93")
            if duration_str.endswith('s'):
                duration_str = duration_str[:-1]
            try:
                parsed_duration = float(duration_str)
            except (ValueError, TypeError):
                parsed_duration = 0.0
        
        tests.append({
            'name': test_method,
            'method': test_method,
            'class': test_class,
            'identifier': identifier,
            'status': normalized_result,
            'duration': parsed_duration,
            'duration_formatted': format_duration(parsed_duration),
            'failures': []
        })
    
    # Recurse into children
    children = node.get('children', node.get('subtests', node.get('testNodes', [])))
    if isinstance(children, list):
        for child in children:
            tests.extend(parse_test_node_new_api(child, name, current_class))
    
    return tests


def run_xcresulttool_legacy(xcresult_path: str, ref_id: str = None) -> Optional[Dict]:
    """Run legacy xcresulttool and return parsed JSON."""
    # Try with legacy flag first
    cmd = ['xcrun', 'xcresulttool', 'get', '--legacy', '--path', xcresult_path, '--format', 'json']
    if ref_id:
        cmd.extend(['--id', ref_id])
    
    success, stdout, stderr = run_command(cmd)
    
    if success and stdout.strip():
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            pass
    
    # If legacy failed, try without legacy flag
    cmd = ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--format', 'json']
    if ref_id:
        cmd.extend(['--id', ref_id])
    
    success, stdout, stderr = run_command(cmd)
    
    if success and stdout.strip():
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            pass
    
    print(f"Legacy xcresulttool failed: {stderr[:200]}", file=sys.stderr)
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


def find_tests_in_subtests_legacy(obj: Any, tests: List[Dict], parent_class: str = ""):
    """Recursively find individual tests in subtests hierarchy (legacy API)."""
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
                'failures': []
            })
        return
    
    # ActionTestSummaryGroup is a container
    if type_name == 'ActionTestSummaryGroup':
        group_name = extract_value(obj.get('name', {})) or extract_value(obj.get('identifier', {}))
        subtests = obj.get('subtests', {})
        subtest_values = extract_value(subtests)
        if isinstance(subtest_values, list):
            for subtest in subtest_values:
                find_tests_in_subtests_legacy(subtest, tests, group_name)
        return
    
    # Recurse into any subtests
    subtests = obj.get('subtests', {})
    subtest_values = extract_value(subtests)
    if isinstance(subtest_values, list):
        for subtest in subtest_values:
            find_tests_in_subtests_legacy(subtest, tests, parent_class)


def get_tests_from_xcresult_legacy(xcresult_path: str) -> List[Dict]:
    """Extract all tests using legacy xcresult API."""
    tests = []
    
    print("Trying legacy xcresult API...", file=sys.stderr)
    main_data = run_xcresulttool_legacy(xcresult_path)
    if not main_data:
        print("Legacy API failed to load xcresult", file=sys.stderr)
        return tests
    
    actions = main_data.get('actions', {}).get('_values', [])
    if not actions:
        print("No actions found in legacy format", file=sys.stderr)
        return tests
    
    for action in actions:
        action_result = action.get('actionResult', {})
        tests_ref = action_result.get('testsRef', {})
        tests_ref_id = extract_value(tests_ref.get('id', {}))
        
        if not tests_ref_id:
            continue
        
        print(f"Querying testsRef (legacy): {tests_ref_id[:50]}...", file=sys.stderr)
        
        tests_data = run_xcresulttool_legacy(xcresult_path, tests_ref_id)
        if not tests_data:
            continue
        
        summaries = tests_data.get('summaries', {}).get('_values', [])
        for summary in summaries:
            testable_summaries = summary.get('testableSummaries', {}).get('_values', [])
            for testable in testable_summaries:
                test_values = testable.get('tests', {}).get('_values', [])
                for test_group in test_values:
                    find_tests_in_subtests_legacy(test_group, tests)
    
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


def get_build_status(xcresult_path: str) -> Dict:
    """Get build status and errors from xcresult."""
    build_info = {
        'status': 'unknown',
        'errors': [],
        'warnings': []
    }
    
    # Try new API for build results
    success, stdout, stderr = run_command([
        'xcrun', 'xcresulttool', 'get', 'build-results',
        '--path', xcresult_path
    ])
    
    if success and stdout.strip():
        try:
            data = json.loads(stdout)
            # New API uses 'status' not 'result'
            build_info['status'] = data.get('status', data.get('result', 'unknown'))
            
            # Extract errors from 'errors' array
            for issue in data.get('errors', []):
                msg = issue.get('message', '')
                if msg:
                    build_info['errors'].append(msg)
            
            # Also check 'warnings'
            for issue in data.get('warnings', []):
                msg = issue.get('message', '')
                if msg:
                    build_info['warnings'].append(msg)
            
            print(f"New API build-results: status={build_info['status']}, errors={len(build_info['errors'])}", file=sys.stderr)
            return build_info
        except json.JSONDecodeError as e:
            print(f"JSON parse error in build-results: {e}", file=sys.stderr)
    
    # Fallback to legacy API
    main_data = run_xcresulttool_legacy(xcresult_path)
    if main_data:
        actions = main_data.get('actions', {}).get('_values', [])
        for action in actions:
            build_result = action.get('buildResult', {})
            status = extract_value(build_result.get('status', {}))
            if status:
                build_info['status'] = status
            
            # Try to get issues
            issues = build_result.get('issues', {})
            error_summaries = issues.get('errorSummaries', {}).get('_values', [])
            for error in error_summaries:
                msg = extract_value(error.get('message', {}))
                if msg:
                    build_info['errors'].append(msg)
    
    return build_info


def generate_report(xcresult_path: str) -> Dict:
    """Generate comprehensive test report."""
    print(f"Parsing: {xcresult_path}", file=sys.stderr)
    
    tests = []
    summary_data = None
    build_info = get_build_status(xcresult_path)
    
    print(f"Build status: {build_info['status']}", file=sys.stderr)
    if build_info['errors']:
        print(f"Build errors: {len(build_info['errors'])}", file=sys.stderr)
    
    # Try new API first (Xcode 16+)
    print("Trying new xcresulttool API (Xcode 16+)...", file=sys.stderr)
    summary_data = get_test_results_new_api(xcresult_path)
    
    if summary_data and summary_data.get('totalTestCount', 0) > 0:
        print(f"New API: Found {summary_data.get('totalTestCount')} tests", file=sys.stderr)
        
        # Get detailed test list
        tests = get_all_tests_new_api(xcresult_path)
        
        # If we got summary but not detailed tests, create from summary
        if not tests and summary_data.get('totalTestCount', 0) > 0:
            total = summary_data.get('totalTestCount', 0)
            passed = summary_data.get('passedTests', 0)
            failed = summary_data.get('failedTests', 0)
            skipped = summary_data.get('skippedTests', 0)
            
            # Create placeholder tests from failures if available
            failures = summary_data.get('testFailures', [])
            for failure in failures:
                test_name = failure.get('testName', failure.get('name', 'Unknown'))
                test_class = failure.get('targetName', failure.get('className', 'Unknown'))
                
                tests.append({
                    'name': test_name,
                    'method': test_name,
                    'class': test_class,
                    'identifier': f"{test_class}/{test_name}",
                    'status': 'Failure',
                    'duration': 0.0,
                    'duration_formatted': '<1ms',
                    'failures': [failure.get('message', 'Test failed')]
                })
            
            # Use summary stats directly
            return {
                'success': True,
                'xcresult_path': xcresult_path,
                'api_used': 'new',
                'build': build_info,
                'summary': {
                    'tests': total,
                    'passed': passed,
                    'failed': failed,
                    'skipped': skipped,
                    'duration': 0,
                    'duration_formatted': 'N/A',
                    'pass_rate': f"{(passed/total*100):.1f}%" if total > 0 else "N/A"
                },
                'tests': tests,
                'classes': group_tests_by_class(tests),
                'failed_tests': [t for t in tests if t['status'] == 'Failure']
            }
    else:
        print("New API returned no tests, trying legacy...", file=sys.stderr)
    
    # Fallback to legacy API
    if not tests:
        tests = get_tests_from_xcresult_legacy(xcresult_path)
    
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
        'api_used': 'legacy' if tests else 'none',
        'build': build_info,
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
    build_info = report.get('build', {})
    
    with open(output_file, 'a') as f:
        f.write(f"tests={summary['tests']}\n")
        f.write(f"passed={summary['passed']}\n")
        f.write(f"failed={summary['failed']}\n")
        f.write(f"skipped={summary['skipped']}\n")
        f.write(f"duration={summary.get('duration_formatted', 'unknown')}\n")
        f.write(f"pass_rate={summary.get('pass_rate', 'N/A')}\n")
        f.write(f"build_status={build_info.get('status', 'unknown')}\n")
        
        if build_info.get('errors'):
            f.write("build_errors<<ENDOFBUILDERRORS\n")
            for error in build_info['errors'][:20]:
                # Truncate long errors and escape newlines
                error_line = error.replace('\n', ' ')[:200]
                f.write(f"{error_line}\n")
            f.write("ENDOFBUILDERRORS\n")
        
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
    build_info = report.get('build', {})
    
    print("\n" + "=" * 60, file=sys.stderr)
    print("TEST RESULTS SUMMARY", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"API Used:     {report.get('api_used', 'unknown')}", file=sys.stderr)
    print(f"Build Status: {build_info.get('status', 'unknown')}", file=sys.stderr)
    print(f"Total Tests:  {summary['tests']}", file=sys.stderr)
    print(f"Passed:       {summary['passed']} ✓", file=sys.stderr)
    print(f"Failed:       {summary['failed']} ✗", file=sys.stderr)
    print(f"Skipped:      {summary['skipped']} ⊘", file=sys.stderr)
    print(f"Duration:     {summary.get('duration_formatted', 'unknown')}", file=sys.stderr)
    print(f"Pass Rate:    {summary.get('pass_rate', 'N/A')}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    
    if build_info.get('errors'):
        print("\n🔴 BUILD ERRORS:", file=sys.stderr)
        for error in build_info['errors'][:5]:
            print(f"  • {error[:100]}...", file=sys.stderr)
    
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
