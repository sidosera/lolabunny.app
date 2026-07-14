import Foundation

public struct EmbeddedCommandExecutor {
    public init() {}

    public func location(
        for command: String,
        defaultSearch: String,
        historyEnabled: Bool,
        historyMaxEntries: Int,
        address: String,
        port: UInt16,
        volumePath: String?,
        user: String
    ) -> String {
        var config = AppConfig()
        config.defaultSearch = defaultSearch
        config.history.enabled = historyEnabled
        config.history.maxEntries = historyMaxEntries
        config.server.address = address
        config.server.port = port
        config.server.volumePath = volumePath

        let location = CommandRouter().route(command, config: config)
        if config.history.enabled {
            History(config: config).add(command: command, user: user)
        }
        return location
    }
}

public struct HistoryConfig {
    public var enabled: Bool
    public var maxEntries: Int

    public init(enabled: Bool = true, maxEntries: Int = 1_000) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }
}

public struct ServerConfig {
    public var port: UInt16
    public var address: String
    public var logLevel: String
    public var volumePath: String?

    public init(
        port: UInt16 = 8_085,
        address: String = "127.0.0.1",
        logLevel: String = "normal",
        volumePath: String? = nil
    ) {
        self.port = port
        self.address = address
        self.logLevel = logLevel
        self.volumePath = volumePath
    }

    public var displayURL: String {
        "http://localhost:\(port)"
    }
}

public struct AppConfig {
    public var browser: String?
    public var defaultSearch: String
    public var aliases: [String: String]
    public var history: HistoryConfig
    public var server: ServerConfig

    public init(
        browser: String? = nil,
        defaultSearch: String = "google",
        aliases: [String: String] = [:],
        history: HistoryConfig = HistoryConfig(),
        server: ServerConfig = ServerConfig()
    ) {
        self.browser = browser
        self.defaultSearch = defaultSearch
        self.aliases = aliases
        self.history = history
        self.server = server
    }

    public func resolveCommand(_ command: String) -> String {
        aliases[command] ?? command
    }

    public func searchURL(for query: String) -> String {
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

public struct CommandInfo {
    public let bindings: [String]
    public let description: String
    public let example: String
    public let origin: String
}

final class CommandRegistry {
    private let commands: [CommandInfo]

    init() {
        commands = Self.discoverLuaCommandInfo().sorted {
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

public final class CommandRouter {
    private let registry: CommandRegistry

    public convenience init() {
        self.init(registry: CommandRegistry())
    }

    init(registry: CommandRegistry) {
        self.registry = registry
    }

    public func allCommands() -> [CommandInfo] {
        registry.allCommands()
    }

    public func route(_ rawQuery: String, config: AppConfig) -> String {
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

public final class History {
    private let path: URL
    private let maxEntries: Int

    public init(config: AppConfig) {
        path = Paths.historyFile
        maxEntries = config.history.maxEntries
    }

    public func add(command: String, user: String) {
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

public func syncHTTPGet(_ url: URL) throws -> Data {
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
            result.set(.failure(ServerError.message("lolabunny-server returned \(http.statusCode)")))
            return
        }
        result.set(.success(data ?? Data()))
    }.resume()
    semaphore.wait()
    return try result.value().get()
}

public enum ServerError: Error, LocalizedError {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        }
    }
}

public final class SyncHTTPResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Data, Error>?

    public init() {}

    public func set(_ result: Result<Data, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    public func value() -> Result<Data, Error> {
        lock.lock()
        let result = storage
        lock.unlock()
        return result ?? .failure(ServerError.message("request did not complete"))
    }
}
