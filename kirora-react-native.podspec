require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# The iOS side of @kirora/react-native: a bridge to the Kirora iOS SDK, which does the work.
# React Native's autolinking finds this file; apps add nothing for it. The SDK's sources are
# bundled in ios/vendor/kirora-ios (scripts/sync-kirora-ios.sh) and built into this pod, so
# nothing comes from CocoaPods trunk.
Pod::Spec.new do |s|
  s.name           = 'kirora-react-native'
  s.version        = package['version']
  s.summary        = package['description']
  s.homepage       = 'https://github.com/kiroratech/kirora-react-native'
  s.license        = { :type => package['license'], :file => 'LICENSE' }
  s.author         = 'Kirora'
  s.source         = { :git => 'https://github.com/kiroratech/kirora-react-native.git', :tag => s.version.to_s }

  s.platforms      = { :ios => '13.0' }
  s.swift_version  = '5.9'
  # The bridge, and the SDK it calls. Not the extension's sources, which are a separate pod.
  s.source_files   = 'ios/*.{h,m,swift}', 'ios/vendor/kirora-ios/Sources/Kirora/**/*.swift'
  s.resource_bundles = { 'Kirora_Privacy' => ['ios/vendor/kirora-ios/Sources/Kirora/PrivacyInfo.xcprivacy'] }
  s.frameworks     = 'Foundation', 'UIKit', 'UserNotifications'

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
