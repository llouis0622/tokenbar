import Foundation

public struct HTTPResult: Sendable {
    public let status: Int
    public let data: Data
    public let retryAfter: TimeInterval?

    public init(status: Int, data: Data, retryAfter: TimeInterval? = nil) {
        self.status = status
        self.data = data
        self.retryAfter = retryAfter
    }
}

public protocol HTTPClient: Sendable {
    func get(url: URL, headers: [String: String]) async throws -> HTTPResult
}

final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let carriesToken = task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil
        if !carriesToken, let target = request.url, URLSessionHTTPClient.isAllowed(target) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let allowedHosts: Set<String> = [
        "api.anthropic.com",
        "chatgpt.com",
        "raw.githubusercontent.com",
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]
    public static let maxResponseBytes = 16 * 1024 * 1024

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host) && url.user == nil && url.password == nil
    }

    public func get(url: URL, headers: [String: String]) async throws -> HTTPResult {
        guard Self.isAllowed(url) else { throw LimitError.badResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, body.count <= Self.maxResponseBytes else {
            throw LimitError.badResponse
        }
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0) }
        return HTTPResult(status: http.statusCode, data: body, retryAfter: retryAfter)
    }
}

public enum LimitError: Error, Equatable {
    case noCredentials(Provider)
    case tokenExpired(Provider)
    case unauthorized(Provider)
    case rateLimited(TimeInterval?)
    case http(Int)
    case badResponse

    public var message: String {
        switch self {
        case .noCredentials(.claude):
            return "Claude Code 로그인 정보를 찾지 못했습니다. 터미널에서 claude 실행 후 /login 하세요."
        case .noCredentials(.codex):
            return "Codex 로그인 정보를 찾지 못했습니다. 터미널에서 codex login 하세요."
        case .tokenExpired(.claude), .unauthorized(.claude):
            return "토큰이 만료되었습니다. Claude Code를 한 번 실행하면 갱신됩니다."
        case .tokenExpired(.codex), .unauthorized(.codex):
            return "토큰이 만료되었습니다. Codex CLI를 한 번 실행하면 갱신됩니다."
        case .rateLimited:
            return "조회 한도에 걸려 잠시 후 다시 시도합니다."
        case .http(let status):
            return "서버 응답 오류 (HTTP \(status))"
        case .badResponse:
            return "응답 형식을 해석하지 못했습니다."
        }
    }

    static func check(_ result: HTTPResult, provider: Provider) throws {
        switch result.status {
        case 200..<300: return
        case 401, 403: throw LimitError.unauthorized(provider)
        case 429: throw LimitError.rateLimited(result.retryAfter)
        default: throw LimitError.http(result.status)
        }
    }
}

enum SecureFile {
    static func prepareDirectory(_ url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func write(_ content: Data, to url: URL) {
        do {
            try content.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return
        }
    }
}
