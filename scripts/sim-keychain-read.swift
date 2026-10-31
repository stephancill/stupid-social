// Reads the app's credential items from a simulator's keychain, for the probes' --simulator mode.
//
// The simulator build keeps credentials in the keychain under the app group, and writes the UserDefaults
// fallback only when a keychain write fails, so probes can't read them from the preferences plist. Built
// for the simulator and ad-hoc signed with the app group entitlement (scripts/sim_keychain.py does this),
// it runs inside the simulator through `xcrun simctl spawn`.
//
//   sim-keychain-read            prints every item's account (the app's account ids), one per line
//   sim-keychain-read <account>  writes that item's data to stdout

import Foundation
import Security

let arguments = CommandLine.arguments
var query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "tech.stupid.StupidSocial.credentials",
    kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    kSecReturnAttributes as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll,
]
if arguments.count > 1 {
    query[kSecAttrAccount as String] = arguments[1]
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
}

var result: CFTypeRef?
let status = SecItemCopyMatching(query as CFDictionary, &result)
guard status == errSecSuccess else {
    FileHandle.standardError.write(Data("SecItemCopyMatching failed: \(status)\n".utf8))
    exit(status == errSecItemNotFound ? 2 : 1)
}
if arguments.count > 1 {
    guard let item = result as? [String: Any], let data = item[kSecValueData as String] as? Data else { exit(1) }
    FileHandle.standardOutput.write(data)
} else {
    for item in result as? [[String: Any]] ?? [] {
        print(item[kSecAttrAccount as String] as? String ?? "")
    }
}
