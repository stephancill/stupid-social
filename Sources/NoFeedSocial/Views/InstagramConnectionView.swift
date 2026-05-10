import NoFeedSocialCore
import SwiftUI

struct InstagramConnectionView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isFocused: Bool
    @State private var showingLoginSheet = false
    @AppStorage("devModeEnabled") private var devModeEnabled = false

    var body: some View {
        Form {
            Section {
                Button {
                    showingLoginSheet = true
                } label: {
                    HStack {
                        Spacer()
                        Label("Log in to Instagram", systemImage: "safari")
                        Spacer()
                    }
                }
            }

            Section {
                HStack {
                    Text("Status")
                    Spacer()
                    Text(viewModel.instagramStatus.label)
                        .foregroundStyle(.secondary)
                }
            }

            if devModeEnabled {
                Section("Manual (Dev)") {
                    TextField("Cookie header", text: $viewModel.instagramCookieHeader, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)

                    Button("Save Instagram Credentials") {
                        isFocused = false
                        Task { await viewModel.saveInstagramCookieHeader() }
                    }
                }
            }

            if viewModel.instagramStatus != .notConfigured {
                Section("Stories") {
                    Toggle("Show Stories", isOn: $viewModel.instagramStoriesEnabled)
                        .onChange(of: viewModel.instagramStoriesEnabled) { _, enabled in
                            viewModel.toggleInstagramStories(enabled: enabled)
                        }
                }

                Section("Notification Types") {
                    ForEach(InstagramNotificationCategory.allCases, id: \.self) { category in
                        Toggle(isOn: binding(for: category)) {
                            Text(category.displayLabel)
                        }
                    }
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectInstagram()
                    }
                }
            }

            if let message = viewModel.message {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Instagram")
        .sheet(isPresented: $showingLoginSheet) {
            InstagramLoginWebView { credentials in
                Task { await viewModel.saveInstagramCookies(credentials) }
            }
        }
        .task {
            await viewModel.revalidateInstagram()
        }
    }

    private func binding(for category: InstagramNotificationCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.instagramEnabledCategories.contains(category) },
            set: { viewModel.toggleInstagramCategory(category, enabled: $0) }
        )
    }
}
