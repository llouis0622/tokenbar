import AppKit
import Foundation
import ServiceManagement
import TokenBarCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var limits: [Provider: LimitResult] = [:]
    @Published private(set) var costs: CostReport?
    @Published private(set) var system: SystemSample?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var update: UpdateState = .unknown
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var onChange: (() -> Void)?

    let version: String
    private let engine = UsageEngine()
    private let monitor = SystemMonitor()
    private let updater: Updater
    private var menuVisible = false
    private var lastUpdateCheck: Date?
    private var lastCostRefresh: Date?
    private var refreshingCosts = false

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let number = info["CFBundleShortVersionString"] as? String ?? "0"
        version = "v\(number)"
        updater = Updater(currentVersion: number, bundleURL: Bundle.main.bundleURL)
    }

    var barCells: [[BarCell]] {
        [
            [
                BarCell(label: "C", value: limitText(.claude), widest: "100%"),
                BarCell(label: "G", value: limitText(.codex), widest: "100%"),
            ],
            [
                BarCell(label: "CPU", value: percentText(system?.cpu), widest: "100%"),
                BarCell(label: "GPU", value: percentText(system?.gpu), widest: "100%"),
            ],
            [
                BarCell(label: "RAM", value: percentText(system?.memoryPercent), widest: "100%"),
                BarCell(label: "DSK", value: percentText(system?.diskPercent), widest: "100%"),
            ],
            [
                BarCell(label: "↑", value: Format.rate(system?.upload ?? 0), widest: "999M"),
                BarCell(label: "↓", value: Format.rate(system?.download ?? 0), widest: "999M"),
            ],
        ]
    }

    private func limitText(_ provider: Provider) -> String {
        percentText(limits[provider]?.snapshot?.primary?.usedPercent)
    }

    private func percentText(_ value: Double?) -> String {
        value.map { Format.percent($0) } ?? "–"
    }

    func menuOpened() {
        menuVisible = true
        Task {
            await sampleSystem()
            await refreshLimits()
            await refreshCosts(force: false)
            await checkForUpdate(force: false)
        }
    }

    func menuClosed() {
        menuVisible = false
    }

    func sampleSystem() async {
        let sample = await monitor.sample(includeTemperatures: menuVisible)
        guard sample != system else { return }
        system = sample
        onChange?()
    }

    func refreshLimits() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        limits = await engine.limits()
        lastRefresh = Date()
        isRefreshing = false
        onChange?()
    }

    func refreshCosts(force: Bool) async {
        guard !refreshingCosts else { return }
        if !force, let last = lastCostRefresh, Date().timeIntervalSince(last) < 60 { return }
        refreshingCosts = true
        let engine = self.engine
        costs = await Task.detached(priority: .utility) {
            await engine.costs()
        }.value
        lastCostRefresh = Date()
        refreshingCosts = false
    }

    func refreshAll() async {
        await refreshLimits()
        await refreshCosts(force: true)
    }

    func checkForUpdate(force: Bool) async {
        if case .updating = update { return }
        if !force, let last = lastUpdateCheck, Date().timeIntervalSince(last) < 6 * 3_600 { return }
        lastUpdateCheck = Date()
        if force { update = .checking }
        let updater = self.updater
        update = await Task.detached(priority: .utility) {
            await updater.check()
        }.value
    }

    func applyUpdate() async {
        if case .updating = update { return }
        update = .updating
        let updater = self.updater
        let result = await Task.detached(priority: .utility) {
            await updater.install()
        }.value
        update = result
        if case .installed = result {
            Updater.relaunch(Bundle.main.bundleURL)
            NSApp.terminate(nil)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
