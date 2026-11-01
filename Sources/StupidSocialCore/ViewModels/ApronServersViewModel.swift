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
    private let chatList: ChatListViewModel

    public init(service: ApronService, chatList: ChatListViewModel) {
        self.service = service
        self.chatList = chatList
        reload()
        // Servers also arrive and leave from other devices through iCloud.
        for name in [ApronLiveFeed.serversDidChangeNotification, AccountStore.statusDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
    }

    public func server(for serverURL: URL) -> ApronServerMetadata? {
        servers.first { $0.serverURL == serverURL } ?? service.server(for: serverURL)
    }

    public func hasToken(_ server: ApronServerMetadata) -> Bool {
        service.hasToken(serverURL: server.serverURL)
    }

    /// Whether this device gets push notifications from the server.
    public func isPushEnabled(_ server: ApronServerMetadata) -> Bool {
        service.push.isEnabled(serverURL: server.serverURL)
    }

    public func setPushEnabled(_ enabled: Bool, for server: ApronServerMetadata) async {
        objectWillChange.send()
        await service.setPushEnabled(enabled, serverURL: server.serverURL)
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
        chatList.replaceChats(where: { $0.isApronRoom(on: server.serverURL) }, with: [])
        reload()
        NotificationCenter.default.post(name: ApronLiveFeed.serversDidChangeNotification, object: nil)
    }
}
