#!/usr/bin/env ruby
# Phase 6 PR4 — A1 pbxproj surgery.
#
# Removes file refs for `Palace/Network/TPPUserFriendlyError.swift` and
# `Palace/Network/TPPRequestExecuting.swift` (now live in PalaceNetwork).
#
# Adds the new app-target file `Palace/ErrorHandling/NSError+ProblemDocument.swift`
# to the ErrorHandling group and to the Sources build phase of both Palace
# and Palace-noDRM targets.
#
# PalaceNetwork is already wired into both targets (PR3 #882). This script
# only handles the file moves.
#
# Idempotent. Uses CocoaPods' xcodeproj gem.

require 'xcodeproj'

PROJECT_PATH = File.expand_path('../Palace.xcodeproj', __dir__)
APP_TARGETS = %w[Palace Palace-noDRM]

# Files to remove (moved into PalaceNetwork)
FILES_TO_REMOVE = %w[
  Palace/Network/TPPUserFriendlyError.swift
  Palace/Network/TPPRequestExecuting.swift
]

# New file to add to the app target (NSError extension, depends on TPPProblemDocument)
NEW_FILE_RELATIVE = 'Palace/ErrorHandling/NSError+ProblemDocument.swift'
NEW_FILE_NAME = File.basename(NEW_FILE_RELATIVE)
ERROR_HANDLING_GROUP_NAME = 'ErrorHandling'

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Remove old files ────────────────────────────────────────────────────────
removed = []
FILES_TO_REMOVE.each do |relative|
  ref = project.files.find { |f| f.real_path.to_s.end_with?(relative) }
  next unless ref
  ref.remove_from_project
  removed << relative
end
puts "Removed file refs: #{removed.inspect}"

# ── Locate the ErrorHandling group (the source-code group, not the Tests one) ─
error_group = nil
project.main_group.recursive_children.each do |child|
  next unless child.is_a?(Xcodeproj::Project::Object::PBXGroup)
  next unless child.name == ERROR_HANDLING_GROUP_NAME || child.path == ERROR_HANDLING_GROUP_NAME
  # Prefer the one whose real_path ends with "Palace/ErrorHandling"
  rp = child.real_path.to_s
  if rp.end_with?('Palace/ErrorHandling') || rp.end_with?("Palace/#{ERROR_HANDLING_GROUP_NAME}")
    error_group = child
    break
  end
end
raise "ErrorHandling group (real_path …/Palace/ErrorHandling) not found" unless error_group
puts "Using ErrorHandling group: #{error_group.real_path}"

# ── Add or reuse the file ref ──────────────────────────────────────────────
existing_ref = project.files.find { |f| f.real_path.to_s.end_with?(NEW_FILE_RELATIVE) }
file_ref = existing_ref
if file_ref.nil?
  file_ref = error_group.new_file(NEW_FILE_NAME)
  puts "Created file ref for #{NEW_FILE_RELATIVE}"
else
  puts "Reusing existing file ref for #{NEW_FILE_RELATIVE}"
end

# ── Add to Sources build phase of each app target ──────────────────────────
APP_TARGETS.each do |target_name|
  target = project.targets.find { |t| t.name == target_name }
  raise "Target #{target_name} not found" unless target
  sources_phase = target.source_build_phase
  already_added = sources_phase.files_references.any? { |r| r == file_ref }
  unless already_added
    sources_phase.add_file_reference(file_ref)
    puts "  added #{NEW_FILE_NAME} to #{target_name} Sources phase"
  else
    puts "  #{target_name} already has #{NEW_FILE_NAME}"
  end
end

project.save
puts "Saved #{PROJECT_PATH}"
