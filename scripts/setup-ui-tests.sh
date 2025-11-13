#!/bin/bash
#
# Setup script for Palace iOS UI Tests
# Helps add PalaceUITests files to Xcode project
#

set -e

echo "🧪 Palace iOS UI Tests - Setup Script"
echo "======================================"
echo ""

# Check if we're in the right directory
if [ ! -f "Palace.xcodeproj/project.pbxproj" ]; then
    echo "❌ Error: Palace.xcodeproj not found in current directory"
    echo "Please run this script from the ios-core root directory:"
    echo "  cd /path/to/ios-core"
    echo "  ./scripts/setup-ui-tests.sh"
    exit 1
fi

echo "✅ Found Palace.xcodeproj"
echo ""

# Check if PalaceUITests directory exists
if [ ! -d "PalaceUITests" ]; then
    echo "❌ Error: PalaceUITests directory not found"
    echo "Expected structure:"
    echo "  ios-core/"
    echo "    ├── PalaceUITests/"
    echo "    └── Palace.xcodeproj/"
    exit 1
fi

echo "✅ Found PalaceUITests directory"
echo ""

# Check if AccessibilityIdentifiers.swift exists
if [ ! -f "Palace/Utilities/Testing/AccessibilityIdentifiers.swift" ]; then
    echo "❌ Error: AccessibilityIdentifiers.swift not found"
    echo "Expected location: Palace/Utilities/Testing/AccessibilityIdentifiers.swift"
    exit 1
fi

echo "✅ Found AccessibilityIdentifiers.swift"
echo ""

echo "📋 Setup Checklist:"
echo ""
echo "The following files have been created:"
echo ""
echo "  Core Infrastructure:"
echo "  ├── Palace/Utilities/Testing/AccessibilityIdentifiers.swift"
echo "  └── PalaceUITests/"
echo "      ├── Tests/Smoke/SmokeTests.swift"
echo "      ├── Screens/"
echo "      │   ├── BaseScreen.swift"
echo "      │   ├── CatalogScreen.swift"
echo "      │   ├── SearchScreen.swift"
echo "      │   ├── BookDetailScreen.swift"
echo "      │   └── MyBooksScreen.swift"
echo "      ├── Helpers/"
echo "      │   ├── BaseTestCase.swift"
echo "      │   └── TestConfiguration.swift"
echo "      ├── Extensions/"
echo "      │   └── XCUIElement+Extensions.swift"
echo "      └── Documentation/"
echo "          ├── README.md"
echo "          ├── MIGRATION_GUIDE.md"
echo "          └── SETUP_GUIDE.md"
echo ""
echo "  CI/CD:"
echo "  └── .github/workflows/ui-tests.yml"
echo ""
echo "  Documentation:"
echo "  └── PHASE_1_COMPLETE.md"
echo ""

echo "📝 Next Steps:"
echo ""
echo "1. Open Xcode:"
echo "   open Palace.xcodeproj"
echo ""
echo "2. Add PalaceUITests target (if not exists):"
echo "   File → New → Target → iOS UI Testing Bundle"
echo "   Name: PalaceUITests"
echo ""
echo "3. Add test files to target:"
echo "   - Right-click PalaceUITests folder in Project Navigator"
echo "   - Select 'Add Files to PalaceUITests...'"
echo "   - Select all files in PalaceUITests/ directory"
echo "   - ✅ Copy items if needed"
echo "   - ✅ Create groups"
echo "   - ✅ Add to targets: PalaceUITests"
echo ""
echo "4. Add AccessibilityIdentifiers.swift to main app:"
echo "   - Add to Palace target (not test target)"
echo "   - Location: Palace/Utilities/Testing/"
echo ""
echo "5. Configure test scheme:"
echo "   Product → Scheme → Edit Scheme (⌘<)"
echo "   Test section → Environment Variables:"
echo "   - TEST_MODE = 1"
echo "   - SKIP_ANIMATIONS = 1"
echo ""
echo "6. Build and run tests:"
echo "   ⌘B to build"
echo "   ⌘U to run tests"
echo ""
echo "📚 Documentation:"
echo ""
echo "   Main Guide:      PalaceUITests/README.md"
echo "   Setup Guide:     PalaceUITests/SETUP_GUIDE.md"
echo "   Migration Guide: PalaceUITests/MIGRATION_GUIDE.md"
echo "   Summary:         PHASE_1_COMPLETE.md"
echo ""
echo "✨ Phase 1 Complete! Ready to run tests."
echo ""
echo "For detailed instructions, see:"
echo "   cat PalaceUITests/SETUP_GUIDE.md"
echo ""

