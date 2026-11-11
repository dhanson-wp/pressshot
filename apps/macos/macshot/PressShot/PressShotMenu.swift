import Cocoa

@MainActor
enum PressShotMenu {
    struct Recent {
        let id: String
        let title: String
        let detail: String
        let thumbnail: NSImage?
    }

    static func build(target: AnyObject, screenshot: Selector, markup: Selector,
                      record: Selector, recent: Selector, library: Selector,
                      destinations: Selector, settings: Selector, quit: Selector,
                      recentItems: [Recent], primaryTitle: String?, libraryConnected: Bool,
                      moreTools: NSMenu? = nil) -> NSMenu {
        let menu = NSMenu(title: "PressShot")
        menu.autoenablesItems = false
        let header = NSMenuItem()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 310, height: 67))
        let title = PressShotBrand.wordmarkView(height: 20)
        title.frame.origin = NSPoint(x: 18, y: 36)
        let subtitle = NSTextField(labelWithString: primaryTitle.map { "Primary destination · \($0)" } ?? "Connect an upload destination")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 18, y: 14, width: 280, height: 17)
        content.addSubview(title); content.addSubview(subtitle)
        header.view = content
        menu.addItem(header)
        func item(_ title: String, _ action: Selector, _ symbol: String, slot: HotkeyManager.HotkeySlot? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.keepImageVisible()
            if let slot { HotkeyManager.applyMenuShortcut(for: slot, to: item) }
            menu.addItem(item)
            return item
        }
        _ = item("Screenshot", screenshot, "camera", slot: .quickCapture)
        _ = item("Screenshot with markup", markup, "pencil.tip.crop.circle", slot: .captureArea)
        _ = item("Record screen…", record, "video", slot: .recordArea)
        menu.addItem(.separator())
        let heading = NSMenuItem(title: "Recent captures", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if recentItems.isEmpty {
            let empty = NSMenuItem(title: "Your captures will appear here", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in recentItems.prefix(3) {
            let row = item(entry.title, recent, "photo")
            row.representedObject = entry.id
            let text = NSMutableAttributedString(string: entry.title + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            text.append(NSAttributedString(string: entry.detail, attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]))
            row.attributedTitle = text
            if let image = entry.thumbnail?.copy() as? NSImage {
                image.size = NSSize(width: 42, height: 32)
                row.image = image
            }
            row.toolTip = "Open this local capture in the editor"
        }
        menu.addItem(.separator())
        let openLibrary = item("Open library", library, "square.grid.2x2")
        openLibrary.isEnabled = libraryConnected
        openLibrary.toolTip = libraryConnected ? "Open your Spacefast library" : "A Spacefast library hasn’t been connected yet"
        #if !OFFLINE
        _ = item("Upload destinations…", destinations, "icloud.and.arrow.up")
        #endif
        _ = item("Settings…", settings, "gearshape")
        if let moreTools {
            let more = NSMenuItem(title: "More capture tools", action: nil, keyEquivalent: "")
            more.submenu = moreTools
            menu.addItem(more)
        }
        menu.addItem(.separator())
        let quitItem = item("Quit PressShot", quit, "power")
        quitItem.keyEquivalent = "q"
        return menu
    }
}
