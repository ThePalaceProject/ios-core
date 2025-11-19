#!/usr/bin/env python3
"""
GherkinSwift Converter - MVP
Converts Gherkin/Cucumber scenarios to Swift/XCTest code for Palace iOS

Usage:
    python convert.py features/my-test.feature --output MyTests.swift
    python convert.py features/ --output-dir PalaceUITests/Tests/Generated/
"""

import re
import sys
import argparse
from pathlib import Path
from typing import List, Dict, Optional

class GherkinParser:
    """Parses Gherkin feature files"""
    
    def parse_feature(self, content: str) -> Dict:
        """Parse Gherkin content into structured data"""
        lines = content.strip().split('\n')
        
        feature = {
            'name': '',
            'description': '',
            'background': [],
            'scenarios': []
        }
        
        current_scenario = None
        current_section = None
        
        for line in lines:
            line = line.strip()
            
            if not line or line.startswith('#'):
                continue
            
            if line.startswith('Feature:'):
                feature['name'] = line.replace('Feature:', '').strip()
            
            elif line.startswith('Scenario:'):
                if current_scenario:
                    feature['scenarios'].append(current_scenario)
                current_scenario = {
                    'name': line.replace('Scenario:', '').strip(),
                    'steps': []
                }
            
            elif line.startswith('Scenario Outline:'):
                if current_scenario:
                    feature['scenarios'].append(current_scenario)
                current_scenario = {
                    'name': line.replace('Scenario Outline:', '').strip(),
                    'steps': [],
                    'is_outline': True,
                    'examples': []
                }
            
            elif line.startswith('Background:'):
                current_section = 'background'
            
            elif line.startswith('Examples:'):
                current_section = 'examples'
            
            elif any(line.startswith(keyword) for keyword in ['Given', 'When', 'And', 'Then', 'But']):
                # Extract step
                for keyword in ['Given', 'When', 'And', 'Then', 'But']:
                    if line.startswith(keyword):
                        step_text = line.replace(keyword, '').strip()
                        step = {'keyword': keyword, 'text': step_text}
                        
                        if current_section == 'background':
                            feature['background'].append(step)
                        elif current_scenario:
                            current_scenario['steps'].append(step)
                        break
        
        if current_scenario:
            feature['scenarios'].append(current_scenario)
        
        return feature


class SwiftCodeGenerator:
    """Generates Swift/XCTest code from parsed Gherkin"""
    
    def __init__(self):
        self.step_mappings = self._load_step_mappings()
    
    def _load_step_mappings(self) -> Dict[str, str]:
        """Default step mappings (can be extended)"""
        return {
            # Navigation
            r"I am on the (Catalog|My Books|Settings|Holds) screen": self._navigate_to_screen,
            r"I navigate to (Catalog|My Books|Settings|Holds)": self._navigate_to_screen,
            r"I tap the back button": lambda m: "bookDetail.goBack()",
            
            # Search
            r"I search for [\"'](.+?)[\"']": lambda m: f'search.enterSearchText("{m.group(1)}")',
            r"I tap the first result": lambda m: """guard let bookDetail = search.tapFirstResult() else {
        XCTFail("Could not open book detail")
        return
    }""",
            
            # Book Actions
            r"I tap the (GET|READ|DELETE|LISTEN|RESERVE) button": self._tap_button,
            r"I wait for download to complete": lambda m: "XCTAssertTrue(bookDetail.waitForDownloadComplete())",
            r"I confirm deletion": lambda m: "// Deletion confirmation handled automatically",
            
            # Assertions
            r"I should see the (GET|READ|DELETE|LISTEN) button": self._assert_button,
            r"the book should download": lambda m: "XCTAssertTrue(bookDetail.waitForDownloadComplete())",
            r"the book should be in My Books": lambda m: """navigateToTab(.myBooks)
    let myBooks = MyBooksScreen(app: app)
    XCTAssertTrue(myBooks.hasBooks())""",
        }
    
    def _navigate_to_screen(self, match):
        screen = match.group(1)
        screen_map = {
            'Catalog': 'catalog',
            'My Books': 'myBooks',
            'Settings': 'settings',
            'Holds': 'holds'
        }
        screen_lower = screen_map.get(screen, screen.lower().replace(' ', ''))
        screen_class = screen.replace(' ', '') + 'Screen'
        
        return f"""navigateToTab(.{screen_lower})
    let {screen_lower} = {screen_class}(app: app)
    XCTAssertTrue({screen_lower}.isDisplayed())"""
    
    def _tap_button(self, match):
        button = match.group(1).lower().capitalize()
        return f"bookDetail.tap{button}Button()"
    
    def _assert_button(self, match):
        button = match.group(1).lower().capitalize()
        return f'XCTAssertTrue(bookDetail.has{button}Button(), "{button} button should be visible")'
    
    def generate_test(self, feature: Dict) -> str:
        """Generate Swift test class from parsed feature"""
        class_name = self._feature_to_class_name(feature['name'])
        
        swift_code = f"""import XCTest

/// Auto-generated from Gherkin feature
/// Feature: {feature['name']}
/// Generated: {self._timestamp()}
///
/// **IMPORTANT:** This is auto-generated code.
/// To regenerate: ./tools/gherkin-to-swift/convert.py features/xxx.feature
final class {class_name}: BaseTestCase {{
"""
        
        # Add setUp if background exists
        if feature['background']:
            swift_code += self._generate_setup(feature['background'])
        
        # Generate test methods for each scenario
        for scenario in feature['scenarios']:
            swift_code += self._generate_scenario(scenario)
        
        swift_code += "}\n"
        
        return swift_code
    
    def _generate_scenario(self, scenario: Dict) -> str:
        """Generate test method from scenario"""
        method_name = self._scenario_to_method_name(scenario['name'])
        
        code = f"""
  /// {scenario['name']}
  func {method_name}() {{
"""
        
        # Generate code for each step
        for step in scenario['steps']:
            comment = f"// {step['keyword']} {step['text']}"
            swift_code = self._convert_step(step['text'])
            
            code += f"    {comment}\n"
            
            # Indent Swift code properly
            for line in swift_code.split('\n'):
                if line.strip():
                    code += f"    {line}\n"
            code += "\n"
        
        # Add screenshot at end
        code += f'    takeScreenshot(named: "{method_name}")\n'
        code += "  }\n"
        
        return code
    
    def _generate_setup(self, background_steps: List[Dict]) -> str:
        """Generate setUp method from background"""
        code = """
  override func setUpWithError() throws {
    try super.setUpWithError()
    
"""
        for step in background_steps:
            code += f"    // {step['keyword']} {step['text']}\n"
            swift_code = self._convert_step(step['text'])
            for line in swift_code.split('\n'):
                if line.strip():
                    code += f"    {line}\n"
        
        code += "  }\n"
        return code
    
    def _convert_step(self, step_text: str) -> str:
        """Convert a single Gherkin step to Swift code"""
        # Try pattern matching first
        for pattern, handler in self.step_mappings.items():
            match = re.search(pattern, step_text, re.IGNORECASE)
            if match:
                if callable(handler):
                    return handler(match)
                else:
                    return handler
        
        # Fallback: return as comment (AI would enhance this)
        return f"// TODO: Implement step: {step_text}"
    
    def _feature_to_class_name(self, feature_name: str) -> str:
        """Convert feature name to Swift class name"""
        # "Book Download" → "BookDownloadTests"
        words = re.findall(r'\w+', feature_name)
        return ''.join(word.capitalize() for word in words) + 'Tests'
    
    def _scenario_to_method_name(self, scenario_name: str) -> str:
        """Convert scenario name to Swift method name"""
        # "Download a book" → "testDownloadABook"
        words = re.findall(r'\w+', scenario_name.lower())
        return 'test' + ''.join(word.capitalize() for word in words)
    
    def _timestamp(self) -> str:
        from datetime import datetime
        return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def main():
    parser = argparse.ArgumentParser(description='Convert Gherkin to Swift/XCTest')
    parser.add_argument('input', help='Input .feature file or directory')
    parser.add_argument('--output', help='Output .swift file')
    parser.add_argument('--output-dir', help='Output directory for generated tests')
    parser.add_argument('--dry-run', action='store_true', help='Print output without writing files')
    parser.add_argument('--verbose', action='store_true', help='Verbose output')
    
    args = parser.parse_args()
    
    # Initialize converters
    gherkin_parser = GherkinParser()
    swift_generator = SwiftCodeGenerator()
    
    # Read input
    input_path = Path(args.input)
    
    if input_path.is_file():
        # Single file
        with open(input_path, 'r') as f:
            content = f.read()
        
        feature = gherkin_parser.parse_feature(content)
        swift_code = swift_generator.generate_test(feature)
        
        if args.dry_run:
            print(swift_code)
        else:
            output_file = args.output or f"{feature['name'].replace(' ', '')}Tests.swift"
            with open(output_file, 'w') as f:
                f.write(swift_code)
            print(f"✅ Generated: {output_file}")
    
    elif input_path.is_dir():
        # Directory of features
        feature_files = list(input_path.glob('**/*.feature'))
        
        if not feature_files:
            print(f"❌ No .feature files found in {input_path}")
            return 1
        
        print(f"Found {len(feature_files)} feature files")
        
        for feature_file in feature_files:
            with open(feature_file, 'r') as f:
                content = f.read()
            
            feature = gherkin_parser.parse_feature(content)
            swift_code = swift_generator.generate_test(feature)
            
            # Determine output path
            if args.output_dir:
                output_dir = Path(args.output_dir)
                output_dir.mkdir(parents=True, exist_ok=True)
                output_file = output_dir / f"{feature['name'].replace(' ', '')}Tests.swift"
            else:
                output_file = feature_file.with_suffix('.swift')
            
            if args.dry_run:
                print(f"\n{'='*60}")
                print(f"File: {feature_file}")
                print('='*60)
                print(swift_code)
            else:
                with open(output_file, 'w') as f:
                    f.write(swift_code)
                print(f"✅ {feature_file.name} → {output_file}")
        
        if not args.dry_run:
            print(f"\n🎉 Generated {len(feature_files)} test files")
    
    else:
        print(f"❌ Error: {input_path} is not a file or directory")
        return 1
    
    return 0


if __name__ == '__main__':
    sys.exit(main())


