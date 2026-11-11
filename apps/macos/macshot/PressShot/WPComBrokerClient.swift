#if !OFFLINE
import Foundation

private final class WPComBrokerRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class WPComBrokerClient {
    private let session: URLSession
    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: WPComBrokerRedirectPolicy(), delegateQueue: nil)
    }
    func exchange(service: URL, handoff: String, verifier: String) async throws -> WPComGrant {
        guard WPComApproval.validService(service) else { throw WPComError.configuration }
        var request = URLRequest(url: service.appendingPathComponent("exchange"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["handoff": handoff, "code_verifier": verifier])
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw WPComError.network }
        guard let http = response as? HTTPURLResponse else { throw WPComError.invalidResponse }
        guard http.statusCode == 200 else { throw WPComError.http(http.statusCode) }
        guard data.count <= 32768,
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = values["access_token"] as? String, !token.isEmpty, !token.contains("\r"), !token.contains("\n"),
              (values["token_type"] as? String)?.lowercased() == "bearer" else { throw WPComError.invalidResponse }
        var expires: Date?
        if let raw = values["expires_in"] {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue <= 315360000 else { throw WPComError.invalidResponse }
            expires = Date().addingTimeInterval(number.doubleValue)
        }
        return WPComGrant(token: token, expires: expires)
    }
}
#endif
