import Foundation
import OSLog

public enum RefreshTiming {
    private static let signposter = OSSignposter(subsystem: "tech.stupid.StupidSocial", category: "Refresh")
    private static let logger = Logger(subsystem: "tech.stupid.StupidSocial", category: "Refresh")

    @MainActor
    public static func measure<Output>(
        _ name: String,
        _ operation: () async throws -> Output,
    ) async rethrows -> Output {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval("RefreshWork", id: signpostID)
        let start = ContinuousClock.now
        defer {
            let elapsed = start.duration(to: .now)
            logger.info("\(name, privacy: .public) took \(elapsed)")
            signposter.endInterval("RefreshWork", state)
        }
        return try await operation()
    }
}
