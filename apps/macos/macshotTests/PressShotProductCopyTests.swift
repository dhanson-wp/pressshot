import Cocoa
import XCTest

@MainActor
final class PressShotProductCopyTests: XCTestCase {
    func testTranslatedProductNamesKeepFormattingAndUseThePressShotScheme() {
        let key = "%d settings were applied. Relaunch macshot to apply all changes."
        XCTAssertEqual(LanguageManager.productText("%d réglages appliqués. Relancez MacShot.", forKey: key),
                       "%d réglages appliqués. Relancez PressShot.")
        XCTAssertEqual(LanguageManager.productText("请为macshot启用权限", forKey: "macshot needs one permission"), "请为PressShot启用权限")
        XCTAssertEqual(LanguageManager.productText("Enable macshot:// URL scheme", forKey: "Enable macshot:// URL scheme"),
                       "Enable pressshot:// URL scheme")
    }

    func testAttributionAndNonProductValuesRemainIntact() {
        for credit in ["Based on MacShot by sw33tLie · GPLv3", "MacShot upstream source"] {
            XCTAssertEqual(LanguageManager.productText(credit, forKey: credit), credit)
        }
        XCTAssertEqual(LanguageManager.productText("macshot", forKey: "A configured folder name"), "macshot")
        XCTAssertEqual(LanguageManager.productText("__macshotData__", forKey: "macshot"), "__macshotData__")
        // The export's identity stays compatible; only the suggested filename changes.
        XCTAssertEqual(SettingsPortability.fileType, "macshot-settings")
        XCTAssertTrue(SettingsPortability.suggestedExportFilename().hasPrefix("pressshot-settings-"))
    }

    func testUpstreamCreditIsOnlyInAbout() throws {
        let controller = SettingsWindowController()
        defer { controller.close() }
        func labels(in view: NSView) -> [String] {
            var result: [String] = []
            if let text = view as? NSTextField { result.append(text.stringValue) }
            if let button = view as? NSButton { result.append(button.title) }
            return result + view.subviews.flatMap { labels(in: $0) }
        }
        func savePreview(_ view: NSView, name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        let content = try XCTUnwrap(controller.window?.contentView)
        for tab in ["general", "capture", "shortcuts", "tools", "recording"] {
            controller.showTab(id: tab)
            let copy = labels(in: content).joined(separator: "\n")
            XCTAssertFalse(copy.localizedCaseInsensitiveContains("macshot"), tab)
            XCTAssertFalse(copy.contains("sw33tLie"), tab)
            if tab == "general" { try savePreview(content, name: "pressshot-product-copy-general.png") }
        }
        controller.showTab(id: "about")
        let about = labels(in: content)
        XCTAssertTrue(about.contains("Based on MacShot by sw33tLie · GPLv3"))
        XCTAssertTrue(about.contains("MacShot upstream source"))
        try savePreview(content, name: "pressshot-product-copy-about.png")
    }
}
