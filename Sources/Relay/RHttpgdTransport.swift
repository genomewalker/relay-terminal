import Foundation

/// Device state as served by httpgd's `/state`, `/plots`, `/remove` and `/clear`
/// routes (httpgd 2.1.x): `upid` is an update counter, not an identity.
struct RHttpgdState: Decodable, Sendable, Equatable {
    let upid: Int
    let hsize: Int
    let active: Bool
}

struct RHttpgdPlotList: Sendable, Equatable {
    let state: RHttpgdState
    let ids: [String]
}

/// Relay only ever talks to 127.0.0.1: either the local R process or the
/// local endpoint of its Relay-native bridge to the R host's loopback.
struct RHttpgdEndpoint: Sendable, Equatable {
    let port: UInt16
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var socketURL: URL { URL(string: "ws://127.0.0.1:\(port)/")! }
}

enum RHttpgdError: LocalizedError, Equatable {
    case unauthorized
    case unreachable(String)
    case redirected
    case oversized(Int)
    case invalidResponse(String)
    case tunnel(String)
    case unknownPlot

    var errorDescription: String? {
        switch self {
        case .unauthorized: "httpgd rejected Relay's token. The descriptor is stale or another server took the port; start httpgd again."
        case .unreachable(let detail): "httpgd is not reachable: \(detail)"
        case .redirected: "httpgd endpoint attempted a redirect; refused"
        case .oversized(let limit): "httpgd response exceeds \(limit / 1024) KiB; refused"
        case .invalidResponse(let detail): "Unexpected httpgd response: \(detail)"
        case .tunnel(let detail): "Native forwarding failed: \(detail)"
        case .unknownPlot: "That plot is no longer in httpgd's history"
        }
    }
}

protocol RHttpgdAPI: Sendable {
    func state() async throws -> RHttpgdState
    func plots(limit: Int) async throws -> RHttpgdPlotList
    func render(id: String, width: Int, height: Int, zoom: Double) async throws -> Data
    func remove(id: String) async throws -> RHttpgdState
    func clear() async throws -> RHttpgdState
    /// Change notifications only; httpgd's socket route is unauthenticated and
    /// echoes client messages, so nothing received here is trusted.
    func makeWebSocket() -> URLSessionWebSocketTask?
    func invalidate()
}

enum RHttpgdLimits {
    static let stateBytes = 4 * 1024
    static let listBytes = 256 * 1024
    static let renderBytes = 8 << 20
    static let historyEntries = 200
    static let minimumDimension = 100
    static let maximumDimension = 4000
    static let plotIDPattern = "^-?[0-9]{1,10}$"
}

/// Authenticated HTTP reads over the loopback endpoint. Redirects are refused,
/// bodies are bounded, and the token travels only as a header, never in URLs.
final class RHttpgdClient: RHttpgdAPI, @unchecked Sendable {
    let endpoint: RHttpgdEndpoint
    private let token: String
    private let session: URLSession

    init(endpoint: RHttpgdEndpoint, token: String) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: RHttpgdRedirectRefusal(), delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    private func request(_ path: String, _ query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-HTTPGD-TOKEN")
        request.setValue("close", forHTTPHeaderField: "Connection")
        return request
    }

    private func fetch(_ path: String, _ query: [URLQueryItem] = [], limit: Int, mime: String) async throws -> Data {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request(path, query)) }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw RHttpgdError.unreachable(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw RHttpgdError.invalidResponse("not HTTP") }
        guard http.url?.host == "127.0.0.1", http.url?.port == Int(endpoint.port) else { throw RHttpgdError.redirected }
        switch http.statusCode {
        case 200: break
        case 401: throw RHttpgdError.unauthorized
        case 300...399: throw RHttpgdError.redirected
        case 404: throw RHttpgdError.unknownPlot
        default: throw RHttpgdError.invalidResponse("HTTP \(http.statusCode)")
        }
        guard http.expectedContentLength <= Int64(limit) else { throw RHttpgdError.oversized(limit) }
        guard (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().hasPrefix(mime) else {
            throw RHttpgdError.invalidResponse("content type")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw RHttpgdError.oversized(limit) }
        }
        return data
    }

    private func decodeState(_ data: Data) throws -> RHttpgdState {
        do { return try JSONDecoder().decode(RHttpgdState.self, from: data) }
        catch { throw RHttpgdError.invalidResponse("state") }
    }

    func state() async throws -> RHttpgdState { try await stateAt(path: "/state") }

    /// Bounded JSON state read; tests point it at hostile routes.
    func stateAt(path: String) async throws -> RHttpgdState {
        try decodeState(try await fetch(path, limit: RHttpgdLimits.stateBytes, mime: "application/json"))
    }

    func plots(limit: Int) async throws -> RHttpgdPlotList {
        let bounded = min(max(limit, 1), RHttpgdLimits.historyEntries)
        let data = try await fetch("/plots", [URLQueryItem(name: "index", value: "0"), URLQueryItem(name: "limit", value: String(bounded))],
                                   limit: RHttpgdLimits.listBytes, mime: "application/json")
        struct Listing: Decodable { struct Entry: Decodable { let id: String }; let state: RHttpgdState; let plots: [Entry] }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing.plots.count <= bounded,
              listing.plots.allSatisfy({ $0.id.range(of: RHttpgdLimits.plotIDPattern, options: .regularExpression) != nil }),
              Set(listing.plots.map(\.id)).count == listing.plots.count else {
            throw RHttpgdError.invalidResponse("plot listing")
        }
        return RHttpgdPlotList(state: listing.state, ids: listing.plots.map(\.id))
    }

    /// Callers must pass an id from a fresh listing: httpgd renders the newest
    /// plot for unknown ids instead of failing.
    func render(id: String, width: Int, height: Int, zoom: Double) async throws -> Data {
        guard id.range(of: RHttpgdLimits.plotIDPattern, options: .regularExpression) != nil else { throw RHttpgdError.unknownPlot }
        let clampedWidth = min(max(width, RHttpgdLimits.minimumDimension), RHttpgdLimits.maximumDimension)
        let clampedHeight = min(max(height, RHttpgdLimits.minimumDimension), RHttpgdLimits.maximumDimension)
        let clampedZoom = min(max(zoom, 0.5), 3)
        let data = try await fetch("/plot", [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "width", value: String(clampedWidth)),
            URLQueryItem(name: "height", value: String(clampedHeight)),
            URLQueryItem(name: "zoom", value: String(format: "%.2f", clampedZoom)),
            URLQueryItem(name: "renderer", value: "png"),
        ], limit: RHttpgdLimits.renderBytes, mime: "image/png")
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { throw RHttpgdError.invalidResponse("not a PNG") }
        return data
    }

    func remove(id: String) async throws -> RHttpgdState {
        guard id.range(of: RHttpgdLimits.plotIDPattern, options: .regularExpression) != nil else { throw RHttpgdError.unknownPlot }
        return try decodeState(try await fetch("/remove", [URLQueryItem(name: "id", value: id)], limit: RHttpgdLimits.stateBytes, mime: "application/json"))
    }

    func clear() async throws -> RHttpgdState {
        try decodeState(try await fetch("/clear", limit: RHttpgdLimits.stateBytes, mime: "application/json"))
    }

    func makeWebSocket() -> URLSessionWebSocketTask? {
        var request = URLRequest(url: endpoint.socketURL)
        request.timeoutInterval = 20
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024
        return task
    }
}

private final class RHttpgdRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
