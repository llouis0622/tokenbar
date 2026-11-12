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
    @Published private(set) var fanHelperReady = false
    @Published private(set) var fanTargets: [Int: Int] = [:]
    @Published private(set) var fanBusy = false
    @Published private(set) var fanNotice: String?

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
        if let saved = UserDefaults.standard.dictionary(forKey: Self.fanTargetsKey) as? [String: Int] {
            for (key, rpm) in saved {
                if let index = Int(key) { fanTargets[index] = rpm }
            }
        }
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
            await refreshFanHelper()
            await refreshCosts(force: false)
            await checkForUpdate(force: false)
        }
    }

    func menuClosed() {
        menuVisible = false
    }

    func sampleSystem() async {
        let guarding = !fanTargets.isEmpty
        let sample = await monitor.sample(includeTemperatures: menuVisible || guarding, includeFans: menuVisible)
        if guarding {
            if let temperature = sample.cpuTemperature {
                if temperature >= FanHelper.safetyTemperature {
                    await releaseFans(notice: "CPU 온도가 \(Int(FanHelper.safetyTemperature))°를 넘어 팬을 자동 모드로 되돌렸습니다.")
                }
            } else if fanNotice == nil {
                fanNotice = "온도를 읽지 못해 과열 시 자동 복귀가 동작하지 않습니다."
            }
        }
        guard sample != system else { return }
        system = sample
        onChange?()
    }

    private static let fanTargetsKey = "fanTargets"

    private func saveFanTargets() {
        var stored: [String: Int] = [:]
        for (index, rpm) in fanTargets {
            stored[String(index)] = rpm
        }
        UserDefaults.standard.set(stored, forKey: Self.fanTargetsKey)
    }

    func refreshFanHelper() async {
        fanHelperReady = await Task.detached(priority: .utility) { FanHelper.isReady() }.value
    }

    func installFanHelper() async {
        guard !fanBusy else { return }
        fanBusy = true
        let bundle = Bundle.main.bundleURL
        fanHelperReady = await Task.detached(priority: .userInitiated) { FanHelper.install(bundle: bundle) }.value
        fanNotice = fanHelperReady ? nil : "헬퍼를 설치하지 못했습니다."
        fanBusy = false
    }

    func removeFanHelper() async {
        guard !fanBusy else { return }
        fanBusy = true
        let bundle = Bundle.main.bundleURL
        let removed = await Task.detached(priority: .userInitiated) { FanHelper.uninstall(bundle: bundle) }.value
        if removed {
            fanHelperReady = false
            fanTargets = [:]
            saveFanTargets()
            fanNotice = nil
        } else {
            fanNotice = "헬퍼를 제거하지 못했습니다."
        }
        fanBusy = false
        await sampleSystem()
    }

    func setFan(_ index: Int, rpm: Int?) async {
        guard fanHelperReady, !fanBusy else { return }
        fanBusy = true
        let succeeded: Bool
        if let rpm {
            succeeded = await Task.detached(priority: .userInitiated) { FanHelper.setManual(fan: index, rpm: rpm) }.value
            if succeeded { fanTargets[index] = rpm }
        } else {
            succeeded = await Task.detached(priority: .userInitiated) { FanHelper.setAuto(fan: index) }.value
            if succeeded { fanTargets[index] = nil }
        }
        fanNotice = succeeded ? nil : "팬 설정을 적용하지 못했습니다. 이 Mac에서는 지원되지 않을 수 있습니다."
        saveFanTargets()
        fanBusy = false
        await sampleSystem()
    }

    func reapplyFans() async {
        await refreshFanHelper()
        guard fanHelperReady, !fanTargets.isEmpty, !fanBusy else { return }
        fanBusy = true
        let targets = fanTargets
        await Task.detached(priority: .utility) {
            for (index, rpm) in targets {
                _ = FanHelper.setManual(fan: index, rpm: rpm)
            }
        }.value
        fanBusy = false
    }

    private func releaseFans(notice: String?) async {
        fanTargets = [:]
        saveFanTargets()
        fanNotice = notice
        _ = await Task.detached(priority: .userInitiated) { FanHelper.setAuto(fan: nil) }.value
    }

    func shutdown() {
        guard fanHelperReady, !fanTargets.isEmpty else { return }
        _ = FanHelper.setAuto(fan: nil)
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
            shutdown()
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
