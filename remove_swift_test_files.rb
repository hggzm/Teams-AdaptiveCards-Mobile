#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

# List of Swift test file names to remove (from SwiftAdaptiveCardsTests directory)
test_files_to_remove = [
  # ExpressionEngineTests
  'AllExpressionTests.swift',
  'BindingTests.swift',
  'BuiltInFunctionIntegrationTests.swift',
  'CustomFunctionCategoryTests.swift',
  'DateFunctionsTests.swift',
  'ErrorHandlingTests.swift',
  'ExpressionTests.swift',
  'FunctionCacheTests.swift',
  'FunctionRegistryTests.swift',
  'IntegrationTests.swift',
  'MathFunctionsTests.swift',
  'ObjCExpressionEvaluatorTests.swift',
  'StringFunctionTests.swift',
  'TokenizerTests.swift',
  'UtilityFunctionsTests.swift',
  # Flattened
  'ACAdaptiveCardParserTests.swift',
  'ACCardActionsTests.swift',
  'ACContainerTests.swift',
  'ACElementTests.swift',
  'ACFallBackTests.swift',
  'ACInputTests.swift',
  # ObjectModel
  'AdaptiveCardParseExceptionTest.swift',
  'AdditionalPropertiesTest.swift',
  'Base64Test.swift',
  'ContainerStyleTest.swift',
  'DateAndTimeUnitTest.swift',
  'ElementTest.swift',
  'EnumTest.swift',
  'EverythingBagelTest.swift',
  'ExplicitDimensionTest.swift',
  'FactUnitTest.swift',
  'FallBackTests.swift',
  'FontStylesUnitTest.swift',
  'HostConfigTest.swift',
  'ImageBackgroundColorTest.swift',
  'MarkDownUnitTest.swift',
  'ObjectModelTest.swift',
  'ParserRegistrationTest.swift',
  'ParseUtilTest.swift',
  'SemanticVersionTest.swift',
  'TableTests.swift',
  'TextParsingTest.swift',
  'UnsupportedtypesParsingTest.swift'
]

puts "=== Looking for #{test_files_to_remove.count} Swift test files to remove ==="

removed_count = 0
test_files_to_remove.each do |filename|
  file_refs = project.files.select { |f| f.path == filename }
  
  file_refs.each do |file_ref|
    puts "Found: #{file_ref.path}"
    
    # Remove from all targets
    project.targets.each do |target|
      next unless target.respond_to?(:source_build_phase)
      
      target.source_build_phase.files.each do |build_file|
        if build_file.file_ref == file_ref
          target.source_build_phase.remove_file_reference(file_ref)
          puts "  Removed from target: #{target.name}"
        end
      end
    end
    
    # Remove from file hierarchy
    file_ref.remove_from_project
    removed_count += 1
  end
end

puts "\n=== Summary ==="
puts "Swift test files removed: #{removed_count}/#{test_files_to_remove.count}"
puts "Swift files remaining in project: #{project.files.select { |f| f.path&.end_with?('.swift') }.count}"

if removed_count > 0
  project.save
  puts "\n✅ Project saved successfully!"
else
  puts "\n⚠️  No files were removed - project not saved"
end

puts "Remember: These test files now live in SwiftAdaptiveCardsPackage/Tests/"

