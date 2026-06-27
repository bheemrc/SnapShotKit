import AppKit
import Carbon.HIToolbox

/// Registers one or more global hotkeys using the Carbon Hot Key API.
///
/// Carbon's `RegisterEventHotKey` is the only system-wide hotkey mechanism that does
/// NOT require Accessibility permission (unlike `CGEventTap` or
/// `NSEvent.addGlobalMonitorForEvents`). It needs a live Cocoa run loop to deliver
/// events, which an `NSApplication`-based app (regular or `LSUIElement` menu-bar agent)
/// always has.
///
/// A single application-wide Carbon event handler is installed lazily on first
/// registration; it reads the `EventHotKeyID` from each event and dispatches the
/// matching handler. Handlers are keyed by `EventHotKeyID.id`.
///
/// IMPORTANT: the owner MUST keep a strong reference to the `HotkeyManager` instance.
/// The C event handler receives `self` via an *unretained* opaque pointer, so if the
/// manager is deallocated while still registered the callback would dereference freed
/// memory.
final class HotkeyManager {

    // MARK: - Stored state

    /// A single live hotkey registration: its Carbon reference plus the closure
    /// to invoke when it fires.
    private struct Registration {
        let hotKeyRef: EventHotKeyRef
        let handler: () -> Void
    }

    /// Active registrations keyed by `EventHotKeyID.id`.
    private var registrations: [UInt32: Registration] = [:]

    /// The shared Carbon event handler, installed once and reused by every hotkey.
    private var handlerRef: EventHandlerRef?

    /// Four-char-code signature ('SSK1') identifying our hot keys.
    private static let signature: OSType = 0x53_53_4B_31 // 'SSK1'

    // MARK: - Lifecycle

    init() {}

    deinit {
        unregisterAll()
    }

    // MARK: - Public API

    /// Registers a global hotkey. The supplied handler is invoked on the main
    /// thread each time the combination is pressed. Re-registering the same `id`
    /// replaces the previous registration for that id.
    ///
    /// - Parameters:
    ///   - id: A caller-chosen identifier, unique per hotkey, used to route events.
    ///   - keyCode: The layout-independent physical key code (e.g. `kVK_ANSI_2`).
    ///   - modifiers: The Carbon modifier mask (e.g. `cmdKey | shiftKey`).
    ///   - handler: The closure to run when the hotkey fires.
    func registerHotkey(id: UInt32,
                        keyCode: UInt32,
                        modifiers: UInt32,
                        handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        guard handlerRef != nil else { return }

        // Replace any existing registration for this id cleanly.
        if let existing = registrations[id] {
            UnregisterEventHotKey(existing.hotKeyRef)
            registrations[id] = nil
        }

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return }
        registrations[id] = Registration(hotKeyRef: ref, handler: handler)
    }

    /// Unregisters every hotkey and removes the shared event handler. Safe to
    /// call repeatedly.
    func unregisterAll() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.hotKeyRef)
        }
        registrations.removeAll()

        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    // MARK: - Private

    /// Installs the shared Carbon hot-key-pressed handler if it is not yet present.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))

        // Pass `self` to the C callback through the userData (refcon) pointer.
        // `passUnretained` does NOT retain self — the owner must hold a strong ref.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            // This closure MUST capture nothing so Swift can bridge it to a
            // C function pointer (EventHandlerUPP).
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                // Read which hotkey fired from the event's EventHotKeyID.
                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr else {
                    return OSStatus(eventNotHandledErr)
                }

                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData)
                    .takeUnretainedValue()
                manager.dispatch(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        if status != noErr {
            handlerRef = nil
        }
    }

    /// Invoked from the C callback. Carbon dispatches hot-key events for the
    /// application event target on the main run loop, so we are already on the
    /// main thread here and can invoke the handler directly. (A `DispatchQueue`
    /// hop is both unnecessary and, under Swift 6 strict concurrency, unsafe —
    /// it would send the non-`Sendable` manager across an isolation boundary.)
    private func dispatch(id: UInt32) {
        registrations[id]?.handler()
    }
}
