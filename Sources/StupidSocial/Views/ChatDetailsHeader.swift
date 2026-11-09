import StupidChatKit
import SwiftUI

/// The top of a chat's member list: its photo, which opens full screen, its title and a line such as the member
/// count, then its description. Laid out like a profile.
struct ChatDetailsHeader: View {
    let title: String
    let subtitle: String?
    let description: String?
    let avatarURL: URL?
    var fullAvatarURL: URL?
    let colorKey: String

    var body: some View {
        Section {
            VStack(spacing: 6) {
                ChatAvatarImage(url: avatarURL, title: title, size: 96, colorKey: colorKey)
                    .opensFullScreenPhoto(avatarURL, fullURL: fullAvatarURL)
                    .padding(.bottom, 6)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        if let description {
            Section("Description") {
                Text(AttributedString(linkingWebURLsIn: description))
                    .textSelection(.enabled)
            }
        }
    }
}

/// A chat's member list under its details: one "Members" section that starts with a field filtering the rows
/// below it, and a no-results line when nothing matches.
struct MembersSection<Rows: View>: View {
    @Binding var query: String
    let hasResults: Bool
    /// Such as how many of the members are listed.
    var footer: String?
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Members", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !query.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            if !hasResults, !query.isEmpty {
                Text("No members match “\(query)”.")
                    .foregroundStyle(.secondary)
            }
            rows()
        } header: {
            Text("Members")
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

/// Edits a chat's title and description; `save` gets the trimmed fields.
struct ChatDetailsEditView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let description: String
    /// Telegram groups need a title; an Apron room without one shows its id.
    var requiresTitle = true
    let save: (_ title: String, _ description: String) async throws -> Void
    @State private var newTitle = ""
    @State private var newDescription = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $newTitle)
                }
                Section {
                    TextField("Description", text: $newDescription, axis: .vertical)
                        .lineLimit(3 ... 10)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await submit() } }
                            .disabled(!canSave)
                    }
                }
            }
            .disabled(isSaving)
            .interactiveDismissDisabled(isSaving || hasChanges)
        }
        .onAppear {
            newTitle = title
            newDescription = description
        }
    }

    private var trimmedTitle: String {
        newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDescription: String {
        newDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedTitle != title || trimmedDescription != description
    }

    private var canSave: Bool {
        hasChanges && (!requiresTitle || !trimmedTitle.isEmpty)
    }

    private func submit() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await save(trimmedTitle, trimmedDescription)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
