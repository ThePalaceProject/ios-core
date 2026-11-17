#!/usr/bin/env ruby
# frozen_string_literal: true

# pbxproj_add_swift.rb — add source files to Palace.xcodeproj cleanly.
#
# Handles Swift, Objective-C and Objective-C++ sources plus their headers.
#
# Removes the 6-hand-edit tax (PBXBuildFile×N targets, PBXFileReference,
# PBXGroup membership, PBXSourcesBuildPhase×N targets) by delegating to the
# xcodeproj gem (the same library CocoaPods uses, well-tested round-trip).
#
# Usage:
#   pbxproj_add_swift.rb [--targets Palace,Palace-noDRM] \
#                         [--group Palace/SignInLogic] \
#                         [--project Palace.xcodeproj] \
#                         [--repo-root /path/to/checkout] \
#                         [--dry-run] [--verbose] [--force-add] \
#                         FILE [FILE ...]
#
# Defaults:
#   --targets   Palace,Palace-noDRM   (production targets; tests auto-route)
#   --group     inferred from file path (parent dir under repo root)
#   --project   Palace.xcodeproj
#   --repo-root the directory holding --project, else this script's checkout
#
# Test files (path matches PalaceTests/) auto-route to PalaceTests target,
# overriding --targets unless --force-targets is set. Headers get a file
# reference and group membership but no Sources phase entry.
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

# The checkout this copy of the script lives in. Only the fallback root: see
# resolve_repo_root for the order the run actually uses.
SCRIPT_REPO_ROOT = Pathname.new(File.expand_path('..', __dir__))
DEFAULT_PROJECT_NAME = 'Palace.xcodeproj'
DEFAULT_PROD_TARGETS = %w[Palace Palace-noDRM].freeze
TEST_TARGET = 'PalaceTests'

# Every path in a pbxproj is relative to the checkout holding the project, so
# one wrong root writes groups that resolve on one machine only. Ruby warns on
# constant reassignment, so the resolved root lives in an accessor instead.
module Repo
  class << self
    attr_accessor :root
  end
  self.root = SCRIPT_REPO_ROOT
end

# Which checkout the file arguments and the project belong to, most specific
# first:
#   1. --repo-root, for a project that does not sit at its checkout's root.
#   2. the directory holding --project. Palace.xcodeproj sits at the root of
#      its checkout, so that directory is a far better guess than wherever this
#      script happens to live. An absolute --project into a sibling checkout
#      used to resolve every file against this script's own root, producing a
#      group named after the other directory with a path only the machine that
#      ran it could resolve.
#   3. this script's checkout, which keeps every existing invocation identical.
def resolve_repo_root(opts)
  if opts[:repo_root]
    root = Pathname.new(File.expand_path(opts[:repo_root]))
    unless root.directory?
      warn "ERROR: --repo-root is not a directory: #{root}"
      exit 1
    end
    return root
  end

  if opts[:project]
    given = Pathname.new(opts[:project])
    # A relative --project has always resolved against this script's checkout,
    # not the working directory; keep that so the default stays unchanged.
    given = SCRIPT_REPO_ROOT.join(given) unless given.absolute?
    return Pathname.new(File.expand_path(given.to_s)).dirname
  end

  SCRIPT_REPO_ROOT
end

def parse_args(argv)
  opts = {
    targets: DEFAULT_PROD_TARGETS.join(','),
    force_targets: false,
    force_add: false,
    group: nil,
    project: nil,
    repo_root: nil,
    dry_run: false,
    verbose: false,
  }

  parser = OptionParser.new do |o|
    o.banner = "Usage: pbxproj_add_swift.rb [options] FILE [FILE ...]"
    o.on('--targets T', "Comma-separated targets (default: #{opts[:targets]})") { |v| opts[:targets] = v }
    o.on('--force-targets', 'Use --targets even for test files') { opts[:force_targets] = true }
    o.on('--force-add', 'Add file even if same-named ref exists') { opts[:force_add] = true }
    o.on('--group G', 'PBXGroup path (default: inferred from file dir)') { |v| opts[:group] = v }
    o.on('--project P', "Project path (default: #{DEFAULT_PROJECT_NAME} in the repo root)") { |v| opts[:project] = v }
    o.on('--repo-root R', 'Checkout the files and project belong to',
         '(default: the directory holding --project, else this script\'s checkout)') { |v| opts[:repo_root] = v }
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

# Sources-phase languages. Headers get a file reference and group membership
# but no build phase, which is how AdobeDRMContainer.h is already carried.
COMPILED_EXTENSIONS = ['.swift', '.m', '.mm', '.c', '.cpp', '.cc'].freeze
# Types xcodeproj does not infer from the extension.
EXPLICIT_FILE_TYPES = {
  '.mm' => 'sourcecode.cpp.objcpp',
  '.m' => 'sourcecode.c.objc',
  '.cpp' => 'sourcecode.cpp.cpp',
  '.cc' => 'sourcecode.cpp.cpp',
  '.c' => 'sourcecode.c.c',
  '.hpp' => 'sourcecode.cpp.h'
}.freeze
HEADER_EXTENSIONS = ['.h', '.hpp'].freeze

def normalize_file(arg)
  p = Pathname.new(arg)
  p = p.absolute? ? p : Repo.root.join(p)
  unless p.exist?
    warn "ERROR: file does not exist: #{p}"
    exit 1
  end
  unless COMPILED_EXTENSIONS.include?(p.extname) || HEADER_EXTENSIONS.include?(p.extname)
    supported = (COMPILED_EXTENSIONS + HEADER_EXTENSIONS).join(', ')
    warn "ERROR: unsupported extension #{p.extname}; supported: #{supported}"
    exit 1
  end
  repo_relative(p)
end

# A file above the root has no expressible group, so refuse instead of writing
# one. The caller who hit this ran the script from one checkout against another
# with absolute paths: the inferred group began '../<other-checkout>', Xcode
# recorded a group with that directory's name as its `path`, the build worked on
# that machine, and CI reported "Build input file cannot be found" for a file
# the commit plainly contained.
def repo_relative(abs_path)
  rel = begin
    abs_path.relative_path_from(Repo.root)
  rescue ArgumentError
    nil
  end
  return rel unless rel.nil? || rel.to_s.split('/').include?('..')

  warn "ERROR: #{abs_path}"
  warn "  is outside the repo root #{Repo.root}"
  warn "  (relative to that root: #{rel || 'no relative path exists'})."
  warn "  Adding it would create an Xcode group named after a directory outside"
  warn "  the project, which resolves only on this machine."
  warn "  Pass --repo-root <checkout> to name the checkout these paths belong to."
  exit 1
end

# --group is caller-supplied, so it needs the same guarantee the inferred group
# gets: relative to the repo root, no '..', no absolute path. An absolute group
# also splits into an empty leading segment and would create a nameless group.
def validate_group_path!(group_path, rel_path)
  segments = group_path.to_s.split('/')
  return unless group_path.to_s.start_with?('/') ||
                segments.include?('..') ||
                segments.any?(&:empty?)

  warn "ERROR: refusing group path #{group_path.inspect} for #{rel_path}."
  warn "  A group path must be relative to the repo root #{Repo.root}"
  warn "  with no '..' segments; anything else writes a path into the project"
  warn "  file that resolves only on this machine."
  warn "  Pass --repo-root <checkout> so the paths resolve inside that checkout."
  exit 1
end

def test_file?(rel_path)
  parts = rel_path.to_s.split('/')
  parts.first == 'PalaceTests' || rel_path.basename.to_s.end_with?('Tests.swift')
end

def resolve_targets(rel_path, requested, force_targets)
  return [] if HEADER_EXTENSIONS.include?(rel_path.extname)
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
      rel = abs.relative_path_from(Repo.root).to_s
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
      assert_bare_component!(seg, group_path)
      child = current.new_group(seg, seg)
    end
    current = child
  end
  current
end

# The last line of defence, and the only one that holds however the root was
# resolved: a group this script creates carries one bare directory name as its
# path, never a path with separators and never '..'. A filesystem path in a
# group's `path` resolves on one machine only. Traversal of groups the project
# already has is untouched — some of those legitimately carry a multi-component
# path — so this guards creation alone.
def assert_bare_component!(segment, group_path)
  return unless segment.empty? || segment == '..' || segment.include?('/')

  warn "ERROR: refusing to create the group #{segment.inspect} from group path #{group_path.inspect}."
  warn "  A group's path must be one bare directory name. #{segment.inspect} is not,"
  warn "  so Xcode would record a location that resolves only on this machine."
  warn "  Pass --repo-root <checkout> so the paths resolve inside that checkout."
  exit 1
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
  file_ref = group.new_file(Repo.root.join(rel_path).to_s)
  # xcodeproj infers no type for .mm, so the reference lands without
  # `lastKnownFileType` and a target compiling it has nothing declared (the
  # existing AdobeDRMContainer.mm carries sourcecode.cpp.objcpp). Set it
  # explicitly for the types it does not infer.
  explicit_type = EXPLICIT_FILE_TYPES[rel_path.extname]
  file_ref.last_known_file_type = explicit_type if explicit_type

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

# This script REWRITES the project file. If the file was already staged when it
# ran, the rewrite lands in the working tree only, and `git commit` (which
# commits the index) ships a project file without the entries just added.
#
# That happened on PR #1610: a merge conflict was resolved with
# `checkout --theirs` + `git add`, then this script re-added the extracted view.
# The commit carried zero Sources entries for it while the working tree carried
# four, and CI failed with "cannot find 'AudiobookCoverArt' in scope". Every
# local check passed, because every local check reads the working tree.
def warn_if_already_staged(project_path)
  rel = project_path.relative_path_from(Repo.root).to_s
  status = `git -C #{Repo.root} status --porcelain -- #{rel} 2>/dev/null`
  return if status.nil? || status.empty?

  # An .xcodeproj is a directory, so status can list several files. Take the
  # worst case over every line rather than reading only the first: a line for
  # some other file in the bundle must not mask the one that diverged.
  diverged = status.lines.any? do |line|
    index_state = line[0]
    tree_state = line[1]
    tree_state == 'M' && index_state != ' ' && index_state != '?'
  end
  return unless diverged

  warn ""
  warn "  WARNING: #{rel} was already staged, and this script has just"
  warn "  rewritten it. The new entries are in the working tree but NOT in the"
  warn "  index, so a commit now would omit them and the build would fail on a"
  warn "  target that needs the file."
  warn ""
  warn "  Stage the rewrite before committing:"
  warn "      git add #{rel}"
  warn ""
end

def main(argv)
  opts = parse_args(argv)

  Repo.root = resolve_repo_root(opts)
  puts "repo root #{Repo.root}" if opts[:verbose]

  project_path = Pathname.new(opts[:project] || DEFAULT_PROJECT_NAME)
  project_path = Repo.root.join(project_path) unless project_path.absolute?
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
    validate_group_path!(group_path, rel_path)

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
    puts "saved #{project_path.relative_path_from(Repo.root)}" if opts[:verbose]
    warn_if_already_staged(project_path)
  end

  puts "\nadded=#{counts[:added]} skipped=#{counts[:skipped]} failed=#{counts[:failed]}"

  return 2 if counts[:failed].positive? && counts[:added].positive?
  return 1 if counts[:failed].positive?
  0
end

exit main(ARGV) if __FILE__ == $PROGRAM_NAME
