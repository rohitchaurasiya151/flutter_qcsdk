#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_qcsdk.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_qcsdk'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A new Flutter plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Frameworks Configuration
  s.vendored_frameworks = 'Frameworks/QCSDK.framework', 'Frameworks/JLAudioUnitKit.framework', 'Frameworks/JLLogHelper.framework'
  
  # Ensure the frameworks are embedded in the host app
  s.xcconfig = { 
    'OTHER_LDFLAGS' => '-framework QCSDK -framework JLAudioUnitKit -framework JLLogHelper'
  }

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
