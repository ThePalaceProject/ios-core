#!/usr/bin/env ruby
# Wire the local PalaceDownloads Swift Package into Palace.xcodeproj for the
# Palace, Palace-noDRM and PalaceTests targets, and drop the in-target file
# references for the files that moved into the package.
#
# Modeled on scripts/add_palace_utilities_package.rb: an extraction both
# removes file references and adds one package product, which
# pbxproj_add_swift.rb (add-only) does not do.
#
# Idempotent. Uses CocoaPods' xcodeproj gem.

require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] ||
               File.expand_path('../Palace.xcodeproj', __dir__)
PACKAGE_RELATIVE = 'Palace/Packages/PalaceDownloads'
PACKAGE_NAME = 'PalaceDownloads'
APP_TARGETS = %w[Palace Palace-noDRM]
TARGETS = APP_TARGETS + %w[PalaceTests]

# Files that moved into Sources/PalaceDownloads.
FILES_TO_REMOVE = %w[
  Palace/MyBooks/ReturnReducer.swift
  Palace/MyBooks/RedirectPolicy.swift
  Palace/MyBooks/UserRetryTracker.swift
  Palace/MyBooks/LoanEvictionPolicy.swift
  Palace/MyBooks/DownloadAccountContext.swift
]

# Test files that moved into Tests/PalaceDownloadsTests.
TEST_FILES_TO_REMOVE = %w[
  PalaceTests/MyBooks/RedirectPolicyTests.swift
  PalaceTests/MyBooks/UserRetryTrackerTests.swift
  PalaceTests/MyBooks/LoanEvictionPolicyTests.swift
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
