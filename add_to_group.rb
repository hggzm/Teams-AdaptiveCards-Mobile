require 'xcodeproj'

project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Remove any existing references first
project.files.select { |f| f.path&.include?('SwiftAdaptiveCardsWrapper') }.each do |file_ref|
  puts "Removing existing: #{file_ref.path}"
  file_ref.remove_from_project
end

# Find the AdaptiveCards group (the inner one with the source files)
def find_group_recursive(group, name)
  return group if group.name == name || group.path == name
  group.groups.each do |subgroup|
    result = find_group_recursive(subgroup, name)
    return result if result
  end
  nil
end

adaptivecards_group = find_group_recursive(project.main_group, 'AdaptiveCards')

if adaptivecards_group
  puts "Found group: #{adaptivecards_group.name} at #{adaptivecards_group.hierarchy_path}"
  
  # Add files to the same group where other .m files are
  file_ref_h = adaptivecards_group.new_reference('SwiftAdaptiveCardsWrapper.h')
  file_ref_m = adaptivecards_group.new_reference('SwiftAdaptiveCardsWrapper.m')
  
  # Find target and add files
  target = project.targets.find { |t| t.name == 'AdaptiveCards' }
  if target
    target.source_build_phase.add_file_reference(file_ref_m)
    target.headers_build_phase.add_file_reference(file_ref_h, true)
    puts "Added files to target"
  end
  
  project.save
  puts "Saved project"
else
  puts "Could not find AdaptiveCards group"
  puts "Available groups:"
  project.main_group.recursive_children.select { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) }.each do |g|
    puts "  - #{g.name} (#{g.path})"
  end
end
