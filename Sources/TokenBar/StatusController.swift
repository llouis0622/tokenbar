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
    private var lastColumns: [BarColumn] = []
    private var statsImage: NSImage?
    private var slimeFrames: [NSImage] = []
    private var slimeIndex = 0
    private var slimeTimer: Timer?
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
        slimeFrames = SlimeRenderer.frames(scale: backingScale)
        renderBar()
        startTimers()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(screensDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(screensDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResumed), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionResumed), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(sessionResumed),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
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

    private var backingScale: CGFloat {
        max(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 1)
    }

    private var slimeInterval: TimeInterval {
        let load = min(max(store.system?.cpu ?? 0, 0), 100) / 100
        return 1 / (1.5 + 8.5 * load)
    }

    private func scheduleSlime() {
        slimeTimer?.invalidate()
        slimeTimer = nil
        guard !asleep, !ProcessInfo.processInfo.isLowPowerModeEnabled, !slimeFrames.isEmpty else {
            if slimeIndex != 0 {
                slimeIndex = 0
                updateButton()
            }
            return
        }
        let interval = slimeInterval
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.slimeIndex = (self.slimeIndex + 1) % self.slimeFrames.count
                self.updateButton()
                self.scheduleSlime()
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        slimeTimer = timer
    }

    private func updateButton() {
        guard let stats = statsImage else { return }
        let leading = slimeFrames.isEmpty ? nil : slimeFrames[slimeIndex % slimeFrames.count]
        statusItem.button?.image = MenuBarRenderer.compose(leading: leading, stats: stats)
    }

    private var systemInterval: TimeInterval {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 10 : 5
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
        scheduleSlime()
    }

    private func stopTimers() {
        systemTimer?.invalidate()
        limitTimer?.invalidate()
        slimeTimer?.invalidate()
        systemTimer = nil
        limitTimer = nil
        slimeTimer = nil
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
            await store.resumeFans()
        }
    }

    @objc private nonisolated func sessionResumed() {
        Task { @MainActor in
            await self.store.resumeFans()
        }
    }

    @objc private nonisolated func powerStateChanged() {
        Task { @MainActor in
            self.startTimers()
        }
    }

    private func renderBar() {
        let columns = store.barColumns
        guard columns != lastColumns else { return }
        lastColumns = columns
        statsImage = MenuBarRenderer.rasterize(MenuBarRenderer.image(columns: columns), scale: backingScale)
        updateButton()
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
