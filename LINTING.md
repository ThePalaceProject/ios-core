# Code Linting and Formatting Setup

This document describes the linting and formatting setup for the Palace iOS project.

## Overview

We use two main tools to maintain code quality:

- **SwiftLint**: Static analysis tool for Swift that enforces style and conventions
- **SwiftFormat**: Code formatter that automatically fixes formatting issues

## Installation

### Automatic Installation

Run the installation script to set up both tools:

```bash
./scripts/install-linting-tools.sh
```

### Manual Installation

If the automatic installation fails, you can install manually:

```bash
# Via Homebrew (recommended)
brew install swiftlint swiftformat

# Or download binaries from GitHub releases:
# - SwiftLint: https://github.com/realm/SwiftLint/releases
# - SwiftFormat: https://github.com/nicklockwood/SwiftFormat/releases
```

## Usage

### Formatting Code

Format all Swift files in the project:

```bash
./scripts/format-code.sh
```

Preview formatting changes without applying them:

```bash
./scripts/format-code.sh --preview
```

Format a specific file:

```bash
./scripts/format-code.sh --file Palace/Book/TPPBook.swift
```

### Linting Code

Lint all Swift files in the project:

```bash
./scripts/lint-code.sh
```

Auto-fix linting issues where possible:

```bash
./scripts/lint-code.sh --fix
```

Lint a specific file:

```bash
./scripts/lint-code.sh --file Palace/Book/TPPBook.swift
```

Show all available linting rules:

```bash
./scripts/lint-code.sh --rules
```

### Xcode Integration

To see linting warnings and errors directly in Xcode:

1. Open `Palace.xcodeproj` in Xcode
2. Select the 'Palace' target
3. Go to 'Build Phases' tab
4. Click the '+' button and choose 'New Run Script Phase'
5. Name it 'SwiftLint'
6. Add this script:

```bash
# SwiftLint Build Phase
if which swiftlint > /dev/null; then
  swiftlint
else
  echo "warning: SwiftLint not installed, download from https://github.com/realm/SwiftLint"
fi
```

7. Move the SwiftLint phase to run after 'Compile Sources'

You can also run the build phase setup script for detailed instructions:

```bash
./scripts/add-swiftlint-buildphase.sh
```

## Configuration

### SwiftLint Configuration (`.swiftlint.yml`)

The SwiftLint configuration includes:

- **Included paths**: `Palace/`, `PalaceTests/`, `PalaceUIKit/`, and audiobook toolkit modules
- **Excluded paths**: Third-party code, Carthage dependencies, build artifacts
- **Rules**: Comprehensive set of style and quality rules
- **Customizations**: Adjusted line length, complexity thresholds, and naming rules

Key configurations:
- Line length: 120 characters (warning), 150 (error)
- Function body length: 50 lines (warning), 100 (error)
- File length: 500 lines (warning), 1000 (error)
- Cyclomatic complexity: 15 (warning), 25 (error)

### SwiftFormat Configuration (`.swiftformat`)

The SwiftFormat configuration includes:

- **Indentation**: 2 spaces
- **Line width**: 120 characters
- **Rules**: Comprehensive formatting rules for consistent style
- **Swift features**: Support for modern Swift syntax and SwiftUI

Key formatting rules:
- Consistent spacing around operators, braces, and parentheses
- Sorted imports with testable imports at bottom
- Trailing commas in collections
- Redundant code removal
- Modern Swift syntax preferences

## Project Structure

The linting setup covers these directories:

```
Palace/                                    # Main app code
PalaceTests/                              # App tests
PalaceUIKit/                              # UI framework
ios-audiobooktoolkit/PalaceAudiobookToolkit/        # Audiobook toolkit
ios-audiobooktoolkit/PalaceAudiobookToolkitTests/   # Toolkit tests
ios-audiobook-overdrive/OverdriveProcessor/         # Overdrive processor
```

Excluded directories:
- `Carthage/` - Third-party dependencies
- `readium-sdk/` - Legacy Readium SDK
- `adept-ios/` - Adobe DRM
- `scripts/` - Build scripts
- Generated files (`*.generated.swift`)

## Workflow Integration

### Pre-commit Hooks

Consider setting up pre-commit hooks to automatically format code:

```bash
# Create .git/hooks/pre-commit
#!/bin/bash
./scripts/format-code.sh --preview
if [ $? -ne 0 ]; then
  echo "Code formatting issues found. Run './scripts/format-code.sh' to fix."
  exit 1
fi
```

### CI/CD Integration

Add linting to your CI pipeline:

```bash
# In your CI script
./scripts/lint-code.sh --strict
```

The `--strict` flag treats warnings as errors for CI environments.

### Recommended Workflow

1. **Before committing**:
   ```bash
   ./scripts/format-code.sh    # Format code
   ./scripts/lint-code.sh      # Check for issues
   ```

2. **During development**:
   - Build in Xcode to see real-time linting feedback
   - Use `--fix` flag to auto-correct simple issues

3. **Code review**:
   - Formatting should be consistent
   - No linting errors should be present

## Customization

### Adding New Rules

Edit `.swiftlint.yml` to add new rules to the `opt_in_rules` section:

```yaml
opt_in_rules:
  - new_rule_name
```

### Disabling Rules

Add rules to the `disabled_rules` section:

```yaml
disabled_rules:
  - rule_to_disable
```

### File-specific Overrides

Use inline comments to disable rules for specific lines:

```swift
// swiftlint:disable rule_name
problematic_code()
// swiftlint:enable rule_name
```

Or for entire files:

```swift
// swiftlint:disable file_length
```

### Formatting Overrides

Use inline comments for SwiftFormat:

```swift
// swiftformat:disable rule_name
code_to_preserve()
// swiftformat:enable rule_name
```

## Troubleshooting

### Common Issues

1. **Tools not found**: Ensure SwiftLint/SwiftFormat are in your PATH
2. **Configuration errors**: Validate YAML syntax in `.swiftlint.yml`
3. **Performance**: Large files may take time to process
4. **Xcode integration**: Ensure build phase script path is correct

### Getting Help

```bash
swiftlint help                     # SwiftLint help
swiftformat --help                 # SwiftFormat help
./scripts/lint-code.sh --rules     # List all linting rules
```

## Version Information

Current tool versions:
- SwiftLint: 0.61.0
- SwiftFormat: 0.58.2

Update tools regularly:

```bash
brew upgrade swiftlint swiftformat
```

## Contributing

When contributing to the project:

1. Ensure your code passes linting: `./scripts/lint-code.sh`
2. Format your code: `./scripts/format-code.sh`
3. Follow the existing code style conventions
4. Update this documentation if you modify the linting setup

## Resources

- [SwiftLint Documentation](https://realm.github.io/SwiftLint/)
- [SwiftFormat Documentation](https://github.com/nicklockwood/SwiftFormat)
- [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
