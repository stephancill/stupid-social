import ExpoModulesCore
import WebKit

public final class SocialPlatformModule: Module {
    private func checkedURL(_ value: String) throws -> URL {
        let hosts = ["x.com", "www.instagram.com", "github.com", "open.spotify.com", "accounts.spotify.com", "127.0.0.1"]
        guard let url = URL(string: value), let host = url.host, hosts.contains(host) else {
            throw NSError(domain: "SocialPlatform", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported cookie domain"])
        }
        return url
    }

    public func definition() -> ModuleDefinition {
        Name("ValidationBridge")
        Function("environment") {
            ["webView": "WKWebView", "documentStart": true, "messageListener": true] as [String: Any]
        }
        Function("captionFonts") {
            let font = UIFont.systemFont(ofSize: 34, weight: .bold)
            return [UIFontDescriptor.SystemDesign.default, .rounded, .serif, .monospaced].map { design in
                UIFont(descriptor: font.fontDescriptor.withDesign(design) ?? font.fontDescriptor, size: 34).fontName
            }
        }
        AsyncFunction("cookies") { (value: String) async throws -> String in
            let url = try self.checkedURL(value)
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            return cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return (url.host == domain || url.host!.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https")
            }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        AsyncFunction("seedCookie") { (value: String, header: String) async throws in
            let url = try self.checkedURL(value)
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url)
            guard !cookies.isEmpty else { throw NSError(domain: "SocialPlatform", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cookie rejected"]) }
            for cookie in cookies {
                await WKWebsiteDataStore.default().httpCookieStore.setCookie(cookie)
            }
        }
        AsyncFunction("writeReport") { (json: String) throws in
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try json.write(to: directory.appendingPathComponent("validation-report.json"), atomically: true, encoding: .utf8)
        }
        AsyncFunction("importSeed") { () throws -> String? in
            #if DEBUG
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("validation-seed.json")
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                let result = try String(contentsOf: file, encoding: .utf8)
                try FileManager.default.removeItem(at: file)
                return result
            #else
                throw NSError(domain: "SocialPlatform", code: 3, userInfo: [NSLocalizedDescriptionKey: "Seed import requires a debug build"])
            #endif
        }
    }
}

final class SocialKeyboardView: ExpoView {
    let onKey = EventDispatcher()
    var enabled = false {
        didSet { if enabled { becomeFirstResponder() } else { resignFirstResponder() } }
    }

    override var canBecomeFirstResponder: Bool {
        enabled
    }

    override var keyCommands: [UIKeyCommand]? {
        guard enabled else { return [] }
        return [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, " "].flatMap { key in
            [UIKeyModifierFlags(), .shift].map { flags in
                let command = UIKeyCommand(input: key, modifierFlags: flags, action: #selector(handleKey(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
    }

    @objc private func handleKey(_ command: UIKeyCommand) {
        let key = command.input == UIKeyCommand.inputLeftArrow ? "left" : command.input == UIKeyCommand.inputRightArrow ? "right" : "space"
        onKey(["key": key, "shift": command.modifierFlags.contains(.shift)])
    }
}

public final class SocialKeyboardModule: Module {
    public func definition() -> ModuleDefinition {
        Name("StoryKeyboard")
        View(SocialKeyboardView.self) {
            Events("onKey")
            Prop("enabled") { (view: SocialKeyboardView, enabled: Bool) in view.enabled = enabled }
        }
    }
}
