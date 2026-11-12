import CSensors
import Foundation

public struct FanInfo: Equatable, Sendable, Identifiable {
    public let id: Int
    public let actual: Double
    public let minimum: Double
    public let maximum: Double
    public let target: Double
    public let mode: Int

    public var isAdjustable: Bool { maximum > minimum && minimum >= 0 }

    public func clamped(_ rpm: Int) -> Int {
        guard isAdjustable else { return rpm }
        return min(max(rpm, Int(minimum.rounded(.up))), Int(maximum.rounded(.down)))
    }

    static func readSpeeds() -> [Int] {
        var speeds: [Int] = []
        for index in 0..<Int(tb_fan_count()) {
            let rpm = tb_fan_actual(Int32(index))
            if rpm >= 0 { speeds.append(Int(rpm.rounded())) }
        }
        return speeds
    }

    static func readAll() -> [FanInfo] {
        var fans: [FanInfo] = []
        for index in 0..<Int(tb_fan_count()) {
            var raw = tb_fan_info()
            guard tb_fan_read(Int32(index), &raw) != 0 else { continue }
            fans.append(FanInfo(id: index, actual: raw.actual, minimum: raw.minimum, maximum: raw.maximum, target: raw.target, mode: Int(raw.mode)))
        }
        return fans
    }
}

public enum FanHelper {
    public static let path = "/Library/PrivilegedHelperTools/io.github.llouis0622.tokenbar.fan"
    public static let requiredVersion = 1
    public static let safetyTemperature = 90.0

    private static let appleScript = [
        "on run argv",
        "do shell script \"/bin/sh \" & quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) & \" \" & quoted form of (item 3 of argv) & \" \" & quoted form of (item 4 of argv) with administrator privileges",
        "end run",
    ]

    public static func isReady() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let result = Shell.run(path, ["version"], timeout: 5)
        guard result.status == 0, let version = Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return version >= requiredVersion
    }

    public static func setManual(fan: Int, rpm: Int) -> Bool {
        guard (0..<8).contains(fan), (0...20_000).contains(rpm) else { return false }
        return Shell.run("/usr/bin/sudo", ["-n", path, "set", String(fan), String(rpm)], timeout: 30).status == 0
    }

    public static func setAuto(fan: Int?) -> Bool {
        if let fan, !(0..<8).contains(fan) { return false }
        let target = fan.map { String($0) } ?? "all"
        return Shell.run("/usr/bin/sudo", ["-n", path, "auto", target], timeout: 15).status == 0
    }

    private static func privileged(_ action: String, bundle: URL) -> Bool {
        let script = bundle.appendingPathComponent("Contents/Resources/fan-helper.sh").path
        let source = bundle.appendingPathComponent("Contents/MacOS/tokenbar-fan").path
        guard FileManager.default.fileExists(atPath: script), FileManager.default.fileExists(atPath: source) else { return false }
        var arguments: [String] = []
        for line in appleScript {
            arguments += ["-e", line]
        }
        arguments += [script, action, source, NSUserName()]
        return Shell.run("/usr/bin/osascript", arguments, timeout: 180).status == 0
    }

    public static func install(bundle: URL) -> Bool {
        privileged("install", bundle: bundle) && isReady()
    }

    public static func uninstall(bundle: URL) -> Bool {
        privileged("uninstall", bundle: bundle) && !FileManager.default.fileExists(atPath: path)
    }
}

enum Shell {
    static func environment() -> [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"]
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let watchdog = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: raw.prefix(4_096), as: UTF8.self))
    }
}
