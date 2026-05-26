#!/usr/bin/env ruby
# Wire the local PalaceLogging Swift Package into Palace.xcodeproj for both
# Palace and Palace-noDRM targets, remove the in-target Log.swift +
# PersistentLogger.swift entries, and add FirebaseCrashlyticsBridge.swift to
# both targets' Sources phases under the existing Logging group.
#
# Idempotent. Uses CocoaPods' xcodeproj gem (preinstalled on macOS dev machines).

require 'xcodeproj'

PROJECT_PATH = '/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj'
PACKAGE_RELATIVE = 'Palace/Packages/PalaceLogging'
PACKAGE_NAME = 'PalaceLogging'
LOGGING_GROUP_PATH = 'Palace/Logging'
APP_TARGETS = %w[Palace Palace-noDRM]
ALL_TARGETS = APP_TARGETS + %w[PalaceTests]
TARGETS = ALL_TARGETS
BRIDGE_FILE = 'Palace/Logging/FirebaseCrashlyticsBridge.swift'
FILES_TO_REMOVE = %w[Palace/Logging/Log.swift Palace/Logging/PersistentLogger.swift]

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

# ── Add FirebaseCrashlyticsBridge.swift to Logging group ────────────────────
logging_group = project.main_group.find_subpath('Palace/Logging', false)
raise "Logging group not found" unless logging_group

bridge_ref = logging_group.files.find { |f| f.path == File.basename(BRIDGE_FILE) }
if bridge_ref.nil?
  bridge_ref = logging_group.new_reference(File.basename(BRIDGE_FILE))
  puts "Created PBXFileReference for #{BRIDGE_FILE}"
else
  puts "Reusing existing PBXFileReference for #{BRIDGE_FILE}"
end

APP_TARGETS.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  raise "Target #{target_name} not found" unless target
  unless target.source_build_phase.files_references.include?(bridge_ref)
    target.add_file_references([bridge_ref])
    puts "  added #{BRIDGE_FILE} to #{target_name} Sources"
  end
end

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
