import Foundation

public enum Format {
    public static func tokens(_ count: Int) -> String {
        let value = Double(count)
        if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return "\(count)"
    }

    public static func usd(_ value: Double) -> String {
        value >= 100 ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "리셋됨" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)일 \(hours)시간 후 리셋" }
        if hours > 0 { return "\(hours)시간 \(minutes)분 후 리셋" }
        return "\(max(minutes, 1))분 후 리셋"
    }

    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "방금" }
        if seconds < 3_600 { return "\(seconds / 60)분 전" }
        if seconds < 86_400 { return "\(seconds / 3_600)시간 전" }
        return "\(seconds / 86_400)일 전"
    }

    public static func windowLabel(seconds: Int) -> String {
        if seconds <= 0 { return "한도" }
        if seconds == 604_800 { return "주간" }
        if seconds % 86_400 == 0 { return "\(seconds / 86_400)일" }
        let hours = Int((Double(seconds) / 3_600).rounded())
        return "\(max(hours, 1))시간"
    }
}

public enum DateParsing {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ text: String) -> Date? {
        var trimmed = text
        if let dot = trimmed.firstIndex(of: ".") {
            var end = trimmed.index(after: dot)
            while end < trimmed.endIndex, trimmed[end].isNumber {
                end = trimmed.index(after: end)
            }
            trimmed.removeSubrange(dot..<end)
        }
        return formatter.date(from: trimmed)
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        (self[key] as? NSNumber)?.intValue ?? 0
    }

    func double(_ key: String) -> Double? {
        if let number = self[key] as? NSNumber { return number.doubleValue }
        if let text = self[key] as? String { return Double(text) }
        return nil
    }

    func dict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }
}
