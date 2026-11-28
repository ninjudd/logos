import Foundation

/// A fake OpenAI-compatible transcription API for tests, reached through
/// URLSession.shared at a host of its own, so tests that run at once don't
/// share one. Each request's `response_format` goes to `respond`, which
/// returns an HTTP status and a JSON body.
final class StubTranscriptionAPI {
    typealias Respond = (_ format: String) -> (status: Int, body: String)

    let host = "\(UUID().uuidString.lowercased()).logos-test.invalid"
    var baseURL: String { "https://\(host)/v1" }

    init(respond: @escaping Respond) {
        StubProtocol.register(host: host, respond: respond)
    }

    deinit { StubProtocol.unregister(host: host) }

    /// The `response_format` of each request, in order.
    var formats: [String] { StubProtocol.formats(host: host) }
}

private final class StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responders: [String: StubTranscriptionAPI.Respond] = [:]
    private static var seen: [String: [String]] = [:]
    private static let registered: Void = { URLProtocol.registerClass(StubProtocol.self) }()

    static func register(host: String, respond: @escaping StubTranscriptionAPI.Respond) {
        _ = registered
        lock.withLock { responders[host] = respond }
    }

    static func unregister(host: String) {
        lock.withLock {
            responders[host] = nil
            seen[host] = nil
        }
    }

    static func formats(host: String) -> [String] { lock.withLock { seen[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { responders[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let format = Self.field("response_format", in: Self.body(of: request)) ?? ""
        let respond = Self.lock.withLock { () -> StubTranscriptionAPI.Respond? in
            Self.seen[host, default: []].append(format)
            return Self.responders[host]
        }
        let (status, body) = respond?(format) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands a protocol the body as a stream.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// The value of a multipart form's text field `name`.
    private static func field(_ name: String, in body: Data) -> String? {
        let marker = Data("name=\"\(name)\"\r\n\r\n".utf8)
        guard let start = body.range(of: marker)?.upperBound,
              let end = body.range(of: Data("\r\n".utf8), in: start..<body.endIndex)?.lowerBound else { return nil }
        return String(data: body[start..<end], encoding: .utf8)
    }
}
