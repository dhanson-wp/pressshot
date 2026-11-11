import Cocoa

/// Capture feedback, not a second library. All organization stays on Spacefast.
final class PressShotMarkupFooter: NSView {
    private let label = NSTextField(labelWithString: "Edits stay local until you click Save.")
    private let retry = NSButton(title: "Retry upload", target: nil, action: nil)
    var onRetry: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        layer?.backgroundColor = NSColor(white: 0.19, alpha: 1).cgColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(white: 0.85, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        retry.bezelStyle = .rounded
        retry.target = self; retry.action = #selector(retryClicked)
        retry.isHidden = true
        for v in [label, retry] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: retry.leadingAnchor, constant: -12),
            retry.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            retry.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(message: String, canRetry: Bool) {
        label.stringValue = message; label.toolTip = message
        retry.isHidden = !canRetry
    }
    @objc private func retryClicked() { onRetry?() }
}
