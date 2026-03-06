import Foundation
import os

private let logger = Logger(subsystem: Config.bundleIdentifier, category: "app")

func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    let ts = Date().formatted(.iso8601)
    let line = "\(ts) \(message)\n"
    guard let lineData = line.data(using: .utf8) else {
        return
    }

    if let fh = FileHandle(forWritingAtPath: Config.Log.path) {
        fh.seekToEndOfFile()
        fh.write(lineData)
        fh.closeFile()
    } else {
        _ = FileManager.default.createFile(atPath: Config.Log.path, contents: lineData)
    }
}
