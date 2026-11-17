#!/usr/bin/env ruby
# Wire the local PalaceUtilities Swift Package into Palace.xcodeproj for the
# Palace, Palace-noDRM and PalaceTests targets, and drop the in-target file
# references for the 20 files that moved into the package.
#
# Modeled on scripts/add_palace_catalog_package.rb — a package extraction both
# REMOVES references and ADDS one package product, which is why
# pbxproj_add_swift.rb (add-only) is the wrong tool for this shape.
#
# Idempotent. Uses CocoaPods' xcodeproj gem.

require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] ||
               File.expand_path('../Palace.xcodeproj', __dir__)
PACKAGE_RELATIVE = 'Palace/Packages/PalaceUtilities'
PACKAGE_NAME = 'PalaceUtilities'
APP_TARGETS = %w[Palace Palace-noDRM]
TARGETS = APP_TARGETS + %w[PalaceTests]

# Files that moved into Sources/PalaceUtilities — remove their PBXFileReferences.
FILES_TO_REMOVE = %w[
  Palace/Utilities/Testing/AccessibilityIdentifiers.swift
  Palace/Utilities/Concurrency/MainActorHelpers.swift
  Palace/Utilities/Concurrency/TPPMainThreadChecker.swift
  Palace/Utilities/SafeDictionary.swift
  Palace/Utilities/Date-Time/Date+NYPLAdditions.swift
  Palace/Utilities/AudiobookSkipIntervalSettings.swift
  Palace/Utilities/Extensions/Dictionary+Extensions.swift
  Palace/Utilities/Extensions/Array+Extensions.swift
  Palace/Utilities/Extensions/String+Extensions.swift
  Palace/Utilities/Extensions/Date+Extensions.swift
  Palace/Utilities/Localization/String+MD5.swift
  Palace/Utilities/Localization/NSString+JSONParse.swift
  Palace/Utilities/Localization/Data+Base64.swift
  Palace/Utilities/Localization/TPPLocalization.swift
  Palace/Utilities/Networking/URL+Extensions.swift
  Palace/Utilities/Networking/NSURL+NYPLURLAdditions.swift
  Palace/Utilities/Networking/URLResponse+NYPL.swift
  Palace/Utilities/EmailAddress.swift
  Palace/Utilities/TPPProcessInfo.swift
  Palace/Utilities/Parsing/TPPJSON.swift
]

# Test files that moved into Tests/PalaceUtilitiesTests.
TEST_FILES_TO_REMOVE = %w[
  PalaceTests/Concurrency/MainActorHelpersTests.swift
  PalaceTests/Concurrency/TPPMainThreadCheckerTests.swift
  PalaceTests/Utilities/EmailAddressTests.swift
  PalaceTests/Utilities/SafeDictionaryTests.swift
  PalaceTests/Utilities/SafeDictionarySyncMirrorTests.swift
  PalaceTests/Utilities/URLExtensionTests.swift
  PalaceTests/Utilities/StringExtensionTests.swift
  PalaceTests/Utilities/StringExtensionsTests.swift
  PalaceTests/Extensions/ArrayExtensionsTests.swift
  PalaceTests/Extensions/DictionaryExtensionsTests.swift
  PalaceTests/Extensions/DataBase64Tests.swift
  PalaceTests/Network/URLResponseNYPLTests.swift
  PalaceTests/Network/URLExtensionsTests.swift
  PalaceTests/Audiobooks/AudiobookSkipIntervalSettingsTests.swift
]

project = Xcodeproj::Project.open(PROJECT_PATH)

removed = []
(FILES_TO_REMOVE + TEST_FILES_TO_REMOVE).each do |relative|
  project.files.select { |f| f.real_path.to_s.end_with?(relative) }.each do |ref|
    ref.remove_from_project
    removed << relative
  end
end
puts "Removed #{removed.size} file refs"

local_ref = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCLocalSwiftPackageReference) &&
    r.relative_path == PACKAGE_RELATIVE
end

if local_ref.nil?
  local_ref = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
  local_ref.relative_path = PACKAGE_RELATIVE
  project.root_object.package_references << local_ref
  puts "Created XCLocalSwiftPackageReference for #{PACKAGE_RELATIVE}"
else
  puts "Reusing existing XCLocalSwiftPackageReference for #{PACKAGE_RELATIVE}"
end

TARGETS.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  raise "Target #{target_name} not found" unless target

  product_dep = target.package_product_dependencies.find { |d| d.product_name == PACKAGE_NAME }
  if product_dep.nil?
    product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product_dep.product_name = PACKAGE_NAME
    product_dep.package = local_ref
    target.package_product_dependencies << product_dep
    puts "  added product dependency #{PACKAGE_NAME} to #{target_name}"
  end

  frameworks_phase = target.frameworks_build_phase
  unless frameworks_phase.files.any? { |bf| bf.product_ref == product_dep }
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = product_dep
    frameworks_phase.files << bf
    puts "  linked #{PACKAGE_NAME} in #{target_name} Frameworks phase"
  end
end

project.save
puts "Saved #{PROJECT_PATH}"
