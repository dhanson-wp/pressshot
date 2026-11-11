#if !OFFLINE
import Foundation

/// Bounded-memory tus upload. Resume is scoped to this operation; no automatic
/// restart after ambiguous completion or token expiry can create a duplicate.
final class WPComVideoUpload {
    let client: WPComClient
    let chunkSize: Int
    let retryDelays: [UInt64]
    init(client: WPComClient, chunkSize: Int = 10_000_000, retryDelays: [UInt64] = [1, 3, 5, 10, 30]) {
        self.client = client; self.chunkSize = max(1, chunkSize); self.retryDelays = retryDelays
    }
    private func request(_ url: URL, token: String, method: String) throws -> URLRequest {
        try WPComClient.validateAPIURL(url)
        guard !token.isEmpty, !token.contains("\n"), !token.contains("\r") else { throw WPComError.invalidResponse }
        var req = URLRequest(url: url); req.httpMethod = method
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(token, forHTTPHeaderField: "x-videopress-upload-token")
        req.timeoutInterval = 600
        return req
    }
    private func offset(_ response: HTTPURLResponse, size: Int64) throws -> Int64 {
        guard let raw = response.value(forHTTPHeaderField: "Upload-Offset"), let value = Int64(raw), value >= 0, value <= size else { throw WPComError.invalidResponse }
        return value
    }
    private func result(_ response: HTTPURLResponse) throws -> WPComUploadResult {
        guard let guid = response.value(forHTTPHeaderField: "x-videopress-upload-guid"), !guid.isEmpty,
              guid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }),
              let rawID = response.value(forHTTPHeaderField: "x-videopress-upload-media-id"), let id = Int(rawID), id > 0 else { throw WPComError.incompleteUpload }
        let source = response.value(forHTTPHeaderField: "x-videopress-upload-src-url").flatMap { try? WPComClient.mediaURL($0) }
        return .init(mediaID: id, sourceURL: source, videoPressGUID: guid, link: URL(string: "https://videopress.com/v/" + guid)!)
    }
    func upload(file: URL, ticket: WPComClient.VideoTicket, progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws -> WPComUploadResult {
        let mime: String
        switch file.pathExtension.lowercased() {
        case "mp4": mime = "video/mp4"
        case "mov": mime = "video/quicktime"
        default: throw WPComError.invalidResponse
        }
        guard file.isFileURL, let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize, size > 0 else { throw WPComError.invalidResponse }
        let total = Int64(size)
        var create = try request(ticket.endpoint, token: ticket.token, method: "POST")
        create.setValue(String(size), forHTTPHeaderField: "Upload-Length")
        let filename = "PressShot-\(UUID().uuidString)." + file.pathExtension.lowercased()
        create.setValue("filename \(Data(filename.utf8).base64EncodedString()),filetype \(Data(mime.utf8).base64EncodedString())", forHTTPHeaderField: "Upload-Metadata")
        create.httpBody = Data()
        let (_, response) = try await client.send(create)
        guard let raw = response.value(forHTTPHeaderField: "Location"), let location = URL(string: raw, relativeTo: ticket.endpoint)?.absoluteURL else { throw WPComError.invalidResponse }
        try WPComClient.validateAPIURL(location)
        let key = response.value(forHTTPHeaderField: "x-videopress-upload-key-token") ?? ticket.token
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var sent: Int64 = 0
        var failures = 0
        while sent < total {
            try Task.checkCancellation()
            let start = sent
            try handle.seek(toOffset: UInt64(start))
            guard let chunk = try handle.read(upToCount: min(chunkSize, Int(total - start))), !chunk.isEmpty else { throw WPComError.invalidResponse }
            var patch = try request(location, token: key, method: "POST")
            patch.setValue("PATCH", forHTTPHeaderField: "X-HTTP-Method-Override")
            patch.setValue(String(start), forHTTPHeaderField: "Upload-Offset")
            patch.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            patch.httpBody = chunk
            do {
                let (_, reply) = try await client.send(patch)
                sent = try offset(reply, size: total)
                guard sent == start + Int64(chunk.count) else { throw WPComError.invalidResponse }
                progress(sent, total); failures = 0
                if sent == total { return try result(reply) }
            } catch let error as WPComError where error.retryable && failures < retryDelays.count {
                let delay = retryDelays[failures]; failures += 1
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                var head = try request(location, token: key, method: "GET")
                head.setValue("HEAD", forHTTPHeaderField: "X-HTTP-Method-Override")
                let (_, reply) = try await client.send(head)
                sent = try offset(reply, size: total)
                // A lost final response is recoverable only if the server returns its identity.
                if sent == total { return try result(reply) }
                progress(sent, total)
            }
        }
        throw WPComError.incompleteUpload
    }
}
#endif
