import Foundation

struct Session: Codable {
    var name: String
    var sid: String
    var machine: String
    var kind: String
    var cwd: String
    var lastBeat: Double
    var lastMsgAt: Double
    var lastMsgText: String
}

struct SessionView: Identifiable {
    var s: Session
    var live: Bool
    var id: String { s.sid }
}

struct Msg: Codable, Identifiable {
    var mid: String
    var seq: Int
    var from: String
    var fromName: String
    var to: String
    var toName: String
    var text: String
    var ts: Double
    var delivered: Bool
    var via: String
    var typed: Bool? = nil
    var id: Int { seq }
}

final class Watcher {
    let uid = UUID()
    let send: (Data) -> Void
    init(send: @escaping (Data) -> Void) { self.send = send }
}

var hubEpoch = ""

func nowTs() -> Double { Date().timeIntervalSince1970 }

func baseName(_ n: String) -> String {
    if let r = n.range(of: " (") { return String(n[..<r.lowerBound]) }
    return n
}

func msgDict(_ m: Msg) -> [String: Any] {
    return ["id": m.mid, "seq": m.seq, "from": m.from, "fromName": m.fromName, "to": m.to, "toName": m.toName,
            "text": m.text, "ts": m.ts, "delivered": m.delivered, "read": m.delivered, "via": m.via, "epoch": hubEpoch]
}

final class Core {
    static let shared = Core()
    let lock = NSLock()
    var sessions: [String: Session] = [:]
    var msgs: [Msg] = []
    var seq = 0
    var seen = Set<String>()
    var watchers: [String: [Watcher]] = [:]
    var onChange: (() -> Void)?
    var localMachine = ProcessInfo.processInfo.hostName
    var tsIP = ""
    var port: UInt16 = 8890
    var listening: [String] = []
    let dir: URL
    let otherSessions = NSHomeDirectory() + "/Developer/claude-code/tools/other_sessions.py"

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Session Hub")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        if hubEpoch.isEmpty { hubEpoch = UUID().uuidString.lowercased() }
        ensureMarko()
    }

    // MARK: persistence and log

    struct State: Codable {
        var sessions: [Session]
        var msgs: [Msg]
        var seq: Int
        var epoch: String? = nil
    }

    func load() {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
              let st = try? JSONDecoder().decode(State.self, from: d) else { return }
        for s in st.sessions { sessions[s.sid] = s }
        msgs = st.msgs
        seq = st.seq
        hubEpoch = st.epoch ?? ""
        for m in msgs { seen.insert(m.mid + "|" + m.to) }
    }

    func save() {
        if hubEpoch.isEmpty { hubEpoch = UUID().uuidString.lowercased() }
        let st = State(sessions: Array(sessions.values), msgs: msgs, seq: seq, epoch: hubEpoch)
        if let d = try? JSONEncoder().encode(st) {
            try? d.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    func log(_ obj: [String: Any]) {
        var o = obj
        o["at"] = nowTs()
        guard JSONSerialization.isValidJSONObject(o),
              var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(10)
        let url = dir.appendingPathComponent("log.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(d); try? h.close()
        } else {
            try? d.write(to: url)
        }
    }

    func ensureMarko() {
        if sessions["marko"] == nil {
            sessions["marko"] = Session(name: "Marko", sid: "marko", machine: "window", kind: "human", cwd: "",
                                        lastBeat: nowTs(), lastMsgAt: 0, lastMsgText: "")
        }
    }

    // MARK: live state

    func isLive(_ s: Session) -> Bool {
        if s.kind == "human" { return true }
        if let w = watchers[s.sid], !w.isEmpty { return true }
        return nowTs() - s.lastBeat < 90
    }

    func snapshot() -> ([SessionView], [Msg]) {
        lock.lock(); defer { lock.unlock() }
        let v = sessions.values.map { SessionView(s: $0, live: isLive($0)) }
        return (v, msgs)
    }

    func changed() { onChange?() }

    // MARK: API

    func register(_ j: [String: Any]) -> (Int, [String: Any]) {
        let sid = (j["sid"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let name = (j["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if sid.isEmpty || name.isEmpty { return (400, ["error": "name and sid needed"]) }
        lock.lock()
        var s = sessions[sid] ?? Session(name: name, sid: sid, machine: "", kind: "cli", cwd: "",
                                         lastBeat: 0, lastMsgAt: 0, lastMsgText: "")
        s.name = name
        if let m = j["machine"] as? String, !m.isEmpty { s.machine = m }
        if let k = j["kind"] as? String, !k.isEmpty { s.kind = k }
        if let c = j["cwd"] as? String { s.cwd = c }
        s.lastBeat = nowTs()
        sessions[sid] = s
        let queued = msgs.filter { $0.to == sid && !$0.delivered }.count
        log(["type": "register", "sid": sid, "name": name, "machine": s.machine, "kind": s.kind])
        save()
        lock.unlock()
        changed()
        return (200, ["ok": true, "queued": queued])
    }

    func beat(_ sid: String) -> (Int, [String: Any]) {
        lock.lock()
        guard var s = sessions[sid] else { lock.unlock(); return (404, ["error": "unknown sid, register first"]) }
        s.lastBeat = nowTs()
        sessions[sid] = s
        lock.unlock()
        changed()
        return (200, ["ok": true])
    }

    func who() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let list: [[String: Any]] = sessions.values.sorted { $0.machine + $0.name < $1.machine + $1.name }.map { s in
            ["name": s.name, "sid": s.sid, "machine": s.machine, "kind": s.kind, "cwd": s.cwd,
             "live": isLive(s), "watching": watchers[s.sid]?.count ?? 0, "lastBeat": s.lastBeat, "lastMsgAt": s.lastMsgAt, "lastMsg": s.lastMsgText]
        }
        return ["sessions": list, "now": nowTs()]
    }

    func identify(_ ident: String) -> Session? {
        if let s = sessions[ident] { return s }
        let l = ident.lowercased()
        let hit = sessions.values.filter { $0.name.lowercased() == l || baseName($0.name).lowercased() == l }
        return hit.count == 1 ? hit[0] : nil
    }

    func matches(_ t: String) -> [Session] {
        let l = t.lowercased()
        let all = Array(sessions.values)
        let stages: [[Session]] = [
            all.filter { $0.name.lowercased() == l || $0.sid == t || (t.count >= 6 && $0.sid.hasPrefix(t)) },
            all.filter { baseName($0.name).lowercased() == l },
            all.filter { $0.name.lowercased().contains(l) }
        ]
        for st in stages where !st.isEmpty {
            if st.count > 1 {
                let live = st.filter { isLive($0) }
                if live.count == 1 { return live }
            }
            return st
        }
        return []
    }

    func send(from: String, to: String, text rawText: String, id: String) -> (Int, [String: Any]) {
        let text = String(rawText.prefix(8000))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (400, ["error": "no text"]) }
        var out: [[String: Any]] = []
        var typeJobs: [(Int, String, String, String)] = []
        lock.lock()
        let f = identify(from)
        let fromSid = f?.sid ?? from
        let fromName = f?.name ?? from
        if var fs = f, fs.kind != "human" { fs.lastBeat = nowTs(); sessions[fs.sid] = fs }
        var targets: [Session] = []
        var err: String? = nil
        let t = to.trimmingCharacters(in: .whitespaces)
        if t.lowercased() == "all" {
            targets = sessions.values.filter { $0.sid != fromSid && $0.kind != "human" }
        } else {
            let r = matches(t)
            if r.count == 1 { targets = r }
            else if r.isEmpty { err = "no such session: \(t)" }
            else { err = "ambiguous: " + r.map { $0.name }.joined(separator: " | ") }
        }
        if let e = err { lock.unlock(); return (404, ["error": e]) }
        let ts = nowTs()
        for tg in targets {
            let key = id + "|" + tg.sid
            if !id.isEmpty && seen.contains(key) {
                out.append(["to": tg.name, "sid": tg.sid, "status": "duplicate", "id": id])
                continue
            }
            let mid = id.isEmpty ? UUID().uuidString.lowercased() : id
            seen.insert(mid + "|" + tg.sid)
            seq += 1
            var m = Msg(mid: mid, seq: seq, from: fromSid, fromName: fromName, to: tg.sid, toName: tg.name,
                        text: text, ts: ts, delivered: false, via: "")
            // delivered = read (inbox fetched or watch acked). Watch and typing only NOTIFY; the inbox keeps the message until read.
            var notify = "none"
            let wc = watchers[tg.sid]?.count ?? 0
            if tg.kind == "human" {
                m.delivered = true; m.via = "window"; notify = "window"
            } else if wc > 0, let ws = watchers[tg.sid] {
                let line = "data: " + String(decoding: (try? JSONSerialization.data(withJSONObject: msgDict(m))) ?? Data(), as: UTF8.self) + "\n\n"
                for w in ws { w.send(Data(line.utf8)) }
                m.via = "watch"; notify = "watch"
            } else if tg.kind == "mac-cli" && tg.machine == localMachine {
                m.via = "typing"; notify = "typing"
                typeJobs.append((m.seq, tg.sid, fromName, text))
            }
            log(["type": "decision", "seq": m.seq, "toSid": tg.sid, "toKind": tg.kind, "toMachine": tg.machine,
                 "localMachine": localMachine, "watchers": wc, "notify": notify])
            msgs.append(m)
            if msgs.count > 2000 { msgs.removeFirst(msgs.count - 2000) }
            if var ts2 = sessions[tg.sid] { ts2.lastMsgAt = ts; ts2.lastMsgText = fromName + ": " + String(text.prefix(120)); sessions[tg.sid] = ts2 }
            if var fs2 = sessions[fromSid] { fs2.lastMsgAt = ts; fs2.lastMsgText = "to " + tg.name + ": " + String(text.prefix(120)); sessions[fromSid] = fs2 }
            log(["type": "msg", "id": mid, "seq": m.seq, "from": fromName, "fromSid": fromSid, "to": tg.name, "toSid": tg.sid,
                 "text": text, "delivered": m.delivered, "via": m.via])
            out.append(["to": tg.name, "sid": tg.sid, "status": m.delivered ? "delivered" : "queued", "notify": notify, "id": mid, "seq": m.seq])
        }
        save()
        lock.unlock()
        for (sq, sid, fn, tx) in typeJobs { typeInto(seq: sq, sid: sid, fromName: fn, text: tx) }
        changed()
        return (200, ["ok": true, "results": out])
    }

    /// A local Mac tab with no watcher open: type the line into its iTerm tab (other_sessions.py type), like phonereply.py.
    func typeInto(seq sq: Int, sid: String, fromName: String, text: String) {
        DispatchQueue.global().async {
            let one = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            let line = "[hub message from \(fromName)] \(one)"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", self.otherSessions, "type", sid, line]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            var ok = false
            var out = ""
            do {
                try p.run(); p.waitUntilExit(); ok = p.terminationStatus == 0
                if let pp = p.standardOutput as? Pipe { out = String(decoding: pp.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
            } catch { out = "\(error)" }
            self.lock.lock()
            if let i = self.msgs.firstIndex(where: { $0.seq == sq }) { self.msgs[i].typed = ok; self.msgs[i].via = ok ? "typed" : "typing-failed" }
            self.log(["type": "typing", "seq": sq, "toSid": sid, "ok": ok, "out": String(out.prefix(80))])
            self.save()
            self.lock.unlock()
            self.changed()
        }
    }

    func ack(sid: String, seqs: [Int]) -> (Int, [String: Any]) {
        lock.lock()
        var n = 0
        for i in msgs.indices where msgs[i].to == sid && seqs.contains(msgs[i].seq) && !msgs[i].delivered {
            msgs[i].delivered = true; n += 1
        }
        log(["type": "ack", "sid": sid, "seqs": seqs, "marked": n])
        save()
        lock.unlock()
        changed()
        return (200, ["ok": true, "marked": n])
    }

    func inbox(sid: String, since: Int?) -> (Int, [String: Any]) {
        lock.lock()
        guard sessions[sid] != nil else { lock.unlock(); return (404, ["error": "unknown sid, register first"]) }
        var out: [[String: Any]] = []
        for i in msgs.indices where msgs[i].to == sid {
            if let s = since { if msgs[i].seq <= s { continue } } else if msgs[i].delivered { continue }
            out.append(msgDict(msgs[i]))
            if !msgs[i].delivered { msgs[i].delivered = true; msgs[i].via = "inbox" }  // fetched = read
        }
        if var s = sessions[sid] { s.lastBeat = nowTs(); sessions[sid] = s }
        save()
        lock.unlock()
        changed()
        return (200, ["ok": true, "messages": out])
    }

    /// SSE: the undelivered messages first, then every new one as it arrives.
    func addWatcher(sid: String, watcher: Watcher) -> Bool {
        lock.lock()
        guard var s = sessions[sid] else { lock.unlock(); return false }
        s.lastBeat = nowTs(); sessions[sid] = s
        watchers[sid, default: []].append(watcher)
        for i in msgs.indices where msgs[i].to == sid && !msgs[i].delivered {
            if let d = try? JSONSerialization.data(withJSONObject: msgDict(msgs[i])) {
                watcher.send(Data(("data: " + String(decoding: d, as: UTF8.self) + "\n\n").utf8))
            }
        }
        log(["type": "watch-open", "sid": sid, "count": watchers[sid]?.count ?? 0])
        lock.unlock()
        changed()
        return true
    }

    func removeWatcher(sid: String, watcher: Watcher) {
        lock.lock()
        watchers[sid]?.removeAll { $0.uid == watcher.uid }
        if watchers[sid]?.isEmpty == true { watchers[sid] = nil }
        log(["type": "watch-close", "sid": sid, "left": watchers[sid]?.count ?? 0])
        if var s = sessions[sid] { s.lastBeat = nowTs(); sessions[sid] = s }
        lock.unlock()
        changed()
    }

    func pingWatchers() {
        lock.lock()
        let all = watchers.values.flatMap { $0 }
        lock.unlock()
        for w in all { w.send(Data(": ping\n\n".utf8)) }
    }

    // MARK: Tailscale

    static func tailscale(_ args: [String]) -> String {
        for exe in ["/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale"] {
            guard FileManager.default.isExecutableFile(atPath: exe) else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = Pipe()
            do { try p.run() } catch { continue }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { return String(decoding: d, as: UTF8.self) }
        }
        return ""
    }

    var whoisCache: [String: Bool] = [:]

    /// Trust: this Mac itself, or a tailnet node whose login is Marko's. No token.
    func trusted(ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" { return true }
        guard ip.hasPrefix("100.") else { return false }
        lock.lock()
        if let c = whoisCache[ip] { lock.unlock(); return c }
        lock.unlock()
        var ok = false
        let out = Core.tailscale(["whois", "--json", ip])
        if let d = out.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let up = j["UserProfile"] as? [String: Any],
           let login = up["LoginName"] as? String {
            ok = login.hasPrefix("marko.bosko@")
        }
        lock.lock(); whoisCache[ip] = ok; lock.unlock()
        return ok
    }

    func readTailscale() {
        let ip = Core.tailscale(["ip", "-4"]).split(separator: "\n").first.map(String.init) ?? ""
        let st = Core.tailscale(["status", "--json"])
        var host = ""
        if let d = st.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let me = j["Self"] as? [String: Any], let h = me["HostName"] as? String { host = h }
        lock.lock()
        tsIP = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        if !host.isEmpty { localMachine = host }
        lock.unlock()
    }
}
