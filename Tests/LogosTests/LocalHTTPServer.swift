import Foundation
import Network

/// An HTTP server on 127.0.0.1, at a port the system picks, for tests that
/// need a real HTTP exchange without the internet. It answers every request
/// with what `respond` returns for that request's number, counting from 1, and
/// closes the connection after each answer.
final class LocalHTTPServer {
    typealias Response = (headers: [String: String], body: String)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let respond: (Int) -> Response
    private var count = 0

    init(respond: @escaping (Int) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.respond = respond
    }

    /// The server's root, such as http://127.0.0.1:52814, once it has started.
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)")! }

    /// How many requests the server has answered.
    var requests: Int { queue.sync { count } }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(on: connection, buffer: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    /// Reads until the end of the request's headers, then answers. The tests
    /// send only GET requests, which have no body.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else { return connection.cancel() }
            let buffer = buffer + (data ?? Data())
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.answer(on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func answer(on connection: NWConnection) {
        count += 1
        let response = respond(count)
        let body = Data(response.body.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        let headers = response.headers.merging([
            "Content-Type": "application/json",
            "Content-Length": "\(body.count)",
            "Date": Self.httpDate.string(from: Date()),
            "Connection": "close",
        ]) { mine, _ in mine }
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
}
