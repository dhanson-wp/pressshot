import AppKit
import CoreGraphics

/// Which app and window are in front.
nonisolated struct AINotesFocus: Equatable, Sendable {
    var app: String
    var bundleID: String?
    var title: String
    var pid: pid_t = 0
}

/// Reports which app and window are in front, once a second and whenever the active app changes.
/// Window titles come from the window list, which Screen Recording access already covers.
nonisolated final class AINotesFocusMonitor: @unchecked Sendable {
    private let onChange: (AINotesFocus) -> Void
    private let queue = DispatchQueue(label: "com.derekhanson.pressshot.ai-notes.focus")
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var last: AINotesFocus?

    init(onChange: @escaping (AINotesFocus) -> Void) {
        self.onChange = onChange
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.poll() }
            timer.resume()
            self.timer = timer
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] _ in
                    // The new app's window takes a moment to reach the front of the list.
                    self?.queue.asyncAfter(deadline: .now() + 0.15) { self?.poll() }
                }
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
        }
    }

    private func poll() {
        guard timer != nil, let focus = Self.frontmost(), focus != last else { return }
        last = focus
        onChange(focus)
    }

    /// The frontmost ordinary window that is not PressShot's own (its HUD and overlays).
    static func frontmost() -> AINotesFocus? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        return frontmost(in: list, ownPID: ProcessInfo.processInfo.processIdentifier) { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
    }

    static func frontmost(in list: [[String: Any]], ownPID: pid_t, bundleID: (pid_t) -> String?) -> AINotesFocus? {
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.width >= 120, bounds.height >= 80 else { continue }
            return AINotesFocus(app: info[kCGWindowOwnerName as String] as? String ?? "",
                                bundleID: bundleID(pid),
                                title: info[kCGWindowName as String] as? String ?? "",
                                pid: pid)
        }
        return nil
    }
}

/// Watches mouse buttons, the scroll wheel and (with Input Monitoring access) the fact that keys
/// are being pressed, for the whole Mac while a recording runs. Events sent to PressShot's own
/// windows never reach a global monitor, so a click on Stop stays out of the notes.
final class AINotesInputMonitor {
    private let recorder: AINotesEventRecorder
    private var monitors: [Any] = []
    private var keyTap: KeyTap?

    init(recorder: AINotesEventRecorder) {
        self.recorder = recorder
    }

    static var canWatchKeys: Bool { CGPreflightListenEventAccess() }

    func start() {
        guard monitors.isEmpty else { return }
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel]
        let recorder = recorder
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: { event in
            switch event.type {
            case .leftMouseDown, .rightMouseDown:
                recorder.click(at: Self.screenPoint(of: event),
                               button: event.type == .leftMouseDown ? "left" : "right",
                               uptime: event.timestamp)
            case .scrollWheel:
                recorder.scroll(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY), uptime: event.timestamp)
            default:
                break
            }
        }) {
            monitors.append(monitor)
        }
        if Self.canWatchKeys { keyTap = KeyTap(recorder: recorder) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        keyTap?.stop()
        keyTap = nil
    }

    /// The pointer position in Core Graphics space (top-left origin), which is what the recording uses.
    private static func screenPoint(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location { return location }
        return AINotesGeometry.cgPoint(fromAppKit: NSEvent.mouseLocation,
                                       primaryDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// A listen-only tap for key-down events. The event itself is never read: the recorder is
    /// only told that a key went down, and when.
    private final class KeyTap {
        private let context: Unmanaged<Context>
        private var source: CFRunLoopSource?

        nonisolated final class Context: @unchecked Sendable {
            let recorder: AINotesEventRecorder
            var tap: CFMachPort?

            init(recorder: AINotesEventRecorder) {
                self.recorder = recorder
            }
        }

        init?(recorder: AINotesEventRecorder) {
            let context = Unmanaged.passRetained(Context(recorder: recorder))
            let mask: CGEventMask = 1 << CGEventType.keyDown.rawValue
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask,
                callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let context = Unmanaged<Context>.fromOpaque(refcon).takeUnretainedValue()
                    if type == .keyDown {
                        context.recorder.keyPressed(uptime: AINotesClock.hostNow())
                    } else if type == .tapDisabledByTimeout, let tap = context.tap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                },
                userInfo: context.toOpaque()) else {
                context.release()
                return nil
            }
            self.context = context
            context.takeUnretainedValue().tap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.source = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        func stop() {
            guard let source else { return }
            if let tap = context.takeUnretainedValue().tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = nil
            context.takeUnretainedValue().tap = nil
            context.release()
        }
    }
}
