#!/usr/bin/env ruby
# Wire the local PalaceKeychain Swift Package into Palace.xcodeproj for both
# Palace and Palace-noDRM targets, also add as a dep for PalaceTests, and
# remove the in-target TPPKeychain.swift + TPPKeychainStoredVariable.swift
# entries (they now live in Palace/Packages/PalaceKeychain).
#
# Also removes the in-target TPPKeychainTests.swift, TPPKeychainSwiftTests.swift,
# and TPPKeychainStoredVariableTests.swift entries from PalaceTests (they
# moved into the package's Tests/PalaceKeychainTests directory).
#
# Idempotent. Uses CocoaPods' xcodeproj gem (preinstalled on macOS dev machines).

require 'xcodeproj'

PROJECT_PATH = '/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj'
PACKAGE_RELATIVE = 'Palace/Packages/PalaceKeychain'
PACKAGE_NAME = 'PalaceKeychain'
APP_TARGETS = %w[Palace Palace-noDRM]
ALL_TARGETS = APP_TARGETS + %w[PalaceTests]
TARGETS = ALL_TARGETS

# Source files to remove from the project (moved into the package)
FILES_TO_REMOVE = %w[
  Palace/Keychain/TPPKeychain.swift
  Palace/Keychain/TPPKeychainStoredVariable.swift
  PalaceTests/TPPKeychainTests.swift
  PalaceTests/Keychain/TPPKeychainSwiftTests.swift
  PalaceTests/Keychain/TPPKeychainStoredVariableTests.swift
]

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Remove old files ────────────────────────────────────────────────────────
removed = []
FILES_TO_REMOVE.each do |relative|
  ref = project.files.find { |f| f.real_path.to_s.end_with?(relative) }
  next unless ref
  ref.remove_from_project
  removed << relative
end
puts "Removed file refs: #{removed}"

# ── Add local Swift package reference ───────────────────────────────────────
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
  puts "Reusing existing XCLocalSwiftPackageReference"
end

# ── Add product dependency + framework link to each target ──────────────────
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

  # Frameworks link
  frameworks_phase = target.frameworks_build_phase
  already_linked = frameworks_phase.files.any? do |bf|
    bf.product_ref == product_dep
  end
  unless already_linked
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = product_dep
    frameworks_phase.files << bf
    puts "  linked #{PACKAGE_NAME} in #{target_name} Frameworks phase"
  end
end

project.save
puts "Saved #{PROJECT_PATH}"
