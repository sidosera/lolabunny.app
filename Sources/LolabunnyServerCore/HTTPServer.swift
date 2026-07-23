import Darwin
import Foundation

public struct HTTPRequest {
    public let method: String
    public let target: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, target: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.target = target
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    static func read(from fd: Int32, maxBodyBytes: Int = 64 * 1024 * 1024) -> HTTPRequest? {
        var buffer = Data()
        let headerTerminator = Data([13, 10, 13, 10])
        var temporary = [UInt8](repeating: 0, count: 16 * 1024)

        while buffer.range(of: headerTerminator) == nil, buffer.count < 128 * 1024 {
            let count = recv(fd, &temporary, temporary.count, 0)
            guard count > 0 else {
                return nil
            }
            buffer.append(temporary, count: count)
        }

        guard let headerRange = buffer.range(of: headerTerminator) else {
            return nil
        }

        let headerData = buffer[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = headerRange.upperBound
        var body = Data(buffer[bodyStart...])
        let expectedBodyLength = Int(headers["content-length"] ?? "") ?? 0
        while body.count < expectedBodyLength, body.count < maxBodyBytes {
            let count = recv(fd, &temporary, temporary.count, 0)
            guard count > 0 else {
                break
            }
            body.append(temporary, count: count)
        }

        if body.count > expectedBodyLength {
            body = body.prefix(expectedBodyLength)
        }

        let target = requestParts[1]
        let parsed = parseTarget(target)
        return HTTPRequest(
            method: requestParts[0].uppercased(),
            target: target,
            path: parsed.path,
            query: parsed.query,
            headers: headers,
            body: body
        )
    }

    private static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let urlString: String
        if target.hasPrefix("http://") || target.hasPrefix("https://") {
            urlString = target
        } else {
            urlString = "http://localhost\(target)"
        }

        guard let components = URLComponents(string: urlString) else {
            return (target, [:])
        }

        var query: [String: String] = [:]
        if let rawQuery = components.percentEncodedQuery {
            for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = percentDecode(String(parts.first ?? ""))
                let value = parts.count > 1 ? percentDecode(String(parts[1])) : ""
                query[key] = value
            }
        }

        return (components.path.removingPercentEncoding ?? components.path, query)
    }
}

public struct HTTPResponse {
    public let statusCode: Int
    public let reason: String
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, reason: String, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.reason = reason
        self.headers = headers
        self.body = body
    }

    public static func text(
        _ text: String,
        statusCode: Int = 200,
        reason: String = "OK",
        contentType: String = "text/plain; charset=utf-8"
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            reason: reason,
            headers: ["Content-Type": contentType],
            body: Data(text.utf8)
        )
    }

    public static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
    }

    public static func json(_ json: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            reason: "OK",
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: Data(json.utf8)
        )
    }

    public static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 302,
            reason: "Found",
            headers: ["Location": location],
            body: Data()
        )
    }
}

public final class SimpleHTTPServer: @unchecked Sendable {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let address: String
    private let port: UInt16
    private let maxBodyBytes: Int
    private let handler: Handler
    private let clientQueue = DispatchQueue(label: "lolabunny.http.clients", qos: .userInitiated, attributes: .concurrent)

    public init(
        address: String,
        port: UInt16,
        maxBodyBytes: Int = 64 * 1024 * 1024,
        handler: @escaping Handler
    ) {
        self.address = address
        self.port = port
        self.maxBodyBytes = maxBodyBytes
        self.handler = handler
    }

    public func run() throws -> Never {
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw ServerError.message("socket failed")
        }
        defer { close(serverFD) }

        var noSIGPipe: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPipe, socklen_t(MemoryLayout<Int32>.size))

        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = port.bigEndian
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            throw ServerError.message("invalid bind address: \(address)")
        }

        let bindResult = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                bind(serverFD, socketPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw ServerError.message("bind failed on \(address):\(port): \(String(cString: strerror(errno)))")
        }

        guard listen(serverFD, SOMAXCONN) == 0 else {
            throw ServerError.message("listen failed: \(String(cString: strerror(errno)))")
        }

        while true {
            var clientAddress = sockaddr_storage()
            var clientLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    accept(serverFD, socketPointer, &clientLength)
                }
            }

            guard clientFD >= 0 else {
                continue
            }

            configureClientSocket(clientFD)
            clientQueue.async { [self] in
                handleClient(clientFD)
                close(clientFD)
            }
        }
    }

    private func configureClientSocket(_ fd: Int32) {
        var noSIGPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPipe, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func handleClient(_ fd: Int32) {
        guard let request = HTTPRequest.read(from: fd, maxBodyBytes: maxBodyBytes) else {
            send(.text("bad request", statusCode: 400, reason: "Bad Request"), to: fd)
            return
        }

        send(handler(request), to: fd)
    }

    private func send(_ response: HTTPResponse, to fd: Int32) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"

        var head = "HTTP/1.1 \(response.statusCode) \(response.reason)\r\n"
        for (key, value) in headers {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"

        sendAll(Data(head.utf8), to: fd)
        if !response.body.isEmpty {
            sendAll(response.body, to: fd)
        }
    }

    private func sendAll(_ data: Data, to fd: Int32) {
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else {
                    return -1
                }
                return Darwin.send(fd, base.advanced(by: offset), bytes.count - offset, 0)
            }
            guard sent > 0 else {
                return
            }
            offset += sent
        }
    }
}

public final class HTTPServer {
    private let address: String
    private let port: UInt16
    private let router: CommandRouter
    private let config: AppConfig

    public init(address: String, port: UInt16, router: CommandRouter, config: AppConfig) {
        self.address = address
        self.port = port
        self.router = router
        self.config = config
    }

    public func run() throws -> Never {
        print("Lolabunny listening on \(address):\(port)")
        let server = SimpleHTTPServer(address: address, port: port) { [router, config] request in
            Self.response(for: request, router: router, config: config)
        }
        try server.run()
    }

    private static func response(for request: HTTPRequest, router: CommandRouter, config: AppConfig) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .text(Paths.versionString())
        case ("GET", "/api/commands"):
            return .json(commandsJSON(router: router))
        case ("GET", "/api/resolve"):
            return resolveCommandRequest(request, router: router, config: config)
        case ("GET", "/api/suggest"):
            return suggestCommandArguments(request, router: router)
        case ("GET", "/api/search-suggestions"), ("GET", "/suggest"):
            return suggestSearchTerms(request, router: router)
        case ("GET", "/"):
            return handleCommandRequest(request, router: router, config: config)
        default:
            return .html(bindingsHTML(router: router))
        }
    }

    private static func handleCommandRequest(_ request: HTTPRequest, router: CommandRouter, config: AppConfig) -> HTTPResponse {
        guard let query = request.query["cmd"] else {
            return .html(bindingsHTML(router: router))
        }

        let location = router.route(query, config: config)
        if config.history.enabled {
            History(config: config).add(command: query, user: request.headers["x-forwarded-for"] ?? "localhost")
        }
        return .redirect(to: location)
    }

    private static func resolveCommandRequest(_ request: HTTPRequest, router: CommandRouter, config: AppConfig) -> HTTPResponse {
        let query = request.query["cmd"] ?? ""
        let location = router.route(query, config: config)
        return .json("""
        {"query":\(jsonString(query)),"location":\(jsonString(location)),"kind":\(jsonString(locationKind(location)))}
        """)
    }

    private static func suggestCommandArguments(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        let binding = request.query["cmd"] ?? ""
        let query = request.query["q"] ?? ""
        guard let command = router.allCommands().first(where: { command in
            command.bindings.contains { $0.caseInsensitiveCompare(binding) == .orderedSame }
        }), let template = command.suggestURL else {
            return .json("[]")
        }

        let encoded = percentEncode(query)
        guard let url = URL(string: template.replacingOccurrences(of: "%s", with: encoded)),
              let data = try? syncHTTPGet(url),
              let suggestions = parseSuggestionPayload(data) else {
            return .json("[]")
        }
        return .json("[\(suggestions.prefix(8).map(jsonString).joined(separator: ","))]")
    }

    private static func suggestSearchTerms(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        let query = request.query["q"] ?? request.query["searchTerms"] ?? ""
        let suggestions = searchSuggestions(for: query, router: router)
        return .json("[\(jsonString(query)),[\(suggestions.map(jsonString).joined(separator: ","))]]")
    }

    private static func bindingsHTML(router: CommandRouter) -> String {
        let commands = router.allCommands()
        let rows = commands.map { command in
            let binding = htmlEscape(command.bindings.first ?? "")
            let aliases = htmlEscape(command.bindings.dropFirst().joined(separator: ", "))
            let description = htmlEscape(command.description)
            let example = htmlEscape(command.example)
            let search = htmlAttributeEscape(
                ([command.bindings.joined(separator: " "), command.description, command.example, command.origin])
                    .joined(separator: " ")
                    .lowercased()
            )
            let aliasHTML = aliases.isEmpty ? "" : "<span class=\"alias\">\(aliases)</span>"
            return """
            <li data-cmd="\(search)">
            <div class="row">
            <span class="cmd">\(binding)</span>
            <span class="desc">\(description)\(aliasHTML)<span class="example">\(example)</span></span>
            </div>
            </li>
            """
        }.joined(separator: "\n")

        return bindingsTemplate()
            .replacingOccurrences(of: "__LOGO__", with: logoBase64())
            .replacingOccurrences(of: "__COMMAND_COUNT__", with: "\(commands.count)")
            .replacingOccurrences(of: "__COMMAND_ROWS__", with: rows)
            .replacingOccurrences(of: "__COMMANDS_JSON__", with: commandsJSON(router: router))
            .replacingOccurrences(of: "__VERSION__", with: htmlEscape(Paths.versionString()))
    }

}

func commandsJSON(router: CommandRouter) -> String {
    let commands = router.allCommands().map { command in
        """
        {"bindings":[\(command.bindings.map(jsonString).joined(separator: ","))],"description":\(jsonString(command.description)),"example":\(jsonString(command.example)),"origin":\(jsonString(command.origin)),"suggestURL":\(command.suggestURL.map(jsonString) ?? "null")}
        """
    }
    return "[\(commands.joined(separator: ","))]"
}

func searchSuggestions(for rawQuery: String, router: CommandRouter) -> [String] {
    let query = rawQuery
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .dropLeadingSlash()
    let commands = router.allCommands()

    guard !query.isEmpty else {
        return deduplicatedSuggestions(commands.compactMap(\.example).filter { !$0.isEmpty })
    }

    let binding = commandName(from: query).lowercased()
    let commandArguments = arguments(after: binding, in: query)

    if let command = commands.first(where: { command in
        command.bindings.contains { $0.caseInsensitiveCompare(binding) == .orderedSame }
    }) {
        let primary = command.bindings.first ?? binding
        var suggestions: [String] = []
        if commandArguments.isEmpty, !command.example.isEmpty {
            suggestions.append(command.example)
        }
        suggestions.append(contentsOf: remoteArgumentSuggestions(for: command, query: commandArguments).map { suggestion in
            let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            let alreadyComplete = command.bindings.contains { commandBinding in
                trimmed.caseInsensitiveCompare(commandBinding) == .orderedSame
                    || trimmed.lowercased().hasPrefix(commandBinding.lowercased() + " ")
            }
            return alreadyComplete ? trimmed : "\(primary) \(trimmed)"
        })
        return deduplicatedSuggestions(suggestions)
    }

    let matches = commands.filter { command in
        command.bindings.contains { $0.lowercased().hasPrefix(binding) }
            || command.description.lowercased().contains(binding)
            || command.example.lowercased().contains(binding)
    }
    return deduplicatedSuggestions(matches.compactMap { command in
        if !command.example.isEmpty {
            return command.example
        }
        guard let primary = command.bindings.first else {
            return nil
        }
        return primary + " "
    })
}

func remoteArgumentSuggestions(for command: CommandInfo, query: String) -> [String] {
    guard let template = command.suggestURL,
          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return []
    }

    let encoded = percentEncode(query)
    guard let url = URL(string: template.replacingOccurrences(of: "%s", with: encoded)),
          let data = try? syncHTTPGet(url),
          let suggestions = parseSuggestionPayload(data) else {
        return []
    }
    return Array(suggestions.prefix(8))
}

func deduplicatedSuggestions(_ suggestions: [String], limit: Int = 8) -> [String] {
    var seen = Set<String>()
    var results: [String] = []
    for suggestion in suggestions {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              seen.insert(trimmed.lowercased()).inserted else {
            continue
        }
        results.append(trimmed)
        if results.count == limit {
            break
        }
    }
    return results
}

func locationKind(_ location: String) -> String {
    if location.hasPrefix("data:text/plain") {
        return "text"
    }
    if location.hasPrefix("http://") || location.hasPrefix("https://") {
        return "url"
    }
    return "raw"
}

func parseSuggestionPayload(_ data: Data) -> [String]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        return nil
    }
    if let values = object as? [String] {
        return values
    }
    if let values = object as? [Any], values.count > 1, let suggestions = values[1] as? [String] {
        return suggestions
    }
    return nil
}

func bindingsTemplate() -> String {
    guard let url = Bundle.module.url(forResource: "BindingsPage", withExtension: "html"),
          let template = try? String(contentsOf: url, encoding: .utf8) else {
        return "<!doctype html><html><body>__COMMAND_ROWS__</body></html>"
    }
    return template
}

func logoBase64() -> String {
    guard let url = Bundle.module.url(forResource: "bunny", withExtension: "png"),
          let data = try? Data(contentsOf: url) else {
        return ""
    }
    return data.base64EncodedString()
}

func htmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

func htmlAttributeEscape(_ value: String) -> String {
    htmlEscape(value).replacingOccurrences(of: "'", with: "&#39;")
}

func jsonString(_ value: String) -> String {
    var result = "\""
    for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22:
            result += "\\\""
        case 0x5C:
            result += "\\\\"
        case 0x08:
            result += "\\b"
        case 0x0C:
            result += "\\f"
        case 0x0A:
            result += "\\n"
        case 0x0D:
            result += "\\r"
        case 0x09:
            result += "\\t"
        case 0x00...0x1F:
            result += String(format: "\\u%04X", scalar.value)
        default:
            result.unicodeScalars.append(scalar)
        }
    }
    result += "\""
    return result
}
