require 'xcodeproj'

project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Remove the incorrectly added files
project.files.select { |f| f.path&.include?('SwiftAdaptiveCardsWrapper') }.each do |file_ref|
  puts "Removing: #{file_ref.path}"
  file_ref.remove_from_project
end

# Find the target
target = project.targets.find { |t| t.name == 'AdaptiveCards' }

if target
  # Add with correct relative paths
  file_ref_h = project.main_group.new_reference('SwiftAdaptiveCardsWrapper.h')
  file_ref_h.source_tree = '<group>'
  
  file_ref_m = project.main_group.new_reference('SwiftAdaptiveCardsWrapper.m')
  file_ref_m.source_tree = '<group>'
  
  target.source_build_phase.add_file_reference(file_ref_m)
  target.headers_build_phase.add_file_reference(file_ref_h, true)
  
  puts "Added wrapper files with correct paths"
  project.save
  puts "Project saved"
else
  puts "Target not found"
end
