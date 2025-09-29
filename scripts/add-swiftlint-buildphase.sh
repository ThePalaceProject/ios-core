#!/bin/bash

# Add SwiftLint Run Script Build Phase to Xcode project
# This script will modify the Palace.xcodeproj to include SwiftLint in the build process

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_FILE="$PROJECT_ROOT/Palace.xcodeproj/project.pbxproj"

# Check if project file exists
check_project_file() {
    if [[ ! -f "$PROJECT_FILE" ]]; then
        echo -e "${RED}❌ Palace.xcodeproj/project.pbxproj not found${NC}"
        exit 1
    fi
}

# Function to backup project file
backup_project_file() {
    local backup_file="${PROJECT_FILE}.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$PROJECT_FILE" "$backup_file"
    echo -e "${BLUE}📦 Backed up project file to: ${backup_file##*/}${NC}"
}

# Function to check if SwiftLint build phase already exists
check_existing_build_phase() {
    if grep -q "SwiftLint" "$PROJECT_FILE" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  SwiftLint build phase may already exist${NC}"
        echo "Please check your Xcode project build phases manually."
        return 0
    fi
    return 1
}

# Function to show manual instructions
show_manual_instructions() {
    echo ""
    echo -e "${BLUE}📋 Manual Setup Instructions:${NC}"
    echo "============================================="
    echo ""
    echo "1. Open Palace.xcodeproj in Xcode"
    echo "2. Select the 'Palace' target"
    echo "3. Go to 'Build Phases' tab"
    echo "4. Click the '+' button and choose 'New Run Script Phase'"
    echo "5. Name the run script phase 'SwiftLint'"
    echo "6. Add this shell script:"
    echo ""
    echo "   # SwiftLint Build Phase"
    echo "   if which swiftlint > /dev/null; then"
    echo "     swiftlint"
    echo "   else"
    echo "     echo \"warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint\""
    echo "   fi"
    echo ""
    echo "7. Move the SwiftLint phase to run after 'Compile Sources'"
    echo "8. Build your project to see SwiftLint warnings and errors in Xcode"
    echo ""
    echo -e "${GREEN}✅ That's it! SwiftLint will now run on every build.${NC}"
    echo ""
}

# Function to attempt automatic setup (experimental)
attempt_automatic_setup() {
    echo -e "${YELLOW}⚠️  Attempting automatic setup (experimental)...${NC}"
    echo "This will try to add a SwiftLint build phase to your project."
    echo ""
    
    # Check if we can find the main target
    local main_target_uuid
    main_target_uuid=$(grep -A 5 "isa = PBXNativeTarget" "$PROJECT_FILE" | grep -B 5 "name = Palace" | head -1 | awk '{print $1}')
    
    if [[ -z "$main_target_uuid" ]]; then
        echo -e "${RED}❌ Could not find Palace target UUID${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Found Palace target: $main_target_uuid${NC}"
    
    # This is complex to do reliably without a proper Xcode project parser
    echo -e "${YELLOW}⚠️  Automatic setup is complex and error-prone for .pbxproj files${NC}"
    echo "Falling back to manual instructions..."
    return 1
}

# Main function
main() {
    echo -e "${GREEN}🎯 Palace Project - Add SwiftLint Build Phase${NC}"
    echo "=============================================="
    echo ""
    
    # Check prerequisites
    check_project_file
    
    # Check if SwiftLint is installed
    if ! command -v swiftlint >/dev/null 2>&1; then
        echo -e "${RED}❌ SwiftLint not installed${NC}"
        echo "Please run: ./scripts/install-linting-tools.sh"
        exit 1
    fi
    
    echo -e "${GREEN}✅ SwiftLint found: $(swiftlint version)${NC}"
    
    # Check if build phase already exists
    if check_existing_build_phase; then
        echo "If you need to update the build phase, please do so manually in Xcode."
        show_manual_instructions
        exit 0
    fi
    
    # Backup project file
    backup_project_file
    
    # Try automatic setup
    if ! attempt_automatic_setup; then
        show_manual_instructions
        exit 0
    fi
    
    echo -e "${GREEN}🎉 SwiftLint build phase setup complete!${NC}"
}

# Show usage if help requested
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    echo "Usage: $0"
    echo ""
    echo "Add SwiftLint Run Script Build Phase to Palace.xcodeproj"
    echo ""
    echo "This script will provide instructions to manually add SwiftLint to your Xcode build process."
    echo "Due to the complexity of .pbxproj files, manual setup is recommended."
    echo ""
    exit 0
fi

# Run main function
main "$@"
