import Foundation
import Darwin

enum HostClientError: LocalizedError {
    case invalidURL
    case insecureURL
    case unauthenticated
    case invalidResponse
    case httpStreamUnavailable
    case remote(code: String, message: String)
    case streamEnded

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid dsh Web URL."
        case .insecureURL:
            return "Use an HTTPS URL. Debug builds also accept HTTP for local development."
        case .unauthenticated:
            return "Paste the complete URL printed by dsh web, including its token."
        case .invalidResponse:
            return "The dsh Host returned an invalid response."
        case .httpStreamUnavailable:
            return "The dsh Host does not provide the native HTTP stream carrier."
        case let .remote(code, message):
            return "\(code): \(message)"
        case .streamEnded:
            return "The dsh Host ended the live session stream."
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .streamEnded = error as? HostClientError {
            return true
        }
        return isTransient(error as NSError, depth: 0)
    }

    private static func isTransient(_ error: NSError, depth: Int) -> Bool {
        guard depth < 4 else { return false }
        if error.domain == NSURLErrorDomain {
            return [
                URLError.timedOut.rawValue,
                URLError.cannotFindHost.rawValue,
                URLError.cannotConnectToHost.rawValue,
                URLError.networkConnectionLost.rawValue,
                URLError.notConnectedToInternet.rawValue,
                URLError.secureConnectionFailed.rawValue,
                URLError.cannotLoadFromNetwork.rawValue
            ].contains(error.code)
        }
        if error.domain == NSPOSIXErrorDomain {
            return [ECONNABORTED, ECONNRESET, ENETDOWN, ENETUNREACH, ENOTCONN, ETIMEDOUT]
                .contains(Int32(error.code))
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError else {
            return false
        }
        return isTransient(underlying, depth: depth + 1)
    }
}

private struct RPCResponse<Value: Decodable>: Decodable {
    let type: String
    let rpcId: String
    let result: RPCResult<Value>
}

private enum RPCResult<Value: Decodable>: Decodable {
    case success(Value)
    case failure(code: String, message: String)

    private enum CodingKeys: String, CodingKey {
        case ok
        case value
        case error
    }

    private struct Failure: Decodable {
        let code: String
        let message: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(Bool.self, forKey: .ok) {
            self = .success(try container.decode(Value.self, forKey: .value))
        } else {
            let failure = try container.decode(Failure.self, forKey: .error)
            self = .failure(code: failure.code, message: failure.message)
        }
    }
}

private struct RemoteStreamFrame: Decodable {
    let type: String
    let streamId: String
    let value: JSONValue?
    let error: RemoteStreamError?
}

private struct RemoteStreamError: Decodable {
    let code: String
    let message: String
}

actor HostClient {
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var baseURL: URL?

    init(session: URLSession? = nil) {
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func configure(address: String) async throws -> URL {
        WhaleDiagnostics.transport.debug("configuring Host transport")
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              components.host != nil else {
            throw HostClientError.invalidURL
        }
        #if DEBUG
        guard scheme == "https" || scheme == "http" else {
            throw HostClientError.insecureURL
        }
        #else
        guard scheme == "https" else {
            throw HostClientError.insecureURL
        }
        #endif
        guard let authenticationURL = components.url else {
            throw HostClientError.invalidURL
        }
        let (_, response) = try await session.data(from: authenticationURL)
        guard let http = response as? HTTPURLResponse else {
            throw HostClientError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw HostClientError.unauthenticated
        }
        guard (200..<400).contains(http.statusCode) else {
            throw HostClientError.remote(
                code: "http/\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let cleanURL = components.url else {
            throw HostClientError.invalidURL
        }
        baseURL = cleanURL
        WhaleDiagnostics.transport.debug("Host transport configured")
        return cleanURL
    }

    func call<Value: Decodable>(
        _ endpoint: String,
        args: [String: JSONValue]
    ) async throws -> Value {
        guard let baseURL else { throw HostClientError.invalidURL }
        let rpcId = UUID().uuidString.lowercased()
        WhaleDiagnostics.transport.debug("RPC \(endpoint, privacy: .public) started")
        let body: JSONValue = .object([
            "type": .string("client-request"),
            "rpcId": .string(rpcId),
            "method": .string(endpoint),
            "payload": .object(["args": .object(args)])
        ])
        var request = URLRequest(url: baseURL.appending(path: "api/\(endpoint)"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HostClientError.invalidResponse
        }
        guard http.statusCode != 401 else {
            throw HostClientError.unauthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HostClientError.remote(
                code: "http/\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        let envelope = try decoder.decode(RPCResponse<Value>.self, from: data)
        guard envelope.type == "server-response", envelope.rpcId == rpcId else {
            throw HostClientError.invalidResponse
        }
        switch envelope.result {
        case let .success(value):
            WhaleDiagnostics.transport.debug("RPC \(endpoint, privacy: .public) succeeded")
            return value
        case let .failure(code, message):
            WhaleDiagnostics.transport.error(
                "RPC \(endpoint, privacy: .public) failed code=\(code, privacy: .public)"
            )
            throw HostClientError.remote(code: code, message: message)
        }
    }

    func stream(
        _ endpoint: String,
        args: [String: JSONValue]
    ) -> AsyncThrowingStream<JSONValue, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    WhaleDiagnostics.transport.debug("opening stream \(endpoint, privacy: .public)")
                    WhaleDiagnostics.console("transport", "opening stream \(endpoint)")
                    try await self.runStream(endpoint, args: args, continuation: continuation)
                } catch is CancellationError {
                    WhaleDiagnostics.transport.debug("stream \(endpoint, privacy: .public) cancelled")
                    WhaleDiagnostics.console("transport", "stream \(endpoint) cancelled")
                    continuation.finish()
                } catch {
                    let value = error as NSError
                    WhaleDiagnostics.transport.error(
                        "stream \(endpoint, privacy: .public) failed domain=\(value.domain, privacy: .public) code=\(value.code)"
                    )
                    WhaleDiagnostics.console(
                        "transport",
                        "stream \(endpoint) failed domain=\(value.domain) code=\(value.code)"
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        _ endpoint: String,
        args: [String: JSONValue],
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    ) async throws {
        try await runHttpStream(endpoint, args: args, continuation: continuation)
    }

    private func runHttpStream(
        _ endpoint: String,
        args: [String: JSONValue],
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    ) async throws {
        guard let baseURL else { throw HostClientError.invalidURL }
        let streamId = UUID().uuidString.lowercased()
        let open: JSONValue = .object([
            "type": .string("open"),
            "streamId": .string(streamId),
            "endpoint": .string(endpoint),
            "payload": .object(["args": .object(args)])
        ])
        var request = URLRequest(url: baseURL.appending(path: "api/remote.stream"))
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(open)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        WhaleDiagnostics.transport.debug("opening HTTP stream \(endpoint, privacy: .public)")
        WhaleDiagnostics.console("transport", "opening HTTP stream \(endpoint)")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HostClientError.invalidResponse
        }
        if http.statusCode == 404 || http.statusCode == 405 {
            throw HostClientError.httpStreamUnavailable
        }
        guard http.statusCode != 401 else {
            throw HostClientError.unauthenticated
        }
        guard (200..<300).contains(http.statusCode) else {
            throw HostClientError.remote(
                code: "http/\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            )
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.isEmpty else { continue }
            try acceptRemoteFrame(
                decoder.decode(RemoteStreamFrame.self, from: Data(line.utf8)),
                streamId: streamId,
                continuation: continuation
            )
        }
        throw HostClientError.streamEnded
    }

    private func acceptRemoteFrame(
        _ frame: RemoteStreamFrame,
        streamId: String,
        continuation: AsyncThrowingStream<JSONValue, Error>.Continuation
    ) throws {
        guard frame.streamId == streamId else { return }
        switch frame.type {
        case "item":
            if let value = frame.value {
                continuation.yield(value)
            }
        case "error":
            throw HostClientError.remote(
                code: frame.error?.code ?? "gateway/internal",
                message: frame.error?.message ?? "Remote stream failed."
            )
        case "end":
            throw HostClientError.streamEnded
        default:
            throw HostClientError.invalidResponse
        }
    }

    func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        try decoder.decode(type, from: encoder.encode(value))
    }
}
