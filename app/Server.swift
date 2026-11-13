import Foundation
import Network

struct Req {
    var method: String
    var path: String
    var query: [String: String]
    var body: Data
}

final class Server {
    static let shared = Server()
    let queue = DispatchQueue(label: "hub.server", attributes: .concurrent)
    var listeners: [String: NWListener] = [:]
    let lk = NSLock()

    /// Starts 127.0.0.1 at once, and the Tailscale address as soon as tailscale answers (retried every 30 s).
    func start() {
        let core = Core.shared
        queue.async {
            core.readTailscale()
            self.openAll()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler {
            if Core.shared.tsIP.isEmpty || !self.has(Core.shared.tsIP) {
                Core.shared.readTailscale()
                self.openAll()
            }
        }
        t.resume()
        keep.append(t)
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 20, repeating: 20)
        ping.setEventHandler { Core.shared.pingWatchers() }
        ping.resume()
        keep.append(ping)
    }

    var keep: [DispatchSourceTimer] = []

    func has(_ host: String) -> Bool { lk.lock(); defer { lk.unlock() }; return listeners[host] != nil }

    func openAll() {
        open(host: "127.0.0.1")
        let ip = Core.shared.tsIP
        if !ip.isEmpty { open(host: ip) }
    }

    func open(host: String) {
        if has(host) { return }
        let port = Core.shared.port
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                Core.shared.lock.lock()
                if !Core.shared.listening.contains(host) { Core.shared.listening.append(host) }
                Core.shared.lock.unlock()
                Core.shared.changed()
            case .failed, .cancelled:
                self?.lk.lock(); self?.listeners[host] = nil; self?.lk.unlock()
                Core.shared.lock.lock()
                Core.shared.listening.removeAll { $0 == host }
                Core.shared.lock.unlock()
                Core.shared.changed()
            default: break
            }
        }
        lk.lock(); listeners[host] = l; lk.unlock()
        l.start(queue: queue)
    }

    // MARK: HTTP

    func remoteIP(_ c: NWConnection) -> String {
        if case let .hostPort(host, _) = c.endpoint {
            var s = "\(host)"
            if let i = s.firstIndex(of: "%") { s = String(s[..<i]) }
            if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
            return s
        }
        return ""
    }

    func handle(_ c: NWConnection) {
        c.start(queue: queue)
        var buf = Data()
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isDone, err in
                if let d = data { buf.append(d) }
                if let req = Server.parse(buf) {
                    self.queue.async { self.route(c, req) }
                    return
                }
                if err != nil || isDone || buf.count > 2_000_000 { c.cancel(); return }
                more()
            }
        }
        more()
    }

    static func parse(_ buf: Data) -> Req? {
        guard let r = buf.range(of: Data([13, 10, 13, 10])) else { return nil }
        let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var clen = 0
        for l in lines.dropFirst() {
            let kv = l.split(separator: ":", maxSplits: 1)
            if kv.count == 2 && kv[0].lowercased() == "content-length" {
                clen = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = r.upperBound
        if buf.count - (bodyStart - buf.startIndex) < clen { return nil }
        let body = buf[bodyStart..<(bodyStart + clen)]
        var path = String(parts[1])
        var q: [String: String] = [:]
        if let i = path.firstIndex(of: "?") {
            let qs = String(path[path.index(after: i)...])
            path = String(path[..<i])
            for kv in qs.split(separator: "&") {
                let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(p[0]).removingPercentEncoding ?? String(p[0])
                let v = p.count > 1 ? (String(p[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(p[1])) : ""
                q[k] = v
            }
        }
        return Req(method: String(parts[0]).uppercased(), path: path, query: q, body: Data(body))
    }

    func respond(_ c: NWConnection, _ code: Int, _ obj: [String: Any]) {
        let data = (JSONSerialization.isValidJSONObject(obj) ? try? JSONSerialization.data(withJSONObject: obj) : nil) ?? Data("{}".utf8)
        let reason = code == 200 ? "OK" : (code == 401 ? "Unauthorized" : (code == 404 ? "Not Found" : "Bad Request"))
        var out = Data("HTTP/1.1 \(code) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(data)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    func route(_ c: NWConnection, _ r: Req) {
        let core = Core.shared
        let ip = remoteIP(c)
        guard core.trusted(ip: ip) else {
            return respond(c, 401, ["error": "not Marko's machine on the tailnet"])
        }
        let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        switch (r.method, r.path) {
        case ("GET", "/"), ("GET", "/status"):
            respond(c, 200, ["app": "Session Hub (Mantra)", "version": VERSION, "port": Int(core.port), "machine": core.localMachine])
        case ("POST", "/register"):
            let (code, o) = core.register(json); respond(c, code, o)
        case ("POST", "/beat"):
            let (code, o) = core.beat(json["sid"] as? String ?? ""); respond(c, code, o)
        case ("GET", "/who"):
            respond(c, 200, core.who())
        case ("POST", "/send"):
            let (code, o) = core.send(from: json["from"] as? String ?? "", to: json["to"] as? String ?? "",
                                      text: json["text"] as? String ?? "", id: json["id"] as? String ?? "")
            respond(c, code, o)
        case ("POST", "/ack"):
            let seqs = (json["seqs"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
            let (code, o) = core.ack(sid: json["sid"] as? String ?? "", seqs: seqs); respond(c, code, o)
        case ("GET", "/inbox"):
            let since = r.query["since"].flatMap { Int($0) }
            let (code, o) = core.inbox(sid: r.query["sid"] ?? "", since: since); respond(c, code, o)
        case ("GET", "/watch"):
            watch(c, sid: r.query["sid"] ?? "")
        default:
            respond(c, 404, ["error": "no such path"])
        }
    }

    func watch(_ c: NWConnection, sid: String) {
        let core = Core.shared
        let w = Watcher { data in c.send(content: data, completion: .contentProcessed { e in if e != nil { c.cancel() } }) }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n: watching\n\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        guard core.addWatcher(sid: sid, watcher: w) else {
            c.cancel()
            return
        }
        c.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: core.removeWatcher(sid: sid, watcher: w)
            default: break
            }
        }
        // a closed peer shows as a failed read
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, err in
            if done || err != nil { c.cancel() }
        }
    }
}
