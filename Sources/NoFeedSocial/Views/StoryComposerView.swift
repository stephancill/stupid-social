import PhotosUI
import SwiftUI

#if os(iOS)
    import Photos
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct StoryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPost: (Data, Int, Int) async throws -> Void
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var canvasSize = CGSize(width: 390, height: 844)
    @State private var background = StoryComposerBackground.default
    @State private var captions: [StoryCaption] = []
    @State private var focusedCaptionID: UUID?
    @State private var selectionError: String?
    @State private var saveSucceeded = false
    @State private var postSucceeded = false
    @State private var isPosting = false
    @State private var composerMessage: String?
    @GestureState private var captionDrag: CaptionDrag?
    @FocusState private var swiftUIFocusedCaptionID: UUID?

    init(onPost: @escaping (Data, Int, Int) async throws -> Void = { _, _, _ in }) {
        self.onPost = onPost
    }

    var body: some View {
        ZStack {
            background.view.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    Rectangle()
                        .fill(.clear)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            clearFocusedCaption()
                        }

                    if let selectedImage {
                        selectedImage
                            .resizable()
                            .scaledToFit()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                clearFocusedCaption()
                            }
                    } else if !hasComposerElements {
                        emptyCanvas
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                clearFocusedCaption()
                            }
                    }

                    if focusedCaptionID != nil {
                        Color.black.opacity(0.46)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                            .zIndex(1)
                    }

                    #if os(iOS)
                        ForEach($captions) { $caption in
                            SmoothDraggableTextOverlay(
                                id: caption.id,
                                text: $caption.text,
                                isFocused: captionFocusBinding(caption.id),
                                offset: $caption.offset,
                                scale: $caption.scale,
                                textBackground: $caption.textBackground,
                                fontStyle: $caption.fontStyle,
                                textColor: $caption.textColor,
                                maxTextWidth: min(proxy.size.width - 88, 420),
                                onDragEnded: { id, shouldDelete in
                                    if shouldDelete {
                                        removeCaption(id)
                                    }
                                },
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .zIndex(focusedCaptionID == caption.id ? 2 : 0)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                        }
                    #else
                        ForEach(captions) { caption in
                            textOverlay(caption: caption, maxWidth: min(proxy.size.width - 88, 420))
                                .zIndex(focusedCaptionID == caption.id ? 2 : 0)
                        }
                    #endif
                }
                .onAppear {
                    canvasSize = proxy.size
                }
                .onChange(of: proxy.size) { _, newSize in
                    canvasSize = newSize
                }
            }

            VStack {
                HStack(alignment: .top) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close composer")

                    Spacer()

                    VStack(spacing: 12) {
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            ComposerToolbarIcon(systemName: "photo")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Select image")

                        Button {
                            addText()
                        } label: {
                            ComposerToolbarIcon(systemName: "textformat")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add text")

                        Button {
                            cycleBackground()
                        } label: {
                            BackgroundToolbarIcon(background: background)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Change background color")

                        if hasComposerElements {
                            Button {
                                saveComposedStoryImage()
                            } label: {
                                ComposerToolbarIcon(systemName: saveSucceeded ? "checkmark" : "square.and.arrow.down")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Save story image")
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 12) {
                    if hasComposerElements {
                        Button {
                            postComposedStoryImage()
                        } label: {
                            HStack(spacing: 8) {
                                if isPosting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                } else {
                                    Image(systemName: postSucceeded ? "checkmark" : "paperplane.fill")
                                        .font(.title3)
                                }
                                Text(isPosting ? "Posting..." : "Post Story")
                                    .font(.subheadline.weight(.medium))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 22)
                            .frame(height: 44)
                            .background(.black.opacity(0.45), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPosting)
                        .accessibilityLabel("Post story")
                    }
                }
                .padding(.bottom, 28)
            }
        }
        .task(id: selectedPhoto) {
            await loadSelectedPhoto()
        }
        .alert("Image Selection Failed", isPresented: errorBinding) {
            Button("OK", role: .cancel) {
                selectionError = nil
            }
        } message: {
            Text(selectionError ?? "Could not load the selected image.")
        }
        .alert("Story Image", isPresented: composerMessageBinding) {
            Button("OK", role: .cancel) {
                composerMessage = nil
            }
        } message: {
            Text(composerMessage ?? "")
        }
        .ignoresSafeArea(.keyboard)
    }

    private var emptyCanvas: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.white.opacity(0.52))
            Text("Select an image to start")
                .font(.headline)
                .foregroundStyle(.white)
            Text("The image will fit centered on the story canvas.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private var selectedImage: Image? {
        guard let selectedImageData else { return nil }
        #if os(iOS)
            guard let image = UIImage(data: selectedImageData) else { return nil }
            return Image(uiImage: image)
        #elseif os(macOS)
            guard let image = NSImage(data: selectedImageData) else { return nil }
            return Image(nsImage: image)
        #else
            return nil
        #endif
    }

    private var hasComposerElements: Bool {
        selectedImageData != nil || !captions.isEmpty || background != .default
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { selectionError != nil },
            set: { if !$0 { selectionError = nil } },
        )
    }

    private var composerMessageBinding: Binding<Bool> {
        Binding(
            get: { composerMessage != nil },
            set: { if !$0 { composerMessage = nil } },
        )
    }

    private func captionFocusBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { focusedCaptionID == id },
            set: { isFocused in
                if isFocused {
                    focusedCaptionID = id
                } else if focusedCaptionID == id {
                    focusedCaptionID = nil
                }
            },
        )
    }

    private func bindingForCaption(_ id: UUID) -> Binding<String> {
        Binding(
            get: { captions.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
                captions[index].text = newValue
            },
        )
    }

    private func textDisplay(_ caption: StoryCaption) -> String {
        caption.text.isEmpty ? "Text" : caption.text
    }

    private func liveOffset(_ caption: StoryCaption) -> CGSize {
        guard captionDrag?.id == caption.id else { return caption.offset }
        return CGSize(
            width: caption.offset.width + (captionDrag?.translation.width ?? 0),
            height: caption.offset.height + (captionDrag?.translation.height ?? 0),
        )
    }

    private func textOverlay(caption: StoryCaption, maxWidth: CGFloat) -> some View {
        Group {
            if swiftUIFocusedCaptionID == caption.id {
                TextField("Text", text: bindingForCaption(caption.id), axis: .vertical)
                    .focused($swiftUIFocusedCaptionID, equals: caption.id)
                    .submitLabel(.done)
            } else {
                Text(textDisplay(caption))
                    .onTapGesture {
                        focusedCaptionID = caption.id
                        swiftUIFocusedCaptionID = caption.id
                    }
            }
        }
        .font(.largeTitle.weight(.bold))
        .multilineTextAlignment(.center)
        .foregroundStyle(caption.textColor.color)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(caption.textBackground.color, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: maxWidth)
        .scaleEffect(caption.scale)
        .contentShape(Rectangle())
        .offset(liveOffset(caption))
        .highPriorityGesture(textDragGesture(caption))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func textDragGesture(_ caption: StoryCaption) -> some Gesture {
        DragGesture()
            .updating($captionDrag) { value, state, _ in
                state = CaptionDrag(id: caption.id, translation: value.translation)
            }
            .onChanged { value in
                if value.translation != .zero {
                    focusedCaptionID = nil
                    swiftUIFocusedCaptionID = nil
                }
            }
            .onEnded { value in
                guard let index = captions.firstIndex(where: { $0.id == caption.id }) else { return }
                captions[index].offset.width += value.translation.width
                captions[index].offset.height += value.translation.height
            }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }
        do {
            selectedImageData = try await selectedPhoto.loadTransferable(type: Data.self)
        } catch {
            selectionError = "Could not load the selected image."
        }
    }

    private func addText() {
        let caption = StoryCaption(text: "Text")
        captions.append(caption)
        focusedCaptionID = caption.id
        swiftUIFocusedCaptionID = caption.id
    }

    private func cycleBackground() {
        background = background.next
    }

    private func removeCaption(_ id: UUID) {
        captions.removeAll { $0.id == id }
        if focusedCaptionID == id {
            focusedCaptionID = nil
        }
        if swiftUIFocusedCaptionID == id {
            swiftUIFocusedCaptionID = nil
        }
    }

    private func clearFocusedCaption() {
        focusedCaptionID = nil
        swiftUIFocusedCaptionID = nil
    }

    private func saveComposedStoryImage() {
        #if os(iOS)
            guard let image = renderedStoryImage() else {
                composerMessage = "Add an image or text before saving."
                return
            }

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        composerMessage = "Allow photo library access to save the story image."
                    }
                    return
                }

                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                } completionHandler: { success, _ in
                    DispatchQueue.main.async {
                        if success {
                            showTemporarySaveSuccess()
                        } else {
                            composerMessage = "Could not save the story image."
                        }
                    }
                }
            }
        #else
            composerMessage = "Saving story images is only available on iOS."
        #endif
    }

    private func postComposedStoryImage() {
        #if os(iOS)
            guard let image = renderedStoryImage(), let jpegData = image.jpegData(compressionQuality: 0.95) else {
                composerMessage = "Add an image or text before posting."
                return
            }

            isPosting = true
            Task {
                do {
                    try await onPost(jpegData, Int(image.size.width), Int(image.size.height))
                    await MainActor.run {
                        isPosting = false
                        showTemporaryPostSuccess()
                        dismiss()
                    }
                } catch {
                    await MainActor.run {
                        isPosting = false
                        composerMessage = "Could not post the story. Check your Instagram connection and try again."
                    }
                }
            }
        #else
            composerMessage = "Posting stories is only available on iOS."
        #endif
    }

    private func showTemporarySaveSuccess() {
        saveSucceeded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            saveSucceeded = false
        }
    }

    private func showTemporaryPostSuccess() {
        postSucceeded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            postSucceeded = false
        }
    }
}

#if os(iOS)
    private extension StoryComposerView {
        func renderedStoryImage() -> UIImage? {
            guard hasComposerElements else { return nil }
            let image = selectedImageData.flatMap(UIImage.init(data:))

            let outputSize = CGSize(width: 1080, height: 1920)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1

            return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: outputSize))
                background.draw(in: CGRect(origin: .zero, size: outputSize))

                image?.drawAspectFit(in: CGRect(origin: .zero, size: outputSize))

                let xScale = outputSize.width / max(canvasSize.width, 1)
                let yScale = outputSize.height / max(canvasSize.height, 1)
                let textScale = min(xScale, yScale)
                let maxTextWidth = min(canvasSize.width - 88, 420) * xScale

                for caption in captions {
                    drawCaption(caption, in: outputSize, maxTextWidth: maxTextWidth, textScale: textScale, xScale: xScale, yScale: yScale)
                }
            }
        }

        func drawCaption(_ caption: StoryCaption, in outputSize: CGSize, maxTextWidth: CGFloat, textScale: CGFloat, xScale: CGFloat, yScale: CGFloat) {
            let displayText = textDisplay(caption)
            let scaledText = textScale * caption.scale
            let font = caption.fontStyle.uiFont(size: 34 * scaledText)
            let horizontalInset = 18 * scaledText
            let verticalInset = 12 * scaledText
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            paragraphStyle.lineBreakMode = .byWordWrapping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: caption.textColor.uiColor,
                .paragraphStyle: paragraphStyle,
            ]
            let textBounds = (displayText as NSString).boundingRect(
                with: CGSize(width: maxTextWidth - horizontalInset * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil,
            )
            let width = min(max(ceil(textBounds.width + horizontalInset * 2), 90 * scaledText), maxTextWidth)
            let height = max(ceil(textBounds.height + verticalInset * 2), 58 * scaledText)
            let center = CGPoint(
                x: outputSize.width / 2 + caption.offset.width * xScale,
                y: outputSize.height / 2 + caption.offset.height * yScale,
            )
            let backgroundRect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            let path = UIBezierPath(roundedRect: backgroundRect, cornerRadius: 16 * scaledText)
            caption.textBackground.uiColor.setFill()
            path.fill()

            let textRect = backgroundRect.insetBy(dx: horizontalInset, dy: verticalInset)
            (displayText as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        }
    }

    private extension UIImage {
        func drawAspectFit(in rect: CGRect) {
            let scale = min(rect.width / size.width, rect.height / size.height)
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            let drawRect = CGRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height,
            )
            draw(in: drawRect)
        }
    }
#endif

private struct StoryCaption: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var offset = CGSize.zero
    var scale: CGFloat = 1
    var textBackground = StoryTextBackground.translucentBlack
    var fontStyle = StoryTextFont.bold
    var textColor = StoryTextColor.white
}

private enum StoryTextBackground: CaseIterable, Equatable {
    case translucentBlack
    case translucentWhite
    case clear
    case red
    case blue

    var next: StoryTextBackground {
        let options = Self.allCases
        guard let index = options.firstIndex(of: self) else { return .translucentBlack }
        return options[(index + 1) % options.count]
    }

    var color: Color {
        switch self {
        case .translucentBlack:
            .black.opacity(0.35)
        case .translucentWhite:
            .white.opacity(0.55)
        case .clear:
            .clear
        case .red:
            .red.opacity(0.75)
        case .blue:
            .blue.opacity(0.75)
        }
    }
}

private enum StoryTextFont: CaseIterable, Equatable {
    case bold
    case rounded
    case serif
    case mono

    var next: StoryTextFont {
        let options = Self.allCases
        guard let index = options.firstIndex(of: self) else { return .bold }
        return options[(index + 1) % options.count]
    }
}

private enum StoryTextColor: CaseIterable, Equatable {
    case white
    case black
    case yellow
    case pink
    case blue

    var next: StoryTextColor {
        let options = Self.allCases
        guard let index = options.firstIndex(of: self) else { return .white }
        return options[(index + 1) % options.count]
    }

    var color: Color {
        switch self {
        case .white:
            .white
        case .black:
            .black
        case .yellow:
            .yellow
        case .pink:
            .pink
        case .blue:
            .blue
        }
    }
}

#if os(iOS)
    private extension StoryTextBackground {
        var uiColor: UIColor {
            switch self {
            case .translucentBlack:
                UIColor.black.withAlphaComponent(0.35)
            case .translucentWhite:
                UIColor.white.withAlphaComponent(0.55)
            case .clear:
                UIColor.clear
            case .red:
                UIColor.systemRed.withAlphaComponent(0.75)
            case .blue:
                UIColor.systemBlue.withAlphaComponent(0.75)
            }
        }
    }

    private extension StoryTextFont {
        func uiFont(size: CGFloat) -> UIFont {
            switch self {
            case .bold:
                .systemFont(ofSize: size, weight: .bold)
            case .rounded:
                UIFont.systemFont(ofSize: size, weight: .bold).withDesign(.rounded)
            case .serif:
                UIFont.systemFont(ofSize: size, weight: .bold).withDesign(.serif)
            case .mono:
                .monospacedSystemFont(ofSize: size, weight: .bold)
            }
        }
    }

    private extension StoryTextColor {
        var uiColor: UIColor {
            switch self {
            case .white:
                .white
            case .black:
                .black
            case .yellow:
                .systemYellow
            case .pink:
                .systemPink
            case .blue:
                .systemBlue
            }
        }
    }

    private extension UIFont {
        func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
            guard let descriptor = fontDescriptor.withDesign(design) else { return self }
            return UIFont(descriptor: descriptor, size: pointSize)
        }
    }
#endif

private struct CaptionDrag: Equatable {
    let id: UUID
    let translation: CGSize
}

private enum StoryComposerBackground: Equatable, CaseIterable {
    case black
    case white
    case blue
    case purple
    case sunset
    case ocean
    case graphite

    static let `default` = StoryComposerBackground.black

    var next: StoryComposerBackground {
        let options = Self.allCases
        guard let index = options.firstIndex(of: self) else { return Self.default }
        return options[(index + 1) % options.count]
    }

    @ViewBuilder var view: some View {
        switch self {
        case .black:
            Color.black
        case .white:
            Color.white
        case .blue:
            Color.blue
        case .purple:
            Color.purple
        case .sunset:
            LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ocean:
            LinearGradient(colors: [.cyan, .blue, .indigo], startPoint: .top, endPoint: .bottom)
        case .graphite:
            LinearGradient(colors: [.black, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

#if os(iOS)
    private extension StoryComposerBackground {
        func draw(in rect: CGRect) {
            switch self {
            case .black:
                UIColor.black.setFill()
                UIRectFill(rect)
            case .white:
                UIColor.white.setFill()
                UIRectFill(rect)
            case .blue:
                UIColor.systemBlue.setFill()
                UIRectFill(rect)
            case .purple:
                UIColor.systemPurple.setFill()
                UIRectFill(rect)
            case .sunset:
                drawGradient(colors: [UIColor.systemOrange, UIColor.systemPink, UIColor.systemPurple], in: rect)
            case .ocean:
                drawGradient(colors: [UIColor.systemCyan, UIColor.systemBlue, UIColor.systemIndigo], in: rect)
            case .graphite:
                drawGradient(colors: [UIColor.black, UIColor.systemGray], in: rect)
            }
        }

        private func drawGradient(colors: [UIColor], in rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext(), let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors.map(\.cgColor) as CFArray,
                locations: nil,
            ) else { return }
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [],
            )
        }
    }
#endif

private struct ComposerToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.black.opacity(0.45), in: Circle())
    }
}

private struct BackgroundToolbarIcon: View {
    let background: StoryComposerBackground

    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.45))

            background.view
                .frame(width: 24, height: 24)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.75), lineWidth: 1.5)
                }
        }
        .frame(width: 44, height: 44)
    }
}

#if os(iOS)
    private struct SmoothDraggableTextOverlay: UIViewRepresentable {
        let id: UUID
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var offset: CGSize
        @Binding var scale: CGFloat
        @Binding var textBackground: StoryTextBackground
        @Binding var fontStyle: StoryTextFont
        @Binding var textColor: StoryTextColor
        let maxTextWidth: CGFloat
        let onDragEnded: (UUID, Bool) -> Void

        func makeUIView(context: Context) -> DraggableTextCanvasView {
            let view = DraggableTextCanvasView()
            view.textView.delegate = context.coordinator
            view.onOffsetChange = { offset in
                self.offset = offset
            }
            view.onScaleChange = { scale in
                self.scale = scale
            }
            view.onTextBackgroundChange = { textBackground in
                self.textBackground = textBackground
            }
            view.onFontStyleChange = { fontStyle in
                self.fontStyle = fontStyle
            }
            view.onTextColorChange = { textColor in
                self.textColor = textColor
            }
            view.onFocusChange = { focused in
                isFocused = focused
            }
            view.onDragEnded = { shouldDelete in
                onDragEnded(id, shouldDelete)
            }
            return view
        }

        func updateUIView(_ view: DraggableTextCanvasView, context _: Context) {
            view.maxTextWidth = maxTextWidth
            if !view.isInteracting {
                view.committedOffset = offset
                view.committedScale = scale
            }
            view.isEditingCentered = isFocused
            if view.textBackground != textBackground {
                view.textBackground = textBackground
            }
            if view.fontStyle != fontStyle {
                view.fontStyle = fontStyle
            }
            if view.textColor != textColor {
                view.textColor = textColor
            }
            view.onOffsetChange = { offset in
                self.offset = offset
            }
            view.onScaleChange = { scale in
                self.scale = scale
            }
            view.onTextBackgroundChange = { textBackground in
                self.textBackground = textBackground
            }
            view.onFontStyleChange = { fontStyle in
                self.fontStyle = fontStyle
            }
            view.onTextColorChange = { textColor in
                self.textColor = textColor
            }
            view.onFocusChange = { focused in
                isFocused = focused
            }
            view.onDragEnded = { shouldDelete in
                onDragEnded(id, shouldDelete)
            }

            let displayText = text.isEmpty ? "Text" : text
            if view.textView.text != displayText, !view.textView.isFirstResponder {
                view.textView.text = displayText
            }

            if isFocused, !view.textView.isFirstResponder {
                view.textView.becomeFirstResponder()
            } else if !isFocused, view.textView.isFirstResponder {
                view.textView.resignFirstResponder()
            }

            if !view.isInteracting {
                view.setNeedsLayout()
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(text: $text, isFocused: $isFocused)
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            @Binding var text: String
            @Binding var isFocused: Bool

            init(text: Binding<String>, isFocused: Binding<Bool>) {
                _text = text
                _isFocused = isFocused
            }

            func textViewDidChange(_ textView: UITextView) {
                text = textView.text
            }

            func textViewDidBeginEditing(_: UITextView) {
                isFocused = true
            }

            func textViewDidEndEditing(_: UITextView) {
                isFocused = false
            }
        }
    }

    private final class DraggableTextCanvasView: UIView {
        let textView = UITextView()
        private let trashContainer = UIView()
        private let trashImageView = UIImageView(image: UIImage(systemName: "trash.fill"))
        var maxTextWidth: CGFloat = 420
        var committedOffset = CGSize.zero
        var committedScale: CGFloat = 1
        var isEditingCentered = false {
            didSet {
                if oldValue != isEditingCentered, !isInteracting {
                    moveTextViewToCurrentEditingPosition(animated: true)
                }
            }
        }

        var textBackground = StoryTextBackground.translucentBlack {
            didSet { applyTextAppearance(preserving: textView.center) }
        }

        var fontStyle = StoryTextFont.bold {
            didSet { applyTextAppearance(preserving: textView.center) }
        }

        var textColor = StoryTextColor.white {
            didSet { applyTextAppearance(preserving: textView.center) }
        }

        var onOffsetChange: ((CGSize) -> Void)?
        var onScaleChange: ((CGFloat) -> Void)?
        var onTextBackgroundChange: ((StoryTextBackground) -> Void)?
        var onFontStyleChange: ((StoryTextFont) -> Void)?
        var onTextColorChange: ((StoryTextColor) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
        var onDragEnded: ((Bool) -> Void)?
        private(set) var isDragging = false
        private(set) var isResizing = false
        var isInteracting: Bool {
            isDragging || isResizing
        }

        private var dragStartCenter = CGPoint.zero
        private var resizeStartScale: CGFloat = 1
        private var trashIsActive = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear

            textView.isScrollEnabled = false
            textView.textAlignment = .center
            textView.textContainer.lineFragmentPadding = 0
            textView.clipsToBounds = true
            textView.inputAccessoryView = makeAccessoryToolbar()
            applyTextAppearance(preserving: textView.center)
            addSubview(textView)

            trashContainer.isHidden = true
            trashContainer.alpha = 0
            trashContainer.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            trashContainer.layer.cornerRadius = 38
            trashContainer.layer.borderWidth = 2
            trashContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
            trashContainer.isUserInteractionEnabled = false
            addSubview(trashContainer)

            trashImageView.tintColor = .white
            trashImageView.contentMode = .scaleAspectFit
            trashContainer.addSubview(trashImageView)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            pan.cancelsTouchesInView = false
            textView.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.delegate = self
            pinch.cancelsTouchesInView = false
            textView.addGestureRecognizer(pinch)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if isInteracting {
                layoutTrashTarget()
            } else {
                layoutTextView()
            }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !isHidden, alpha > 0, isUserInteractionEnabled else { return nil }
            let expandedFrame = textView.frame.insetBy(dx: -20, dy: -20)
            guard expandedFrame.contains(point) else { return nil }
            return textView.hitTest(convert(point, to: textView), with: event) ?? textView
        }

        private func layoutTextView() {
            updateTextMetrics(preserving: currentTextCenter())

            layoutTrashTarget()
        }

        private func currentTextCenter() -> CGPoint {
            CGPoint(
                x: bounds.midX + (isEditingCentered ? 0 : committedOffset.width),
                y: bounds.midY + (isEditingCentered ? -96 : committedOffset.height),
            )
        }

        private func moveTextViewToCurrentEditingPosition(animated: Bool) {
            let updates = {
                self.updateTextMetrics(preserving: self.currentTextCenter())
            }
            if animated {
                UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut], animations: updates)
            } else {
                updates()
            }
        }

        private func updateTextMetrics(preserving center: CGPoint) {
            let clampedScale = min(max(committedScale, 0.45), 2.5)
            textView.font = fontStyle.uiFont(size: 34 * clampedScale)
            textView.textContainerInset = UIEdgeInsets(top: 12 * clampedScale, left: 18 * clampedScale, bottom: 12 * clampedScale, right: 18 * clampedScale)
            textView.layer.cornerRadius = 16 * clampedScale

            let targetWidth = min(maxTextWidth, max(bounds.width - 88, 120))
            let fittingSize = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
            let width = min(max(fittingSize.width, 90 * clampedScale), targetWidth)
            let height = max(fittingSize.height, 58 * clampedScale)
            textView.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            textView.center = center
        }

        private func applyTextAppearance(preserving center: CGPoint) {
            textView.backgroundColor = textBackground.uiColor
            textView.textColor = textColor.uiColor
            updateTextMetrics(preserving: center)
        }

        private func makeAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            toolbar.items = [
                UIBarButtonItem(customView: accessoryButton(accessibilityLabel: "Change text background", action: #selector(cycleTextBackground), content: textBackgroundIcon())),
                UIBarButtonItem(systemItem: .fixedSpace),
                UIBarButtonItem(customView: accessoryButton(accessibilityLabel: "Change font", action: #selector(cycleFontStyle), content: fontStyleIcon())),
                UIBarButtonItem(systemItem: .fixedSpace),
                UIBarButtonItem(customView: accessoryButton(accessibilityLabel: "Change text color", action: #selector(cycleTextColor), content: textColorIcon())),
                UIBarButtonItem(systemItem: .flexibleSpace),
                UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), style: .plain, target: self, action: #selector(doneEditing)),
            ]
            toolbar.items?[1].width = 10
            toolbar.items?[3].width = 10
            return toolbar
        }

        private func accessoryButton(accessibilityLabel: String, action: Selector, content: UIView) -> UIButton {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityLabel = accessibilityLabel
            button.addTarget(self, action: action, for: .touchUpInside)
            content.isUserInteractionEnabled = false
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 36),
                content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                content.widthAnchor.constraint(equalToConstant: content.bounds.width),
                content.heightAnchor.constraint(equalToConstant: content.bounds.height),
            ])
            return button
        }

        private func textBackgroundIcon() -> UIView {
            swatchView(fillColor: textBackground.uiColor, borderColor: UIColor.label.withAlphaComponent(0.45))
        }

        private func textColorIcon() -> UIView {
            swatchView(fillColor: textColor.uiColor, borderColor: UIColor.label.withAlphaComponent(0.45))
        }

        private func swatchView(fillColor: UIColor, borderColor: UIColor) -> UIView {
            let view = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 24, height: 24)))
            view.backgroundColor = fillColor
            view.layer.cornerRadius = 12
            view.layer.borderWidth = 1.5
            view.layer.borderColor = borderColor.cgColor
            if fillColor == .clear {
                view.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.5)
            }
            return view
        }

        private func fontStyleIcon() -> UIView {
            let label = UILabel(frame: CGRect(origin: .zero, size: CGSize(width: 28, height: 28)))
            label.text = "A"
            label.textAlignment = .center
            label.textColor = .label
            label.font = fontStyle.uiFont(size: 24)
            return label
        }

        private func refreshAccessoryToolbar() {
            guard textView.inputAccessoryView != nil else { return }
            textView.inputAccessoryView = makeAccessoryToolbar()
            textView.reloadInputViews()
        }

        @objc private func cycleTextBackground() {
            textBackground = textBackground.next
            onTextBackgroundChange?(textBackground)
            refreshAccessoryToolbar()
        }

        @objc private func cycleFontStyle() {
            fontStyle = fontStyle.next
            onFontStyleChange?(fontStyle)
            refreshAccessoryToolbar()
        }

        @objc private func cycleTextColor() {
            textColor = textColor.next
            onTextColorChange?(textColor)
            refreshAccessoryToolbar()
        }

        @objc private func doneEditing() {
            textView.resignFirstResponder()
            onFocusChange?(false)
        }

        private func layoutTrashTarget() {
            let trashFrame = captionTrashFrame()
            trashContainer.frame = trashFrame
            trashImageView.frame = trashContainer.bounds.insetBy(dx: 24, dy: 24)
        }

        private func captionTrashFrame() -> CGRect {
            let dimension: CGFloat = 76
            return CGRect(
                x: (bounds.width - dimension) / 2,
                y: bounds.height - dimension - 54,
                width: dimension,
                height: dimension,
            )
        }

        private func captionTrashHitFrame() -> CGRect {
            captionTrashFrame().insetBy(dx: -14, dy: -14)
        }

        private func setTrashVisible(_ visible: Bool) {
            trashContainer.isHidden = false
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.trashContainer.alpha = visible ? 1 : 0
            } completion: { _ in
                if !visible {
                    self.trashContainer.isHidden = true
                }
            }
        }

        private func setTrashActive(_ active: Bool) {
            guard trashIsActive != active else { return }
            trashIsActive = active
            UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.trashContainer.backgroundColor = active ? .systemRed : UIColor.black.withAlphaComponent(0.55)
                self.trashContainer.layer.borderColor = UIColor.white.withAlphaComponent(active ? 0.9 : 0.35).cgColor
                self.trashContainer.transform = active ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
            }
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                isDragging = true
                if !isResizing {
                    setTrashVisible(true)
                }
                dragStartCenter = textView.center
                textView.resignFirstResponder()
                onFocusChange?(false)
                setTrashActive(captionTrashHitFrame().contains(textView.center))
            case .changed:
                let translation = recognizer.translation(in: self)
                textView.center = CGPoint(
                    x: dragStartCenter.x + translation.x,
                    y: dragStartCenter.y + translation.y,
                )
                setTrashActive(captionTrashHitFrame().contains(textView.center))
            case .ended, .cancelled, .failed:
                isDragging = false
                let shouldDelete = captionTrashHitFrame().contains(textView.center)
                if !isResizing {
                    setTrashVisible(false)
                }
                setTrashActive(false)
                if shouldDelete {
                    onDragEnded?(true)
                    return
                }
                committedOffset = CGSize(
                    width: textView.center.x - bounds.midX,
                    height: textView.center.y - bounds.midY,
                )
                onOffsetChange?(committedOffset)
                onDragEnded?(false)
            default:
                break
            }
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            switch recognizer.state {
            case .began:
                isResizing = true
                resizeStartScale = committedScale
                textView.resignFirstResponder()
                onFocusChange?(false)
            case .changed:
                committedScale = min(max(resizeStartScale * recognizer.scale, 0.45), 2.5)
                updateTextMetrics(preserving: textView.center)
            case .ended, .cancelled, .failed:
                committedScale = min(max(committedScale, 0.45), 2.5)
                isResizing = false
                updateTextMetrics(preserving: textView.center)
                onScaleChange?(committedScale)
            default:
                break
            }
        }
    }

    extension DraggableTextCanvasView: UIGestureRecognizerDelegate {
        func gestureRecognizer(_: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer) -> Bool {
            true
        }
    }
#endif
