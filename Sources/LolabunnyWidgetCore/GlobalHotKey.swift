import Carbon
import Foundation

private let lolabunnyHotKeySignature: OSType = 0x4C424E59
private let hotKeyEventTapUnavailableStatus: OSStatus = -1

private final class GlobalHotKeyEventTapContext {
    let identifier: UInt32
    let keyCode: UInt32
    let requiredFlags: CGEventFlags

    init(identifier: UInt32, keyCode: UInt32, requiredFlags: CGEventFlags) {
        self.identifier = identifier
        self.keyCode = keyCode
        self.requiredFlags = requiredFlags
    }
}

@MainActor
final class GlobalHotKey {
    private static var nextIdentifier: UInt32 = 1
    private static var callbacks: [UInt32: @MainActor () -> Void] = [:]
    private static var eventHandler: EventHandlerRef?

    private let identifier: UInt32
    private let label: String
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let eventTapFlags: CGEventFlags?
    private let action: @MainActor () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var eventTapContext: GlobalHotKeyEventTapContext?

    init(
        label: String,
        keyCode: UInt32,
        modifiers: UInt32,
        eventTapFlags: CGEventFlags? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
        self.label = label
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.eventTapFlags = eventTapFlags
        self.action = action
    }

    static func commandP(action: @escaping @MainActor () -> Void) -> GlobalHotKey {
        GlobalHotKey(
            label: Config.CommandPalette.hotKeyLabel,
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: UInt32(cmdKey),
            eventTapFlags: .maskCommand,
            action: action
        )
    }

    @discardableResult
    func register() -> OSStatus {
        guard hotKeyRef == nil else {
            return noErr
        }

        Self.installEventHandlerIfNeeded()
        Self.callbacks[identifier] = action

        if let eventTapFlags {
            let status = registerEventTap(flags: eventTapFlags)
            guard status == noErr else {
                Self.callbacks[identifier] = nil
                log("hotkey: event tap register failed \(label) status=\(status)")
                return status
            }
            log("hotkey: registered \(label) event tap")
            return noErr
        }

        let hotKeyID = EventHotKeyID(signature: lolabunnyHotKeySignature, id: identifier)
        var registeredHotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )

        guard status == noErr, let registeredHotKey else {
            Self.callbacks[identifier] = nil
            log("hotkey: register failed \(label) status=\(status)")
            return status
        }

        hotKeyRef = registeredHotKey
        log("hotkey: registered \(label)")
        return noErr
    }

    func unregister() {
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        Self.callbacks[identifier] = nil
        eventTapSource = nil
        eventTap = nil
        eventTapContext = nil
        hotKeyRef = nil
    }

    private func registerEventTap(flags: CGEventFlags) -> OSStatus {
        let context = GlobalHotKeyEventTapContext(
            identifier: identifier,
            keyCode: keyCode,
            requiredFlags: flags
        )
        eventTapContext = context

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard type == .keyDown,
                      let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let context = Unmanaged<GlobalHotKeyEventTapContext>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                guard keyCode == context.keyCode else {
                    return Unmanaged.passUnretained(event)
                }

                let relevantFlags = event.flags.intersection([
                    .maskCommand,
                    .maskControl,
                    .maskAlternate,
                    .maskShift,
                ])
                guard relevantFlags == context.requiredFlags else {
                    return Unmanaged.passUnretained(event)
                }

                Task { @MainActor in
                    GlobalHotKey.invoke(identifier: context.identifier)
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            return hotKeyEventTapUnavailableStatus
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return hotKeyEventTapUnavailableStatus
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return noErr
    }

    private static func installEventHandlerIfNeeded() {
        guard eventHandler == nil else {
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else {
                    return noErr
                }

                var hotKeyID = EventHotKeyID(signature: 0, id: 0)
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == lolabunnyHotKeySignature else {
                    return noErr
                }

                Task { @MainActor in
                    GlobalHotKey.invoke(identifier: hotKeyID.id)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )

        guard status == noErr, let handlerRef else {
            log("hotkey: event handler install failed status=\(status)")
            return
        }

        eventHandler = handlerRef
    }

    private static func invoke(identifier: UInt32) {
        callbacks[identifier]?()
    }
}
