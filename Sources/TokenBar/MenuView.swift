import AppKit
import SwiftUI
import TokenBarCore

struct MenuView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Provider.allCases, id: \.self) { provider in
                ProviderSection(provider: provider, result: store.limits[provider])
            }
            Divider()
            SystemSection(sample: store.system)
            Divider()
            CostSection(report: store.costs)
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            UpdateRow(state: store.update, version: store.version)
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("새로고침") {
                    Task { await store.refreshAll() }
                }
                .disabled(store.isRefreshing)
                Button("종료") {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
        }
    }

    private var statusText: String {
        if store.isRefreshing { return "갱신 중…" }
        if let last = store.lastRefresh { return "갱신 \(Format.ago(last))" }
        return ""
    }
}

struct UpdateRow: View {
    @EnvironmentObject private var store: UsageStore
    let state: UpdateState
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if canApply {
                    Button("업데이트") {
                        Task { await store.applyUpdate() }
                    }
                } else if canCheck {
                    Button("업데이트 확인") {
                        Task { await store.checkForUpdate(force: true) }
                    }
                }
            }
            .controlSize(.small)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: String {
        switch state {
        case .available(let count): return "\(version) · 새 변경 \(count)건"
        case .upToDate: return "\(version) · 최신"
        case .checking: return "\(version) · 확인 중…"
        case .updating: return "\(version) · 업데이트 중…"
        default: return version
        }
    }

    private var detail: String? {
        switch state {
        case .updating: return "빌드에 1분 정도 걸리고, 끝나면 자동으로 다시 시작됩니다."
        case .unavailable(let message), .failed(let message): return message
        default: return nil
        }
    }

    private var canApply: Bool {
        switch state {
        case .available, .failed: return true
        default: return false
        }
    }

    private var canCheck: Bool {
        switch state {
        case .unknown, .upToDate, .unavailable: return true
        default: return false
        }
    }
}

struct ProviderSection: View {
    let provider: Provider
    let result: LimitResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(provider.displayName)
                    .font(.headline)
                if let plan = result?.snapshot?.plan {
                    Text(plan.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = result?.snapshot, snapshot.source != .api {
                    Text(sourceText(snapshot))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let snapshot = result?.snapshot {
                ForEach(snapshot.windows, id: \.label) { window in
                    WindowRow(window: window)
                }
            } else if result == nil {
                Text("불러오는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = result?.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceText(_ snapshot: LimitSnapshot) -> String {
        let kind = snapshot.source == .localLog ? "로컬 로그" : "캐시"
        return "\(kind) · \(Format.ago(snapshot.fetchedAt))"
    }
}

struct WindowRow: View {
    let window: LimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label)
                    .font(.callout)
                Spacer()
                Text(Format.percent(window.usedPercent))
                    .font(.callout.monospacedDigit())
                    .fontWeight(.semibold)
            }
            ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                .tint(tint)
            if let resetsAt = window.resetsAt {
                Text(Format.countdown(to: resetsAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tint: Color {
        if window.usedPercent >= 90 { return .red }
        if window.usedPercent >= 70 { return .orange }
        return .primary
    }
}

struct CostSection: View {
    let report: CostReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API 환산 비용")
                .font(.headline)
            if let report {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("")
                            .gridColumnAlignment(.leading)
                        ForEach(Period.allCases, id: \.self) { period in
                            Text(period.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Provider.allCases, id: \.self) { provider in
                        GridRow {
                            Text(provider == .claude ? "Claude Code" : "Codex CLI")
                                .font(.callout)
                            ForEach(Period.allCases, id: \.self) { period in
                                Text(Format.usd(report.summary(period, provider).cost))
                                    .font(.callout.monospacedDigit())
                            }
                        }
                    }
                    GridRow {
                        Text("합계")
                            .font(.callout)
                            .fontWeight(.semibold)
                        ForEach(Period.allCases, id: \.self) { period in
                            Text(Format.usd(report.total(period).cost))
                                .font(.callout.monospacedDigit())
                                .fontWeight(.semibold)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(caption(report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("로컬 로그를 읽는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func caption(_ report: CostReport) -> String {
        var text = "오늘 \(Format.tokens(report.total(.today).tokens)) 토큰 · CLI 로컬 로그 기준"
        if report.total(.month).unpricedTokens > 0 {
            text += " · 단가 미등록 모델 제외"
        }
        return text
    }
}

struct SystemSection: View {
    let sample: SystemSample?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("시스템")
                .font(.headline)
            if let sample {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    row("CPU", percent(sample.cpu), sample.cpuTemperature.map { Format.degrees($0) } ?? "")
                    row("GPU", percent(sample.gpu), sample.gpuTemperature.map { Format.degrees($0) } ?? "")
                    row("메모리", percent(sample.memoryPercent), "\(Format.memory(sample.memoryUsed)) / \(Format.memory(sample.memoryTotal))")
                    row("디스크", percent(sample.diskPercent), sample.diskFree.map { "\(Format.gigabytes(Double($0))) 남음" } ?? "")
                    row("네트워크", "↑ \(Format.rate(sample.upload))", "↓ \(Format.rate(sample.download))")
                }
            } else {
                Text("측정 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { Format.percent($0) } ?? "–"
    }

    private func row(_ label: String, _ value: String, _ detail: String) -> some View {
        GridRow {
            Text(label)
                .font(.callout)
            Text(value)
                .font(.callout.monospacedDigit())
                .fontWeight(.semibold)
                .gridColumnAlignment(.trailing)
            Text(detail)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
