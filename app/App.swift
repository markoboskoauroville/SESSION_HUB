import SwiftUI
import AppKit

let VERSION = 2

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // headless runs (tests) show no window and take no focus
        if ProcessInfo.processInfo.environment["HUB_HEADLESS"] == "1" {
            NSApp.setActivationPolicy(.prohibited)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Server.shared.start()
        DispatchQueue.main.async {
            NSApp.windows.first?.setFrameAutosaveName("SessionHubMain")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct SessionHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared

    var body: some Scene {
        WindowGroup("Session Hub (Mantra)") {
            MainView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 480)
        }
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
            Text("\(store.liveCount)")
        }
    }
}
