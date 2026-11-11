import Foundation
import Network

/* The same HTTP contract server.mjs serves, on 127.0.0.1 only, so the extension
   needs no changes to talk to either:

     GET  /ping            {ok}
     GET  /version         {ok, extension, app, engine}  ?v=<installed extension version>
     POST /session         the recorded bundle → {ok, dir, notes, brief}

   and, app only, on-device transcription for the overlay:

     POST /listen          {on: bool}
     GET  /listen/status   {listening, tail, count, error} — also the heartbeat

   Only the extension may call it. Binding to 127.0.0.1 keeps other machines out
   but not other websites: any page you visit can send requests to localhost, and
   without this check one could turn the microphone on through /listen and read
   what you say from /listen/status. Browsers always send Origin on a page's
   POST and cross-origin fetch, and a page cannot forge it, so a request is
   served only when Origin is absent (a local tool like curl, or a page's plain
   GET that cannot read the reply) or a browser extension. The Host check stops
   DNS rebinding, where a hostile name is pointed at 127.0.0.1 to look same-origin.
*/
final class HostServer {
    var onState: ((Bool, String) -> Void)?
    var onExtensionSeen: ((String, String?) -> Void)?   // version, shortcut ("" = none set)
    var onSession: ((LastSession) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "pointy.server")
    private var listener: NWListener?
    private static let maxBody = 300 * 1024 * 1024

    init(port: UInt16) { self.port = port }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: params)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.onState?(true, "Ready — listening on 127.0.0.1:\(self.port)")
                case .failed(let error):
                    // Almost always a node server.mjs still running from a terminal.
                    let busy = "\(error)".contains("Address already in use")
                    self.onState?(false, busy ? "Port \(self.port) is busy — quit the old node server, then reopen Pointy" : "Server stopped: \(error)")
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onState?(false, "Server could not start: \(error)")
        }
    }

    // MARK: - connection

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                // Refuse a stranger as soon as its headers arrive, before reading any body.
                if !Self.allowed(origin: request.origin, host: request.host) { return self.handle(request, conn) }
                if request.contentLength > Self.maxBody { return self.send(conn, 413, ["ok": false, "error": "too large"]) }
                if request.body.count >= request.contentLength { return self.handle(request, conn) }
            }
            if done || error != nil { conn.cancel(); return }
            self.receive(conn, buffer: buffer)
        }
    }

    static func allowed(origin: String?, host: String?) -> Bool {
        let hostName = host?.split(separator: ":").first.map { $0.lowercased() }
        guard hostName == "127.0.0.1" || hostName == "localhost" else { return false }
        guard let origin else { return true }
        return ["chrome-extension://", "moz-extension://", "safari-web-extension://"].contains { origin.hasPrefix($0) }
    }

    private func handle(_ req: Request, _ conn: NWConnection) {
        guard Self.allowed(origin: req.origin, host: req.host) else {
            return send(conn, 403, ["ok": false, "error": "only the Pointy extension can use this server"], origin: req.origin)
        }
        if req.method == "OPTIONS" { return send(conn, 204, nil, origin: req.origin) }
        switch (req.method, req.path) {
        case ("GET", "/ping"):
            send(conn, 200, ["ok": true], origin: req.origin)
        case ("GET", "/version"):
            if let v = req.query["v"] { onExtensionSeen?(v, req.query["k"]) }
            send(conn, 200, ["ok": true, "extension": ExtensionInstaller.bundledVersion ?? "",
                             "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                             "engine": Preferences.shared.engine.rawValue, "keymap": Keymap.json], origin: req.origin)
        case ("POST", "/listen"):
            let json = (try? JSONSerialization.jsonObject(with: req.body.prefix(req.contentLength))) as? [String: Any]
            Transcription.shared.setListening(json?["on"] as? Bool ?? false)
            send(conn, 200, ["ok": true], origin: req.origin)
        case ("GET", "/listen/status"):
            send(conn, 200, Transcription.shared.status().merging(["ok": true]) { a, _ in a }, origin: req.origin)
        case ("POST", "/session"):
            do {
                let body = req.body.prefix(req.contentLength)
                let window = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                let from = window?["startedAt"] as? Double ?? 0
                let to = window?["endedAt"] as? Double ?? Date().timeIntervalSince1970 * 1000
                // Waits for the on-device model to finish the last phrase first.
                let speech = Preferences.shared.engine.onDevice ? Transcription.shared.drain(from: from, to: to) : []
                let saved = try SessionStore.shared.save(body, speech: speech)
                onSession?(saved)
                send(conn, 200, ["ok": true, "dir": saved.dir.path, "notes": saved.marks, "brief": saved.brief], origin: req.origin)
            } catch {
                NSLog("Pointy: failed to write session: \(error)")
                send(conn, 500, ["ok": false, "error": "\(error)"], origin: req.origin)
            }
        default:
            send(conn, 404, ["ok": false, "error": "not found"], origin: req.origin)
        }
    }

    private func send(_ conn: NWConnection, _ status: Int, _ json: [String: Any]?, origin: String? = nil) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [200: "OK", 204: "No Content", 403: "Forbidden", 404: "Not Found", 413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        // Never "*": only the extension that asked may read the reply.
        if let origin, Self.allowed(origin: origin, host: "127.0.0.1") {
            head += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nAccess-Control-Allow-Headers: content-type\r\n"
        }
        if json != nil { head += "Content-Type: application/json\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Just enough HTTP/1.1 to parse one request: method, path, query, Content-Length body.
private struct Request {
    let method: String
    let path: String
    let query: [String: String]
    let contentLength: Int
    let body: Data
    let origin: String?
    let host: String?

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        let target = URLComponents(string: String(parts[1]))
        path = target?.path ?? "/"
        query = Dictionary((target?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        func header(_ name: String) -> String? {
            lines.dropFirst().first { $0.lowercased().hasPrefix(name + ":") }
                .map { $0.split(separator: ":", maxSplits: 1).dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }
        }
        contentLength = header("content-length").flatMap { Int($0) } ?? 0
        origin = header("origin").flatMap { $0.isEmpty ? nil : $0 }   // "null" (sandboxed frames) stays, and is refused
        host = header("host")
        body = data[end.upperBound...]
    }
}
