#!/bin/bash
# Converts xcresult bundle to JUnit XML format for test reporting

XCRESULT_PATH="$1"

if [ -z "$XCRESULT_PATH" ] || [ ! -d "$XCRESULT_PATH" ]; then
    echo '<?xml version="1.0"?><testsuites><testsuite name="PalaceTests" tests="0"/></testsuites>'
    exit 0
fi

# Extract test metrics from xcresult
JSON=$(xcrun xcresulttool get --path "$XCRESULT_PATH" --format json 2>/dev/null)

if [ -z "$JSON" ]; then
    echo '<?xml version="1.0"?><testsuites><testsuite name="PalaceTests" tests="0"/></testsuites>'
    exit 0
fi

# Parse with Python for reliable JSON handling
python3 << 'PYTHON_SCRIPT'
import json
import sys
import os

xcresult_path = os.environ.get('XCRESULT_PATH', 'TestResults.xcresult')

try:
    # Get the JSON from xcresulttool
    import subprocess
    result = subprocess.run(
        ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--format', 'json'],
        capture_output=True, text=True
    )
    data = json.loads(result.stdout)
    
    metrics = data.get('metrics', {})
    tests_count = metrics.get('testsCount', {}).get('_value', '0')
    failures_count = metrics.get('testsFailedCount', {}).get('_value', '0')
    
    # Generate JUnit XML
    print('<?xml version="1.0" encoding="UTF-8"?>')
    print(f'<testsuites tests="{tests_count}" failures="{failures_count}">')
    print(f'  <testsuite name="PalaceTests" tests="{tests_count}" failures="{failures_count}">')
    
    # Try to get individual test results
    actions = data.get('actions', {}).get('_values', [])
    for action in actions:
        action_result = action.get('actionResult', {})
        tests_ref = action_result.get('testsRef', {})
        if tests_ref:
            ref_id = tests_ref.get('id', {}).get('_value', '')
            if ref_id:
                # Get detailed test results
                detail_result = subprocess.run(
                    ['xcrun', 'xcresulttool', 'get', '--path', xcresult_path, '--id', ref_id, '--format', 'json'],
                    capture_output=True, text=True
                )
                try:
                    test_data = json.loads(detail_result.stdout)
                    summaries = test_data.get('summaries', {}).get('_values', [])
                    for summary in summaries:
                        tests = summary.get('testableSummaries', {}).get('_values', [])
                        for testable in tests:
                            test_cases = testable.get('tests', {}).get('_values', [])
                            for test_group in test_cases:
                                subtests = test_group.get('subtests', {}).get('_values', [])
                                for subtest in subtests:
                                    test_methods = subtest.get('subtests', {}).get('_values', [])
                                    for method in test_methods:
                                        name = method.get('name', {}).get('_value', 'unknown')
                                        status = method.get('testStatus', {}).get('_value', 'Success')
                                        duration = method.get('duration', {}).get('_value', '0')
                                        
                                        classname = subtest.get('name', {}).get('_value', 'PalaceTests')
                                        
                                        if status == 'Success':
                                            print(f'    <testcase classname="{classname}" name="{name}" time="{duration}"/>')
                                        else:
                                            print(f'    <testcase classname="{classname}" name="{name}" time="{duration}">')
                                            print(f'      <failure message="Test failed">{status}</failure>')
                                            print(f'    </testcase>')
                except:
                    pass
    
    print('  </testsuite>')
    print('</testsuites>')
    
except Exception as e:
    # Fallback to minimal JUnit XML
    print('<?xml version="1.0" encoding="UTF-8"?>')
    print('<testsuites><testsuite name="PalaceTests" tests="0" failures="0"/></testsuites>')
PYTHON_SCRIPT

