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

            handleClient(clientFD)
            close(clientFD)
        }
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

    private static func bindingsHTML(router: CommandRouter) -> String {
        let rows = router.allCommands().map { command in
            let binding = htmlEscape(command.bindings.first ?? "")
            let aliases = htmlEscape(command.bindings.dropFirst().joined(separator: ", "))
            let description = htmlEscape(command.description)
            return "<tr><td>\(binding)</td><td>\(aliases)</td><td>\(description)</td></tr>"
        }.joined(separator: "\n")

        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>Lolabunny</title>
          <style>
            body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; color: #1f2328; }
            table { border-collapse: collapse; width: min(960px, 100%); }
            th, td { border-bottom: 1px solid #d8dee4; padding: 8px 10px; text-align: left; }
            th { color: #57606a; font-weight: 600; }
          </style>
        </head>
        <body>
          <h1>Lolabunny</h1>
          <table>
            <thead><tr><th>Command</th><th>Aliases</th><th>Description</th></tr></thead>
            <tbody>
              \(rows)
            </tbody>
          </table>
        </body>
        </html>
        """
    }

}

func htmlEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
