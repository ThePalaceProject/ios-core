#!/usr/bin/env python3
"""
Parse xcresult JSON to extract failed test names.
Usage: xcrun xcresulttool get --path TestResults.xcresult --format json | python3 parse-test-results.py
"""
import json
import sys

def find_failures(obj, failed_list):
    """Recursively find failed tests in xcresult JSON."""
    if isinstance(obj, dict):
        # Check if this is a test with failure status
        if obj.get('testStatus', {}).get('_value') == 'Failure':
            name = obj.get('name', {}).get('_value', '')
            if name:
                failed_list.append(name)
        # Recurse into all values
        for v in obj.values():
            find_failures(v, failed_list)
    elif isinstance(obj, list):
        for item in obj:
            find_failures(item, failed_list)

def main():
    try:
        data = json.load(sys.stdin)
        failed = []
        find_failures(data, failed)
        # Print up to 20 failed test names
        for name in failed[:20]:
            print(name)
    except Exception:
        # Silent failure - just output nothing
        pass

if __name__ == '__main__':
    main()
