import CryptoKit
import Foundation

public enum UpdateState: Error, Equatable, Sendable {
    case unknown
    case checking
    case upToDate
    case available(String)
    case updating
    case installed
    case unavailable(String)
    case failed(String)
}

public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let archive: URL
    public let checksum: URL?
    public let digest: String?
}

public actor Updater {
    public static let repository = "llouis0622/tokenbar"
    public static let bundleIdentifier = "io.github.llouis0622.tokenbar"
    public static let latestRelease = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let archiveName = "TokenBar.zip"
    static let checksumName = "TokenBar.zip.sha256"

    private let currentVersion: String
    private let bundleURL: URL
    private let client: HTTPClient
    private var installing = false

    public init(currentVersion: String, bundleURL: URL, client: HTTPClient = URLSessionHTTPClient()) {
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        self.client = client
    }

    public static func components(_ version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let left = components(candidate), let right = components(current) else { return false }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    public static func hexDigest(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        if value.hasPrefix("sha256:") { value.removeFirst(7) }
        let head = String(value.prefix(64))
        guard head.count == 64, head.allSatisfy({ $0.isHexDigit }) else { return nil }
        return head
    }

    public static func parseRelease(_ body: Data) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let numbers = components(tag),
              root["draft"] as? Bool != true,
              root["prerelease"] as? Bool != true,
              let assets = root["assets"] as? [[String: Any]]
        else { return nil }
        var archive: URL?
        var checksum: URL?
        var digest: String?
        for asset in assets {
            guard let name = asset["name"] as? String,
                  let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  URLSessionHTTPClient.isAllowed(link)
            else { continue }
            if name == archiveName {
                archive = link
                digest = hexDigest(asset["digest"] as? String)
            } else if name == checksumName {
                checksum = link
            }
        }
        guard let archive, checksum != nil || digest != nil else { return nil }
        let version = numbers.map(String.init).joined(separator: ".")
        return ReleaseInfo(version: version, archive: archive, checksum: checksum, digest: digest)
    }

    private func latest() async -> Result<ReleaseInfo, UpdateState> {
        let headers = ["Accept": "application/vnd.github+json", "User-Agent": "TokenBar"]
        guard let result = try? await client.get(url: Self.latestRelease, headers: headers) else {
            return .failure(.unavailable("업데이트 서버에 연결하지 못했습니다."))
        }
        if result.status == 404 { return .failure(.upToDate) }
        guard result.status == 200, let release = Self.parseRelease(result.data) else {
            return .failure(.unavailable("릴리스 정보를 읽지 못했습니다. (HTTP \(result.status))"))
        }
        return .success(release)
    }

    public func check() async -> UpdateState {
        if installing { return .updating }
        switch await latest() {
        case .failure(let state): return state
        case .success(let release):
            return Self.isNewer(release.version, than: currentVersion) ? .available(release.version) : .upToDate
        }
    }

    public func install() async -> UpdateState {
        if installing { return .updating }
        installing = true
        defer { installing = false }
        guard bundleURL.lastPathComponent == "TokenBar.app", !bundleURL.path.contains("/AppTranslocation/") else {
            return .unavailable("응용 프로그램 폴더에 설치된 TokenBar.app에서만 업데이트할 수 있습니다.")
        }
        let release: ReleaseInfo
        switch await latest() {
        case .failure(let state): return state
        case .success(let found): release = found
        }
        guard Self.isNewer(release.version, than: currentVersion) else { return .upToDate }
        let binaryHeaders = ["Accept": "application/octet-stream", "User-Agent": "TokenBar"]
        guard let archive = try? await client.get(url: release.archive, headers: binaryHeaders), archive.status == 200 else {
            return .failed("새 버전을 내려받지 못했습니다.")
        }
        var expected = release.digest
        if expected == nil, let link = release.checksum,
           let sidecar = try? await client.get(url: link, headers: binaryHeaders), sidecar.status == 200 {
            expected = Self.hexDigest(String(decoding: sidecar.data.prefix(256), as: UTF8.self))
        }
        let actual = SHA256.hash(data: archive.data).map { String(format: "%02x", $0) }.joined()
        guard let expected, expected == actual else {
            return .failed("내려받은 파일의 체크섬이 일치하지 않아 설치하지 않았습니다.")
        }
        return Self.replaceBundle(at: bundleURL, with: archive.data, release: release)
    }

    static func replaceBundle(at bundleURL: URL, with archive: Data, release: ReleaseInfo) -> UpdateState {
        let manager = FileManager.default
        guard let staging = try? manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundleURL, create: true) else {
            return .failed("임시 폴더를 만들지 못했습니다.")
        }
        defer { try? manager.removeItem(at: staging) }
        let zip = staging.appendingPathComponent(archiveName)
        let unpacked = staging.appendingPathComponent("unpacked")
        do {
            try archive.write(to: zip, options: .atomic)
        } catch {
            return .failed("내려받은 파일을 저장하지 못했습니다.")
        }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path], timeout: 60).status == 0 else {
            return .failed("압축을 풀지 못했습니다.")
        }
        let fresh = unpacked.appendingPathComponent("TokenBar.app")
        guard let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String,
              components(version) == components(release.version),
              manager.isExecutableFile(atPath: fresh.appendingPathComponent("Contents/MacOS/TokenBar").path)
        else {
            return .failed("내려받은 앱이 TokenBar \(release.version)이 아니어서 설치하지 않았습니다.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--strict", "--deep", fresh.path], timeout: 60).status == 0 else {
            return .failed("내려받은 앱의 코드 서명이 손상되어 설치하지 않았습니다.")
        }
        do {
            _ = try manager.replaceItemAt(bundleURL, withItemAt: fresh)
        } catch {
            return .failed("앱을 교체하지 못했습니다. 응용 프로그램 폴더 쓰기 권한을 확인하세요.")
        }
        return .installed
    }

    public static func relaunch(_ bundleURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sleep 1; /usr/bin/open \"$1\"", "sh", bundleURL.path]
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func environment() -> [String: String] {
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
