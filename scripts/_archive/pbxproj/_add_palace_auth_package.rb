#!/usr/bin/env ruby
# One-shot: wire the local PalaceAuth Swift Package into Palace.xcodeproj for
# Palace, Palace-noDRM, and PalaceTests targets. Models on
# add_palace_catalog_package.rb but does NOT remove any in-target file
# references — the trunk extraction is deferred per swarm_ea663ab6 contract
# revision #2 (recovery scope).
#
# Idempotent. Uses CocoaPods' xcodeproj gem.

require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] || '/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj'
PACKAGE_RELATIVE = 'Palace/Packages/PalaceAuth'
PACKAGE_NAME = 'PalaceAuth'
APP_TARGETS = %w[Palace Palace-noDRM]
ALL_TARGETS = APP_TARGETS + %w[PalaceTests]

# Files that moved into the package (impl 1) — remove main-target file refs
FILES_TO_REMOVE = %w[
  Palace/SignInLogic/AuthReducer.swift
  Palace/SignInLogic/TokenRequest.swift
  Palace/SignInLogic/TPPSAMLHelper.swift
  Palace/SignInLogic/TPPUserAccountFrontEndValidation.swift
  Palace/SignInLogic/URLResponse+TPPAuthentication.swift
]

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Remove old file references for files moved into the package ────────────
removed = []
FILES_TO_REMOVE.each do |relative|
  refs = project.files.select { |f| f.real_path.to_s.end_with?(relative) }
  refs.each do |ref|
    ref.remove_from_project
    removed << relative
  end
end
puts "Removed #{removed.size} file refs (moved-into-package)" unless removed.empty?

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
  puts "Reusing existing XCLocalSwiftPackageReference for #{PACKAGE_RELATIVE}"
end

# ── Add product dependency + framework link to each target ──────────────────
ALL_TARGETS.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  raise "Target #{target_name} not found" unless target

  product_dep = target.package_product_dependencies.find { |d| d.product_name == PACKAGE_NAME }
  if product_dep.nil?
    product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    product_dep.product_name = PACKAGE_NAME
    product_dep.package = local_ref
    target.package_product_dependencies << product_dep
    puts "  added product dependency #{PACKAGE_NAME} to #{target_name}"
  else
    puts "  reusing product dependency #{PACKAGE_NAME} on #{target_name}"
  end

  frameworks_phase = target.frameworks_build_phase
  already_linked = frameworks_phase.files.any? { |bf| bf.product_ref == product_dep }
  unless already_linked
    bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
    bf.product_ref = product_dep
    frameworks_phase.files << bf
    puts "  linked #{PACKAGE_NAME} in #{target_name} Frameworks phase"
  end
end

project.save
puts "Saved #{PROJECT_PATH}"
