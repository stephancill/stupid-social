import Foundation

@MainActor
public final class DebugNotificationsClient {
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func notifications(baseURL: URL) async throws -> [DebugNotificationResponse] {
        let url = baseURL.appending(path: "notifications")
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw SourceError.serviceError("Debug server request failed")
        }

        return try decoder.decode(DebugNotificationsResponse.self, from: data).notifications
    }
}

public struct DebugNotificationsResponse: Decodable, Sendable {
    public let notifications: [DebugNotificationResponse]
}

public struct DebugNotificationResponse: Decodable, Sendable {
    public let id: String
    public let type: NotificationType
    public let timestamp: Date
    public let text: String
    public let actorUsername: String
}
