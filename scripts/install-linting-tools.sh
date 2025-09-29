#!/bin/bash

# Install SwiftLint and SwiftFormat for the Palace Project
# This script will install via Homebrew if available, otherwise provide instructions

set -euo pipefail

echo "🔧 Installing SwiftLint and SwiftFormat..."

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install via Homebrew
install_via_homebrew() {
    echo -e "${GREEN}Installing via Homebrew...${NC}"
    
    if ! command_exists brew; then
        echo -e "${RED}Homebrew not found. Please install Homebrew first:${NC}"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        return 1
    fi
    
    echo "Installing SwiftLint..."
    brew install swiftlint
    
    echo "Installing SwiftFormat..."
    brew install swiftformat
    
    return 0
}

# Function to install via Swift Package Manager (SPM)
install_via_spm() {
    echo -e "${YELLOW}Installing via Swift Package Manager (requires Xcode)...${NC}"
    
    # Create a temporary directory for the SPM package
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Create Package.swift
    cat > Package.swift << 'EOF'
// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "PalaceLintingTools",
    platforms: [.macOS(.v10_15)],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint", from: "0.54.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.52.0")
    ],
    targets: [
        .executableTarget(
            name: "PalaceLintingTools",
            dependencies: []
        )
    ]
)
EOF
    
    # Create main.swift (dummy executable)
    mkdir -p Sources/PalaceLintingTools
    echo 'print("Palace Linting Tools installed")' > Sources/PalaceLintingTools/main.swift
    
    # Build to install the tools
    swift build --product SwiftLint
    swift build --product SwiftFormat
    
    # Copy binaries to /usr/local/bin (requires admin)
    echo -e "${YELLOW}Installing binaries to /usr/local/bin (may require sudo)...${NC}"
    sudo cp .build/debug/SwiftLint /usr/local/bin/ 2>/dev/null || cp .build/debug/SwiftLint ~/bin/ 2>/dev/null || echo -e "${RED}Could not install SwiftLint binary${NC}"
    sudo cp .build/debug/SwiftFormat /usr/local/bin/ 2>/dev/null || cp .build/debug/SwiftFormat ~/bin/ 2>/dev/null || echo -e "${RED}Could not install SwiftFormat binary${NC}"
    
    # Cleanup
    cd - > /dev/null
    rm -rf "$TEMP_DIR"
}

# Main installation logic
main() {
    echo "🎯 Palace Project - Linting Tools Installation"
    echo "============================================="
    
    # Check if tools are already installed
    if command_exists swiftlint && command_exists swiftformat; then
        echo -e "${GREEN}✅ SwiftLint and SwiftFormat are already installed!${NC}"
        echo "SwiftLint version: $(swiftlint version)"
        echo "SwiftFormat version: $(swiftformat --version)"
        return 0
    fi
    
    # Try Homebrew first
    if install_via_homebrew; then
        echo -e "${GREEN}✅ Successfully installed via Homebrew!${NC}"
    else
        echo -e "${YELLOW}⚠️  Homebrew installation failed. Trying Swift Package Manager...${NC}"
        if install_via_spm; then
            echo -e "${GREEN}✅ Successfully installed via Swift Package Manager!${NC}"
        else
            echo -e "${RED}❌ Installation failed. Please install manually:${NC}"
            echo ""
            echo "Option 1 - Homebrew:"
            echo "  brew install swiftlint swiftformat"
            echo ""
            echo "Option 2 - Download binaries:"
            echo "  SwiftLint: https://github.com/realm/SwiftLint/releases"
            echo "  SwiftFormat: https://github.com/nicklockwood/SwiftFormat/releases"
            echo ""
            return 1
        fi
    fi
    
    # Verify installation
    echo ""
    echo "🔍 Verifying installation..."
    
    if command_exists swiftlint; then
        echo -e "${GREEN}✅ SwiftLint: $(swiftlint version)${NC}"
    else
        echo -e "${RED}❌ SwiftLint not found in PATH${NC}"
    fi
    
    if command_exists swiftformat; then
        echo -e "${GREEN}✅ SwiftFormat: $(swiftformat --version)${NC}"
    else
        echo -e "${RED}❌ SwiftFormat not found in PATH${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}🎉 Installation complete!${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Run './scripts/format-code.sh' to format your entire codebase"
    echo "2. Run './scripts/lint-code.sh' to lint your code"
    echo "3. The Xcode build phase will automatically run SwiftLint on builds"
}

# Run main function
main "$@"
