# The Kirora iOS SDK, for apps and wrapper SDKs (React Native, Flutter) that link native
# code through CocoaPods. Swift Package Manager users need none of this: see Package.swift.
# The version is the SDK's `sdkVersion` (Sources/Kirora/Internal/Support.swift) and the
# release's git tag; a test checks the three agree.
Pod::Spec.new do |s|
  s.name             = 'Kirora'
  s.version          = '0.1.0'
  s.summary          = 'Kirora for iOS: events, sessions, consent and push for signed-in users.'
  s.homepage         = 'https://github.com/kiroratech/kirora-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Kirora'
  s.source           = { :git => 'https://github.com/kiroratech/kirora-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9']

  s.source_files     = 'Sources/Kirora/**/*.swift'
  s.resource_bundles = { 'Kirora_Privacy' => ['Sources/Kirora/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UIKit', 'UserNotifications'
end
