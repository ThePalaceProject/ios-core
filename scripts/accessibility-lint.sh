#!/bin/bash
# Run AccessLint accessibility analysis on Palace iOS project

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ACCESSLINT_PATH="${ACCESSLINT_PATH:-accesslint}"

# Check if accesslint is installed
if ! command -v "$ACCESSLINT_PATH" &> /dev/null; then
    echo "❌ AccessLint not found. Install it with:"
    echo ""
    echo "  cd /path/to/AccessLint && swift build -c release"
    echo "  cp .build/release/accesslint /usr/local/bin/"
    echo ""
    echo "Or set ACCESSLINT_PATH environment variable"
    exit 1
fi

echo "🔍 Running AccessLint on Palace iOS..."
echo ""

# Run analysis
"$ACCESSLINT_PATH" analyze \
    --path "$PROJECT_ROOT/Palace" \
    --output "$PROJECT_ROOT/accesslint-reports" \
    --format json \
    --format md \
    --relative-paths \
    "$@"

EXIT_CODE=$?

echo ""
echo "📄 Reports saved to: $PROJECT_ROOT/accesslint-reports/"
echo "   - findings.json (machine-readable)"
echo "   - report.md (human-readable)"

exit $EXIT_CODE
