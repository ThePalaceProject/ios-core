#!/bin/bash
# Fix Swift Package Manager dependency issues

echo "🔧 Fixing Package Dependencies..."

# Close Xcode first (packages can't be reset while Xcode is open)
echo "1. Close Xcode completely"
read -p "Press Enter when Xcode is closed..."

# Remove derived data
echo "2. Removing DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Palace-*

# Remove package caches
echo "3. Removing package caches..."
rm -rf ~/Library/Caches/org.swift.swiftpm/
rm -rf .build/

# Remove resolved packages (will force re-resolution)
echo "4. Removing Package.resolved..."
rm -rf Palace.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo ""
echo "✅ Cleanup complete!"
echo ""
echo "Now:"
echo "  1. Open Xcode: open Palace.xcodeproj"
echo "  2. File → Packages → Resolve Package Versions"
echo "  3. Wait for all packages to download"
echo "  4. Build: ⌘B"
echo ""

