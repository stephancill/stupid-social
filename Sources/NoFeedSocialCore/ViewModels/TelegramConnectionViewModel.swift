import Foundation

/// Telegram sign-in: phone number, then the code Telegram sends, then the 2FA password when the account has one.
@MainActor
public final class TelegramConnectionViewModel: ObservableObject {
    public enum Step: Equatable {
        case phone
        case code(sentTo: String)
        case password(hint: String?)
        case signedIn(TelegramAccount)
    }

    @Published public private(set) var step: Step = .phone
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?
    @Published public var phone = ""
    @Published public var code = ""
    @Published public var password = ""

    private let client: TelegramClient
    /// Called after signing in or out, such as to reload the Chats list.
    public var onChange: (() -> Void)?

    public init(client: TelegramClient) {
        self.client = client
    }

    public var isAvailable: Bool {
        TelegramClient.isAvailable
    }

    public var connectionLabel: String {
        if case let .signedIn(account) = step {
            return account.username.map { "@\($0)" } ?? account.name
        }
        return isAvailable ? "Not connected" : "Unavailable"
    }

    public func reload() async {
        if let account = await client.account {
            step = .signedIn(account)
        } else if case .signedIn = step {
            step = .phone
        }
    }

    public func sendCode() async {
        let number = phone.filter { $0.isNumber || $0 == "+" }
        guard !number.isEmpty else { return }
        await perform {
            let sentTo = try await self.client.sendCode(phone: number)
            self.code = ""
            self.step = .code(sentTo: sentTo)
        }
    }

    public func signIn() async {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        await perform {
            switch try await self.client.signIn(code: trimmed) {
            case .signedIn:
                await self.finishSignIn()
            case let .passwordNeeded(hint):
                self.password = ""
                self.step = .password(hint: hint)
            }
        }
    }

    public func checkPassword() async {
        guard !password.isEmpty else { return }
        await perform {
            try await self.client.checkPassword(self.password)
            self.password = ""
            await self.finishSignIn()
        }
    }

    public func startOver() {
        errorMessage = nil
        code = ""
        password = ""
        step = .phone
    }

    public func signOut() async {
        await perform {
            await self.client.signOut()
            self.phone = ""
            self.step = .phone
            self.onChange?()
        }
    }

    private func finishSignIn() async {
        if let account = await client.account {
            step = .signedIn(account)
        }
        onChange?()
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
