import Cocoa

/// Durable local captures and independent destination delivery. Team transport
/// remains separate from the saved personal WordPress connection.
@MainActor
final class PressShotDeliveryCenter {
    enum Status: String, Codable { case saving, saved, uploading, uploaded, failed, unsupported }
    struct Record: Codable {
        let id: String
        let createdAt: Date
        let primaryID: String?
        var destinationIDs: [String]
        var statuses: [String: Status]
        var links: [String: String]
        var message: String
        var historyEntryID: String?
        let fileExtension: String
        var isRecording: Bool { fileExtension != "png" }
        init(id: String, selection: PressShotDestinationSelection, fileExtension: String = "png") {
            self.id = id; createdAt = Date(); primaryID = selection.primaryID
            self.fileExtension = fileExtension
            destinationIDs = selection.selectedIDs.sorted()
            statuses = Dictionary(uniqueKeysWithValues: destinationIDs.map { ($0, .saved) })
            links = [:]; message = "Saving on this Mac…"
        }
        enum CodingKeys: String, CodingKey { case id, createdAt, primaryID, destinationIDs, statuses, links, message, historyEntryID, fileExtension }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadCorruptFile) }
            fileExtension = try c.decodeIfPresent(String.self, forKey: .fileExtension) ?? "png"
            guard ["png", "mp4", "mov"].contains(fileExtension) else { throw CocoaError(.fileReadCorruptFile) }
            createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? .distantPast
            primaryID = try? c.decode(String.self, forKey: .primaryID)
            destinationIDs = (try? c.decode([String].self, forKey: .destinationIDs)) ?? []
            statuses = (try? c.decode([String: Status].self, forKey: .statuses)) ?? [:]
            links = (try? c.decode([String: String].self, forKey: .links)) ?? [:]
            historyEntryID = try? c.decode(String.self, forKey: .historyEntryID)
            message = (try? c.decode(String.self, forKey: .message)) ?? "Saved on this Mac"
        }
        var primaryLink: String? { primaryID.flatMap { links[$0] } }
        var isUploading: Bool { statuses.values.contains(.uploading) }
    }
    typealias Completion = @MainActor (Result<String, Error>) -> Void
    typealias Transport = (String, NSImage, @escaping Completion) -> Void
    typealias RecordingTransport = (String, URL, @escaping Completion) -> Void
    static let shared = PressShotDeliveryCenter()
    static let changed = Notification.Name("pressshot.deliveryChanged")
    private(set) var records: [Record] = []
    private let directory: URL
    private let transport: Transport
    private let recordingTransport: RecordingTransport
    private let copyLink: (String) -> Void
    private let recordingRestriction: (String) -> String?
    private var saving = 0

    init(directory: URL? = nil, transport: Transport? = nil, recordingTransport: RecordingTransport? = nil, copyLink: ((String) -> Void)? = nil, recordingRestriction: ((String) -> String?)? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = directory ?? support.appendingPathComponent("com.derekhanson.pressshot/PendingCaptures", isDirectory: true)
        self.transport = transport ?? Self.upload
        self.recordingTransport = recordingTransport ?? Self.uploadRecording
        self.recordingRestriction = recordingRestriction ?? { provider in
            #if !OFFLINE
            if let destination = WPComDestinationsStore.shared.destination(provider: provider), !destination.hasVideoPress { return WPComError.screenshotOnly.localizedDescription }
            #endif
            return nil
        }
        self.copyLink = copyLink ?? { value in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        if let urls = try? FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
            records = urls.filter { $0.pathExtension == "json" }.compactMap {
                guard let data = try? Data(contentsOf: $0), var record = try? JSONDecoder().decode(Record.self, from: data),
                      $0.deletingPathExtension().lastPathComponent == record.id,
                      FileManager.default.fileExists(atPath: self.directory.appendingPathComponent(record.id + "." + record.fileExtension).path) else { return nil }
                for (key, status) in record.statuses where status == .uploading { record.statuses[key] = .failed }
                record.message = record.primaryLink == nil ? "Kept on this Mac · ready to retry" : "Primary uploaded · local copy kept"
                return record
            }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    func fileURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil, let record = record(id) else { return nil }
        return directory.appendingPathComponent(id + "." + record.fileExtension)
    }
    func record(_ id: String) -> Record? { records.first { $0.id == id } }

    /// Own a finished video before uploading. The original take stays untouched.
    @discardableResult
    func submitRecording(file: URL, selection: PressShotDestinationSelection) -> String? {
        let ext = file.pathExtension.lowercased()
        guard saving < 3, file.isFileURL, ["mp4", "mov"].contains(ext),
              (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else { return nil }
        let record = Record(id: UUID().uuidString, selection: selection, fileExtension: ext)
        records.insert(record, at: 0); saving += 1
        let id = record.id, directory = self.directory
        changed(id)
        MediaExportCoordinator.shared.start(title: "Prepare recording", status: "Preparing recording…", operation: { cancellation, _ in
            try cancellation.beginPublication()
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let target = directory.appendingPathComponent(id + "." + ext)
                let staging = directory.appendingPathComponent(id + ".partial")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: file, to: staging)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                try FileManager.default.moveItem(at: staging, to: target)
            }.value
        }, completion: { [weak self] result in
            guard let self else { return }
            self.saving -= 1
            switch result {
            case .success:
                self.update(id) { $0.message = "Saved on this Mac" }
                self.retry(id)
            case .failure:
                self.update(id) { $0.message = "Couldn’t prepare the recording. Original kept in the recording library." }
            }
        })
        return id
    }

    func associateHistory(_ historyID: String, with id: String) {
        update(id) { $0.historyEntryID = historyID }
    }

    /// Own an immutable pixel snapshot before allowing the editor to change.
    @discardableResult
    func submit(image: NSImage, selection: PressShotDestinationSelection) -> String? {
        guard saving < 3, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let record = Record(id: UUID().uuidString, selection: selection)
        records.insert(record, at: 0)
        saving += 1
        let snapshot = PixelSnapshot(cg)
        let directory = self.directory
        changed(record.id)
        let id = record.id
        MediaExportCoordinator.shared.start(title: "Save capture", status: "Saving on this Mac", operation: { cancellation, _ in
            try cancellation.beginPublication()
            try await Self.savePNG(snapshot, id: id, directory: directory)
        }, completion: { [weak self] result in
            guard let self else { return }
            self.saving -= 1
            switch result {
            case .success:
                self.update(id) { $0.message = "Saved on this Mac" }
                self.retry(id)
            case .failure:
                self.update(id) { $0.message = "Couldn’t save the capture. Keep the editor open and try again." }
            }
        })
        return record.id
    }

    func retry(_ id: String) {
        guard let record = record(id), !record.isUploading,
              let url = fileURL(id), FileManager.default.fileExists(atPath: url.path) else { return }
        let image = record.isRecording ? nil : NSImage(contentsOf: url)
        guard record.isRecording || image != nil else { return }
        guard record.primaryID != nil else {
            update(id) { $0.message = "Saved on this Mac · choose a primary destination in Settings" }
            return
        }
        if record.isRecording, let primary = record.primaryID, let reason = recordingRestriction(primary) {
            update(id) { $0.message = reason; $0.statuses[primary] = .unsupported }
            return
        }
        let ids = record.destinationIDs.filter { record.statuses[$0] != .uploaded }
        guard !ids.isEmpty else { return }
        // Mark every destination before starting: synchronous test transports and
        // fast callbacks must not make a partially started job appear complete.
        update(id) { value in
            for destination in ids { value.statuses[destination] = .uploading }
            value.message = "Uploading… · local copy kept"
        }
        for destination in ids {
            let done: Completion = { [weak self] result in self?.finish(id, destination: destination, result: result) }
            if record.isRecording { recordingTransport(destination, url, done) }
            else if let image { transport(destination, image, done) }
        }
    }

    /// Additional uploads reuse the saved pixels and never repeat completed destinations.
    func addDestinations(_ ids: Set<String>, to id: String) {
        guard let record = record(id), record.primaryLink != nil, !record.isUploading else { return }
        update(id) { value in
            for destination in ids where !value.destinationIDs.contains(destination) {
                value.destinationIDs.append(destination)
                value.statuses[destination] = .saved
            }
        }
        retry(id)
    }

    func finish(_ id: String, destination: String, result: Result<String, Error>) {
        guard let previous = record(id), previous.statuses[destination] == .uploading else { return }
        var validResult = result
        if case .success(let link) = result {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                finish(id, destination: destination, result: .failure(URLError(.badServerResponse))); return
            }
            if previous.primaryID == destination, previous.links[destination] == nil { copyLink(link) }
            validResult = .success(link)
        }
        update(id) { value in
            switch validResult {
            case .success(let link): value.statuses[destination] = .uploaded; value.links[destination] = link
            case .failure: value.statuses[destination] = .failed
            }
            if value.primaryLink != nil {
                value.message = value.statuses.values.contains(.failed) ? "Primary link copied · another destination failed. Retry is available." : value.isUploading ? "Primary link copied · other uploads continuing…" : "Link copied · local copy kept"
            } else {
                value.message = value.isUploading ? "Uploading… · waiting for the primary destination" : "Primary upload failed · local copy kept. Retry or reconnect in Settings."
                #if !OFFLINE
                if !value.isUploading, previous.primaryID == destination, case .failure(let error) = validResult, let wpcom = error as? WPComError { value.message = wpcom.localizedDescription }
                #endif
            }
        }
    }

    nonisolated private static func savePNG(_ snapshot: PixelSnapshot, id: String, directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    guard let data = NSBitmapImageRep(cgImage: snapshot.image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: directory.appendingPathComponent(id + ".png"), options: .atomic)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func update(_ id: String, change: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(records[index]).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
        } catch { records[index].message = "Local capture kept, but upload status couldn’t be saved. Keep this window open." }
        changed(id)
    }
    private func changed(_ id: String) {
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["id": id])
    }
    private final class PixelSnapshot: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private static func upload(_ provider: String, image: NSImage, completion: @escaping Completion) {
        #if !OFFLINE
        if provider.hasPrefix("wpcom:") {
            WPComDestinationsStore.shared.uploadImage(provider: provider, image: image, completion: completion)
            return
        }
        if provider.hasPrefix("wordpress:") {
            WordPressDestinationsStore.shared.uploadImage(provider: provider, image: image, completion: completion)
            return
        }
        switch provider {
        case "gdrive" where GoogleDriveUploader.shared.isSignedIn:
            GoogleDriveUploader.shared.uploadImage(image, completion: completion)
        case "s3" where S3Uploader.shared.isConfigured:
            S3Uploader.shared.uploadImage(image, completion: completion)
        case "imgbb" where UserDefaults.standard.string(forKey: "uploadProvider") == "imgbb":
            ImageUploader.upload(image: image) { result in completion(result.map { $0.link }) }
        default: completion(.failure(URLError(.userAuthenticationRequired)))
        }
        #else
        completion(.failure(URLError(.notConnectedToInternet)))
        #endif
    }

    private static func uploadRecording(_ provider: String, file: URL, completion: @escaping Completion) {
        #if !OFFLINE
        if provider.hasPrefix("wpcom:") {
            Task {
                do { completion(.success(try await WPComDestinationsStore.shared.uploadRecording(provider: provider, file: file))) }
                catch { completion(.failure(error)) }
            }
        } else if provider.hasPrefix("wordpress:") {
            Task {
                do { completion(.success(try await WordPressDestinationsStore.shared.uploadRecording(provider: provider, file: file))) }
                catch { completion(.failure(error)) }
            }
        } else if provider == "s3", S3Uploader.shared.isConfigured {
            S3Uploader.shared.uploadVideo(url: file, completion: completion)
        } else if provider == "gdrive", GoogleDriveUploader.shared.isSignedIn {
            GoogleDriveUploader.shared.uploadVideo(url: file, completion: completion)
        } else { completion(.failure(URLError(.unsupportedURL))) }
        #else
        completion(.failure(URLError(.notConnectedToInternet)))
        #endif
    }
}
