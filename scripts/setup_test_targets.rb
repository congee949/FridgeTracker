#!/usr/bin/env ruby
# Wires the FridgeTrackerTests (unit) and FridgeTrackerUITests (UI) targets into the
# Xcode project, plus a shared scheme. Idempotent + re-runnable: re-running syncs any new
# .swift files on disk into the matching target and refreshes settings.
require 'xcodeproj'

PROJECT_PATH = 'FridgeTracker.xcodeproj'
TEAM   = 'AU57X34LPB'
DEPLOY = '26.0'
SWIFTV = '5.0'

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'FridgeTracker' }
raise 'app target FridgeTracker not found' unless app_target

def group_named(project, name)
  project.main_group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == name } ||
    project.main_group.new_group(name, name)
end

def target_source_paths(target)
  target.source_build_phase.files.map { |bf| bf.file_ref && bf.file_ref.real_path.to_s }.compact
end

def sync_dir_into_target(target, base_group, dir)
  existing = target_source_paths(target)
  Dir.glob("#{dir}/**/*.swift").sort.each do |path|
    abs = File.expand_path(path)
    next if existing.include?(abs)
    rel_parts = abs.sub(File.expand_path(dir) + '/', '').split('/')
    rel_parts.pop # filename
    group = base_group
    rel_parts.each do |part|
      sub = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == part }
      group = sub || group.new_group(part, part)
    end
    ref = group.new_reference(abs)
    target.add_file_references([ref])
    puts "  + #{abs.sub(Dir.pwd + '/', '')} -> #{target.name}"
  end
end

# ---------------- Unit-test bundle (hosted in the app) ----------------
unit = project.targets.find { |t| t.name == 'FridgeTrackerTests' } ||
       project.new_target(:unit_test_bundle, 'FridgeTrackerTests', :ios, DEPLOY, project.products_group, :swift)
unit.build_configurations.each do |c|
  bs = c.build_settings
  bs['PRODUCT_NAME']              = '$(TARGET_NAME)'
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.congee.FridgeTracker.FridgeTrackerTests'
  bs['DEVELOPMENT_TEAM']          = TEAM
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  bs['SWIFT_VERSION']             = SWIFTV
  bs['GENERATE_INFOPLIST_FILE']   = 'YES'
  bs['CURRENT_PROJECT_VERSION']   = '1'
  bs['MARKETING_VERSION']         = '1.0'
  bs['TEST_HOST']    = '$(BUILT_PRODUCTS_DIR)/FridgeTracker.app/FridgeTracker'
  bs['BUNDLE_LOADER'] = '$(TEST_HOST)'
  bs.delete('INFOPLIST_FILE')
end
unit.add_dependency(app_target) unless unit.dependencies.any? { |d| d.target == app_target }
sync_dir_into_target(unit, group_named(project, 'FridgeTrackerTests'), 'FridgeTrackerTests')

# ---------------- UI-testing bundle ----------------
uitests = project.targets.find { |t| t.name == 'FridgeTrackerUITests' } ||
          project.new_target(:ui_test_bundle, 'FridgeTrackerUITests', :ios, DEPLOY, project.products_group, :swift)
uitests.build_configurations.each do |c|
  bs = c.build_settings
  bs['PRODUCT_NAME']              = '$(TARGET_NAME)'
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.congee.FridgeTracker.FridgeTrackerUITests'
  bs['DEVELOPMENT_TEAM']          = TEAM
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOY
  bs['SWIFT_VERSION']             = SWIFTV
  bs['GENERATE_INFOPLIST_FILE']   = 'YES'
  bs['CURRENT_PROJECT_VERSION']   = '1'
  bs['MARKETING_VERSION']         = '1.0'
  bs['TEST_TARGET_NAME']          = 'FridgeTracker'
  bs.delete('INFOPLIST_FILE')
end
uitests.add_dependency(app_target) unless uitests.dependencies.any? { |d| d.target == app_target }
sync_dir_into_target(uitests, group_named(project, 'FridgeTrackerUITests'), 'FridgeTrackerUITests')

# ---------------- Shared scheme with a test action ----------------
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app_target)
scheme.add_test_target(unit)
scheme.add_test_target(uitests)
scheme.set_launch_target(app_target)
scheme.test_action.code_coverage_enabled = true
scheme.save_as(PROJECT_PATH, 'FridgeTracker', true)

project.save
puts "Done. Targets: #{project.targets.map(&:name).join(', ')}"
