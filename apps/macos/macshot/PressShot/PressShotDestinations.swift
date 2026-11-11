import Cocoa

struct PressShotDestination: Equatable {
    let id: String
    let title: String
}

/// Capture-scoped selections never change the configured primary destination.
struct PressShotDestinationSelection: Equatable {
    let primaryID: String?
    private(set) var selectedIDs: Set<String>

    init(primaryID: String?, additionalIDs: Set<String> = []) {
        self.primaryID = primaryID
        selectedIDs = additionalIDs
        if let primaryID { selectedIDs.insert(primaryID) }
    }

    mutating func setSelected(_ selected: Bool, id: String) {
        guard id != primaryID else { return }
        if selected { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
    }
}

@MainActor
enum PressShotDestinations {
    static var available: [PressShotDestination] {
        #if !OFFLINE
        var result = WordPressDestinationsStore.shared.destinations.map { PressShotDestination(id: $0.providerID, title: $0.title) }
        result += WPComDestinationsStore.shared.destinations.map { PressShotDestination(id: $0.providerID, title: $0.title) }
        if GoogleDriveUploader.shared.isSignedIn {
            result.append(.init(id: "gdrive", title: "Google Drive"))
        }
        if S3Uploader.shared.isConfigured {
            result.append(.init(id: "s3", title: "S3-compatible storage"))
        }
        // imgbb is public hosting. Never silently select it on a fresh install.
        if UserDefaults.standard.string(forKey: "uploadProvider") == "imgbb" {
            result.append(.init(id: "imgbb", title: "imgbb (public image hosting)"))
        }
        return result
        #else
        return []
        #endif
    }

    static var primary: PressShotDestination? {
        guard let id = UserDefaults.standard.string(forKey: "uploadProvider") else { return nil }
        return available.first { $0.id == id }
    }

    static var libraryURL: URL? {
        guard let value = UserDefaults.standard.string(forKey: "pressshotLibraryURL"),
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

@MainActor
final class PressShotDestinationPopover: NSViewController {
    var selection: PressShotDestinationSelection
    var onSelection: ((PressShotDestinationSelection) -> Void)?
    var onSettings: (() -> Void)?
    private let destinations: [PressShotDestination]

    init(destinations: [PressShotDestination], selection: PressShotDestinationSelection) {
        self.destinations = destinations
        self.selection = selection
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        let heading = NSTextField(labelWithString: "Upload this capture to")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(heading)
        if destinations.isEmpty || selection.primaryID == nil {
            let label = NSTextField(wrappingLabelWithString: "Connect and choose a primary destination in Settings. Until then, Save keeps your capture on this Mac.")
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 250
            stack.addArrangedSubview(label)
        }
        for destination in destinations {
            let isPrimary = destination.id == selection.primaryID
            let button = NSButton(checkboxWithTitle: destination.title + (isPrimary ? " · Default" : ""), target: self, action: #selector(toggle(_:)))
            button.identifier = .init(destination.id)
            button.state = selection.selectedIDs.contains(destination.id) ? .on : .off
            button.isEnabled = !isPrimary
            button.setAccessibilityLabel(button.title)
            stack.addArrangedSubview(button)
        }
        let note = NSTextField(wrappingLabelWithString: "Only the successful primary upload changes the clipboard link.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 250
        stack.addArrangedSubview(note)
        let settings = NSButton(title: "Upload destinations…", target: self, action: #selector(openSettings))
        settings.bezelStyle = .rounded
        stack.addArrangedSubview(settings)
        view = stack
        preferredContentSize = NSSize(width: 295, height: stack.fittingSize.height)
    }
    @objc private func toggle(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        selection.setSelected(sender.state == .on, id: id)
        onSelection?(selection)
    }
    @objc private func openSettings() { onSettings?() }
}
