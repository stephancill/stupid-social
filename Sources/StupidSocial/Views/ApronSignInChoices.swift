import StupidSocialCore
import SwiftUI

/// A server's sign-in methods as an invite shows them, in the server's order (PROTOCOL.md §3.2): its ways to sign
/// in and create an account (passkeys, external sign-in) shown, the first as the prominent button, and a token and
/// guest access behind Other. A server with only those shows them at once. A token is typed in only after choosing
/// it. Used by Add Account → Apron and by links to a new server.
struct ApronSignInChoices: View {
    let options: ApronSignInOptions
    let isWorking: Bool
    /// Signs in; the token is the one typed in, for `.token`.
    let signIn: (ApronSignInMethod, String?) async -> Void
    @State private var running: ApronSignInMethod?
    @State private var isEnteringToken = false
    @State private var showsOther = false
    @State private var token = ""
    @FocusState private var isTokenFocused: Bool

    private var methods: [ApronSignInMethod] {
        options.methods
    }

    /// Ways to sign in or create an account; a token and guest access are the others.
    private var main: [ApronSignInMethod] {
        methods.filter(\.usesPage)
    }

    private var other: [ApronSignInMethod] {
        methods.filter { !$0.usesPage }
    }

    private var shown: [ApronSignInMethod] {
        main.isEmpty ? other : main
    }

    private var firstExternal: ApronSignInMethod? {
        methods.first { if case .external = $0 { true } else { false } }
    }

    var body: some View {
        VStack(spacing: 10) {
            if methods.isEmpty {
                Text("The app can't use this server's sign-in methods (\(options.auth.joined(separator: ", "))).")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if isEnteringToken {
                tokenEntry
            } else {
                ForEach(Array(shown.enumerated()), id: \.element) { index, method in
                    // `labels.external` heads the ways external sign-in can go (`ext:auth_external`).
                    if let heading = options.externalHeading, method == firstExternal {
                        Text(heading)
                            .foregroundStyle(.secondary)
                    }
                    if index == 0 {
                        prominentButton(options.title(for: method), isRunning: running == method) { choose(method) }
                    } else {
                        borderedButton(options.title(for: method), isRunning: running == method) { choose(method) }
                    }
                }
                if !main.isEmpty, !other.isEmpty {
                    if showsOther {
                        ForEach(other, id: \.self) { method in
                            borderedButton(options.title(for: method), isRunning: running == method) { choose(method) }
                        }
                    } else {
                        plainButton("Other", isRunning: false) {
                            withAnimation { showsOther = true }
                        }
                    }
                }
            }
        }
        .disabled(isWorking)
    }

    private var tokenEntry: some View {
        VStack(spacing: 12) {
            SecureField(options.labels["token"] ?? "Token", text: $token)
                .textContentType(.password)
                .padding(12)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                .focused($isTokenFocused)
                .submitLabel(.go)
                .onSubmit { run(.token) }
            prominentButton(options.title(for: .token), isRunning: running == .token) { run(.token) }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            plainButton("Back", isRunning: false) {
                isEnteringToken = false
                token = ""
            }
        }
    }

    private func choose(_ method: ApronSignInMethod) {
        if method == .token {
            isEnteringToken = true
            isTokenFocused = true
        } else {
            run(method)
        }
    }

    private func run(_ method: ApronSignInMethod) {
        guard running == nil else { return }
        running = method
        Task {
            defer { running = nil }
            await signIn(method, method == .token ? token.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
    }

    private func prominentButton(_ title: String, isRunning: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, isRunning: isRunning)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func borderedButton(_ title: String, isRunning: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, isRunning: isRunning)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// The spinner is an overlay on the hidden title, so a running button keeps its size.
    private func label(_ title: String, isRunning: Bool) -> some View {
        Text(title)
            .opacity(isRunning ? 0 : 1)
            .overlay {
                if isRunning {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
    }

    private func plainButton(_ title: String, isRunning: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label(title, isRunning: isRunning)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderless)
    }
}

/// A server's welcome text (§3.1: CommonMark for the sign-in screen) in a fixed-height box that scrolls when it is
/// longer: paragraphs, and list items with their markers, each with its inline markdown (links, emphasis, code).
struct ApronWelcomeText: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .paragraph(line):
                        Text(Self.inline(line))
                    case let .item(marker, line):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker)
                                .foregroundStyle(.secondary)
                            Text(Self.inline(line))
                        }
                    }
                }
            }
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        // Shows that a longer message scrolls.
        .scrollIndicatorsFlash(onAppear: true)
        .frame(height: 150)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 14))
    }

    enum Block: Equatable {
        case paragraph(String)
        /// A list item: its marker ("•", or "1." for a numbered list) and text.
        case item(String, String)
    }

    /// Lines of a paragraph join with spaces; a blank line ends one. `-`, `*` and `+` items become "•".
    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func endParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
                endParagraph()
                blocks.append(.item("•", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].first == " "
            {
                endParagraph()
                blocks.append(.item(String(line[...dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        endParagraph()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A server's icon, or its initial without one.
struct ApronServerIcon: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                CachedAsyncImage(url: url) { initial } failure: { initial }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var initial: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.18))
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

/// A server as an invite shows it: icon, name, address and description. The address always shows, so a server's
/// chosen name can't pass for another server's (PROTOCOL.md §3.1).
struct ApronServerCard: View {
    let preview: ApronServerPreview

    var body: some View {
        VStack(spacing: 12) {
            ApronServerIcon(url: preview.server.avatarURL, name: preview.displayTitle, size: 88)
            VStack(spacing: 4) {
                Text(preview.displayTitle)
                    .font(.title2.weight(.semibold))
                Text(preview.serverURL.absoluteString)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
            if let description = preview.server.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                Text(Self.markdown(description))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.center)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
