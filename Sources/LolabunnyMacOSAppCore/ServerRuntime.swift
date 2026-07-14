import Foundation

extension AppDelegate {
    func scheduleServerWatchdog() {
        serverWatchdogTimer?.invalidate()
        serverWatchdogTimer = Timer.scheduledTimer(
            withTimeInterval: Config.Server.watchdogIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.serverWatchdogTick()
            }
        }
    }

    func serverWatchdogTick() async {
        guard !isStartingServer else {
            return
        }

        if let version = await probeRunningServerAsync() {
            setServerSetupState(.Ready(version: version))
        } else {
            log("embedded lolabunny-server is not healthy at \(Config.serverBaseURL.absoluteString)")
            setServerSetupState(.Failed(message: "embedded lolabunny-server unavailable"))
        }
    }

    func startServer() async {
        guard !isStartingServer else {
            return
        }
        isStartingServer = true
        defer { isStartingServer = false }

        setServerSetupState(.GettingReady)
        if let version = await probeRunningServerAsync() {
            setServerSetupState(.Ready(version: version))
            log("embedded lolabunny-server ready: \(version) at \(Config.serverBaseURL.absoluteString)")
        } else {
            setServerSetupState(.Failed(message: "embedded lolabunny-server unavailable"))
            log("embedded lolabunny-server unavailable at \(Config.serverBaseURL.absoluteString)")
        }
    }

    func probeRunningServerAsync() async -> String? {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if let version = await probeServerOnce() {
                return version
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func probeServerOnce() async -> String? {
        let url = Config.serverBaseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
