#if !OFFLINE
import AppKit
import Foundation
import Network
import Security
import CryptoKit

struct WPComGrant: CustomStringConvertible, CustomDebugStringConvertible {
    let token: String
    let expires: Date?
    var description: String { "WPComGrant(<redacted>)" }
    var debugDescription: String { description }
}

struct WPComApproval {
    static let redirect = "http://127.0.0.1:52632/callback"
    static var configuredService: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "PressShotAuthServiceURL") as? String,
              let url = URL(string: value), validService(url) else { return nil }
        return url
    }
    static func validService(_ url: URL) -> Bool {
        url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil &&
        (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil && (url.port == nil || url.port == 443)
    }
    let verifier: String
    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let state: String
    let expires: Date
    init(now: Date = Date()) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WPComError.callback }
        state = bytes.map { String(format: "%02x", $0) }.joined()
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WPComError.callback }
        verifier = bytes.map { String(format: "%02x", $0) }.joined()
        expires = now.addingTimeInterval(300)
    }
    func authorizationURL(service: URL) throws -> URL {
        guard Self.validService(service) else { throw WPComError.configuration }
        var c = URLComponents(url: service.appendingPathComponent("start"), resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        return c.url!
    }
    func handoff(fragment: String, now: Date = Date()) throws -> String {
        guard now <= expires, fragment.utf8.count < 16384 else { throw WPComError.callback }
        guard let components = URLComponents(string: "?" + fragment), components.fragment == nil else { throw WPComError.callback }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard values[item.name] == nil, let value = item.value else { throw WPComError.callback }
            values[item.name] = value
        }
        guard values["state"] == state else { throw WPComError.callback }
        if values["error"] != nil { throw WPComError.cancelled }
        guard Set(values.keys) == Set(["state", "handoff"]), let handoff = values["handoff"],
              !handoff.isEmpty, handoff.utf8.count <= 8192,
              handoff.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else { throw WPComError.callback }
        return handoff
    }
}

/// The browser returns only a one-use handoff. The token arrives over HTTPS
/// after the Mac proves possession of its per-attempt verifier.
@MainActor
final class WPComAuthorization {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var completion: ((Result<WPComGrant, Error>) -> Void)?
    private var timeout: Task<Void, Never>?
    private var pending: WPComApproval?
    private var browserURL: URL?
    private var opened = false
    private var exchanging = false
    private var service: URL?
    private var exchangeTask: Task<Void, Never>?
    private let exchange: (URL, String, String) async throws -> WPComGrant
    private let browserOpener: (URL) -> Bool
    init(browserOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         exchange: @escaping (URL, String, String) async throws -> WPComGrant = { try await WPComBrokerClient().exchange(service: $0, handoff: $1, verifier: $2) }) {
        self.browserOpener = browserOpener; self.exchange = exchange
    }
    func start(service: URL, completion: @escaping (Result<WPComGrant, Error>) -> Void) throws {
        cancel()
        let approval = try WPComApproval()
        browserURL = try approval.authorizationURL(service: service)
        pending = approval; self.completion = completion; opened = false; exchanging = false; self.service = service
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 52632)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.pending?.state == approval.state else { return }
                switch state {
                case .ready:
                    if !self.opened { self.opened = true; self.openBrowser() }
                case .failed: self.finish(.failure(WPComError.portInUse))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.pending?.state == approval.state, self.connections.count < 16 else { connection.cancel(); return }
                self.connections.append(connection); connection.start(queue: .main)
                self.receive(connection, buffer: Data())
            }
        }
        listener.start(queue: .main)
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { return }
            self?.finish(.failure(WPComError.cancelled))
        }
    }
    func openBrowser() {
        guard let browserURL else { return }
        if !browserOpener(browserURL) { finish(.failure(WPComError.cancelled)) }
    }
    func cancel() { finish(.failure(WPComError.cancelled)) }
    private func finish(_ result: Result<WPComGrant, Error>) {
        let callback = completion; completion = nil; pending = nil; browserURL = nil
        exchangeTask?.cancel(); exchangeTask = nil; service = nil
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil
        for connection in connections { connection.cancel() }; connections.removeAll()
        callback?(result)
    }
    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] bytes, _, ended, error in
            Task { @MainActor [weak self] in
                guard let self, self.pending != nil else { connection.cancel(); return }
                var data = buffer; if let bytes { data.append(bytes) }
                guard data.count <= 32768 else { connection.cancel(); return }
                if let split = data.range(of: Data("\r\n\r\n".utf8)) {
                    let lines = String(decoding: data[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    var headers: [String: String] = [:]
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { connection.cancel(); return }
                        let key = line[..<colon].lowercased()
                        guard headers[key] == nil else { connection.cancel(); return }
                        headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                    let length = headers["content-length"].flatMap(Int.init) ?? 0
                    guard length >= 0, length < 16384, headers["transfer-encoding"] == nil else { connection.cancel(); return }
                    if data.count - split.upperBound >= length {
                        self.handle(connection, line: lines.first ?? "", headers: headers, body: String(decoding: data[split.upperBound..<(split.upperBound + length)], as: UTF8.self)); return
                    }
                }
                if ended || error != nil { connection.cancel() }
                else { self.receive(connection, buffer: data) }
            }
        }
    }
    private func handle(_ connection: NWConnection, line: String, headers: [String: String], body: String) {
        guard let approval = pending, headers["host"] == "127.0.0.1:52632" else { respond(connection, status: 400, html: "Invalid callback."); return }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { respond(connection, status: 400, html: "Invalid callback."); return }
        if parts[0] == "GET", String(parts[1]).split(separator: "?").first == "/callback" {
            let html = Self.returnPage(nonce: approval.state)
            respond(connection, status: 200, html: html, nonce: approval.state)
        } else if parts[0] == "POST", parts[1] == Substring("/callback/" + approval.state), headers["origin"] == "http://127.0.0.1:52632" {
            do {
                let handoff = try approval.handoff(fragment: body)
                guard !exchanging, let service else { respond(connection, status: 409, html: "Already completing sign-in."); return }
                exchanging = true
                exchangeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let grant = try await self.exchange(service, handoff, approval.verifier)
                        guard !Task.isCancelled, self.pending?.state == approval.state else { return }
                        self.respond(connection, status: 200, html: "Approved") { [weak self] in self?.finish(.success(grant)) }
                    } catch {
                        guard !Task.isCancelled, self.pending?.state == approval.state else { return }
                        self.respond(connection, status: 400, html: "Sign-in failed") { [weak self] in self?.finish(.failure(error)) }
                    }
                }
            } catch WPComError.cancelled {
                respond(connection, status: 400, html: "Sign-in cancelled.") { [weak self] in self?.finish(.failure(WPComError.cancelled)) }
            } catch {
                respond(connection, status: 400, html: "Approval invalid.")
                // Invalid unsolicited requests don't consume the pending approval.
            }
        } else { respond(connection, status: 404, html: "Not found.") }
    }
    static func returnPage(nonce: String) -> String {
        let template = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PressShot · Sign-in return review</title><style nonce="__NONCE__">
*{box-sizing:border-box}body{margin:0;background:#f7f8fc;color:#222b3a;font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;text-align:center}main{min-height:100svh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:40px 24px 64px}header{display:flex;justify-content:center;align-items:center;gap:8px;font-size:18px;font-weight:650;letter-spacing:-.5px;color:#3159d8;margin-bottom:52px}header img{width:28px;height:28px}.mark{width:84px;height:84px;color:#3159d8;overflow:visible}.ring{fill:#e9eeff;stroke:currentColor;stroke-width:1.5;transform-origin:center;animation:arrive .65s cubic-bezier(.2,.8,.2,1) both}.check{fill:none;stroke:currentColor;stroke-width:3;stroke-linecap:round;stroke-linejoin:round;stroke-dasharray:48;stroke-dashoffset:0;animation:draw .5s .25s ease both}.spark{stroke:currentColor;stroke-width:2;stroke-linecap:round;transform-origin:42px 42px;animation:spark .85s .1s ease both}h1{font-size:40px;line-height:1.15;font-weight:620;letter-spacing:-1.2px;margin:25px 0 12px}p{color:#586171;margin:0 0 28px;max-width:300px}button{font:inherit;cursor:pointer}#open{border:0;border-radius:9px;background:#3159d8;color:#fff;padding:12px 22px;font-weight:600}button:focus-visible{outline:3px solid #9eb3fc;outline-offset:4px}.review{position:fixed;bottom:0;inset-inline:0;padding:12px;display:flex;justify-content:center;align-items:center;gap:8px;flex-wrap:wrap;background:#e9edf6;font-size:12px}.review button{background:transparent;color:inherit;border:1px solid #b8c3d8;border-radius:5px;padding:4px 9px;font-size:12px}.review button[aria-pressed=true]{background:#3159d8;color:white;border-color:#3159d8}.waiting .check,.waiting .spark{display:none}.waiting .ring{stroke-dasharray:70 200;animation:spin 1.6s linear infinite}.error .mark,.expired .mark{color:#9b6432}.error .spark,.expired .spark{display:none}.error .ring,.expired .ring{fill:transparent}.error .check,.expired .check{animation:none;stroke-dasharray:none} @keyframes arrive{from{opacity:0;transform:scale(.7)}to{opacity:1;transform:scale(1)}}@keyframes draw{from{stroke-dashoffset:48}to{stroke-dashoffset:0}}@keyframes spark{0%{opacity:0;transform:scale(.75)}35%{opacity:.65}100%{opacity:0;transform:scale(1.2)}}@keyframes spin{to{transform:rotate(360deg)}}@media(prefers-reduced-motion:reduce){.ring,.check,.spark{animation:none}.spark{display:none}}@media(prefers-color-scheme:dark){body{background:#191e28;color:#eef1fa}p{color:#b1bbcd}header,.mark{color:#a7bcff}.ring{fill:#252f48}.review{background:#252d3c}.error .mark,.expired .mark{color:#e0b77e}}@media(max-width:420px){h1{font-size:36px}main{padding-bottom:100px}.review{gap:6px}}
</style></head><body><main class="waiting" id="screen"><header><img src="data:image/png;base64,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" alt="">PressShot</header><svg class="mark" aria-hidden="true" viewBox="0 0 84 84"><circle class="ring" cx="42" cy="42" r="35"/><path class="check" id="check" d="M27 42l10 10 20-21"/><g class="spark"><path d="M42 -5v-5M42 89v5M-5 42h-5M89 42h5M9 9l-4-4M75 75l4 4M9 75l-4 4M75 9l4-4"/></g></svg><h1 id="title">Connecting</h1><p id="copy">Just a moment.</p><button id="open">Return to PressShot</button></main><script nonce="__NONCE__">
const fragment = location.hash.slice(1) || location.search.slice(1);
history.replaceState(null, '', '/callback');
function show(ok) {
 document.getElementById('screen').className = ok ? 'approved' : 'error';
 document.getElementById('title').textContent = ok ? 'Approved' : 'Try again';
 document.getElementById('copy').textContent = ok ? 'Choose your site in PressShot.' : 'Restart sign-in in PressShot.';
 if (!ok) document.getElementById('check').setAttribute('d','M42 28v18M42 55v1');
 const mark=document.querySelector('.mark');mark.replaceWith(mark.cloneNode(true));
}
if (fragment) fetch('/callback/__NONCE__', {method:'POST',headers:{'Content-Type':'text/plain'},body:fragment}).then(r=>show(r.ok)).catch(()=>show(false));
else {show(false);document.getElementById('title').textContent='Link expired';document.getElementById('copy').textContent='Start a new sign-in in PressShot.';}
document.getElementById('open').onclick=()=>{location.href='pressshot://settings';};
</script></body></html>
"""#
        return template.replacingOccurrences(of: "__NONCE__", with: nonce)
    }
    private func respond(_ connection: NWConnection, status: Int, html: String, nonce: String = "none", after: (() -> Void)? = nil) {
        let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'nonce-\(nonce)'; img-src data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'\r\nConnection: close\r\n\r\n"
        connection.send(content: Data((headers + html).utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor [weak self] in
                connection.cancel(); self?.connections.removeAll { $0 === connection }; after?()
            }
        })
    }
}
#endif
