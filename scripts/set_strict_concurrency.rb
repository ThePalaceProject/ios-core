#!/usr/bin/env ruby
# Sets SWIFT_STRICT_CONCURRENCY on the app targets (NOT the SPM packages, which
# already declare their own Swift 6 language mode). Usage:
#   ruby scripts/set_strict_concurrency.rb <targeted|complete|"">
# Empty string removes the setting (revert). App targets only: Palace, Palace-noDRM.
require 'xcodeproj'

level = ARGV[0]
abort "usage: set_strict_concurrency.rb <targeted|complete|''>" if level.nil?

proj_path = File.join(__dir__, '..', 'Palace.xcodeproj')
project = Xcodeproj::Project.open(proj_path)
app_targets = %w[Palace Palace-noDRM]

changed = 0
project.targets.each do |t|
  next unless app_targets.include?(t.name)
  t.build_configurations.each do |config|
    if level.empty?
      config.build_settings.delete('SWIFT_STRICT_CONCURRENCY')
    else
      config.build_settings['SWIFT_STRICT_CONCURRENCY'] = level
    end
    changed += 1
    puts "  #{t.name} / #{config.name}: SWIFT_STRICT_CONCURRENCY = #{level.empty? ? '(removed)' : level}"
  end
end

project.save
puts "Updated #{changed} build configuration(s)."
