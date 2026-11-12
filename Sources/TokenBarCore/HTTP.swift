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

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func get(url: URL, headers: [String: String]) async throws -> HTTPResult {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (body, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
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
