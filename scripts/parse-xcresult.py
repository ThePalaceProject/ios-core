#!/usr/bin/env python3
"""
Parse xcresult bundle to extract test metrics and failed test names.
Usage: python3 parse-xcresult.py <path-to-xcresult>

Outputs GitHub Actions format:
  tests=N
  passed=N
  failed=N
  skipped=N
  failed_tests<<EOF
  test1
  test2
  EOF
"""
import json
import subprocess
import sys
import os

def run_xcresulttool(xcresult_path, *args):
    """Run xcresulttool and return JSON output."""
    cmd = ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--format', 'json'] + list(args)
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            return json.loads(result.stdout)
    except Exception:
        pass
    return None

def extract_value(obj, *keys):
    """Safely extract nested value from xcresult JSON structure."""
    for key in keys:
        if isinstance(obj, dict):
            obj = obj.get(key, {})
        else:
            return None
    if isinstance(obj, dict) and '_value' in obj:
        return obj['_value']
    return obj if obj else None

def find_all_tests(obj, tests_list, path=''):
    """Recursively find all test results."""
    if isinstance(obj, dict):
        # Check if this looks like a test result
        test_status = extract_value(obj, 'testStatus')
        test_name = extract_value(obj, 'name')
        
        if test_status and test_name:
            tests_list.append({
                'name': test_name,
                'status': test_status,
                'path': path
            })
        
        # Recurse into nested structures
        for key, value in obj.items():
            find_all_tests(value, tests_list, f"{path}.{key}" if path else key)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            find_all_tests(item, tests_list, f"{path}[{i}]")

def get_metrics_from_root(data):
    """Extract metrics from root level of xcresult JSON."""
    metrics = data.get('metrics', {})
    return {
        'tests': extract_value(metrics, 'testsCount') or 0,
        'failed': extract_value(metrics, 'testsFailedCount') or 0,
        'skipped': extract_value(metrics, 'testsSkippedCount') or 0,
    }

def count_tests_from_traversal(data):
    """Count tests by traversing the entire JSON structure."""
    tests_list = []
    find_all_tests(data, tests_list)
    
    total = len(tests_list)
    failed = sum(1 for t in tests_list if t['status'] == 'Failure')
    skipped = sum(1 for t in tests_list if t['status'] == 'Skipped')
    passed = total - failed - skipped
    
    failed_names = [t['name'] for t in tests_list if t['status'] == 'Failure']
    
    return {
        'tests': total,
        'passed': passed,
        'failed': failed,
        'skipped': skipped,
        'failed_names': failed_names
    }

def main():
    if len(sys.argv) < 2:
        print("Usage: parse-xcresult.py <path-to-xcresult>", file=sys.stderr)
        sys.exit(1)
    
    xcresult_path = sys.argv[1]
    output_file = os.environ.get('GITHUB_OUTPUT', '')
    
    if not os.path.exists(xcresult_path):
        print(f"Error: {xcresult_path} not found", file=sys.stderr)
        sys.exit(1)
    
    # Get the main xcresult data
    data = run_xcresulttool(xcresult_path)
    
    if not data:
        print("Error: Could not parse xcresult", file=sys.stderr)
        sys.exit(1)
    
    # Try to get metrics from root level first
    metrics = get_metrics_from_root(data)
    
    # If no tests found at root, traverse the structure
    if metrics['tests'] == 0:
        traversal_results = count_tests_from_traversal(data)
        if traversal_results['tests'] > 0:
            metrics = traversal_results
    else:
        # Get failed test names via traversal
        traversal_results = count_tests_from_traversal(data)
        metrics['passed'] = metrics['tests'] - metrics['failed'] - metrics['skipped']
        metrics['failed_names'] = traversal_results.get('failed_names', [])
    
    # Output results
    tests = int(metrics.get('tests', 0))
    failed = int(metrics.get('failed', 0))
    skipped = int(metrics.get('skipped', 0))
    passed = tests - failed - skipped
    failed_names = metrics.get('failed_names', [])
    
    # Print summary to stderr for logging
    print(f"Tests: {tests}, Passed: {passed}, Failed: {failed}, Skipped: {skipped}", file=sys.stderr)
    
    if output_file:
        with open(output_file, 'a') as f:
            f.write(f"tests={tests}\n")
            f.write(f"passed={passed}\n")
            f.write(f"failed={failed}\n")
            f.write(f"skipped={skipped}\n")
            if failed_names:
                f.write("failed_tests<<EOF\n")
                for name in failed_names[:20]:
                    f.write(f"{name}\n")
                f.write("EOF\n")
    else:
        # Print to stdout for manual testing
        print(f"tests={tests}")
        print(f"passed={passed}")
        print(f"failed={failed}")
        print(f"skipped={skipped}")
        if failed_names:
            print("Failed tests:")
            for name in failed_names[:20]:
                print(f"  - {name}")

if __name__ == '__main__':
    main()
