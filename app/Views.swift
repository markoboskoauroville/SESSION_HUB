import SwiftUI
import AppKit

final class Store: ObservableObject {
    static let shared = Store()
    @Published var sessions: [SessionView] = []
    @Published var msgs: [Msg] = []
    @Published var liveCount = 0
    @Published var listening = ""
    private var timer: Timer?

    init() {
        Core.shared.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        let (s, m) = Core.shared.snapshot()
        sessions = s.sorted { ($0.s.machine, $0.s.name) < ($1.s.machine, $1.s.name) }
        msgs = m
        liveCount = s.filter { $0.live && $0.s.kind != "human" }.count
        let core = Core.shared
        core.lock.lock()
        let l = core.listening.sorted()
        let p = core.port
        core.lock.unlock()
        listening = l.isEmpty ? "not listening yet" : l.map { "\($0):\(p)" }.joined(separator: "  ·  ")
    }

    func send(to: String, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        DispatchQueue.global().async {
            _ = Core.shared.send(from: "marko", to: to, text: t, id: "")
        }
    }
}

func clock(_ ts: Double) -> String {
    if ts <= 0 { return "-" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: ts)) ? "HH:mm" : "d.M. HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ts))
}

struct StepButton: View {
    let n: Int
    let title: String
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(enabled ? Color.accentColor : Color.gray, lineWidth: 1)
                        .background(Circle().fill(hover && enabled ? Color.accentColor.opacity(0.25) : Color.clear))
                    Text("\(n)").font(.system(size: 13, weight: .medium))
                }
                .frame(width: 26, height: 26)
                .scaleEffect(hover && enabled ? 1.12 : 1)
                Text(title).font(.system(size: 13, weight: .medium))
                    .underline(hover && enabled)
            }
            .foregroundStyle(enabled ? Color.primary : Color.gray)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in
            hover = h
            if h && enabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel(title)
    }
}

struct Hairline: View {
    var body: some View { Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1) }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @State private var selected: String? = nil
    @State private var draft = ""
    @State private var settings = false

    var machines: [String] { Array(Set(store.sessions.map { $0.s.machine })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Session Hub (Mantra)").font(.system(size: 14, weight: .semibold))
                Text(store.listening).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(settings ? "SESSIONS" : "SETTINGS") { settings.toggle() }.buttonStyle(.plain)
                Text("v\(VERSION)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Hairline()
            if settings {
                SettingsView().environmentObject(store)
            } else {
                HStack(spacing: 0) {
                    listPane.frame(width: 300)
                    Rectangle().fill(Color.gray.opacity(0.35)).frame(width: 1)
                    threadPane
                }
            }
        }
    }

    var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ZStack { Circle().stroke(Color.accentColor, lineWidth: 1); Text("1").font(.system(size: 13, weight: .medium)) }
                    .frame(width: 26, height: 26)
                Text("PICK A SESSION").font(.system(size: 13, weight: .medium))
            }.padding(12)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(title: "ALL SESSIONS", sub: "", dot: nil, id: "all")
                    ForEach(machines, id: \.self) { m in
                        Text(m.uppercased()).font(.system(size: 11)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(store.sessions.filter { $0.s.machine == m }) { sv in
                            row(title: sv.s.name, sub: "\(sv.s.kind)  ·  \(clock(sv.s.lastMsgAt))", dot: sv.live, id: sv.s.sid)
                        }
                    }
                }
            }
        }
    }

    func row(title: String, sub: String, dot: Bool?, id: String) -> some View {
        Button { selected = id } label: {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(dot == nil ? Color.clear : (dot! ? Color.green : Color.gray.opacity(0.5)))
                    .frame(width: 9, height: 9).padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    if !sub.isEmpty { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected == id ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    var thread: [Msg] {
        guard let s = selected else { return [] }
        if s == "all" { return store.msgs.filter { $0.from == "marko" } }
        return store.msgs.filter { $0.from == s || $0.to == s }
    }

    var selectedName: String {
        guard let s = selected else { return "" }
        if s == "all" { return "ALL SESSIONS" }
        return store.sessions.first { $0.s.sid == s }?.s.name ?? s
    }

    var threadPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selected == nil ? "THE THREAD" : selectedName).font(.system(size: 13, weight: .medium))
            }.padding(12)
            Hairline()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(thread) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(clock(m.ts))  \(m.fromName) to \(m.toName)  \(m.delivered ? "" : "(unread)")")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(m.text).font(.system(size: 13)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.id(m.seq)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: thread.count) { _, _ in
                    if let last = thread.last { proxy.scrollTo(last.seq, anchor: .bottom) }
                }
            }
            Hairline()
            HStack(spacing: 12) {
                ZStack { Circle().stroke(Color.accentColor, lineWidth: 1); Text("2").font(.system(size: 13, weight: .medium)) }
                    .frame(width: 26, height: 26)
                TextField("write as Marko", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .onSubmit { go() }
                StepButton(n: 3, title: "SEND", enabled: selected != nil && !draft.trimmingCharacters(in: .whitespaces).isEmpty) { go() }
            }.padding(12)
        }
    }

    func go() {
        guard let s = selected else { return }
        store.send(to: s, text: draft)
        draft = ""
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LISTENING").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(store.listening).font(.system(size: 13))
            Hairline()
            Text("TRUST").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("This Mac, and any tailnet machine that belongs to Marko's login. No token.").font(.system(size: 13))
            Hairline()
            Text("LOG").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("~/Library/Application Support/Session Hub/log.jsonl").font(.system(size: 13)).textSelection(.enabled)
            Spacer()
            Text("\u{00A9} 2026 Mantra Productions").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, 16)
        }
        .padding(16)
    }
}

struct MenuView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(store.sessions.filter { $0.s.kind != "human" }) { sv in
                Text("\(sv.live ? "\u{25CF}" : "\u{25CB}") \(sv.s.name)  (\(sv.s.machine))")
            }
            if store.sessions.filter({ $0.s.kind != "human" }).isEmpty { Text("No sessions registered") }
            Divider()
            Button("Open window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
