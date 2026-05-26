#!/usr/bin/env ruby
# frozen_string_literal: true

# pbxproj_add_swift.rb — add Swift source files to Palace.xcodeproj cleanly.
#
# Removes the 6-hand-edit tax (PBXBuildFile×N targets, PBXFileReference,
# PBXGroup membership, PBXSourcesBuildPhase×N targets) by delegating to the
# xcodeproj gem (the same library CocoaPods uses, well-tested round-trip).
#
# Usage:
#   pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] \
#                         [--group Palace/SignInLogic] \
#                         [--project Palace.xcodeproj] \
#                         [--dry-run] [--verbose] [--force-add] \
#                         FILE [FILE ...]
#
# Defaults:
#   --targets   Palace,Palace-noDRM   (production targets; tests auto-route)
#   --group     inferred from file path (parent dir under repo root)
#   --project   Palace.xcodeproj
#
# Test files (path matches PalaceTests/) auto-route to PalaceTests target,
# overriding --targets unless --force-targets is set.
#
# Idempotent: existing files are skipped (matched by full path under repo root).
# Use --force-add to bypass the dedup check (rare collision case).
#
# Exit codes:
#   0  success (or no-op)
#   1  validation error (missing file, unknown target, malformed project)
#   2  partial success (some failed but pbxproj saved)

require 'optparse'
require 'pathname'

begin
  require 'xcodeproj'
rescue LoadError
  warn "ERROR: xcodeproj gem not installed. Run: gem install xcodeproj"
  exit 1
end

REPO_ROOT = Pathname.new(File.expand_path('..', __dir__))
DEFAULT_PROJECT = REPO_ROOT.join('Palace.xcodeproj').to_s
DEFAULT_PROD_TARGETS = %w[Palace Palace-noDRM].freeze
TEST_TARGET = 'PalaceTests'

def parse_args(argv)
  opts = {
    targets: DEFAULT_PROD_TARGETS.join(','),
    force_targets: false,
    force_add: false,
    group: nil,
    project: DEFAULT_PROJECT,
    dry_run: false,
    verbose: false,
  }

  parser = OptionParser.new do |o|
    o.banner = "Usage: pbxproj_add_swift.rb [options] FILE [FILE ...]"
    o.on('--targets T', "Comma-separated targets (default: #{opts[:targets]})") { |v| opts[:targets] = v }
    o.on('--force-targets', 'Use --targets even for test files') { opts[:force_targets] = true }
    o.on('--force-add', 'Add file even if same-named ref exists') { opts[:force_add] = true }
    o.on('--group G', 'PBXGroup path (default: inferred from file dir)') { |v| opts[:group] = v }
    o.on('--project P', "Project path (default: #{DEFAULT_PROJECT})") { |v| opts[:project] = v }
    o.on('--dry-run', 'Report without writing') { opts[:dry_run] = true }
    o.on('--verbose', '-v', 'Per-file diagnostics') { opts[:verbose] = true }
    o.on('-h', '--help') { puts o; exit 0 }
  end
  parser.parse!(argv)
  opts[:files] = argv
  if opts[:files].empty?
    warn parser.help
    warn "\nERROR: at least one file argument required"
    exit 1
  end
  opts
end

def normalize_file(arg)
  p = Pathname.new(arg)
  p = p.absolute? ? p : REPO_ROOT.join(p)
  unless p.exist?
    warn "ERROR: file does not exist: #{p}"
    exit 1
  end
  unless p.extname == '.swift'
    warn "ERROR: only .swift supported, got #{p.extname}"
    exit 1
  end
  p.relative_path_from(REPO_ROOT)
end

def test_file?(rel_path)
  parts = rel_path.to_s.split('/')
  parts.first == 'PalaceTests' || rel_path.basename.to_s.end_with?('Tests.swift')
end

def resolve_targets(rel_path, requested, force_targets)
  return [TEST_TARGET] if !force_targets && test_file?(rel_path)
  requested
end

def infer_group(rel_path)
  rel_path.dirname.to_s
end

# Build a {full_path => PBXFileReference} map by walking groups.
# `full_path` is repo-relative (e.g. "Palace/SignInLogic/AuthReducer.swift").
def build_file_index(project)
  index = {}
  project.files.each do |f|
    # f.real_path is absolute; relativize to repo root
    abs = Pathname.new(f.real_path)
    begin
      rel = abs.relative_path_from(REPO_ROOT).to_s
    rescue ArgumentError
      next # skip files outside repo
    end
    index[rel] = f
  end
  index
end

# Resolve a slash-delimited group path, creating missing groups along the way.
# `group_path` is relative to repo root (e.g. "Palace/SignInLogic").
# Each group's `path` attribute is set to its segment so on-disk files
# resolve correctly.
def find_or_create_group(project, group_path)
  segments = group_path.split('/')
  current = project.main_group
  segments.each do |seg|
    child = current.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && (c.display_name == seg || c.path == seg || c.name == seg) }
    if child.nil?
      child = current.new_group(seg, seg)
    end
    current = child
  end
  current
end

def find_target(project, name)
  project.targets.find { |t| t.name == name }
end

def add_one(project, file_index, rel_path, targets, group_path, dry_run, verbose, force_add)
  full_key = rel_path.to_s
  if !force_add && file_index.key?(full_key)
    puts "  skip   #{rel_path} (already in pbxproj)" if verbose
    return :skipped
  end

  if dry_run
    puts "  WOULD  #{rel_path} → group=#{group_path} targets=#{targets.join(',')}"
    return :added
  end

  group = find_or_create_group(project, group_path)
  # new_file expects path relative to the group's source tree. Use the file's
  # leaf name with SOURCE_ROOT-relative full path to match existing convention.
  file_ref = group.new_file(REPO_ROOT.join(rel_path).to_s)

  build_phase_count = 0
  targets.each do |target_name|
    target = find_target(project, target_name)
    if target.nil?
      warn "  FAIL   #{rel_path}: target '#{target_name}' not in project"
      return :failed
    end
    target.add_file_references([file_ref])
    build_phase_count += 1
  end

  file_index[full_key] = file_ref
  puts "  add    #{rel_path} → group=#{group_path} targets=#{targets.join(',')} (#{build_phase_count} build phase entries)" if verbose
  :added
end

def main(argv)
  opts = parse_args(argv)

  project_path = Pathname.new(opts[:project])
  project_path = REPO_ROOT.join(project_path) unless project_path.absolute?
  unless project_path.exist?
    warn "ERROR: project not found: #{project_path}"
    return 1
  end

  project = Xcodeproj::Project.open(project_path.to_s)
  target_names = project.targets.map(&:name)
  requested = opts[:targets].split(',').map(&:strip).reject(&:empty?)

  unknown = requested.reject { |t| target_names.include?(t) }
  unless unknown.empty?
    warn "ERROR: unknown target(s): #{unknown.join(',')}. Known: #{target_names.join(',')}"
    return 1
  end

  file_index = build_file_index(project)

  counts = { added: 0, skipped: 0, failed: 0 }

  opts[:files].each do |raw|
    rel_path = normalize_file(raw)
    targets = resolve_targets(rel_path, requested, opts[:force_targets])
    group_path = opts[:group] || infer_group(rel_path)

    targets_unknown = targets.reject { |t| target_names.include?(t) }
    unless targets_unknown.empty?
      warn "  FAIL   #{rel_path}: target(s) not in project: #{targets_unknown.join(',')}"
      counts[:failed] += 1
      next
    end

    result = add_one(project, file_index, rel_path, targets, group_path,
                     opts[:dry_run], opts[:verbose], opts[:force_add])
    counts[result] += 1
  end

  if !opts[:dry_run] && counts[:added].positive?
    project.save
    puts "saved #{project_path.relative_path_from(REPO_ROOT)}" if opts[:verbose]
  end

  puts "\nadded=#{counts[:added]} skipped=#{counts[:skipped]} failed=#{counts[:failed]}"

  return 2 if counts[:failed].positive? && counts[:added].positive?
  return 1 if counts[:failed].positive?
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
