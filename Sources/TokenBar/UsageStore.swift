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

    private let engine = UsageEngine()
    private var loop: Task<Void, Never>?

    init() {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
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
