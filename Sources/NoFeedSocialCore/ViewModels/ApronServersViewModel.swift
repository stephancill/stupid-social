import Foundation

@MainActor
public final class ApronServersViewModel: ObservableObject {
    @Published public private(set) var servers: [ApronServerMetadata] = []
    @Published public var serverInput = ""
    @Published public var tokenInput = ""
    @Published public var nameInput = ""
    @Published public private(set) var isWorking = false
    @Published public var message: String?

    public static let exampleServer = "wss://server.apron.chat/"

    private let service: ApronService
    private let cacheStore: NotificationCacheStore

    public init(service: ApronService, cacheStore: NotificationCacheStore) {
        self.service = service
        self.cacheStore = cacheStore
        reload()
    }

    public var connectionLabel: String {
        switch servers.count {
        case 0: AccountStatus.notConfigured.label
        case 1: servers[0].serverURL.host() ?? "1 server"
        default: "\(servers.count) servers"
        }
    }

    public var hasInvalidCredentials: Bool {
        servers.contains { $0.status == .invalidCredentials }
    }

    public func hasToken(_ server: ApronServerMetadata) -> Bool {
        service.hasToken(serverURL: server.serverURL)
    }

    public func reload() {
        servers = service.servers
    }

    public func addServer() async -> Bool {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            let server = try await service.addServer(input: serverInput, token: tokenInput, name: nameInput)
            serverInput = ""
            tokenInput = ""
            nameInput = ""
            reload()
            NotificationCenter.default.post(name: ApronLiveFeed.serversDidChangeNotification, object: nil)
            message = "Signed in as \(server.user?.displayName ?? "guest")."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    public func updateToken(for server: ApronServerMetadata) async {
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await service.updateToken(serverURL: server.serverURL, token: tokenInput)
            tokenInput = ""
            reload()
            message = "Token saved."
        } catch {
            message = error.localizedDescription
        }
    }

    public func remove(_ server: ApronServerMetadata) {
        service.removeServer(serverURL: server.serverURL)
        try? cacheStore.deleteAccount(network: .apron, accountId: server.serverURL.absoluteString)
        reload()
        NotificationCenter.default.post(name: ApronLiveFeed.serversDidChangeNotification, object: nil)
    }
}
