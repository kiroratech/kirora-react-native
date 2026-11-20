require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

# The iOS side of @kirora/react-native: a bridge to the native Kirora iOS SDK, which does the
# work. React Native's autolinking finds this file; apps add nothing for it. Until Kirora 0.1.0
# is published, an app's Podfile points the `Kirora` pod at a local copy (see the README).
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
  s.source_files   = 'ios/**/*.{h,m,swift}'

  # Kirora's first release, 0.1.0, carries the wrapper interface (`@_spi(Wrapper)`).
  s.dependency 'Kirora', '~> 0.1'

  if respond_to?(:install_modules_dependencies, true)
    install_modules_dependencies(s)
  else
    s.dependency 'React-Core'
  end
end
