import Foundation

extension AppDelegate {
    func hostMachineIdentifier() -> String {
        var uts = utsname()
        uname(&uts)
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    func isRosettaTranslated() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return rc == 0 && translated == 1
    }

    func architectureAliases() -> [String] {
        let machine = hostMachineIdentifier().lowercased()
        if isRosettaTranslated() || machine.contains("x86_64") || machine.contains("amd64") {
            return ["x86_64", "amd64", "x64", "universal"]
        }
        if machine.contains("arm64") || machine.contains("aarch64") {
            return ["arm64", "aarch64", "universal"]
        }
        return [machine, "universal"]
    }

    func architectureLabel() -> String {
        hostMachineIdentifier()
    }

    func shouldSkipAutomaticUpdateChecks() -> Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}
