import PhotosUI
import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

struct StoryComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var captions: [StoryCaption] = []
    @State private var focusedCaptionID: UUID?
    @State private var selectionError: String?
    @GestureState private var captionDrag: CaptionDrag?
    @FocusState private var swiftUIFocusedCaptionID: UUID?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ZStack {
                    Group {
                        if let selectedImage {
                            selectedImage
                                .resizable()
                                .scaledToFit()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        } else {
                            emptyCanvas
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        focusedCaptionID = nil
                        swiftUIFocusedCaptionID = nil
                    }

                    #if os(iOS)
                        ForEach($captions) { $caption in
                            SmoothDraggableTextOverlay(
                                text: $caption.text,
                                isFocused: captionFocusBinding(caption.id),
                                offset: $caption.offset,
                                maxTextWidth: min(proxy.size.width - 88, 420)
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    #else
                        ForEach(captions) { caption in
                            textOverlay(caption: caption, maxWidth: min(proxy.size.width - 88, 420))
                        }
                    #endif
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                Spacer()

                VStack(spacing: 6) {
                    Text("Instagram Story")
                        .font(.subheadline.weight(.semibold))
                    Text("Upload is not implemented yet.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.black.opacity(0.45), in: Capsule())
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

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { selectionError != nil },
            set: { if !$0 { selectionError = nil } }
        )
    }

    private func captionFocusBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { focusedCaptionID == id },
            set: { focusedCaptionID = $0 ? id : nil }
        )
    }

    private func bindingForCaption(_ id: UUID) -> Binding<String> {
        Binding(
            get: { captions.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let index = captions.firstIndex(where: { $0.id == id }) else { return }
                captions[index].text = newValue
            }
        )
    }

    private func textDisplay(_ caption: StoryCaption) -> String {
        caption.text.isEmpty ? "Text" : caption.text
    }

    private func liveOffset(_ caption: StoryCaption) -> CGSize {
        guard captionDrag?.id == caption.id else { return caption.offset }
        return CGSize(
            width: caption.offset.width + (captionDrag?.translation.width ?? 0),
            height: caption.offset.height + (captionDrag?.translation.height ?? 0)
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
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: maxWidth)
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
}

private struct StoryCaption: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var offset = CGSize.zero
}

private struct CaptionDrag: Equatable {
    let id: UUID
    let translation: CGSize
}

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

#if os(iOS)
    private struct SmoothDraggableTextOverlay: UIViewRepresentable {
        @Binding var text: String
        @Binding var isFocused: Bool
        @Binding var offset: CGSize
        let maxTextWidth: CGFloat

        func makeUIView(context: Context) -> DraggableTextCanvasView {
            let view = DraggableTextCanvasView()
            view.textView.delegate = context.coordinator
            view.onOffsetChange = { offset in
                self.offset = offset
            }
            view.onFocusChange = { focused in
                self.isFocused = focused
            }
            return view
        }

        func updateUIView(_ view: DraggableTextCanvasView, context _: Context) {
            view.maxTextWidth = maxTextWidth
            view.committedOffset = offset
            view.onOffsetChange = { offset in
                self.offset = offset
            }
            view.onFocusChange = { focused in
                self.isFocused = focused
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

            view.setNeedsLayout()
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
        var maxTextWidth: CGFloat = 420
        var committedOffset = CGSize.zero
        var onOffsetChange: ((CGSize) -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        private var dragStartCenter = CGPoint.zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear

            textView.isScrollEnabled = false
            textView.backgroundColor = UIColor.black.withAlphaComponent(0.35)
            textView.textColor = .white
            textView.textAlignment = .center
            textView.font = .systemFont(ofSize: 34, weight: .bold)
            textView.textContainerInset = UIEdgeInsets(top: 12, left: 18, bottom: 12, right: 18)
            textView.textContainer.lineFragmentPadding = 0
            textView.layer.cornerRadius = 16
            textView.clipsToBounds = true
            addSubview(textView)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.cancelsTouchesInView = false
            textView.addGestureRecognizer(pan)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutTextView()
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard !isHidden, alpha > 0, isUserInteractionEnabled else { return nil }
            let expandedFrame = textView.frame.insetBy(dx: -20, dy: -20)
            guard expandedFrame.contains(point) else { return nil }
            return textView.hitTest(convert(point, to: textView), with: event) ?? textView
        }

        private func layoutTextView() {
            let targetWidth = min(maxTextWidth, max(bounds.width - 88, 120))
            let fittingSize = textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude))
            let width = min(max(fittingSize.width, 90), targetWidth)
            let height = max(fittingSize.height, 58)
            textView.bounds = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            textView.center = CGPoint(
                x: bounds.midX + committedOffset.width,
                y: bounds.midY + committedOffset.height
            )
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                dragStartCenter = textView.center
                textView.resignFirstResponder()
                onFocusChange?(false)
            case .changed:
                let translation = recognizer.translation(in: self)
                textView.center = CGPoint(
                    x: dragStartCenter.x + translation.x,
                    y: dragStartCenter.y + translation.y
                )
            case .ended, .cancelled, .failed:
                committedOffset = CGSize(
                    width: textView.center.x - bounds.midX,
                    height: textView.center.y - bounds.midY
                )
                onOffsetChange?(committedOffset)
            default:
                break
            }
        }
    }
#endif
