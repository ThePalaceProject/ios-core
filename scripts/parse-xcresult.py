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
import re
from collections import defaultdict
from typing import Dict, List, Any, Optional

def run_xcresulttool(xcresult_path: str, *args) -> Optional[Dict]:
    """Run xcresulttool and return JSON output."""
    cmd = ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--format', 'json'] + list(args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout)
    except json.JSONDecodeError as e:
        print(f"JSON decode error: {e}", file=sys.stderr)
    except subprocess.TimeoutExpired:
        print("xcresulttool timed out", file=sys.stderr)
    except Exception as e:
        print(f"Error running xcresulttool: {e}", file=sys.stderr)
    return None

def extract_value(obj: Any, *keys) -> Any:
    """Safely extract nested value from xcresult JSON structure."""
    for key in keys:
        if isinstance(obj, dict):
            obj = obj.get(key, {})
        else:
            return None
    if isinstance(obj, dict) and '_value' in obj:
        return obj['_value']
    return obj if obj else None

def parse_duration(duration_str: str) -> float:
    """Parse duration string to seconds."""
    if not duration_str:
        return 0.0
    try:
        # Duration might be in format "0.123s" or just a number
        if isinstance(duration_str, (int, float)):
            return float(duration_str)
        duration_str = str(duration_str).strip()
        if duration_str.endswith('s'):
            return float(duration_str[:-1])
        return float(duration_str)
    except (ValueError, TypeError):
        return 0.0

def format_duration(seconds: float) -> str:
    """Format duration for display."""
    if seconds < 0.001:
        return "<1ms"
    elif seconds < 1:
        return f"{seconds*1000:.0f}ms"
    elif seconds < 60:
        return f"{seconds:.1f}s"
    else:
        mins = int(seconds // 60)
        secs = seconds % 60
        return f"{mins}m {secs:.0f}s"

def extract_test_details(obj: Dict) -> Optional[Dict]:
    """Extract detailed information from a test node."""
    test_status = extract_value(obj, 'testStatus')
    test_name = extract_value(obj, 'name')
    
    if not test_status or not test_name:
        return None
    
    # Extract identifier (full path like "TargetTests/ClassTests/testMethod()")
    identifier = extract_value(obj, 'identifier') or test_name
    
    # Extract duration
    duration = parse_duration(extract_value(obj, 'duration'))
    
    # Extract failure information
    failure_summaries = []
    failure_obj = obj.get('failureSummaries', {})
    if isinstance(failure_obj, dict):
        values = failure_obj.get('_values', [])
        if isinstance(values, list):
            for fs in values:
                message = extract_value(fs, 'message')
                file_name = extract_value(fs, 'fileName')
                line_number = extract_value(fs, 'lineNumber')
                if message:
                    failure_summaries.append({
                        'message': message,
                        'file': file_name,
                        'line': line_number
                    })
    
    # Parse class and method from identifier
    # Format: "TargetTests/ClassTests/testMethod()" or "ClassTests/testMethod()"
    parts = identifier.replace('()', '').split('/')
    test_method = parts[-1] if parts else test_name
    test_class = parts[-2] if len(parts) >= 2 else "Unknown"
    test_target = parts[-3] if len(parts) >= 3 else None
    
    return {
        'name': test_name,
        'method': test_method,
        'class': test_class,
        'target': test_target,
        'identifier': identifier,
        'status': test_status,
        'duration': duration,
        'duration_formatted': format_duration(duration),
        'failures': failure_summaries
    }

def find_all_tests(obj: Any, tests_list: List[Dict], depth: int = 0):
    """Recursively find all test results in the xcresult JSON."""
    if depth > 50:  # Prevent infinite recursion
        return
        
    if isinstance(obj, dict):
        # Check if this is a test result node
        test_details = extract_test_details(obj)
        if test_details:
            tests_list.append(test_details)
        
        # Recurse into nested structures
        for key, value in obj.items():
            find_all_tests(value, tests_list, depth + 1)
    elif isinstance(obj, list):
        for item in obj:
            find_all_tests(item, tests_list, depth + 1)

def get_root_metrics(data: Dict) -> Dict:
    """Extract metrics from root level of xcresult JSON."""
    metrics = data.get('metrics', {})
    return {
        'tests': int(extract_value(metrics, 'testsCount') or 0),
        'failed': int(extract_value(metrics, 'testsFailedCount') or 0),
        'skipped': int(extract_value(metrics, 'testsSkippedCount') or 0),
    }

def group_tests_by_class(tests: List[Dict]) -> Dict[str, List[Dict]]:
    """Group tests by their class name."""
    grouped = defaultdict(list)
    for test in tests:
        grouped[test['class']].append(test)
    return dict(grouped)

def calculate_class_stats(tests: List[Dict]) -> Dict:
    """Calculate statistics for a group of tests."""
    total = len(tests)
    passed = sum(1 for t in tests if t['status'] == 'Success')
    failed = sum(1 for t in tests if t['status'] == 'Failure')
    skipped = sum(1 for t in tests if t['status'] == 'Skipped')
    total_duration = sum(t['duration'] for t in tests)
    
    return {
        'total': total,
        'passed': passed,
        'failed': failed,
        'skipped': skipped,
        'duration': total_duration,
        'duration_formatted': format_duration(total_duration)
    }

def generate_test_report(xcresult_path: str) -> Dict:
    """Generate comprehensive test report from xcresult bundle."""
    
    # Get main xcresult data
    data = run_xcresulttool(xcresult_path)
    
    if not data:
        return {
            'success': False,
            'error': 'Could not parse xcresult bundle',
            'summary': {'tests': 0, 'passed': 0, 'failed': 0, 'skipped': 0},
            'tests': [],
            'classes': {}
        }
    
    # Get root-level metrics
    root_metrics = get_root_metrics(data)
    
    # Find all individual tests
    tests_list = []
    find_all_tests(data, tests_list)
    
    # Remove duplicates (same identifier)
    seen = set()
    unique_tests = []
    for test in tests_list:
        key = (test['identifier'], test['status'])
        if key not in seen:
            seen.add(key)
            unique_tests.append(test)
    tests_list = unique_tests
    
    # Calculate statistics
    total_tests = len(tests_list) if tests_list else root_metrics['tests']
    failed_count = sum(1 for t in tests_list if t['status'] == 'Failure') if tests_list else root_metrics['failed']
    skipped_count = sum(1 for t in tests_list if t['status'] == 'Skipped') if tests_list else root_metrics['skipped']
    passed_count = total_tests - failed_count - skipped_count
    total_duration = sum(t['duration'] for t in tests_list)
    
    # Group by class
    classes = group_tests_by_class(tests_list)
    class_stats = {}
    for class_name, class_tests in classes.items():
        class_stats[class_name] = {
            'stats': calculate_class_stats(class_tests),
            'tests': sorted(class_tests, key=lambda t: t['name'])
        }
    
    # Sort classes by name
    class_stats = dict(sorted(class_stats.items()))
    
    # Get failed tests with details
    failed_tests = [t for t in tests_list if t['status'] == 'Failure']
    
    return {
        'success': True,
        'xcresult_path': xcresult_path,
        'summary': {
            'tests': total_tests,
            'passed': passed_count,
            'failed': failed_count,
            'skipped': skipped_count,
            'duration': total_duration,
            'duration_formatted': format_duration(total_duration),
            'pass_rate': f"{(passed_count/total_tests*100):.1f}%" if total_tests > 0 else "N/A"
        },
        'tests': sorted(tests_list, key=lambda t: (t['class'], t['name'])),
        'classes': class_stats,
        'failed_tests': failed_tests
    }

def output_github_actions(report: Dict, output_file: str):
    """Write results in GitHub Actions output format."""
    summary = report['summary']
    failed_tests = report.get('failed_tests', [])
    classes = report.get('classes', {})
    
    with open(output_file, 'a') as f:
        # Basic metrics
        f.write(f"tests={summary['tests']}\n")
        f.write(f"passed={summary['passed']}\n")
        f.write(f"failed={summary['failed']}\n")
        f.write(f"skipped={summary['skipped']}\n")
        f.write(f"duration={summary.get('duration_formatted', 'unknown')}\n")
        f.write(f"pass_rate={summary.get('pass_rate', 'N/A')}\n")
        
        # Failed test names
        if failed_tests:
            f.write("failed_tests<<EOF\n")
            for test in failed_tests[:30]:  # Limit to 30
                f.write(f"{test['class']}.{test['method']}\n")
            f.write("EOF\n")
        
        # Class summary for PR comment table
        if classes:
            f.write("class_summary<<EOF\n")
            for class_name, class_data in sorted(classes.items()):
                stats = class_data['stats']
                f.write(f"{class_name}|{stats['total']}|{stats['passed']}|{stats['failed']}|{stats['duration_formatted']}\n")
            f.write("EOF\n")

def output_json(report: Dict, json_path: str):
    """Write detailed report as JSON file."""
    with open(json_path, 'w') as f:
        json.dump(report, f, indent=2)
    print(f"Wrote detailed report to: {json_path}", file=sys.stderr)

def print_summary(report: Dict):
    """Print human-readable summary to stderr."""
    summary = report['summary']
    
    print("\n" + "="*60, file=sys.stderr)
    print("TEST RESULTS SUMMARY", file=sys.stderr)
    print("="*60, file=sys.stderr)
    print(f"Total Tests:  {summary['tests']}", file=sys.stderr)
    print(f"Passed:       {summary['passed']} ✓", file=sys.stderr)
    print(f"Failed:       {summary['failed']} ✗", file=sys.stderr)
    print(f"Skipped:      {summary['skipped']} ⊘", file=sys.stderr)
    print(f"Duration:     {summary.get('duration_formatted', 'unknown')}", file=sys.stderr)
    print(f"Pass Rate:    {summary.get('pass_rate', 'N/A')}", file=sys.stderr)
    print("="*60, file=sys.stderr)
    
    # Show failed tests
    if report.get('failed_tests'):
        print("\nFAILED TESTS:", file=sys.stderr)
        for test in report['failed_tests'][:10]:
            print(f"  ✗ {test['class']}.{test['method']}", file=sys.stderr)
            for failure in test.get('failures', [])[:2]:
                msg = failure.get('message', '')[:100]
                print(f"    → {msg}", file=sys.stderr)
        if len(report['failed_tests']) > 10:
            print(f"  ... and {len(report['failed_tests']) - 10} more", file=sys.stderr)
    
    # Show class breakdown
    classes = report.get('classes', {})
    if classes:
        print("\nTESTS BY CLASS:", file=sys.stderr)
        for class_name, class_data in sorted(classes.items()):
            stats = class_data['stats']
            status = "✓" if stats['failed'] == 0 else "✗"
            print(f"  {status} {class_name}: {stats['passed']}/{stats['total']} passed ({stats['duration_formatted']})", file=sys.stderr)
    
    print("", file=sys.stderr)

def main():
    if len(sys.argv) < 2:
        print("Usage: parse-xcresult.py <path-to-xcresult> [--json <output.json>]", file=sys.stderr)
        sys.exit(1)
    
    xcresult_path = sys.argv[1]
    json_output_path = None
    
    # Parse arguments
    if '--json' in sys.argv:
        json_idx = sys.argv.index('--json')
        if json_idx + 1 < len(sys.argv):
            json_output_path = sys.argv[json_idx + 1]
    
    # Default JSON output path
    if not json_output_path:
        json_output_path = 'test-data.json'
    
    if not os.path.exists(xcresult_path):
        print(f"Error: {xcresult_path} not found", file=sys.stderr)
        sys.exit(1)
    
    # Generate report
    print(f"Parsing: {xcresult_path}", file=sys.stderr)
    report = generate_test_report(xcresult_path)
    
    if not report['success']:
        print(f"Error: {report.get('error', 'Unknown error')}", file=sys.stderr)
        sys.exit(1)
    
    # Print summary
    print_summary(report)
    
    # Output to GitHub Actions if available
    github_output = os.environ.get('GITHUB_OUTPUT', '')
    if github_output:
        output_github_actions(report, github_output)
        print(f"Wrote GitHub Actions output to: {github_output}", file=sys.stderr)
    
    # Write JSON report
    output_json(report, json_output_path)
    
    # Exit with appropriate code
    if report['summary']['failed'] > 0:
        sys.exit(0)  # Don't fail - let workflow handle it
    sys.exit(0)

if __name__ == '__main__':
    main()
