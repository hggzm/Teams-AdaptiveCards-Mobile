#!/usr/bin/env ruby
require 'xcodeproj'

project_path = 'source/ios/AdaptiveCards/AdaptiveCards/AdaptiveCards.xcodeproj'
project = Xcodeproj::Project.open(project_path)

puts "=== All Swift files in project ==="
project.files.select { |f| f.path&.end_with?('.swift') }.each do |file_ref|
  puts "Path: #{file_ref.path}"
  puts "Real Path: #{file_ref.real_path}" if file_ref.respond_to?(:real_path)
  puts "---"
end
