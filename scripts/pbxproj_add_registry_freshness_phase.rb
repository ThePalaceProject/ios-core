#!/usr/bin/env ruby
# frozen_string_literal: true

# pbxproj_add_registry_freshness_phase.rb — adds a "Check Registry Snapshot
# Freshness" Run Script build phase to the Palace and Palace-noDRM targets.
#
# The script (scripts/check_registry_snapshot_freshness.sh) emits an Xcode-style
# `warning:` line if Palace/Accounts/Library/bundled_registry.json is older than
# REGISTRY_SNAPSHOT_THRESHOLD_DAYS (default 30 days). The build phase runs on
# every build — including manual Xcode Organizer archives — so distribution
# paths that bypass `fastlane refresh_registry_snapshot` still surface the
# stale-snapshot signal.
#
# Idempotent: re-running this script when the phase already exists is a no-op.

require 'xcodeproj'

REPO_ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(REPO_ROOT, 'Palace.xcodeproj')
PHASE_NAME = 'Check Registry Snapshot Freshness'
TARGETS = %w[Palace Palace-noDRM].freeze
SHELL_SCRIPT = <<~SH
  # Emits an Xcode-style warning when bundled_registry.json is stale.
  # Always exits 0; the warning is the signal.
  bash "$SRCROOT/scripts/check_registry_snapshot_freshness.sh"
SH

project = Xcodeproj::Project.open(PROJECT_PATH)
added = 0
skipped = 0

TARGETS.each do |target_name|
  target = project.native_targets.find { |t| t.name == target_name }
  unless target
    warn "skip: target #{target_name} not found"
    next
  end

  existing = target.shell_script_build_phases.find { |p| p.name == PHASE_NAME }
  if existing
    puts "skip: '#{PHASE_NAME}' already present on #{target_name}"
    skipped += 1
    next
  end

  phase = target.new_shell_script_build_phase(PHASE_NAME)
  phase.shell_path = '/bin/sh'
  phase.shell_script = SHELL_SCRIPT
  phase.input_paths = ['$(SRCROOT)/Palace/Accounts/Library/bundled_registry.json']
  phase.output_paths = []
  # Always run — the freshness check is cheap and idempotent. Skipping it
  # on dependency analysis would defeat its purpose (catching stale data
  # the engineer hasn't touched).
  phase.always_out_of_date = '1'
  phase.run_only_for_deployment_postprocessing = '0'
  phase.show_env_vars_in_log = '0'

  # Reorder so the freshness check runs first — surfacing the warning
  # early in the build log keeps it visible above the Swift compile noise.
  target.build_phases.delete(phase)
  target.build_phases.unshift(phase)

  added += 1
  puts "added: '#{PHASE_NAME}' to #{target_name}"
end

if added.zero?
  puts "nothing to do (skipped #{skipped})"
else
  project.save
  puts "saved Palace.xcodeproj (added #{added}, skipped #{skipped})"
end
