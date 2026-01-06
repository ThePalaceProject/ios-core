#!/bin/bash
# Generates a test summary for GitHub Actions Step Summary

echo "## 🧪 Test Results Summary" >> $GITHUB_STEP_SUMMARY
echo "" >> $GITHUB_STEP_SUMMARY

if [ -d "TestResults.xcresult" ]; then
    # Extract summary from xcresult using Python
    python3 << 'PYTHON_SCRIPT' >> $GITHUB_STEP_SUMMARY
import json
import subprocess

try:
    result = subprocess.run(
        ['xcrun', 'xcresulttool', 'get', '--path', 'TestResults.xcresult', '--format', 'json'],
        capture_output=True, text=True
    )
    data = json.loads(result.stdout)
    
    metrics = data.get('metrics', {})
    tests = metrics.get('testsCount', {}).get('_value', 'N/A')
    failures = metrics.get('testsFailedCount', {}).get('_value', '0')
    
    if tests != 'N/A':
        passed = int(tests) - int(failures)
        status = "✅" if int(failures) == 0 else "❌"
    else:
        passed = 'N/A'
        status = "⚠️"
    
    print(f'{status} **Test Run Complete**')
    print('')
    print('| Metric | Count |')
    print('|--------|-------|')
    print(f'| Total Tests | {tests} |')
    print(f'| ✅ Passed | {passed} |')
    print(f'| ❌ Failed | {failures} |')
except Exception as e:
    print(f'⚠️ Unable to parse test results: {e}')
PYTHON_SCRIPT
else
    echo "❌ No test results found" >> $GITHUB_STEP_SUMMARY
fi

