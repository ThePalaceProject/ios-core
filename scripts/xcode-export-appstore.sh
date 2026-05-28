#!/bin/bash
# Thin shim. The real implementation lives in xcode-export.sh — kept as a
# back-compat entry point because .github/workflows/upload.yml and
# upload-on-merge.yml call this script by name. Update the CI side at your
# leisure, then this shim can be deleted.
exec "$(dirname "$0")/xcode-export.sh" --format appstore "$@"
