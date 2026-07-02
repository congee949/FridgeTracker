#!/usr/bin/env ruby
# Adds the Point-Free swift-snapshot-testing SPM package and links its `SnapshotTesting`
# product to the FridgeTrackerTests unit-test target. Idempotent.
require 'xcodeproj'

PROJECT_PATH = 'FridgeTracker.xcodeproj'
URL = 'https://github.com/pointfreeco/swift-snapshot-testing'
PRODUCT = 'SnapshotTesting'

project = Xcodeproj::Project.open(PROJECT_PATH)
unit = project.targets.find { |t| t.name == 'FridgeTrackerTests' }
raise 'FridgeTrackerTests target not found' unless unit

pkg = project.root_object.package_references.find { |r| r.respond_to?(:repositoryURL) && r.repositoryURL == URL }
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = URL
  pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '1.17.0' }
  project.root_object.package_references << pkg
  puts "added package reference #{URL}"
end

dep = unit.package_product_dependencies.find { |d| d.product_name == PRODUCT }
unless dep
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = PRODUCT
  unit.package_product_dependencies << dep
  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dep
  unit.frameworks_build_phase.files << build_file
  puts "linked #{PRODUCT} to #{unit.name}"
end

project.save
puts 'done'
