import Foundation
import UserNotifications

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

    @Published public private(set) var step: Step = .start {
        didSet {
            if case .code = step {} else {
                Self.removeNotifications([Self.timeWarningId])
            }
        }
    }

    @Published public var phoneNumber = ""
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?

    public var onLinked: ((WhatsAppAccount) async -> Void)?
    private let client: WhatsAppClient
    private var linkTask: Task<Void, Never>?
    private var isInBackground = false
    private static let timeWarningId = "whatsapp-link-time"
    private static let linkedId = "whatsapp-link-done"
    /// iOS gives about 30 s of background time; the warning leaves a few seconds to paste the code.
    private static let timeWarningDelay: TimeInterval = 20

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

    /// The app moved to or from the background. A code waiting in the background gets a notification shortly before
    /// iOS's background time runs out; coming back clears the link's notifications.
    public func appMoved(toBackground: Bool) {
        isInBackground = toBackground
        if toBackground, case .code = step {
            Self.post(id: Self.timeWarningId, title: "Linking WhatsApp", body: "Paste the code in WhatsApp now: stupid social can only keep it working for a few more seconds.", after: Self.timeWarningDelay)
        } else if !toBackground {
            Self.removeNotifications([Self.timeWarningId, Self.linkedId])
        }
    }

    public func cancel() {
        linkTask?.cancel()
        linkTask = nil
        isWorking = false
        step = .start
    }

    private enum LinkOutcome {
        case linked
        case failed(any Error)
        /// iOS's background time ran out while the user was in WhatsApp.
        case outOfTime
    }

    private func start(phoneNumber: String?) {
        linkTask?.cancel()
        errorMessage = nil
        isWorking = true
        let link: @MainActor () async -> LinkOutcome = { [weak self, client] in
            do {
                let account = try await client.link(phoneNumber: phoneNumber) { update in
                    Task { @MainActor in self?.apply(update) }
                }
                try Task.checkCancellation()
                await self?.linked(account)
                return .linked
            } catch {
                // A cancelled link's socket closes as it ends, with whatever error that gives.
                return Task.isCancelled ? .outOfTime : .failed(error)
            }
        }
        linkTask = Task {
            // A phone-number link means leaving the app to enter the code in WhatsApp, and WhatsApp answers on this
            // link's connection, so the app has to keep running meanwhile. Ordinary background time (about 30 s)
            // does that even while WhatsApp's camera is on, which ends continued processing tasks.
            let outcome = phoneNumber == nil ? await link() : await BackgroundActivity.run(reason: "Linking WhatsApp", operation: link)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .linked: break
            case let .failed(error): failed(error, phoneNumber: phoneNumber)
            case .outOfTime: ranOutOfTime()
            }
        }
    }

    private func apply(_ update: WhatsAppLinkUpdate) {
        guard linkTask?.isCancelled == false else { return }
        switch update {
        case let .qr(code): step = .qr(code)
        case let .pairingCode(code): step = .code(code)
        case .paired:
            step = .finishing
            if isInBackground {
                Self.post(id: Self.linkedId, title: "WhatsApp linked", body: "Open stupid social to sync your chats.", after: nil)
            }
        }
        isWorking = false
    }

    private func linked(_ account: WhatsAppAccount) async {
        await onLinked?(account)
        step = .linked
        isWorking = false
        AppMetrics.accountConnected(network: .whatsapp, isReconnect: false)
    }

    private func ranOutOfTime() {
        AppMetrics.whatsAppFailed("link_background_time", error: CancellationError())
        errorMessage = "Linking stopped because stupid social was in the background too long. Open the code screen in WhatsApp first, then get a new code and paste it right away."
        step = .phoneNumber
        isWorking = false
    }

    private func failed(_ error: Error, phoneNumber: String?) {
        AppMetrics.accountConnectFailed(network: .whatsapp, error: error)
        errorMessage = Self.message(for: error)
        step = phoneNumber == nil ? .start : .phoneNumber
        isWorking = false
    }

    private static func post(id: String, title: String, body: String, after delay: TimeInterval?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func removeNotifications(_ ids: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
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
