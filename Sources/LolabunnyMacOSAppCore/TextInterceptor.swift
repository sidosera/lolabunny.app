import ApplicationServices
import AppKit


// Monitors for the global ⇧⌘L hotkey and replaces /binding args/; patterns
// in the focused text field by calling the shared command execution path.
@MainActor
final class TextInterceptor: ObservableObject {
    static let shared = TextInterceptor()

    @Published var accessibilityGranted = false
    @Published var isEnabled = true

    private var monitor: Any?
    private var pollingTask: Task<Void, Never>?
    private let pattern = try! NSRegularExpression(pattern: "/(\\w+)\\s+(.*?)/;")

    private init() {}

    func start() {
        refreshPermissionStatus()
        registerMonitor()
        if !accessibilityGranted {
            startPermissionPolling()
        }
    }

    func refreshPermissionStatus() {
        let granted = AXIsProcessTrusted()
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            log("interceptor: accessibility=\(granted)")
        }
    }

    func requestAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { @MainActor [weak self] in
            while let self, !self.accessibilityGranted {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.refreshPermissionStatus()
            }
            self?.pollingTask = nil
        }
    }

    private func registerMonitor() {
        guard monitor == nil else { return }
        let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // ⇧⌘L: keyCode 37, Shift + Command
            guard event.keyCode == 37,
                  event.modifierFlags.contains(.shift),
                  event.modifierFlags.contains(.command) else { return }
            log("interceptor: hotkey fired")
            Task { @MainActor [weak self] in
                await self?.performTransform()
            }
        }
        monitor = m
        log("interceptor: monitor registered=\(m != nil), accessibility=\(AXIsProcessTrusted())")
    }

    private func performTransform() async {
        guard isEnabled else { log("interceptor: disabled"); return }

        let sysWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else {
            log("interceptor: no focused element")
            return
        }

        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        ) == .success, let text = valueRef as? String else {
            log("interceptor: could not read text value")
            return
        }

        log("interceptor: text=\(text.prefix(80))")

        let matches = pattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        guard !matches.isEmpty else {
            log("interceptor: no /cmd args/; pattern found")
            return
        }

        var result = text
        for match in matches.reversed() {
            guard let bindingRange = Range(match.range(at: 1), in: result),
                  let argsRange   = Range(match.range(at: 2), in: result),
                  let fullRange   = Range(match.range,        in: result) else { continue }
            let cmd = "\(result[bindingRange]) \(result[argsRange])"
            log("interceptor: calling lolabunny-server cmd=\(cmd)")
            if let replacement = await callCmd(cmd) {
                log("interceptor: replacement=\(replacement.prefix(80))")
                result.replaceSubrange(fullRange, with: replacement)
            } else {
                log("interceptor: lolabunny-server returned nil for cmd=\(cmd)")
            }
        }

        if result != text {
            AXUIElementSetAttributeValue(focused, kAXValueAttribute as CFString, result as CFTypeRef)
        }
    }

    private func callCmd(_ cmd: String) async -> String? {
        await CommandExecution.textResult(for: cmd, allowURLFallback: false)
    }
}
