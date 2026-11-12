import Foundation

public enum UpdateState: Error, Equatable, Sendable {
    case unknown
    case checking
    case upToDate
    case available(Int)
    case updating
    case unavailable(String)
    case failed(String)
}

public actor Updater {
    public static let trustedRemotes: Set<String> = [
        "https://github.com/llouis0622/tokenbar",
        "git@github.com:llouis0622/tokenbar",
        "ssh://git@github.com/llouis0622/tokenbar",
    ]

    private static let git = "/usr/bin/git"
    private static let toolPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    private let sourceDir: String?
    private let installedCommit: String?
    private let logFile: URL
    private var running: Process?
    private var lastExit: Int32?

    public init(sourceDir: String?, installedCommit: String?, logFile: URL) {
        self.sourceDir = sourceDir
        self.installedCommit = installedCommit
        self.logFile = logFile
    }

    public static func normalize(remote: String) -> String {
        var value = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        return value
    }

    public static func isTrusted(remote: String) -> Bool {
        trustedRemotes.contains(normalize(remote: remote))
    }

    public static func isCommit(_ text: String?) -> Bool {
        guard let text, text.count == 40 else { return false }
        return text.allSatisfy { $0.isHexDigit }
    }

    private func validatedSource() -> Result<String, UpdateState> {
        guard let sourceDir, sourceDir.hasPrefix("/") else {
            return .failure(.unavailable("소스 폴더 정보가 없습니다. 터미널에서 ./build-app.sh --install 로 다시 설치하세요."))
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceDir + "/.git"), manager.fileExists(atPath: sourceDir + "/build-app.sh") else {
            return .failure(.unavailable("소스 폴더를 찾을 수 없습니다: \(sourceDir)"))
        }
        let remote = Self.run(Self.git, ["-C", sourceDir, "remote", "get-url", "origin"], timeout: 10)
        guard remote.status == 0, Self.isTrusted(remote: remote.output) else {
            return .failure(.unavailable("소스 폴더의 원격 저장소가 llouis0622/tokenbar 가 아니어서 업데이트하지 않습니다."))
        }
        return .success(sourceDir)
    }

    public func check() -> UpdateState {
        if let running, running.isRunning { return .updating }
        if let lastExit, lastExit != 0 {
            return .failed("업데이트 실패 (코드 \(lastExit)). 로그: \(logFile.path)")
        }
        let source: String
        switch validatedSource() {
        case .success(let path): source = path
        case .failure(let state): return state
        }
        let fetch = Self.run(Self.git, ["-C", source, "fetch", "--quiet", "origin", "main"], timeout: 30)
        guard fetch.status == 0 else {
            return .unavailable("원격 저장소를 확인하지 못했습니다. 네트워크 또는 Git 인증을 확인하세요.")
        }
        let remote = Self.run(Self.git, ["-C", source, "rev-parse", "origin/main"], timeout: 10)
        let latest = remote.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.status == 0, Self.isCommit(latest) else {
            return .unavailable("원격 버전을 읽지 못했습니다.")
        }
        guard let installedCommit, Self.isCommit(installedCommit) else { return .available(1) }
        if installedCommit == latest { return .upToDate }
        let behind = Self.run(Self.git, ["-C", source, "rev-list", "--count", "\(installedCommit)..\(latest)"], timeout: 10)
        let count = Int(behind.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        return count > 0 ? .available(count) : .upToDate
    }

    public func apply() -> UpdateState {
        if let running, running.isRunning { return .updating }
        let source: String
        switch validatedSource() {
        case .success(let path): source = path
        case .failure(let state): return state
        }
        FileManager.default.createFile(atPath: logFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        guard let log = try? FileHandle(forWritingTo: logFile) else {
            return .failed("로그 파일을 만들지 못했습니다.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [source + "/build-app.sh", "--update"]
        process.currentDirectoryURL = URL(fileURLWithPath: source)
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.finish(status) }
        }
        do {
            try process.run()
        } catch {
            return .failed("업데이트를 시작하지 못했습니다.")
        }
        lastExit = nil
        running = process
        return .updating
    }

    private func finish(_ status: Int32) {
        running = nil
        lastExit = status
    }

    private static func environment() -> [String: String] {
        [
            "PATH": toolPath,
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "LANG": "en_US.UTF-8",
            "GIT_TERMINAL_PROMPT": "0",
        ]
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
