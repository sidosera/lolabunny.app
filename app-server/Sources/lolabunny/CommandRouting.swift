import Foundation

struct HistoryConfig {
    var enabled = true
    var maxEntries = 1_000
}

struct ServerConfig {
    var port: UInt16 = 8_085
    var address = "127.0.0.1"
    var logLevel = "normal"
    var volumePath: String?

    var displayURL: String {
        "http://localhost:\(port)"
    }
}

struct AppConfig {
    var browser: String?
    var defaultSearch = "google"
    var aliases: [String: String] = [:]
    var history = HistoryConfig()
    var server = ServerConfig()

    func resolveCommand(_ command: String) -> String {
        aliases[command] ?? command
    }

    func searchURL(for query: String) -> String {
        let encoded = percentEncode(query)
        switch defaultSearch.lowercased() {
        case "ddg", "duckduckgo":
            return "https://duckduckgo.com/?q=\(encoded)"
        case "bing":
            return "https://www.bing.com/search?q=\(encoded)"
        default:
            return "https://www.google.com/search?q=\(encoded)"
        }
    }
}

struct CommandInfo {
    let bindings: [String]
    let description: String
    let example: String
    let origin: String
}

final class CommandRegistry {
    private let commands: [CommandInfo]

    init() {
        var discovered = Self.discoverLuaCommandInfo()
        Self.addNativeCommandIfMissing(
            &discovered,
            CommandInfo(
                bindings: ["lower"],
                description: "Lowercase the text after the command",
                example: "lower TeXt Lala",
                origin: "native"
            )
        )
        Self.addNativeCommandIfMissing(
            &discovered,
            CommandInfo(
                bindings: ["giff", "m"],
                description: "Insert a GIPHY GIF as markdown. In text fields: /m search term/;",
                example: "m happy cat",
                origin: "native"
            )
        )
        commands = discovered.sorted {
            ($0.bindings.first ?? "").localizedCaseInsensitiveCompare($1.bindings.first ?? "")
                == .orderedAscending
        }
    }

    func allCommands() -> [CommandInfo] {
        commands
    }

    func commandInfo(for binding: String) -> CommandInfo? {
        commands.first { command in
            command.bindings.contains { $0.caseInsensitiveCompare(binding) == .orderedSame }
        }
    }

    private static func addNativeCommandIfMissing(_ commands: inout [CommandInfo], _ command: CommandInfo) {
        guard let primary = command.bindings.first else {
            return
        }
        let exists = commands.contains { info in
            info.bindings.contains { $0.caseInsensitiveCompare(primary) == .orderedSame }
        }
        if !exists {
            commands.append(command)
        }
    }

    private static func discoverLuaCommandInfo() -> [CommandInfo] {
        let fm = FileManager.default
        var results: [CommandInfo] = []
        for directory in Paths.pluginDirectories() {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for case let url as URL in enumerator where url.pathExtension == "lua" {
                guard let info = parseLuaCommandInfo(at: url, root: directory) else {
                    continue
                }
                results.append(info)
            }
        }
        return results
    }

    private static func parseLuaCommandInfo(at url: URL, root: URL) -> CommandInfo? {
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let bindings = parseBindings(from: source),
              !bindings.isEmpty else {
            return nil
        }

        let origin: String
        let path = url.path
        if path.contains("/lola-core/") {
            origin = "lola-core"
        } else if root.lastPathComponent == "commands" {
            origin = "user"
        } else {
            origin = url.deletingLastPathComponent().lastPathComponent
        }

        return CommandInfo(
            bindings: bindings,
            description: parseStringField("description", from: source) ?? "",
            example: parseStringField("example", from: source) ?? "",
            origin: origin
        )
    }

    private static func parseBindings(from source: String) -> [String]? {
        guard let block = firstRegexCapture(
            pattern: #"bindings\s*=\s*\{([^}]*)\}"#,
            source: source
        ) else {
            return nil
        }

        let regex = try? NSRegularExpression(pattern: #""([^"]+)""#)
        let ns = block as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex?.matches(in: block, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else {
                return nil
            }
            return ns.substring(with: match.range(at: 1))
        }
    }

    private static func parseStringField(_ field: String, from source: String) -> String? {
        firstRegexCapture(
            pattern: #"\#(field)\s*=\s*"([^"]*)""#,
            source: source
        )
    }

    private static func firstRegexCapture(pattern: String, source: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: source, range: range),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }
}

final class CommandRouter {
    private let registry: CommandRegistry

    init(registry: CommandRegistry = CommandRegistry()) {
        self.registry = registry
    }

    func allCommands() -> [CommandInfo] {
        registry.allCommands()
    }

    func route(_ rawQuery: String, config: AppConfig) -> String {
        let resolvedQuery = config.resolveCommand(rawQuery)
        let binding = commandName(from: resolvedQuery)

        switch binding.lowercased() {
        case "lower":
            return dataTextURL(text: arguments(after: binding, in: resolvedQuery).lowercased())
        case "giff", "m":
            return giphyMarkdownURL(for: arguments(after: binding, in: resolvedQuery))
        default:
            if registry.commandInfo(for: binding) != nil {
                return config.searchURL(for: resolvedQuery)
            }
            return config.searchURL(for: resolvedQuery)
        }
    }

    private func giphyMarkdownURL(for rawTerm: String) -> String {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            return dataTextURL(text: "[giff: no search term]")
        }

        let apiKey = ProcessInfo.processInfo.environment["GIPHY_API_KEY"] ?? "dc6zaTOxFJmzC"
        let urlString = "https://api.giphy.com/v1/gifs/search"
            + "?api_key=\(percentEncode(apiKey))"
            + "&q=\(percentEncode(term))"
            + "&limit=5&rating=g"

        guard let url = URL(string: urlString) else {
            return dataTextURL(text: "[giff: invalid request]")
        }

        do {
            let data = try syncHTTPGet(url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["data"] as? [[String: Any]],
                  !results.isEmpty else {
                return dataTextURL(text: "[giff: no results for \"\(term)\"]")
            }

            let selected = results[Int.random(in: 0..<min(5, results.count))]
            guard let images = selected["images"] as? [String: Any],
                  let original = images["original"] as? [String: Any],
                  let rawURL = original["url"] as? String else {
                return dataTextURL(text: "[giff: no results for \"\(term)\"]")
            }

            let gifURL = rawURL.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawURL
            return dataTextURL(text: "![\(term)](\(gifURL))")
        } catch {
            return dataTextURL(text: "[giff: request failed: \(error.localizedDescription)]")
        }
    }
}

final class History {
    private let path: URL
    private let maxEntries: Int

    init(config: AppConfig) {
        path = Paths.historyFile
        maxEntries = config.history.maxEntries
    }

    func add(command: String, user: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var lines = ((try? String(contentsOf: path, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            lines.append("\(Int(Date().timeIntervalSince1970))|\(user)|\(trimmed)")
            if lines.count > maxEntries {
                lines = Array(lines.suffix(maxEntries))
            }
            try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        } catch {
            fputs("Warning: Failed to save history: \(error.localizedDescription)\n", stderr)
        }
    }
}

func commandName(from query: String) -> String {
    guard let firstSpace = query.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
        return query
    }
    return String(query[..<firstSpace])
}

func arguments(after binding: String, in query: String) -> String {
    guard query.hasPrefix(binding) else {
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return String(query.dropFirst(binding.count)).trimmingCharacters(in: .whitespacesAndNewlines)
}

func dataTextURL(text: String) -> String {
    "data:text/plain;charset=utf-8,\(percentEncode(text))"
}

func percentEncode(_ value: String) -> String {
    var result = ""
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"):
            result.append(Character(UnicodeScalar(byte)))
        default:
            result += String(format: "%%%02X", byte)
        }
    }
    return result
}

func percentDecode(_ value: String) -> String {
    value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
}

func syncHTTPGet(_ url: URL) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    let result = SyncHTTPResult()
    URLSession.shared.dataTask(with: url) { data, response, error in
        defer { semaphore.signal() }
        if let error {
            result.set(.failure(error))
            return
        }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            result.set(.failure(BackendError.message("server returned \(http.statusCode)")))
            return
        }
        result.set(.success(data ?? Data()))
    }.resume()
    semaphore.wait()
    return try result.value().get()
}

enum BackendError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        }
    }
}

final class SyncHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Data, Error>?

    func set(_ result: Result<Data, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    func value() -> Result<Data, Error> {
        lock.lock()
        let result = storage
        lock.unlock()
        return result ?? .failure(BackendError.message("request did not complete"))
    }
}
