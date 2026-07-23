import Foundation

enum ModuleResources {
    /// Resolve SwiftPM resource bundles for both `swift run` (bundle next to
    /// the executable) and packaged `.app` (bundle under Contents/Resources).
    static func bundle(named name: String) -> Bundle {
        let fileName = "\(name).bundle"
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent(fileName),
            Bundle.main.bundleURL.appendingPathComponent(fileName),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent(fileName),
        ].compactMap { $0 }

        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        fatalError(
            "could not load resource bundle '\(fileName)' from: "
                + candidates.map(\.path).joined(separator: ", ")
        )
    }
}
