import Foundation
import StoreKit

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
    static func environment(bundle: Bundle = .main) async -> String {
        #if targetEnvironment(simulator)
            return "simulator"
        #else
            if bundle.url(forResource: "embedded", withExtension: "mobileprovision") != nil {
                return "development"
            }
            guard let transaction = try? await AppTransaction.shared else { return "unknown" }
            switch transaction.unsafePayloadValue.environment {
            case .production: return "appstore"
            case .sandbox: return "testflight"
            case .xcode: return "development"
            default: return "unknown"
            }
        #endif
    }
}
