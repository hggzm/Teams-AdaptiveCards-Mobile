require 'xcodeproj'

project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# Find the main AdaptiveCards target
target = project.targets.find { |t| t.name == 'AdaptiveCards' }

if target
  # Add the .m file to sources
  file_ref_m = project.main_group.new_file('source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards/SwiftAdaptiveCardsWrapper.m')
  file_ref_h = project.main_group.new_file('source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards/SwiftAdaptiveCardsWrapper.h')
  
  target.source_build_phase.add_file_reference(file_ref_m)
  target.headers_build_phase.add_file_reference(file_ref_h, true) # true = public header
  
  puts "Added wrapper files to project"
  project.save
  puts "Project saved"
else
  puts "Target 'AdaptiveCards' not found"
end
