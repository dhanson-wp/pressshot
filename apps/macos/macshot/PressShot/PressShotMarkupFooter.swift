import Cocoa

/// Capture feedback, not a second library. Organization happens in the Library on the site.
final class PressShotMarkupFooter: NSView {
    private let label = NSTextField(labelWithString: "Edits stay local until you click Save.")
    private let copy = NSButton(title: "Copy link", target: nil, action: nil)
    private let retry = NSButton(title: "Retry upload", target: nil, action: nil)
    private var resetCopyTitle: DispatchWorkItem?
    var onCopyLink: (() -> Bool)?
    var onRetry: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.19, alpha: 1).cgColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.85, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        copy.bezelStyle = .rounded
        copy.controlSize = .small
        copy.font = .systemFont(ofSize: 11)
        copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        copy.imagePosition = .imageLeading
        copy.toolTip = "Copy the link to this capture again"
        copy.target = self; copy.action = #selector(copyClicked)
        copy.isHidden = true
        retry.bezelStyle = .rounded
        retry.target = self; retry.action = #selector(retryClicked)
        retry.isHidden = true
        let buttons = NSStackView(views: [copy, retry])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.detachesHiddenViews = true
        for v in [label, buttons] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(message: String, canRetry: Bool, canCopyLink: Bool = false) {
        label.stringValue = message; label.toolTip = message
        retry.isHidden = !canRetry
        copy.isHidden = !canCopyLink
    }
    @objc private func copyClicked() {
        guard onCopyLink?() == true else { return }
        copy.title = "Copied"
        copy.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        NSAccessibility.post(element: copy, notification: .announcementRequested,
                             userInfo: [.announcement: "Link copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        resetCopyTitle?.cancel()
        let reset = DispatchWorkItem { [weak self] in
            self?.copy.title = "Copy link"
            self?.copy.image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        }
        resetCopyTitle = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: reset)
    }
    @objc private func retryClicked() { onRetry?() }
}
