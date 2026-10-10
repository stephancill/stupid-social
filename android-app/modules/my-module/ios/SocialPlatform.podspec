Pod::Spec.new do |s|
  s.name = 'SocialPlatform'
  s.version = '1.0.0'
  s.summary = 'Stupid Social platform adapters'
  s.description = s.summary
  s.license = 'MIT'
  s.author = 'Stupid Tech'
  s.homepage = 'https://stupidtech.net'
  s.platforms = { :ios => '16.4' }
  s.swift_version = '5.9'
  s.source = { :git => '' }
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.source_files = '**/*.swift'
end
