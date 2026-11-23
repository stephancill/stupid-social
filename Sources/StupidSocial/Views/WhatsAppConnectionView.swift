import CoreImage.CIFilterBuiltins
import StupidSocialCore
import SwiftUI

/// Links WhatsApp as a device: a QR code to scan with WhatsApp on another phone, or, on the iPhone that has
/// WhatsApp, a code to type into it after entering the number. With `account` it shows the linked account and
/// links it again on this device, since each device is its own WhatsApp device.
struct WhatsAppConnectionView: View {
    @ObservedObject var viewModel: WhatsAppConnectionViewModel
    var account: Account?
    var settings: SettingsViewModel?
    var isLinked = false
    let onDone: () -> Void
    @FocusState private var isFocused: Bool
    @Environment(\.scenePhase) private var scenePhase
    /// iOS 26's `WhatsAppLinkBackgroundTask` while a phone-number link runs; `AnyObject` so the view builds for iOS 18.
    @State private var backgroundTask: AnyObject?

    var body: some View {
        Form {
            if let account, let settings {
                Section {
                    LabeledContent("Account", value: settings.connectionLabel(for: account))
                }
            }
            if isLinked, viewModel.step == .start {
                Section {
                    Label("Linked on this device", systemImage: "checkmark.circle.fill")
                } footer: {
                    Text("WhatsApp lists this device as “stupid social” under Linked Devices. Removing the account logs it out.")
                }
                if let account, let component = settings?.services.component(id: account.id), let client = component.whatsAppClient {
                    WhatsAppSyncSection(client: client, liveFeed: component.whatsAppLiveFeed)
                }
            } else {
                steps
            }
            if let settings, let account {
                RemoveAccountSection(viewModel: settings, account: account, onRemoved: onDone)
            }
        }
        .navigationTitle("WhatsApp")
        .alert("WhatsApp", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .onChange(of: viewModel.step) { _, step in
            updateBackgroundTask(for: step)
            if case let .code(code) = step {
                // Pasting is quicker than typing, and the link only lasts about 30 s once the user leaves the app.
                UIPasteboard.general.string = code.replacingOccurrences(of: "-", with: "")
            }
            if step == .linked, account == nil {
                onDone()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: viewModel.appMoved(toBackground: true)
            case .active: viewModel.appMoved(toBackground: false)
            default: break
            }
        }
        .onDisappear {
            viewModel.cancel()
            updateBackgroundTask(for: .start)
        }
    }

    /// Shows the link's progress in the system's UI from the code appearing until the device is linked; starting
    /// over or failing ends it.
    private func updateBackgroundTask(for step: WhatsAppConnectionViewModel.Step) {
        guard #available(iOS 26.0, *) else { return }
        let task = backgroundTask as? WhatsAppLinkBackgroundTask
        switch step {
        case .code:
            if task == nil {
                backgroundTask = WhatsAppLinkBackgroundTask.begin()
            }
        case .finishing:
            task?.advance(to: .finishing)
        case .linked:
            task?.finish(success: true)
            backgroundTask = nil
        case .start, .phoneNumber, .qr:
            task?.finish(success: false)
            backgroundTask = nil
        }
    }

    @ViewBuilder
    private var steps: some View {
        switch viewModel.step {
        case .start:
            Section {
                Button("Link with Phone Number") {
                    viewModel.choosePhoneNumber()
                }
                Button("Show QR Code") {
                    viewModel.showQRCode()
                }
                .disabled(viewModel.isWorking)
            } footer: {
                Text("stupid social links to WhatsApp like WhatsApp Web. On this iPhone, link with your phone number; to link from another phone, scan the QR code. WhatsApp doesn't allow unofficial apps, so it may restrict accounts that use one.")
            }
        case .phoneNumber:
            Section {
                TextField("Phone number", text: $viewModel.phoneNumber)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                    .focused($isFocused)
                Button("Get Code") {
                    viewModel.requestCode()
                }
                .disabled(viewModel.isWorking || viewModel.phoneNumber.isEmpty)
                Button("Show QR Code Instead") {
                    viewModel.showQRCode()
                }
            } footer: {
                Text("Your WhatsApp number, with its country code, such as +27. First, in WhatsApp, open Settings → Linked Devices → Link a Device and tap “Link with phone number instead”, then come back here for the code.")
            }
            .onAppear { isFocused = true }
        case let .code(code):
            Section {
                Text(code)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                Button("Copy Code") {
                    UIPasteboard.general.string = code.replacingOccurrences(of: "-", with: "")
                }
            } footer: {
                Text("Copied. Switch to WhatsApp and paste it right away: stupid social can only wait about 30 seconds in the background. If WhatsApp isn't on its code screen yet, open Settings → Linked Devices → Link a Device and tap “Link with phone number instead”.")
            }
            Section {
                Button("Start Over", action: viewModel.cancel)
            }
        case let .qr(code):
            Section {
                QRCodeImage(text: code)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
            } footer: {
                Text("On the phone with WhatsApp, open Settings → Linked Devices → Link a Device and scan this code. It changes every 20 seconds.")
            }
            Section {
                Button("Start Over", action: viewModel.cancel)
            }
        case .finishing:
            Section {
                HStack {
                    ProgressView()
                    Text("Linking…")
                        .padding(.leading, 8)
                }
            } footer: {
                Text("Keep WhatsApp open on your phone while your chats sync.")
            }
        case .linked:
            Section {
                Label("Linked", systemImage: "checkmark.circle.fill")
            } footer: {
                Text("Your chats appear on the Chats screen as WhatsApp syncs them.")
            }
        }
    }
}

/// The linked account's connection and how far WhatsApp's sync after linking got, read again every second while
/// shown: the client is an actor and the connection isn't observable.
private struct WhatsAppSyncSection: View {
    let client: WhatsAppClient
    let liveFeed: WhatsAppLiveFeed?
    @State private var status: WhatsAppSyncStatus?
    @State private var connection: WhatsAppLiveFeed.State?
    @State private var now = Date()

    var body: some View {
        Section {
            LabeledContent("Connection", value: connectionText)
            if let status {
                if let history = status.history(at: now) {
                    LabeledContent("History", value: historyText(history))
                }
                LabeledContent("Chats", value: status.chatCount.formatted())
                LabeledContent("Contacts", value: status.state?.appStateSyncedAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Not synced yet")
            }
        } header: {
            Text("Sync")
        } footer: {
            if let footer {
                Text(footer)
            }
        }
        .task {
            while !Task.isCancelled {
                status = await client.syncStatus
                connection = liveFeed?.state
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var connectionText: String {
        switch connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .offline, nil: "Offline"
        }
    }

    private func historyText(_ history: WhatsAppSyncState.History) -> String {
        switch history {
        case .waiting: "Waiting for phone"
        case let .syncing(progress): progress.map { "Syncing \($0)%" } ?? "Syncing…"
        case let .paused(progress): progress.map { "Paused at \($0)%" } ?? "Paused"
        case .complete: "Complete"
        }
    }

    private var footer: String? {
        switch status?.history(at: now) {
        case .waiting, .syncing: "Keep WhatsApp open on your phone until history finishes syncing."
        case .paused: "Your phone stopped sending history. Open WhatsApp on your phone to continue."
        case .complete, nil: nil
        }
    }
}

private struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.image(for: text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .accessibilityLabel("QR code")
        }
    }

    private static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
