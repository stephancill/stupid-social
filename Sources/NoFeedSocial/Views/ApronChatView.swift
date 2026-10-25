import NoFeedSocialCore
import SwiftUI

/// Chat detail for one Apron room. Owns the connection lifecycle and hosts the UIKit chat,
/// which outperformed a SwiftUI `ScrollView` on long rooms (see docs/IMPLEMENTATION.md).
struct ApronChatView: View {
    @StateObject private var viewModel: ApronChatViewModel

    init(viewModel: @autoclosure @escaping () -> ApronChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel())
    }

    var body: some View {
        ApronChatUIKitView(viewModel: viewModel)
            .ignoresSafeArea(.keyboard)
            // Full-bleed under the bar and home indicator; the list insets itself from the safe area.
            .ignoresSafeArea(edges: [.top, .bottom])
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            // Messages scroll under a transparent bar; the room and server sit in a floating pill.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ApronChatTitlePill(title: viewModel.title, subtitle: viewModel.serverHost)
                }
            }
            .task {
                await viewModel.connect()
            }
            .onDisappear {
                viewModel.disconnect()
            }
    }
}

private struct ApronChatTitlePill: View {
    let title: String
    let subtitle: String

    var body: some View {
        let content = VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 5)

        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}
