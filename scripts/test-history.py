#!/usr/bin/env python3
"""
Manage test history and analyze trends.
Usage: python3 test-history.py <command> [options]

Commands:
  save <test-data.json> <history-dir>     Save current run to history
  analyze <history-dir>                    Analyze trends and detect flaky tests
  compare <current.json> <history-dir>    Compare current run with history
"""
import json
import sys
import os
import glob
from datetime import datetime
from typing import Dict, List, Any, Optional
from collections import defaultdict

MAX_HISTORY_ENTRIES = 15

def load_json(path: str) -> Optional[Dict]:
    """Load JSON file safely."""
    try:
        with open(path, 'r') as f:
            return json.load(f)
    except Exception as e:
        print(f"Error loading {path}: {e}", file=sys.stderr)
        return None

def save_json(data: Dict, path: str):
    """Save data to JSON file."""
    os.makedirs(os.path.dirname(path) or '.', exist_ok=True)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)

def get_history_files(history_dir: str) -> List[str]:
    """Get sorted list of history files (newest first)."""
    pattern = os.path.join(history_dir, 'run_*.json')
    files = glob.glob(pattern)
    return sorted(files, reverse=True)

def save_to_history(test_data_path: str, history_dir: str) -> str:
    """Save current test run to history."""
    test_data = load_json(test_data_path)
    if not test_data:
        print("Error: Could not load test data", file=sys.stderr)
        sys.exit(1)
    
    os.makedirs(history_dir, exist_ok=True)
    
    # Create history entry
    timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
    entry = {
        'timestamp': datetime.utcnow().isoformat(),
        'summary': test_data.get('summary', {}),
        'tests': {}
    }
    
    # Store test results by identifier for comparison
    for test in test_data.get('tests', []):
        identifier = f"{test.get('class', '')}.{test.get('method', test.get('name', ''))}"
        entry['tests'][identifier] = {
            'status': test.get('status'),
            'duration': test.get('duration', 0)
        }
    
    # Save entry
    output_path = os.path.join(history_dir, f'run_{timestamp}.json')
    save_json(entry, output_path)
    print(f"Saved history entry: {output_path}", file=sys.stderr)
    
    # Clean up old entries
    history_files = get_history_files(history_dir)
    if len(history_files) > MAX_HISTORY_ENTRIES:
        for old_file in history_files[MAX_HISTORY_ENTRIES:]:
            os.remove(old_file)
            print(f"Removed old history: {old_file}", file=sys.stderr)
    
    return output_path

def analyze_history(history_dir: str) -> Dict:
    """Analyze test history for trends and flaky tests."""
    history_files = get_history_files(history_dir)
    
    if not history_files:
        return {
            'runs': 0,
            'flaky_tests': [],
            'trends': {},
            'test_stats': {}
        }
    
    # Load all history
    runs = []
    for f in history_files[:MAX_HISTORY_ENTRIES]:
        data = load_json(f)
        if data:
            runs.append(data)
    
    if not runs:
        return {'runs': 0, 'flaky_tests': [], 'trends': {}, 'test_stats': {}}
    
    # Analyze each test across runs
    test_results = defaultdict(list)
    for run in runs:
        for test_id, test_data in run.get('tests', {}).items():
            test_results[test_id].append({
                'status': test_data.get('status'),
                'duration': test_data.get('duration', 0),
                'timestamp': run.get('timestamp')
            })
    
    # Find flaky tests (inconsistent pass/fail)
    flaky_tests = []
    test_stats = {}
    
    for test_id, results in test_results.items():
        statuses = [r['status'] for r in results]
        pass_count = sum(1 for s in statuses if s == 'Success')
        fail_count = sum(1 for s in statuses if s == 'Failure')
        total = len(statuses)
        
        # Calculate average duration
        durations = [r['duration'] for r in results if r['duration'] > 0]
        avg_duration = sum(durations) / len(durations) if durations else 0
        
        test_stats[test_id] = {
            'total_runs': total,
            'passes': pass_count,
            'failures': fail_count,
            'pass_rate': pass_count / total if total > 0 else 0,
            'avg_duration': avg_duration,
            'is_flaky': pass_count > 0 and fail_count > 0
        }
        
        # Test is flaky if it has both passes and failures
        if pass_count > 0 and fail_count > 0:
            flaky_tests.append({
                'test': test_id,
                'passes': pass_count,
                'failures': fail_count,
                'total': total,
                'flakiness_rate': min(pass_count, fail_count) / total
            })
    
    # Sort flaky tests by flakiness rate
    flaky_tests.sort(key=lambda x: x['flakiness_rate'], reverse=True)
    
    # Calculate trends
    trends = {
        'test_count': [],
        'pass_rate': [],
        'duration': [],
        'failed_count': []
    }
    
    for run in reversed(runs):  # Chronological order
        summary = run.get('summary', {})
        tests = summary.get('tests', 0)
        passed = summary.get('passed', 0)
        failed = summary.get('failed', 0)
        duration = summary.get('duration', 0)
        
        trends['test_count'].append(tests)
        trends['pass_rate'].append(passed / tests * 100 if tests > 0 else 0)
        trends['duration'].append(duration)
        trends['failed_count'].append(failed)
    
    return {
        'runs': len(runs),
        'flaky_tests': flaky_tests[:10],  # Top 10 flaky tests
        'trends': trends,
        'test_stats': test_stats
    }

def compare_with_history(current_path: str, history_dir: str) -> Dict:
    """Compare current run with historical data."""
    current = load_json(current_path)
    if not current:
        return {'comparison': 'unavailable'}
    
    history_files = get_history_files(history_dir)
    if not history_files:
        return {'comparison': 'no_history'}
    
    # Load previous run
    previous = load_json(history_files[0])
    if not previous:
        return {'comparison': 'error'}
    
    current_summary = current.get('summary', {})
    previous_summary = previous.get('summary', {})
    
    # Calculate changes
    comparison = {
        'has_previous': True,
        'previous_timestamp': previous.get('timestamp'),
        'changes': {}
    }
    
    for metric in ['tests', 'passed', 'failed', 'skipped']:
        curr_val = current_summary.get(metric, 0)
        prev_val = previous_summary.get(metric, 0)
        change = curr_val - prev_val
        comparison['changes'][metric] = {
            'current': curr_val,
            'previous': prev_val,
            'change': change,
            'change_formatted': f"+{change}" if change > 0 else str(change)
        }
    
    # Duration comparison
    curr_duration = current_summary.get('duration', 0)
    prev_duration = previous_summary.get('duration', 0)
    duration_change = curr_duration - prev_duration
    comparison['changes']['duration'] = {
        'current': curr_duration,
        'previous': prev_duration,
        'change': duration_change,
        'faster': duration_change < 0
    }
    
    # Find new failures and fixed tests
    current_tests = {
        f"{t.get('class', '')}.{t.get('method', t.get('name', ''))}": t.get('status')
        for t in current.get('tests', [])
    }
    previous_tests = previous.get('tests', {})
    
    new_failures = []
    fixed_tests = []
    new_tests = []
    
    for test_id, status in current_tests.items():
        prev_status = previous_tests.get(test_id, {}).get('status')
        
        if prev_status is None:
            if status == 'Failure':
                new_failures.append(test_id)
            new_tests.append(test_id)
        elif status == 'Failure' and prev_status == 'Success':
            new_failures.append(test_id)
        elif status == 'Success' and prev_status == 'Failure':
            fixed_tests.append(test_id)
    
    comparison['new_failures'] = new_failures
    comparison['fixed_tests'] = fixed_tests
    comparison['new_tests'] = new_tests
    
    # Get flaky test analysis
    analysis = analyze_history(history_dir)
    comparison['flaky_tests'] = analysis.get('flaky_tests', [])
    
    return comparison

def output_github_actions(comparison: Dict, output_file: str):
    """Output comparison results for GitHub Actions."""
    with open(output_file, 'a') as f:
        changes = comparison.get('changes', {})
        
        # Test count changes
        test_change = changes.get('tests', {}).get('change', 0)
        if test_change != 0:
            f.write(f"test_count_change={'+' if test_change > 0 else ''}{test_change}\n")
        
        # Failure changes
        fail_change = changes.get('failed', {}).get('change', 0)
        if fail_change != 0:
            f.write(f"failure_change={'+' if fail_change > 0 else ''}{fail_change}\n")
        
        # Duration changes
        duration_info = changes.get('duration', {})
        if duration_info.get('faster'):
            f.write(f"duration_change=faster by {abs(duration_info.get('change', 0)):.1f}s\n")
        elif duration_info.get('change', 0) > 0:
            f.write(f"duration_change=slower by {duration_info.get('change', 0):.1f}s\n")
        
        # New failures
        new_failures = comparison.get('new_failures', [])
        if new_failures:
            f.write("new_failures<<EOF\n")
            for test in new_failures[:10]:
                f.write(f"{test}\n")
            f.write("EOF\n")
        
        # Fixed tests
        fixed_tests = comparison.get('fixed_tests', [])
        if fixed_tests:
            f.write("fixed_tests<<EOF\n")
            for test in fixed_tests[:10]:
                f.write(f"{test}\n")
            f.write("EOF\n")
        
        # Flaky tests
        flaky_tests = comparison.get('flaky_tests', [])
        if flaky_tests:
            f.write("flaky_tests<<EOF\n")
            for test in flaky_tests[:5]:
                f.write(f"{test['test']} ({test['failures']}/{test['total']} failures)\n")
            f.write("EOF\n")

def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(1)
    
    command = sys.argv[1]
    
    if command == 'save':
        if len(sys.argv) < 4:
            print("Usage: test-history.py save <test-data.json> <history-dir>", file=sys.stderr)
            sys.exit(1)
        save_to_history(sys.argv[2], sys.argv[3])
        
    elif command == 'analyze':
        if len(sys.argv) < 3:
            print("Usage: test-history.py analyze <history-dir>", file=sys.stderr)
            sys.exit(1)
        analysis = analyze_history(sys.argv[2])
        print(json.dumps(analysis, indent=2))
        
    elif command == 'compare':
        if len(sys.argv) < 4:
            print("Usage: test-history.py compare <current.json> <history-dir>", file=sys.stderr)
            sys.exit(1)
        
        comparison = compare_with_history(sys.argv[2], sys.argv[3])
        
        # Output to GitHub Actions if available
        github_output = os.environ.get('GITHUB_OUTPUT', '')
        if github_output:
            output_github_actions(comparison, github_output)
        
        # Print summary
        print("\n" + "=" * 50, file=sys.stderr)
        print("TEST HISTORY COMPARISON", file=sys.stderr)
        print("=" * 50, file=sys.stderr)
        
        changes = comparison.get('changes', {})
        for metric, data in changes.items():
            if isinstance(data, dict) and 'change' in data:
                change = data['change']
                if change != 0:
                    sign = "+" if change > 0 else ""
                    print(f"{metric}: {sign}{change}", file=sys.stderr)
        
        if comparison.get('new_failures'):
            print(f"\n⚠️  New failures: {len(comparison['new_failures'])}", file=sys.stderr)
            for t in comparison['new_failures'][:5]:
                print(f"   - {t}", file=sys.stderr)
        
        if comparison.get('fixed_tests'):
            print(f"\n✅ Fixed tests: {len(comparison['fixed_tests'])}", file=sys.stderr)
            for t in comparison['fixed_tests'][:5]:
                print(f"   - {t}", file=sys.stderr)
        
        if comparison.get('flaky_tests'):
            print(f"\n⚡ Flaky tests detected: {len(comparison['flaky_tests'])}", file=sys.stderr)
            for t in comparison['flaky_tests'][:3]:
                print(f"   - {t['test']} ({t['failures']}/{t['total']} failures)", file=sys.stderr)
        
        print("=" * 50, file=sys.stderr)
        
        # Also output JSON
        print(json.dumps(comparison, indent=2))
        
    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
