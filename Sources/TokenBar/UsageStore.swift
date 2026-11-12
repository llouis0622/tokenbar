import AppKit
import Foundation
import ServiceManagement
import TokenBarCore

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var limits: [Provider: LimitResult] = [:]
    @Published private(set) var costs: CostReport?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    @Published private(set) var system: SystemSample?
    var menuVisible = false

    private let engine = UsageEngine()
    private let monitor = SystemMonitor()
    private var loop: Task<Void, Never>?
    private var systemLoop: Task<Void, Never>?

    init() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
        systemLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sampleSystem()
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            }
        }
    }

    func sampleSystem() async {
        system = await monitor.sample(includeTemperatures: menuVisible)
    }

    var barImage: NSImage {
        MenuBarRenderer.image(columns: [
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
        ])
    }

    private func limitText(_ provider: Provider) -> String {
        percentText(limits[provider]?.snapshot?.primary?.usedPercent)
    }

    private func percentText(_ value: Double?) -> String {
        value.map { Format.percent($0) } ?? "–"
    }

    var menuTitle: String {
        Provider.allCases.map { provider in
            if let window = limits[provider]?.snapshot?.primary {
                return "\(provider.short) \(Format.percent(window.usedPercent))"
            }
            return "\(provider.short) –"
        }.joined(separator: " · ")
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        limits = await engine.limits()
        lastRefresh = Date()
        costs = await engine.costs()
        isRefreshing = false
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TokenBar launch-at-login: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
