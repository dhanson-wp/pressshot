import Cocoa

/// Explicit development-only entry point. It never requests capture permission,
/// registers global shortcuts, connects providers, or changes the clipboard.
@MainActor
final class PressShotNativePreview: NSObject {
    private static var retained: PressShotNativePreview?
    private var status: NSStatusItem?
    private let image: NSImage
    private let center: PressShotDeliveryCenter
    override init() {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 520, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 520).fill()
        NSColor.white.setFill(); NSRect(x: 100, y: 60, width: 700, height: 400).fill()
        ("Northstar / Launch checklist" as NSString).draw(at: NSPoint(x: 145, y: 385), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold), .foregroundColor: NSColor.black])
        for (index, text) in ["Review the welcome screen", "Check the download links", "Share the first walkthrough"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 145, y: 300 - index * 65), withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.darkGray])
        }
        NSGraphicsContext.restoreGraphicsState()
        image = NSImage(size: NSSize(width: 900, height: 520)); image.addRepresentation(bitmap)
        center = PressShotDeliveryCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent("pressshot-native-preview/" + UUID().uuidString),
            transport: { _, _, completion in completion(.failure(URLError(.notConnectedToInternet))) }, copyLink: { _ in })
        super.init()
    }
    static func reopen() { retained?.openMarkup() }
    static func show() {
        let controller = PressShotNativePreview(); retained = controller
        NSApp.setActivationPolicy(.regular)
        let main = NSMenu(); let app = NSMenuItem(); let sub = NSMenu()
        let quit = NSMenuItem(title: "Quit PressShot preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        sub.addItem(quit); app.submenu = sub; main.addItem(app); NSApp.mainMenu = main
        controller.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let mark = NSImage(named: "StatusBarIcon") {
            mark.isTemplate = true; mark.size = NSSize(width: 18, height: 18)
            controller.status?.button?.image = mark
            controller.status?.button?.setAccessibilityLabel("PressShot synthetic preview")
        }
        controller.status?.menu = PressShotMenu.build(target: controller,
            screenshot: #selector(openMarkup), markup: #selector(openMarkup), record: #selector(unavailable),
            recent: #selector(openMarkup), library: #selector(unavailable), destinations: #selector(unavailable),
            settings: #selector(unavailable), quit: #selector(PressShotNativePreview.quit), recentItems: [.init(id: "synthetic", title: "Launch checklist", detail: "Synthetic preview · kept on this Mac", thumbnail: controller.image)],
            primaryTitle: "Team site (preview)", libraryConnected: false)
        app.submenu = controller.status?.menu?.copy() as? NSMenu
        controller.openMarkup()
    }
    @objc private func openMarkup() {
        DetachedEditorWindowController.open(image: image, tool: .arrow, disableBeautify: true, deliveryCenter: center,
            destinations: [.init(id: "preview-team", title: "Team site (preview)"), .init(id: "preview-personal", title: "Personal WordPress (preview)")], primaryID: "preview-team")
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--pressshot-preview-export=") }) {
            let path = String(argument.dropFirst("--pressshot-preview-export=".count))
            DispatchQueue.main.async {
                guard let view = NSApp.windows.first(where: { $0.title.contains("Synthetic preview") })?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
    }
    @objc private func unavailable() {
        let alert = NSAlert(); alert.messageText = "Synthetic screen preview"
        alert.informativeText = "This preview doesn’t capture, connect, upload, or change your clipboard."
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
