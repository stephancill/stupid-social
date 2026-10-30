import Foundation

/// Released as the `cli-v<version>` tag by `scripts/release-cli.sh`.
let version = "0.1.0"

let usage = """
usage: stupid-social <command> [options]

  --version                         Print the version
  pair <token>                      Save the token from the app's Settings → Command Line
  status                            Check the app is reachable
  chats [--archived] [--cached]     List chats, newest first (--cached skips reloading accounts)
  read <chat> [-n <count>] [--mark-read]
                                    Show the latest messages (default 20)
  send <chat> <text…> [--reply-to <message id>]
                                    Send a message; text "-" reads standard input
  mark-read <chat>                  Mark the chat read up to its latest message
  watch [<chat>] [--interval <seconds>]
                                    Stream new messages in a chat, or changed chats across all of them

<chat> is a chat id from `chats`, an exact title, or a unique part of a title.
Options: --json prints the app's JSON (one object per line for watch).
Environment: STUPID_SOCIAL_TOKEN, STUPID_SOCIAL_PORT (default 47823).
"""

struct CLIError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}

// MARK: Arguments

struct Arguments {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    static let valued: Set<String> = ["-n", "--reply-to", "--interval"]

    init(_ arguments: [String]) throws {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if Self.valued.contains(argument) {
                guard let value = iterator.next() else { throw CLIError("\(argument) needs a value") }
                values[argument] = value
            } else if argument.hasPrefix("--") || (argument.hasPrefix("-") && argument != "-") {
                flags.insert(argument)
            } else {
                positional.append(argument)
            }
        }
    }

    func checkFlags(_ allowed: Set<String>) throws {
        let unknown = flags.subtracting(allowed.union(["--json"])).union(Set(values.keys).subtracting(allowed))
        if let flag = unknown.first {
            throw CLIError("Unknown option \(flag)")
        }
    }
}

// MARK: Token

let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/stupid-social")
let tokenFile = configDirectory.appending(path: "token")

func savedToken() throws -> String {
    if let token = ProcessInfo.processInfo.environment["STUPID_SOCIAL_TOKEN"], !token.isEmpty {
        return token
    }
    guard let token = try? String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
        throw CLIError("Not paired. In the app on this Mac, turn on Settings → Command Line → Command-Line Access, then run `stupid-social pair <token>`.")
    }
    return token
}

func pair(token: String) throws {
    try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: tokenFile.path, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
}

// MARK: Connection

/// A line-oriented TCP connection to the app on 127.0.0.1.
final class Connection {
    private let fd: Int32
    private var buffer = Data()

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CLIError("socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            throw ConnectError(code: error)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    struct ConnectError: Error {
        let code: Int32
    }

    deinit {
        close(fd)
    }

    func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                guard written > 0 else { throw CLIError("Lost the connection to the app") }
                offset += written
            }
        }
    }

    /// The next line, or `nil` when the app closed the connection.
    func readLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            if count == 0 {
                return nil
            }
            guard count > 0 else { throw CLIError("read: \(String(cString: strerror(errno)))") }
            buffer.append(contentsOf: chunk[0 ..< count])
        }
    }
}

let port: UInt16 = ProcessInfo.processInfo.environment["STUPID_SOCIAL_PORT"].flatMap(UInt16.init) ?? 47823

/// Connects to the app, opening it in the background first if it isn't running.
func connectToApp() throws -> Connection {
    do {
        return try Connection(port: port)
    } catch let error as Connection.ConnectError where error.code == ECONNREFUSED {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-b", "tech.stupid.StupidSocial"]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw CLIError("Couldn't open stupid social; is it installed on this Mac?") }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if let connection = try? Connection(port: port) {
                return connection
            }
        }
        throw CLIError("stupid social isn't listening on port \(port). Turn on Settings → Command Line → Command-Line Access in the app.")
    } catch let error as Connection.ConnectError {
        throw CLIError("Couldn't connect to the app: \(String(cString: strerror(error.code)))")
    }
}

/// Sends one request and returns its reply's `result`; replies with an error throw.
func request(_ command: String, _ fields: [String: Any] = [:], on connection: Connection? = nil) throws -> (result: Any, raw: Data, connection: Connection) {
    let token = try savedToken()
    let connection = try connection ?? connectToApp()
    var object = fields
    object["id"] = 1
    object["command"] = command
    object["token"] = token
    try connection.send(object)
    guard let line = try connection.readLine() else { throw CLIError("The app closed the connection") }
    let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
    guard reply["ok"] as? Bool == true else {
        throw CLIError(reply["error"] as? String ?? "The app returned an error")
    }
    return (reply["result"] ?? NSNull(), line, connection)
}

// MARK: Output

let isJSON = CommandLine.arguments.contains("--json")

func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    print(String(decoding: data, as: UTF8.self))
}

func timeLabel(_ value: Any?) -> String {
    guard let string = value as? String, let date = try? Date(string, strategy: .iso8601) else { return "" }
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(date: .abbreviated, time: .shortened)
}

func chatLine(_ chat: [String: Any]) -> String {
    let network = chat["network"] as? String ?? ""
    let prefix = (chat["titlePrefix"] as? String).map { "\($0) / " } ?? ""
    var line = "[\(network)] \(prefix)\(chat["title"] as? String ?? "")"
    if let unread = chat["unreadCount"] as? Int, unread > 0 {
        line += " (\(unread) unread\(chat["isMuted"] as? Bool == true ? ", muted" : ""))"
    }
    let time = timeLabel(chat["timestamp"])
    if !time.isEmpty {
        line += " · \(time)"
    }
    return line
}

func printChat(_ chat: [String: Any]) {
    print(chatLine(chat))
    if let preview = chat["preview"] as? String {
        print("  \(preview.replacingOccurrences(of: "\n", with: " "))")
    }
    print("  id: \(chat["id"] as? String ?? "")")
}

func messageLine(_ message: [String: Any]) -> String {
    let sender = (message["sender"] as? [String: Any])?["name"] as? String ?? "?"
    var parts: [String] = []
    if message["isDeleted"] as? Bool == true {
        parts.append("(deleted)")
    }
    if let reply = message["replyToId"] as? String {
        parts.append("↩︎ \(reply)")
    }
    if let text = message["text"] as? String, !text.isEmpty {
        parts.append(text)
    }
    for embed in message["embeds"] as? [[String: Any]] ?? [] {
        let details = [embed["title"], embed["text"], embed["url"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        parts.append("[\(embed["type"] as? String ?? "attachment")\(details.isEmpty ? "" : ": " + details.joined(separator: " · "))]")
    }
    let reactions = (message["reactions"] as? [[String: Any]] ?? []).map { "\($0["emoji"] as? String ?? "")\($0["count"] as? Int ?? 0)" }
    if !reactions.isEmpty {
        parts.append("(\(reactions.joined(separator: " ")))")
    }
    let marker = message["isUnread"] as? Bool == true ? "• " : "  "
    return "\(marker)\(timeLabel(message["timestamp"]))  \(sender): \(parts.joined(separator: " "))  [\(message["id"] as? String ?? "")]"
}

// MARK: Commands

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
        print(usage)
        return
    }
    if command == "--version" {
        print(version)
        return
    }
    arguments.removeFirst()
    let parsed = try Arguments(arguments)

    switch command {
    case "pair":
        try parsed.checkFlags([])
        guard parsed.positional.count == 1 else { throw CLIError("usage: stupid-social pair <token>") }
        try pair(token: parsed.positional[0])
        let status = try request("status")
        print("Paired with \((status.result as? [String: Any])?["app"] as? String ?? "the app").")
    case "status":
        try parsed.checkFlags([])
        let reply = try request("status")
        if isJSON {
            try printJSON(reply.result)
        } else {
            let status = reply.result as? [String: Any] ?? [:]
            print("\(status["app"] as? String ?? "app") build \(status["build"] as? String ?? "?") is listening on port \(port).")
        }
    case "chats":
        try parsed.checkFlags(["--archived", "--cached"])
        let reply = try request("chats", ["archived": parsed.flags.contains("--archived"), "refresh": !parsed.flags.contains("--cached")])
        let result = reply.result as? [String: Any] ?? [:]
        if isJSON {
            try printJSON(result)
            return
        }
        let chats = result["chats"] as? [[String: Any]] ?? []
        if chats.isEmpty {
            print("No chats.")
        }
        for chat in chats {
            printChat(chat)
        }
        for error in result["errors"] as? [[String: Any]] ?? [] {
            FileHandle.standardError.write(Data("warning: \(error["label"] as? String ?? ""): \(error["error"] as? String ?? "")\n".utf8))
        }
    case "read":
        try parsed.checkFlags(["-n", "--mark-read"])
        let chat = try chatArgument(parsed)
        let limit = try parsed.values["-n"].map { value in
            guard let limit = Int(value), limit > 0 else { throw CLIError("-n needs a positive number") }
            return limit
        } ?? 20
        let reply = try request("read", ["chat": chat, "limit": limit, "markRead": parsed.flags.contains("--mark-read")])
        let result = reply.result as? [String: Any] ?? [:]
        if isJSON {
            try printJSON(result)
            return
        }
        if let chat = result["chat"] as? [String: Any] {
            print(chatLine(chat))
        }
        for message in result["messages"] as? [[String: Any]] ?? [] {
            print(messageLine(message))
        }
    case "send":
        try parsed.checkFlags(["--reply-to"])
        guard parsed.positional.count >= 2 else { throw CLIError("usage: stupid-social send <chat> <text…>") }
        let chat = parsed.positional[0]
        var text = parsed.positional.dropFirst().joined(separator: " ")
        if text == "-" {
            text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        var fields: [String: Any] = ["chat": chat, "text": text]
        fields["replyTo"] = parsed.values["--reply-to"]
        let reply = try request("send", fields)
        let result = reply.result as? [String: Any] ?? [:]
        if isJSON {
            try printJSON(result)
        } else {
            let title = (result["chat"] as? [String: Any])?["title"] as? String ?? chat
            let id = (result["message"] as? [String: Any])?["id"] as? String
            print("Sent to \(title)\(id.map { " [\($0)]" } ?? "").")
        }
    case "mark-read":
        try parsed.checkFlags([])
        let reply = try request("mark-read", ["chat": chatArgument(parsed)])
        let result = reply.result as? [String: Any] ?? [:]
        if isJSON {
            try printJSON(result)
        } else {
            let title = (result["chat"] as? [String: Any])?["title"] as? String ?? ""
            print("Marked \(title) read (\(result["markedCount"] as? Int ?? 0) unread).")
        }
    case "watch":
        try parsed.checkFlags(["--interval"])
        guard parsed.positional.count <= 1 else { throw CLIError("usage: stupid-social watch [<chat>]") }
        var fields: [String: Any] = [:]
        fields["chat"] = parsed.positional.first
        if let interval = parsed.values["--interval"] {
            guard let seconds = Double(interval), seconds > 0 else { throw CLIError("--interval needs a number of seconds") }
            fields["interval"] = seconds
        }
        let reply = try request("watch", fields)
        if !isJSON, let chat = (reply.result as? [String: Any])?["chat"] as? [String: Any] {
            FileHandle.standardError.write(Data("Watching \(chatLine(chat))\n".utf8))
        }
        while let line = try reply.connection.readLine() {
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] ?? [:]
            if object["ok"] as? Bool == false {
                throw CLIError(object["error"] as? String ?? "The watch failed")
            }
            if isJSON {
                print(String(decoding: line, as: UTF8.self))
            } else if let message = object["message"] as? [String: Any] {
                print(messageLine(message))
            } else if let chat = object["chat"] as? [String: Any] {
                print(chatLine(chat))
                if let preview = chat["preview"] as? String {
                    print("  \(preview.replacingOccurrences(of: "\n", with: " "))")
                }
            }
            fflush(stdout)
        }
        throw CLIError("The app closed the connection")
    default:
        throw CLIError("Unknown command \(command)\n\n\(usage)")
    }
}

func chatArgument(_ parsed: Arguments) throws -> String {
    guard parsed.positional.count == 1 else { throw CLIError("Name one chat by its id or title") }
    return parsed.positional[0]
}

do {
    try run()
} catch let error as CLIError {
    FileHandle.standardError.write(Data("error: \(error.message)\n".utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
