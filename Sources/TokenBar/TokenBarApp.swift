import AppKit
import SwiftUI
import TokenBarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct TokenBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(store)
        } label: {
            Text(store.menuTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
