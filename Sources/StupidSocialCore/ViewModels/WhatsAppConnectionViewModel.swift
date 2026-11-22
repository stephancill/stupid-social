import Foundation

/// Linking WhatsApp as a device: a QR code to scan from another phone, or a code to type into WhatsApp on this
/// one after entering the number.
@MainActor
public final class WhatsAppConnectionViewModel: ObservableObject {
    public enum Step: Equatable {
        case start
        case qr(String)
        case phoneNumber
        case code(String)
        /// Linked; waiting for the first login and WhatsApp's history sync to begin.
        case finishing
        case linked
    }

    @Published public private(set) var step: Step = .start
    @Published public var phoneNumber = ""
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?

    public var onLinked: ((WhatsAppAccount) async -> Void)?
    private let client: WhatsAppClient
    private var linkTask: Task<Void, Never>?

    public init(client: WhatsAppClient) {
        self.client = client
    }

    public func showQRCode() {
        start(phoneNumber: nil)
    }

    public func choosePhoneNumber() {
        linkTask?.cancel()
        step = .phoneNumber
    }

    public func requestCode() {
        let digits = phoneNumber.filter(\.isNumber)
        guard digits.count > 6, !digits.hasPrefix("0") else {
            errorMessage = "Enter your number with its country code, such as +27 82 123 4567."
            return
        }
        start(phoneNumber: digits)
    }

    public func cancel() {
        linkTask?.cancel()
        linkTask = nil
        isWorking = false
        step = .start
    }

    private func start(phoneNumber: String?) {
        linkTask?.cancel()
        errorMessage = nil
        isWorking = true
        linkTask = Task { [client] in
            do {
                let account = try await client.link(phoneNumber: phoneNumber) { [weak self] update in
                    guard let self else { return }
                    Task { @MainActor in self.apply(update) }
                }
                try Task.checkCancellation()
                await linked(account)
            } catch {
                // A cancelled link's socket closes as it ends; that isn't an error to show.
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failed(error, phoneNumber: phoneNumber)
            }
        }
    }

    private func apply(_ update: WhatsAppLinkUpdate) {
        guard linkTask?.isCancelled == false else { return }
        switch update {
        case let .qr(code): step = .qr(code)
        case let .pairingCode(code): step = .code(code)
        case .paired: step = .finishing
        }
        isWorking = false
    }

    private func linked(_ account: WhatsAppAccount) async {
        await onLinked?(account)
        step = .linked
        isWorking = false
        AppMetrics.accountConnected(network: .whatsapp, isReconnect: false)
    }

    private func failed(_ error: Error, phoneNumber: String?) {
        AppMetrics.accountConnectFailed(network: .whatsapp, error: error)
        errorMessage = Self.message(for: error)
        step = phoneNumber == nil ? .start : .phoneNumber
        isWorking = false
    }

    private static func message(for error: Error) -> String {
        switch error {
        case WhatsAppError.linkExpired: "The code expired. Try again."
        case WhatsAppError.clientOutdated: "WhatsApp asked for a newer version of the app."
        case WhatsAppError.banned: "WhatsApp has restricted this account from linking devices."
        case WhatsAppError.iq(code: "429", text: _): "WhatsApp is limiting link requests for this number. Wait a while and try again."
        default: "Couldn't link WhatsApp. Check your connection and try again."
        }
    }
}
