import SwiftUI
import WebKit

/// Discord's login page. Discord keeps its session in a token, not a cookie: once signed in, the web client sends
/// it as the `Authorization` header of its API calls and keeps it in `localStorage` under `token`. A script that
/// runs before the page's own sees both (Discord hides `localStorage` from later scripts) and hands the token over.
/// The store is ephemeral, so each login starts signed out and closing the sheet doesn't log the token out.
struct DiscordLoginWebView: View {
    @Environment(\.dismiss) private var dismiss
    let onLoginSuccess: (String) -> Void

    var body: some View {
        LoginSheet(title: "Log in to Discord") {
            DiscordTokenWebView { token in
                onLoginSuccess(token)
                dismiss()
            }
            .ignoresSafeArea()
        }
    }
}

private struct DiscordTokenWebView: UIViewRepresentable {
    let onToken: (String) -> Void

    private static let handlerName = "discordToken"

    /// Reports the token once, from an API call's header or from storage.
    private static let script = """
    (() => {
      let sent = false;
      const report = (value) => {
        if (sent || typeof value !== "string") return;
        const token = value.replace(/^"|"$/g, "");
        if (token.length < 50 || token.startsWith("Bearer ") || token.startsWith("Bot ")) return;
        sent = true;
        window.webkit.messageHandlers.\(handlerName).postMessage(token);
      };
      const setHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function (name, value) {
        if (String(name).toLowerCase() === "authorization") report(value);
        return setHeader.apply(this, arguments);
      };
      const originalFetch = window.fetch;
      window.fetch = function (input, init) {
        try {
          const headers = new Headers((init && init.headers) || (input && input.headers) || {});
          if (headers.get("authorization")) report(headers.get("authorization"));
        } catch (e) {}
        return originalFetch.apply(this, arguments);
      };
      const storage = window.localStorage;
      const poll = setInterval(() => {
        if (sent) { clearInterval(poll); return; }
        try { const stored = storage.getItem("token"); if (stored) report(JSON.parse(stored)); } catch (e) {}
      }, 1000);
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: Self.handlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #if DEBUG
            webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: URL(string: "https://discord.com/login")!))
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator _: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: handlerName)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onToken: (String) -> Void
        private var captured = false

        init(onToken: @escaping (String) -> Void) {
            self.onToken = onToken
        }

        func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !captured, let token = message.body as? String else { return }
            captured = true
            onToken(token)
        }
    }
}
