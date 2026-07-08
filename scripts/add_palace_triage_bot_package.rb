#!/usr/bin/env ruby
# Wire the local PalaceTriageBot Swift Package into Palace.xcodeproj.
#
# Products:
#   - TriageBotCore  : pure-Swift business logic. Linked into Palace,
#                      Palace-noDRM, and PalaceTests (so reducer-level tests
#                      can live in PalaceTests too if we ever want them
#                      cross-bundle).
#   - TriageBotIOS   : iOS-native adapters (UIPasteboard, OSLog, NWPathMonitor).
#                      Linked into Palace + Palace-noDRM only.
#   - TriageBotUI    : SwiftUI chat surface. Linked into Palace + Palace-noDRM
#                      only.
#
# Idempotent. Safe to re-run after package edits.

require 'xcodeproj'

PROJECT_PATH = '/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj'
PACKAGE_RELATIVE = 'Palace/Packages/PalaceTriageBot'

# product_name => [target_names]
PRODUCT_TARGETS = {
  'TriageBotCore' => %w[Palace Palace-noDRM PalaceTests],
  'TriageBotIOS'  => %w[Palace Palace-noDRM],
  'TriageBotUI'   => %w[Palace Palace-noDRM]
}

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Local Swift package reference ──────────────────────────────────────────
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

# ── Product dependencies + framework links ─────────────────────────────────
PRODUCT_TARGETS.each do |product_name, target_names|
  target_names.each do |target_name|
    target = project.targets.find { |t| t.name == target_name }
    raise "Target #{target_name} not found" unless target

    product_dep = target.package_product_dependencies.find do |d|
      d.product_name == product_name && d.package == local_ref
    end
    if product_dep.nil?
      product_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
      product_dep.product_name = product_name
      product_dep.package = local_ref
      target.package_product_dependencies << product_dep
      puts "  added product dependency #{product_name} to #{target_name}"
    end

    frameworks_phase = target.frameworks_build_phase
    already_linked = frameworks_phase.files.any? { |bf| bf.product_ref == product_dep }
    unless already_linked
      bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
      bf.product_ref = product_dep
      frameworks_phase.files << bf
      puts "  linked #{product_name} in #{target_name} Frameworks phase"
    end
  end
end

project.save
puts "Saved #{PROJECT_PATH}"
