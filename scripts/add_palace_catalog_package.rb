#!/usr/bin/env ruby
# Wire the local PalaceCatalog Swift Package into Palace.xcodeproj for both
# Palace and Palace-noDRM targets. Removes in-target file references for
# all files that moved into the package (32 files), and adds the new
# app-target extension files.
#
# Idempotent. Uses CocoaPods' xcodeproj gem.

require 'xcodeproj'

PROJECT_PATH = ENV['PROJECT_PATH'] || '/Users/mauricework/PalaceProject/ios-core/Palace.xcodeproj'
PACKAGE_RELATIVE = 'Palace/Packages/PalaceCatalog'
PACKAGE_NAME = 'PalaceCatalog'
APP_TARGETS = %w[Palace Palace-noDRM]
ALL_TARGETS = APP_TARGETS + %w[PalaceTests]
TARGETS = ALL_TARGETS

# Files that moved into the package — remove their PBXFileReferences
FILES_TO_REMOVE = %w[
  Palace/OPDS/TPPOPDSAcquisition.swift
  Palace/OPDS/TPPOPDSAcquisitionAvailability.swift
  Palace/OPDS/TPPOPDSAcquisitionPath.swift
  Palace/OPDS/TPPOPDSAttribute.swift
  Palace/OPDS/TPPOPDSCategory.swift
  Palace/OPDS/TPPOPDSEntry.swift
  Palace/OPDS/TPPOPDSEntryGroupAttributes.swift
  Palace/OPDS/TPPOPDSFeed.swift
  Palace/OPDS/TPPOPDSGroup.swift
  Palace/OPDS/TPPOPDSIndirectAcquisition.swift
  Palace/OPDS/TPPOPDSLink.swift
  Palace/OPDS/TPPOPDSRelation.swift
  Palace/OPDS/TPPOPDSType.swift
  Palace/Utilities/Parsing/TPPXML.swift
  Palace/Utilities/TPPNull.swift
  Palace/Utilities/Concurrency/TPPAsync.swift
  Palace/Utilities/Date-Time/Date+TPPDateAdditions.swift
  Palace/Utilities/Localization/String+HTMLEntities.swift
  Palace/Utilities/Localization/String+TPPStringAdditions.swift
  Palace/ErrorHandling/TPPProblemDocument.swift
  Palace/Catalog/TPPOpenSearchDescription.swift
  Palace/CatalogDomain/Repository/CatalogRepository.swift
  Palace/CatalogDomain/Models/CatalogModels.swift
  Palace/CatalogDomain/API/CatalogAPI.swift
  Palace/CatalogDomain/Parsing/OPDSParser.swift
  Palace/OPDS2/OPDS2AuthenticationDocument.swift
  Palace/OPDS2/OPDS2CatalogsFeed.swift
  Palace/OPDS2/OPDS2Link.swift
  Palace/OPDS2/OPDS2LinkArray.swift
  Palace/OPDS2/OPDS2Publication.swift
  Palace/OPDS2/Models/OPDS2Feed.swift
]

# New app-target Swift files (TPPBook bridge + DI conformance).
# (group_path => [filename, ...])
NEW_FILES = {
  'Palace/ErrorHandling' => ['TPPProblemDocument+Localized.swift'],
  'Palace/FeatureFlags' => ['RemoteFeatureFlags+PalaceCatalog.swift'],
  'Palace/OPDS' => ['TPPOPDSFeed+Networking.swift'],
}

# Test mock added in PalaceTests
NEW_TEST_FILES = {
  'PalaceTests/Mocks' => ['MockFeatureFlagProvider.swift'],
}

project = Xcodeproj::Project.open(PROJECT_PATH)

# ── Remove old file references ──────────────────────────────────────────────
removed = []
FILES_TO_REMOVE.each do |relative|
  refs = project.files.select { |f| f.real_path.to_s.end_with?(relative) }
  refs.each do |ref|
    ref.remove_from_project
    removed << relative
  end
end
puts "Removed #{removed.size} file refs"

# ── Add new app-target Swift files to their groups + Sources phases ─────────
NEW_FILES.each do |group_path, files|
  group = project.main_group.find_subpath(group_path, false)
  raise "Group #{group_path} not found" unless group
  files.each do |basename|
    file_ref = group.files.find { |f| f.path == basename }
    if file_ref.nil?
      file_ref = group.new_reference(basename)
      puts "Created PBXFileReference for #{group_path}/#{basename}"
    end
    APP_TARGETS.each do |target_name|
      target = project.targets.find { |t| t.name == target_name }
      raise "Target #{target_name} not found" unless target
      unless target.source_build_phase.files_references.include?(file_ref)
        target.add_file_references([file_ref])
        puts "  added #{basename} to #{target_name} Sources"
      end
    end
  end
end

# ── Add new test files to PalaceTests target ────────────────────────────────
NEW_TEST_FILES.each do |group_path, files|
  group = project.main_group.find_subpath(group_path, false)
  raise "Group #{group_path} not found" unless group
  files.each do |basename|
    file_ref = group.files.find { |f| f.path == basename }
    if file_ref.nil?
      file_ref = group.new_reference(basename)
      puts "Created PBXFileReference for #{group_path}/#{basename}"
    end
    test_target = project.targets.find { |t| t.name == 'PalaceTests' }
    unless test_target.source_build_phase.files_references.include?(file_ref)
      test_target.add_file_references([file_ref])
      puts "  added #{basename} to PalaceTests Sources"
    end
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
  puts "Reusing existing XCLocalSwiftPackageReference for #{PACKAGE_RELATIVE}"
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
