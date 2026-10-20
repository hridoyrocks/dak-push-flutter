Pod::Spec.new do |s|
  s.name             = 'dak_push'
  s.version          = '0.3.0'
  s.summary          = 'Flutter SDK for Dak, a self-hosted push notification server.'
  s.description      = <<-DESC
Shares what the Dak notification service extension needs with it, sets the
badge, and reads which notification button was tapped.
                       DESC
  s.homepage         = 'https://github.com/hridoyrocks/dak-push-flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Dak' => 'support@cdielts.org' }
  s.source           = { :path => '.' }
  s.source_files     = 'dak_push/Sources/dak_push/**/*.swift'
  s.resource_bundles = { 'dak_push_privacy' => ['dak_push/Sources/dak_push/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
