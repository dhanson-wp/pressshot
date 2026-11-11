import Cocoa

/// Approved Keepsake artwork. Outlines preserve the reviewed Fraunces settings
/// without registering a font or changing the native typography of controls.
@MainActor
enum PressShotBrand {
    static func wordmarkView(height: CGFloat) -> NSImageView {
        let view = NSImageView(frame: NSRect(x: 0, y: 0, width: height * 293 / 53, height: height))
        let image = NSImage(named: "PressShotWordmark")?.copy() as? NSImage
        image?.isTemplate = true
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.contentTintColor = .labelColor
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel(BuildVariant.displayName)
        return view
    }
}
