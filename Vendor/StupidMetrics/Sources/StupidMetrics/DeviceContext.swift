import Foundation

enum DeviceContext {
    static func current(installId: String, bundle: Bundle = .main) -> MetricContext {
        MetricContext(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            environment: "",
            platform: platform,
            osVersion: osVersion,
            deviceModel: deviceModel,
            installId: installId
        )
    }

    static var platform: String {
        #if os(iOS)
            ProcessInfo.processInfo.isiOSAppOnMac ? "mac" : "ios"
        #elseif os(macOS)
            "macos"
        #elseif os(visionOS)
            "visionos"
        #elseif os(tvOS)
            "tvos"
        #elseif os(watchOS)
            "watchos"
        #else
            "unknown"
        #endif
    }

    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// The hardware identifier, e.g. `iPhone17,1`.
    static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// `simulator`, `development` (signed with a provisioning profile, e.g. installed
    /// from Xcode or a device build), `testflight`, `appstore`, or `unknown`.
    ///
    /// TestFlight and the App Store are told apart by the receipt's file name
    /// (`sandboxReceipt` on TestFlight). `appStoreReceiptURL` is deprecated in favour of
    /// StoreKit's `AppTransaction`, but that needs the network and failed on a TestFlight
    /// install, reporting `unknown`; the receipt path is local. It's read through KVC to
    /// avoid the deprecation warning in every app that links this package.
    static func environment(bundle: Bundle = .main) -> String {
        #if targetEnvironment(simulator)
            return "simulator"
        #else
            if bundle.url(forResource: "embedded", withExtension: "mobileprovision") != nil {
                return "development"
            }
            guard let receipt = bundle.value(forKey: "appStoreReceiptURL") as? URL else { return "unknown" }
            return receipt.lastPathComponent == "sandboxReceipt" ? "testflight" : "appstore"
        #endif
    }
}
