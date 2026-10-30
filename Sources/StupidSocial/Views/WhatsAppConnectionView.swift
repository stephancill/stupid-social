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
            if step == .linked, account == nil {
                onDone()
            }
        }
        .onDisappear(perform: viewModel.cancel)
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
                Text("Your WhatsApp number, with its country code, such as +27.")
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
                Text("In WhatsApp, open Settings → Linked Devices → Link a Device, tap “Link with phone number instead” and enter this code.")
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
