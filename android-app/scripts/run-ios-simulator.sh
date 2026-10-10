#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ios_simulator="${IOS_SIMULATOR_UDID:-6552DF1D-95CE-48E3-801F-8F80F0AA8D29}"
ios_bundle="net.stupidtech.socialexpo"
ios_app=".expo/ios-build/Build/Products/Release-iphonesimulator/stupidsocial.app"

bunx expo prebuild --platform ios --no-install
pod install --project-directory=ios
xcrun simctl bootstatus "$ios_simulator" -b
mkdir -p .expo

NODE_OPTIONS=--dns-result-order=ipv4first xcodebuild \
  -workspace ios/stupidsocial.xcworkspace \
  -scheme stupidsocial -configuration Release \
  -destination "platform=iOS Simulator,id=$ios_simulator" \
  -derivedDataPath .expo/ios-build CODE_SIGNING_ALLOWED=NO build \
  2>&1 | tee .expo/ios-build.log | xcpretty

# Simulator Keychain requires the host-platform app identifier. Never use this for device signing.
cat > .expo/ios-simulator.entitlements <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.application-identifier</key><string>net.stupidtech.socialexpo</string>
</dict></plist>
PLIST
codesign --force --sign - --entitlements .expo/ios-simulator.entitlements "$ios_app"
xcrun simctl install "$ios_simulator" "$ios_app"
xcrun simctl launch --terminate-running-process "$ios_simulator" "$ios_bundle"
