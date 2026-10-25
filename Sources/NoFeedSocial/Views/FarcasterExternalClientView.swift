import NoFeedSocialCore
import SwiftUI

struct FarcasterExternalClientView: View {
    @AppStorage(FarcasterExternalClient.storageKey) private var client = FarcasterExternalClient.defaultClient
    @AppStorage(FarcasterExternalClient.customCastURLPatternKey) private var customCastURLPattern = ""
    @AppStorage(FarcasterExternalClient.customProfileURLPatternKey) private var customProfileURLPattern = ""

    var body: some View {
        Form {
            Section {
                Picker("External Client", selection: $client) {
                    ForEach(FarcasterExternalClient.allCases, id: \.self) { client in
                        Text(client.displayName).tag(client)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Casts and profiles open in this client.")
            }

            if client == .custom {
                Section {
                    patternField("https://example.com/c/{hash}", text: $customCastURLPattern)
                } header: {
                    Text("Cast URL")
                } footer: {
                    Text("{hash} is replaced with the cast hash, including the 0x prefix.")
                }

                Section {
                    patternField("https://example.com/u/{username}", text: $customProfileURLPattern)
                } header: {
                    Text("Profile URL")
                } footer: {
                    Text("{username} is replaced with the profile's username.")
                }
            }
        }
        .navigationTitle("External Client")
    }

    private func patternField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
    }
}
