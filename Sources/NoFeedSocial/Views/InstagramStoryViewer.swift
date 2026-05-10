import NoFeedSocialCore
import SwiftUI

struct InstagramStoryViewer: View {
    let reels: [InstagramStoryReel]
    let startIndex: Int
    let onReelSeen: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var currentReelIndex: Int
    @State private var currentSlideIndex: Int = 0
    @State private var seenReels: Set<Int>
    @State private var elapsedTime: Double = 0
    @State private var isPaused: Bool = false

    init(reels: [InstagramStoryReel], startIndex: Int = 0, onReelSeen: @escaping (Int) -> Void) {
        self.reels = reels
        self.startIndex = startIndex
        self.onReelSeen = onReelSeen
        _currentReelIndex = State(initialValue: startIndex)
        _seenReels = State(initialValue: [startIndex])
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if reels.indices.contains(currentReelIndex) {
                let reel = reels[currentReelIndex]

                if !reel.slides.isEmpty, reel.slides.indices.contains(currentSlideIndex) {
                    AsyncImage(url: reel.slides[currentSlideIndex].imageURL) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                        case .failure, .empty:
                            Color.gray.opacity(0.3)
                        @unknown default:
                            Color.clear
                        }
                    }
                } else {
                    Color.gray.opacity(0.3)
                }

                progressBar
                header
                footer
            }
        }
        .onAppear {
            onReelSeen(startIndex)
        }
        .onChange(of: currentReelIndex) { _, newIndex in
            elapsedTime = 0
            guard !seenReels.contains(newIndex) else { return }
            seenReels.insert(newIndex)
            onReelSeen(newIndex)
        }
        .onChange(of: currentSlideIndex) { _, _ in
            elapsedTime = 0
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            guard !isPaused else { return }
            guard reels.indices.contains(currentReelIndex) else { return }
            elapsedTime += 0.05
            if elapsedTime >= slideDuration {
                elapsedTime = 0
                goForward()
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    isPaused = true
                }
                .onEnded { _ in
                    isPaused = false
                }
        )
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .local)
                .onEnded { value in
                    let hTranslation = value.translation.width
                    let vTranslation = value.translation.height
                    if vTranslation > 80 {
                        dismiss()
                    } else if hTranslation < -50 {
                        goForward()
                    } else if hTranslation > 50 {
                        goBack()
                    }
                }
        )
    }

    private var progressBar: some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(Array(reels[currentReelIndex].slides.enumerated()), id: \.offset) { index, _ in
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 3)

                            if index == currentSlideIndex {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(
                                        width: geo.size.width * min(elapsedTime / slideDuration, 1.0),
                                        height: 3
                                    )
                            } else if index < currentSlideIndex {
                                Capsule()
                                    .fill(Color.white)
                                    .frame(height: 3)
                            }
                        }
                    }
                    .frame(height: 3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Spacer()
        }
    }

    private var header: some View {
        VStack {
            HStack(spacing: 10) {
                AsyncImage(url: reels[currentReelIndex].user.avatarURL) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure, .empty:
                        Circle().fill(Color.white.opacity(0.2))
                    @unknown default:
                        Color.clear
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(reels[currentReelIndex].user.username ?? "")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(relativeTimeString)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Spacer()
        }
    }

    private var footer: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()

                HStack(spacing: 20) {
                    Button {
                        goBack()
                    } label: {
                        Color.clear
                            .frame(width: geo.size.width * 0.35, height: geo.size.height * 0.7)
                    }

                    Spacer()

                    Button {
                        goForward()
                    } label: {
                        Color.clear
                            .frame(width: geo.size.width * 0.35, height: geo.size.height * 0.7)
                    }
                }
            }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var relativeTimeString: String {
        guard reels.indices.contains(currentReelIndex) else { return "" }
        let slides = reels[currentReelIndex].slides
        guard slides.indices.contains(currentSlideIndex) else { return "" }
        let date = Date(timeIntervalSince1970: slides[currentSlideIndex].takenAt)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: .now)
    }

    private let slideDuration: Double = 5

    private func goForward() {
        let reel = reels[currentReelIndex]
        if currentSlideIndex + 1 < reel.slides.count {
            currentSlideIndex += 1
        } else if currentReelIndex + 1 < reels.count {
            currentReelIndex += 1
            currentSlideIndex = 0
        } else {
            dismiss()
        }
    }

    private func goBack() {
        if currentSlideIndex > 0 {
            currentSlideIndex -= 1
        } else if currentReelIndex > 0 {
            currentReelIndex -= 1
            currentSlideIndex = max(0, reels[currentReelIndex].slides.count - 1)
        }
    }
}
