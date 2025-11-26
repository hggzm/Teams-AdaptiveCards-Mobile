#!/usr/bin/env ruby
require 'xcodeproj'

# Path to the Xcode project
project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# List of Swift file names to remove (just the filename, not full path)
swift_files_to_remove = [
  'BinaryOperatorNode.swift',
  'Binding.swift',
  'BuiltInFunctions.swift',
  'EvaluationContext.swift',
  'Expression.swift',
  'ExpressionEngine.swift',
  'ExpressionErrors.swift',
  'ExpressionHelpers.swift',
  'ExpressionModels.swift',
  'ExpressionNodes.swift',
  'ExpressionParser.swift',
  'ExpressionTypes.swift',
  'ExpressionUtilities.swift',
  'FunctionCache.swift',
  'Tokenizer.swift',
  'SwiftActionElementParser.swift',
  'SwiftAdaptiveBase64Util.swift',
  'SwiftElementParserRegistration.swift',
  'SwiftLegacyACSupport.swift',
  'SwiftLegacyACSupportPending.swift',
  'SwiftParseUtil.swift',
  'SwiftMarkDownHtmlGenerator.swift',
  'SwiftActionElements.swift',
  'SwiftAdaptiveCard.swift',
  'SwiftBaseCardElement.swift',
  'SwiftBaseElement.swift',
  'SwiftCardElements.swift',
  'SwiftContainerElements.swift',
  'SwiftInputElements.swift',
  'SwiftDateTimePreparser.swift',
  'SwiftEnums.swift',
  'SwiftFeatureRegistration.swift',
  'SwiftHostConfig.swift',
  'SwiftInternalId.swift',
  'SwiftParseContext.swift',
  'SwiftUtil.swift'
]

removed_count = 0

puts "Scanning project for Swift files to remove..."

# Iterate through all file references in the project
project.files.select { |f| f.path&.end_with?('.swift') }.each do |file_ref|
  file_name = file_ref.path
  real_path = file_ref.real_path.to_s rescue ""
  
  # Check if this file should be removed (must be in SwiftAdaptiveCards folder)
  if swift_files_to_remove.include?(file_name) && real_path.include?('SwiftAdaptiveCards/')
    puts "Removing: #{file_name} (#{real_path})"
    file_ref.remove_from_project
    removed_count += 1
  end
end

# Save the project
project.save

puts "\n=== Summary ==="
puts "Removed #{removed_count} Swift file(s) from Xcode project"
puts "Project saved: #{project_path}"
