import StupidSocialCore
import SwiftUI

/// The sticker picker, from the composer's attachments menu: the user's sets as tabs (recently used first), the
/// chosen set's stickers in a grid, and a tap sends one. Stickers show their first frame, so a grid of them doesn't
/// play dozens of animations at once.
struct ChatStickerPicker: View {
    let loadSets: () async throws -> [ChatStickerSet]
    let loadStickers: (String) async throws -> [ChatSticker]
    let send: (ChatSticker) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sets: [ChatStickerSet]?
    @State private var selectedSetId: String?
    @State private var stickers: [String: [ChatSticker]] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(sets?.first { $0.id == selectedSetId }?.title ?? "Stickers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let sets, !sets.isEmpty {
                        tabs(sets)
                    }
                }
        }
        .task { await load() }
        .task(id: selectedSetId) { await loadSelectedSet() }
    }

    @ViewBuilder private var content: some View {
        if let errorMessage {
            ContentUnavailableView("Couldn't Load Stickers", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
        } else if let sets, sets.isEmpty {
            ContentUnavailableView("No Stickers", systemImage: "face.smiling", description: Text("Stickers you add in Telegram show here."))
        } else if let selectedSetId, let stickers = stickers[selectedSetId] {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(stickers) { sticker in
                        Button {
                            send(sticker)
                            dismiss()
                        } label: {
                            StickerImage(sticker: sticker)
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sticker.label)
                    }
                }
                .padding()
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tabs(_ sets: [ChatStickerSet]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(sets) { set in
                    Button {
                        selectedSetId = set.id
                    } label: {
                        tabLabel(set)
                            .frame(width: 36, height: 36)
                            .padding(4)
                            .background(selectedSetId == set.id ? Color.secondary.opacity(0.2) : .clear, in: .rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(set.title)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    @ViewBuilder private func tabLabel(_ set: ChatStickerSet) -> some View {
        switch set.id {
        case "recent":
            Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
        case "favorites":
            Image(systemName: "star").font(.title3).foregroundStyle(.secondary)
        default:
            if let cover = set.cover ?? (stickers[set.id] ?? set.stickers)?.first {
                StickerImage(sticker: cover)
            } else {
                Text(set.title.prefix(1))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        do {
            let sets = try await loadSets()
            for set in sets {
                if let loaded = set.stickers {
                    stickers[set.id] = loaded
                }
            }
            self.sets = sets
            selectedSetId = selectedSetId ?? sets.first?.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedSet() async {
        guard let selectedSetId, stickers[selectedSetId] == nil else { return }
        do {
            stickers[selectedSetId] = try await loadStickers(selectedSetId)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A sticker's first frame, as `ChatStickerView` draws it.
private struct StickerImage: UIViewRepresentable {
    let sticker: ChatSticker

    func makeUIView(context _: Context) -> ChatStickerView {
        let view = ChatStickerView(sticker: sticker, animates: false)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_: ChatStickerView, context _: Context) {}
}
