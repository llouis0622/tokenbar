import AppKit
import SwiftUI
import TokenBarCore

@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = UsageStore()
    private let popover = NSPopover()
    private var systemTimer: Timer?
    private var limitTimer: Timer?
    private var lastCells: [[BarCell]] = []
    private var asleep = false

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }
        store.onChange = { [weak self] in
            self?.renderBar()
        }
        renderBar()
        startTimers()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        Task {
            await store.sampleSystem()
            await store.refreshLimits()
            await store.checkForUpdate(force: false)
            await store.reapplyFans()
        }
    }

    private var systemInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 5 : 2
    }

    private func startTimers() {
        stopTimers()
        guard !asleep else { return }
        let system = Timer(timeInterval: systemInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.sampleSystem()
            }
        }
        system.tolerance = systemInterval * 0.25
        RunLoop.main.add(system, forMode: .common)
        systemTimer = system
        let limits = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.store.refreshLimits()
                await self?.store.checkForUpdate(force: false)
            }
        }
        limits.tolerance = 60
        RunLoop.main.add(limits, forMode: .common)
        limitTimer = limits
    }

    private func stopTimers() {
        systemTimer?.invalidate()
        limitTimer?.invalidate()
        systemTimer = nil
        limitTimer = nil
    }

    @objc private func screensDidSleep() {
        asleep = true
        stopTimers()
    }

    @objc private func screensDidWake() {
        asleep = false
        startTimers()
        Task {
            await store.sampleSystem()
            await store.refreshLimits()
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            await store.reapplyFans()
        }
    }

    @objc private nonisolated func powerStateChanged() {
        Task { @MainActor in
            self.startTimers()
        }
    }

    private func renderBar() {
        let cells = store.barCells
        guard cells != lastCells else { return }
        lastCells = cells
        statusItem.button?.image = MenuBarRenderer.image(columns: cells)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let host = NSHostingController(rootView: MenuView().environmentObject(store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        store.menuOpened()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        store.menuClosed()
    }
}
