# Kirora's Notification Service Extension helper: delivery reports and push images. Add it
# to the extension's target only. It depends on nothing, not even Kirora.
# The version matches Kirora.podspec and the SDK's `sdkVersion`.
Pod::Spec.new do |s|
  s.name             = 'KiroraNotificationService'
  s.version          = '0.1.0'
  s.summary          = 'Kirora delivery reports and images for an iOS Notification Service Extension.'
  s.homepage         = 'https://github.com/kiroratech/kirora-ios'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = 'Kirora'
  s.source           = { :git => 'https://github.com/kiroratech/kirora-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_versions   = ['5.9']

  s.source_files     = 'Sources/KiroraNotificationService/**/*.swift'
  s.resource_bundles = { 'KiroraNotificationService_Privacy' => ['Sources/KiroraNotificationService/PrivacyInfo.xcprivacy'] }
  s.frameworks       = 'Foundation', 'UserNotifications'
end
