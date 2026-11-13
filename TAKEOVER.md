# SESSION HUB (Mantra): takeover

Swift macOS app, the hub where all of Marko's Claude Code sessions (Mac CLI tabs, Remote Control sessions on phones, cloud sessions) register and message each other at once. Text only. Public, unpromoted: no README, no description.

- App: `app/*.swift` (SwiftUI window + menu bar item; Core.swift state, Server.swift Network.framework HTTP + SSE). `let VERSION = n` in app/App.swift, whole numbers. Bundle community.auroville.sessionhub. Compiled only by GitHub Actions (.github/workflows/build.yml, release Latest); the Mac downloads app.zip.
- Server: port 8890, only 127.0.0.1 and the Mac's Tailscale IP (read at start, retried every 30 s). Trust: caller on 127.0.0.1, or a tailnet IP whose `tailscale whois` LoginName starts with marko.bosko@. No token.
- API: POST /register {name,sid,machine,kind,cwd}; POST /beat {sid}; GET /who; POST /send {from,to,text,id} (to = name, base name before " (", sid prefix, or all; "marko" reaches the window); GET /inbox?sid=&since=; GET /watch?sid= (SSE). Offline = no beat for 90 s and no open watch. Queued messages are delivered once when the target returns. A local mac-cli target with no watch open gets the line typed into its iTerm tab through other_sessions.py type.
- State and log: ~/Library/Application Support/Session Hub/ (state.json, log.jsonl).
- CLI: cli/hub (Python 3, stdlib only), installed to ~/.local/bin/hub. SOCKS5 through ALL_PROXY for cloud sessions.
- Env HUB_HEADLESS=1: no window, no focus (tests).
- Phase 2 ideas: Remote Control sessions on phones registering themselves, unread marks, notifications.
