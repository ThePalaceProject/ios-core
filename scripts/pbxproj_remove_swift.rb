#!/usr/bin/env ruby
# Remove source files from Palace.xcodeproj — the counterpart to
# pbxproj_add_swift.rb.
#
# Hand-editing project.pbxproj is forbidden (CLAUDE.md): a file lives in six
# places across two targets, and a partial removal leaves a dangling build file
# that fails the build with no useful message. This drops every reference the
# gem knows about and prunes groups the removal empties.
#
#   ruby scripts/pbxproj_remove_swift.rb FILE [FILE ...]
#   ruby scripts/pbxproj_remove_swift.rb --dry-run FILE
require 'xcodeproj'

dry = ARGV.delete('--dry-run')
paths = ARGV
abort("usage: pbxproj_remove_swift.rb [--dry-run] FILE [FILE ...]") if paths.empty?

project_path = File.expand_path('../Palace.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
wanted = paths.map { |p| p.sub(%r{\A\./}, '') }
removed = Hash.new(0)

project.files.dup.each do |ref|
  full = ref.real_path.to_s.sub("#{File.expand_path('..', __dir__)}/", '')
  next unless wanted.include?(full)
  project.targets.each do |t|
    t.build_phases.each do |phase|
      next unless phase.respond_to?(:files)
      phase.files.dup.each do |bf|
        next unless bf.file_ref == ref
        phase.remove_build_file(bf)
        removed["#{full} (#{t.name})"] += 1
      end
    end
  end
  ref.remove_from_project
  removed["#{full} (file ref)"] += 1
end

# prune groups left with no children
pruned = 0
loop do
  empties = project.groups.select { |g| g.children.empty? && g != project.main_group }
  break if empties.empty?
  empties.each { |g| g.remove_from_project; pruned += 1 }
end

removed.keys.sort.each { |k| puts "  removed #{k}" }
puts "  pruned #{pruned} empty group(s)"
if dry
  puts "DRY RUN — not saved"
else
  project.save
  puts "saved #{project_path}"
end
