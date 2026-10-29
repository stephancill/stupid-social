import Foundation

enum ErrorDescription {
    /// A description of an error's type and case that never includes its payload
    /// or localized text, which can carry user data (names, URLs, server messages).
    ///
    /// - `URLError(.notConnectedToInternet)` → `URLError.-1009`
    /// - `DecodingError.keyNotFound(…)` → `DecodingError.keyNotFound`
    /// - `NSError(domain: "X", code: 3)` → `X.3`
    static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError.\(urlError.code.rawValue)"
        }
        if error is CancellationError {
            return "CancellationError"
        }
        if type(of: error) is NSError.Type {
            let nsError = error as NSError
            return "\(nsError.domain).\(nsError.code)"
        }
        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else { return typeName }
        if let caseName = mirror.children.first?.label {
            return "\(typeName).\(caseName)"
        }
        // A case without associated values prints its name, unless the type
        // supplies its own description, which may not be safe to send.
        if type(of: error) is any CustomStringConvertible.Type {
            return "\(typeName).\((error as NSError).code)"
        }
        return "\(typeName).\(String(describing: error))"
    }
}
