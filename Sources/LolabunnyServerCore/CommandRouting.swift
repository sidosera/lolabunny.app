import Foundation
import LuaSwift

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
        port: UInt16 = 18_085,
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
    public let suggestURL: String?
}

final class CommandRegistry {
    private let commands: [LuaCommand]

    init() {
        commands = Self.discoverLuaCommandInfo().sorted {
            ($0.info.bindings.first ?? "").localizedCaseInsensitiveCompare($1.info.bindings.first ?? "")
                == .orderedAscending
        }
    }

    func allCommands() -> [CommandInfo] {
        commands.map(\.info)
    }

    func commandInfo(for binding: String) -> CommandInfo? {
        command(for: binding)?.info
    }

    func command(for binding: String) -> LuaCommand? {
        commands.first { command in
            command.info.bindings.contains { $0.caseInsensitiveCompare(binding) == .orderedSame }
        }
    }

    func commandThatShouldHandle(_ query: String) -> LuaCommand? {
        commands.first { $0.shouldHandle(query) }
    }

    private static func discoverLuaCommandInfo() -> [LuaCommand] {
        let fm = FileManager.default
        var results: [LuaCommand] = []
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

    private static func parseLuaCommandInfo(at url: URL, root: URL) -> LuaCommand? {
        guard let source = try? String(contentsOf: url, encoding: .utf8),
              let bindings = parseBindings(from: source),
              !bindings.isEmpty else {
            return nil
        }

        let origin: String
        let path = url.path
        if path.contains("/lola-core/") {
            origin = "lola-core"
        } else if root.lastPathComponent == "commands" || root.lastPathComponent == ".lolabunny" {
            origin = "user"
        } else {
            origin = url.deletingLastPathComponent().lastPathComponent
        }

        let info = CommandInfo(
            bindings: bindings,
            description: parseStringField("description", from: source) ?? "",
            example: parseStringField("example", from: source) ?? "",
            origin: origin,
            suggestURL: parseStringField("suggest_url", from: source)
        )
        return LuaCommand(info: info, sourceURL: url)
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

struct LuaCommand {
    let info: CommandInfo
    let sourceURL: URL

    func execute(_ query: String) -> String? {
        runLua(function: "process", query: query)?.nilIfEmpty
    }

    func shouldHandle(_ query: String) -> Bool {
        guard hasFunction("should_handle"),
              let value = runLua(function: "should_handle", query: query) else {
            let normalized = query.lowercased()
            return info.bindings.contains { binding in
                let lower = binding.lowercased()
                return normalized == lower || normalized.hasPrefix(lower + " ")
            }
        }
        return value == "true" || value == "1"
    }

    private func hasFunction(_ name: String) -> Bool {
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return false
        }
        return source.contains("function \(name)")
    }

    private func runLua(function: String, query: String) -> String? {
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }

        do {
            return try EmbeddedLuaCommandRuntime(source: source, chunkName: sourceURL.path)
                .call(function: function, query: query)
        } catch {
            fputs("Warning: Failed to run command \(sourceURL.path): \(error.localizedDescription)\n", stderr)
            return nil
        }
    }
}

private final class EmbeddedLuaCommandRuntime {
    private let engine: LuaEngine

    init(source: String, chunkName: String) throws {
        let configuration = LuaEngineConfiguration(
            sandboxed: true,
            vmMemoryLimit: 8 * 1_024 * 1_024
        )
        engine = try LuaEngine(configuration: configuration)
        engine.setInstructionLimit(250_000)
        registerHelpers()
        try engine.run(source, chunkName: chunkName)
    }

    func call(function: String, query: String) throws -> String? {
        let result = try engine.evaluate("""
        local fn = _G[\(luaStringLiteral(function))]
        if type(fn) ~= "function" then return nil end
        return fn(\(luaStringLiteral(query)))
        """)
        switch result {
        case .nil:
            return nil
        case .string(let value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let value):
            return value == floor(value) ? String(Int(value)) : String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private func registerHelpers() {
        engine.registerFunction(name: "url_encode") { values in
            .string(percentEncode(luaStringArgument(values)))
        }
        engine.registerFunction(name: "url_encode_path") { values in
            .string(percentEncode(luaStringArgument(values), allowingSlash: true))
        }
        engine.registerFunction(name: "get_args") { values in
            let fullArgs = luaStringArgument(values, at: 0)
            let binding = luaStringArgument(values, at: 1)
            if fullArgs.hasPrefix(binding) {
                return .string(String(fullArgs.dropFirst(binding.count)).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .string(fullArgs.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        engine.registerFunction(name: "trim") { values in
            .string(luaStringArgument(values).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        engine.registerFunction(name: "starts_with") { values in
            .bool(luaStringArgument(values, at: 0).hasPrefix(luaStringArgument(values, at: 1)))
        }
        engine.registerFunction(name: "ends_with") { values in
            .bool(luaStringArgument(values, at: 0).hasSuffix(luaStringArgument(values, at: 1)))
        }
        engine.registerFunction(name: "contains") { values in
            .bool(luaStringArgument(values, at: 0).contains(luaStringArgument(values, at: 1)))
        }
        engine.registerFunction(name: "upper") { values in
            .string(luaStringArgument(values).uppercased())
        }
        engine.registerFunction(name: "lower") { values in
            .string(luaStringArgument(values).lowercased())
        }
        engine.registerFunction(name: "split") { values in
            let value = luaStringArgument(values, at: 0)
            let separator = luaStringArgument(values, at: 1)
            guard !separator.isEmpty else {
                return .array([.string(value)])
            }
            return .array(value.components(separatedBy: separator).map(LuaValue.string))
        }
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
            if let command = registry.command(for: binding),
               let url = command.execute(resolvedQuery) {
                return url
            }
            if let command = registry.commandThatShouldHandle(resolvedQuery),
               let url = command.execute(resolvedQuery) {
                return url
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

func percentEncode(_ value: String, allowingSlash: Bool = false) -> String {
    var result = ""
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "-"),
             UInt8(ascii: "."),
             UInt8(ascii: "_"),
             UInt8(ascii: "~"):
            result.append(Character(UnicodeScalar(byte)))
        case UInt8(ascii: "/") where allowingSlash:
            result.append(Character(UnicodeScalar(byte)))
        default:
            result += String(format: "%%%02X", byte)
        }
    }
    return result
}

private func luaStringArgument(_ values: [LuaValue], at index: Int = 0) -> String {
    guard values.indices.contains(index) else {
        return ""
    }
    switch values[index] {
    case .nil:
        return ""
    case .string(let value):
        return value
    case .number(let value):
        return value == floor(value) ? String(Int(value)) : String(value)
    case .bool(let value):
        return value ? "true" : "false"
    default:
        return ""
    }
}

private func luaStringLiteral(_ value: String) -> String {
    var result = "\""
    for byte in value.utf8 {
        switch byte {
        case UInt8(ascii: "\\"):
            result += "\\\\"
        case UInt8(ascii: "\""):
            result += "\\\""
        case UInt8(ascii: "\n"):
            result += "\\n"
        case UInt8(ascii: "\r"):
            result += "\\r"
        case UInt8(ascii: "\t"):
            result += "\\t"
        case 32...126:
            result.append(Character(UnicodeScalar(byte)))
        default:
            result += String(format: "\\%03d", byte)
        }
    }
    result += "\""
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

extension String {
    func dropLeadingSlash() -> String {
        hasPrefix("/") ? String(dropFirst()) : self
    }

    fileprivate var nilIfEmpty: String? {
        isEmpty ? nil : self
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
