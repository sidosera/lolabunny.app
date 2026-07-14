import ApplicationServices
import AppKit
import Carbon
import SwiftUI

enum CommandExecution {
    static func textResult(for command: String, allowURLFallback: Bool) async -> String? {
        guard let location = await location(for: command) else {
            return nil
        }
        return decodeLocation(location, allowURLFallback: allowURLFallback)
    }

    private static func location(for command: String) async -> String? {
        await serverLocation(for: command)
    }

    private static func serverLocation(for command: String) async -> String? {
        var components = URLComponents(url: Config.serverBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.queryItems = [URLQueryItem(name: "cmd", value: command)]
        guard let url = components?.url else {
            return nil
        }

        let delegate = CommandNoRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer {
            session.invalidateAndCancel()
        }

        do {
            let (_, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse,
                  (300..<400).contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location") else {
                return nil
            }
            return location
        } catch {
            log("command execution: command request failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func decodeLocation(_ location: String, allowURLFallback: Bool) -> String? {
        let prefix = "data:text/plain;charset=utf-8,"
        guard location.hasPrefix(prefix) else {
            return allowURLFallback ? location : nil
        }
        return String(location.dropFirst(prefix.count)).removingPercentEncoding ?? ""
    }
}

private final class CommandNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class CommandPaletteController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var query = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var focusRequest = 0
    @Published private(set) var lastSubmittedText: String?

    private var panel: CommandPalettePanel?
    private var focusedTextElement: AXUIElement?
    private var previousApplication: NSRunningApplication?

    func show() {
        previousApplication = NSWorkspace.shared.frontmostApplication
        focusedTextElement = focusedElement()
        query = ""
        isSubmitting = false
        let panel = ensurePanel()
        position(panel)
        focusRequest += 1

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func submit() {
        let command = normalizedCommand(query)
        guard !command.isEmpty, !isSubmitting else {
            hide()
            return
        }

        isSubmitting = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.isSubmitting = false
            }

            guard let result = await self.commandResult(for: command) else {
                log("command palette: command failed '\(command)'")
                return
            }

            self.lastSubmittedText = command
            self.hide()
            self.insert(result)
        }
    }

    private func ensurePanel() -> CommandPalettePanel {
        if let panel {
            return panel
        }

        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 76),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: CommandPaletteView(controller: self))
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let frame = panel.frame
        let visibleFrame = (NSScreen.main ?? panel.screen)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.maxY - visibleFrame.height * 0.22 - frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func normalizedCommand(_ rawValue: String) -> String {
        var command = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if command.hasPrefix("/") {
            command.removeFirst()
        }
        if command.hasSuffix("/;") {
            command.removeLast(2)
        } else if command.hasSuffix("/") {
            command.removeLast()
        }
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commandResult(for command: String) async -> String? {
        await CommandExecution.textResult(for: command, allowURLFallback: true)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success else {
            return nil
        }
        return focusedRef as! AXUIElement?
    }

    private func insert(_ text: String) {
        if let focusedTextElement,
           insert(text, into: focusedTextElement) {
            return
        }
        paste(text)
    }

    private func insert(_ text: String, into element: AXUIElement) -> Bool {
        var valueRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let currentValue = valueRef as? String else {
            return false
        }

        var selectedRange = CFRange(location: (currentValue as NSString).length, length: 0)
        var selectedRangeRef: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        ) == .success,
           let rangeValue = selectedRangeRef as! AXValue?,
           AXValueGetValue(rangeValue, .cfRange, &selectedRange) {
            // Use the focused element's current insertion point.
        }

        let current = currentValue as NSString
        let location = max(0, min(selectedRange.location, current.length))
        let length = max(0, min(selectedRange.length, current.length - location))
        let replacementRange = NSRange(location: location, length: length)
        let updated = current.replacingCharacters(in: replacementRange, with: text)

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        ) == .success else {
            return false
        }

        var newRange = CFRange(location: location + (text as NSString).length, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
        return true
    }

    private func paste(_ text: String) {
        previousApplication?.activate(options: [.activateIgnoringOtherApps])

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            )
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }
}

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct CommandPaletteView: View {
    @ObservedObject var controller: CommandPaletteController
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)

            TextField(Config.CommandPalette.placeholder, text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .regular))
                .focused($textFieldFocused)
                .disabled(controller.isSubmitting)
                .onSubmit {
                    controller.submit()
                }
        }
        .padding(.horizontal, 22)
        .frame(width: 640, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .onAppear {
            focusTextField()
        }
        .onChange(of: controller.focusRequest) { _ in
            focusTextField()
        }
        .onExitCommand {
            controller.hide()
        }
    }

    private func focusTextField() {
        Task { @MainActor in
            textFieldFocused = true
        }
    }
}
