import Darwin
import Foundation
import LolabunnyServerCore

nonisolated(unsafe) private var activePidFilePath: String?

signal(SIGPIPE, SIG_IGN)
signal(SIGTERM) { _ in
    if let activePidFilePath {
        try? FileManager.default.removeItem(atPath: activePidFilePath)
    }
    exit(0)
}
signal(SIGINT) { _ in
    if let activePidFilePath {
        try? FileManager.default.removeItem(atPath: activePidFilePath)
    }
    exit(0)
}

func mainEntry() -> Int32 {
    do {
        return try run(arguments: Array(CommandLine.arguments.dropFirst()))
    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

func run(arguments: [String]) throws -> Int32 {
    if arguments.contains("--version") || arguments.contains("-V") {
        print(Paths.versionString())
        return 0
    }

    if arguments.first == "serve" {
        var config = AppConfig()
        try applyServeOptions(Array(arguments.dropFirst()), to: &config)
        try runServer(config: config)
    }

    var config = AppConfig()
    let parsed = try parseGlobalOptions(arguments, config: &config)

    if parsed.list {
        printCommands(CommandRouter().allCommands())
        return 0
    }

    guard let command = parsed.positionals.first else {
        printHelp()
        return 0
    }

    switch command {
    case "help", "--help", "-h":
        printHelp()
    case "bindings", "list":
        printCommands(CommandRouter().allCommands())
    case "completion":
        print("# Shell completion generation is not required for the Swift lolabunny-server.")
    case "pid-file":
        print(Paths.pidFile.path)
    default:
        try executeCommand(parsed.positionals, config: config, dryRun: parsed.dryRun)
    }

    return 0
}

func runServer(config: AppConfig) throws -> Never {
    let pidFile = Paths.pidFile
    activePidFilePath = pidFile.path
    try "\(getpid())".write(to: pidFile, atomically: true, encoding: .utf8)
    defer {
        try? FileManager.default.removeItem(at: pidFile)
    }

    let server = HTTPServer(
        address: config.server.address,
        port: config.server.port,
        router: CommandRouter(),
        config: config
    )
    try server.run()
}

struct ParsedGlobalOptions {
    var dryRun = false
    var list = false
    var positionals: [String] = []
}

func parseGlobalOptions(_ arguments: [String], config: inout AppConfig) throws -> ParsedGlobalOptions {
    var parsed = ParsedGlobalOptions()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-n", "--dry-run":
            parsed.dryRun = true
            index += 1
        case "-l", "--list":
            parsed.list = true
            index += 1
        case "--browser":
            config.browser = try value(after: argument, in: arguments, index: &index)
        case "--default-search":
            config.defaultSearch = try value(after: argument, in: arguments, index: &index)
        case "--alias":
            let raw = try value(after: argument, in: arguments, index: &index)
            let alias = try parseAlias(raw)
            config.aliases[alias.key] = alias.value
        case "--history-enabled":
            config.history.enabled = try parseBool(value(after: argument, in: arguments, index: &index))
        case "--history-max-entries":
            let raw = try value(after: argument, in: arguments, index: &index)
            guard let count = Int(raw), count > 0 else {
                throw ServerError.message("invalid --history-max-entries: \(raw)")
            }
            config.history.maxEntries = count
        default:
            parsed.positionals.append(argument)
            index += 1
        }
    }
    return parsed
}

func applyServeOptions(_ arguments: [String], to config: inout AppConfig) throws {
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-p", "--port":
            let raw = try value(after: argument, in: arguments, index: &index)
            guard let port = UInt16(raw) else {
                throw ServerError.message("invalid --port: \(raw)")
            }
            config.server.port = port
        case "-a", "--address":
            config.server.address = try value(after: argument, in: arguments, index: &index)
        case "--volume-path":
            config.server.volumePath = try value(after: argument, in: arguments, index: &index)
        case "--log-level":
            config.server.logLevel = try value(after: argument, in: arguments, index: &index)
        case "--default-search":
            config.defaultSearch = try value(after: argument, in: arguments, index: &index)
        case "--history-enabled":
            config.history.enabled = try parseBool(value(after: argument, in: arguments, index: &index))
        case "--history-max-entries":
            let raw = try value(after: argument, in: arguments, index: &index)
            guard let count = Int(raw), count > 0 else {
                throw ServerError.message("invalid --history-max-entries: \(raw)")
            }
            config.history.maxEntries = count
        case "--alias":
            let raw = try value(after: argument, in: arguments, index: &index)
            let alias = try parseAlias(raw)
            config.aliases[alias.key] = alias.value
        case "--browser":
            config.browser = try value(after: argument, in: arguments, index: &index)
        default:
            index += 1
        }
    }
}

func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
        throw ServerError.message("missing value for \(flag)")
    }
    index += 2
    return arguments[valueIndex]
}

func parseAlias(_ raw: String) throws -> (key: String, value: String) {
    let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
        throw ServerError.message("alias must be KEY=VALUE, got '\(raw)'")
    }
    let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty, !value.isEmpty else {
        throw ServerError.message("alias must be KEY=VALUE, got '\(raw)'")
    }
    return (key, value)
}

func parseBool(_ raw: String) throws -> Bool {
    switch raw.lowercased() {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        throw ServerError.message("invalid boolean: \(raw)")
    }
}

func executeCommand(_ args: [String], config: AppConfig, dryRun: Bool) throws {
    let fullArgs = args.joined(separator: " ")
    let url = CommandRouter().route(fullArgs, config: config)
    print(url)

    if config.history.enabled {
        History(config: config).add(command: fullArgs, user: NSUserName())
    }

    if !dryRun {
        try openURL(url, browser: config.browser)
    }
}

func openURL(_ url: String, browser: String?) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let browser, !browser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        process.arguments = ["-a", browser, url]
    } else {
        process.arguments = [url]
    }
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ServerError.message("failed to open URL")
    }
}

func printCommands(_ commands: [CommandInfo]) {
    let rows = commands.map { command in
        let aliases = command.bindings.dropFirst().joined(separator: ", ")
        return (
            command: command.bindings.first ?? "",
            aliases: aliases.isEmpty ? "-" : aliases,
            description: command.description,
            example: command.example
        )
    }

    print("")
    print("Command          Aliases          Description")
    print("-------          -------          -----------")
    for row in rows {
        print("\(row.command.padding(toLength: 16, withPad: " ", startingAt: 0)) \(row.aliases.padding(toLength: 16, withPad: " ", startingAt: 0)) \(row.description)")
    }
    print("")
}

func printHelp() {
    print("""
    Lightweight local command router.

    Usage:
      lolabunny serve [--port PORT] [--address ADDRESS]
      lolabunny bindings
      lolabunny [--dry-run] [BINDING] [ARGS]
    """)
}

exit(mainEntry())
