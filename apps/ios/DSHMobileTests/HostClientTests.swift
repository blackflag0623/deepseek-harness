import Foundation
import Darwin
import XCTest
@testable import WhaleGirl

final class HostClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testAuthenticatesThenUsesTheExistingRPCEnvelope() async throws {
        StubURLProtocol.handler = { request in
            guard let url = request.url else { throw HostClientError.invalidResponse }
            if request.httpMethod == "GET" {
                XCTAssertEqual(url.query, "token=one-time")
                return (
                    HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }

            let body = try XCTUnwrap(Self.body(of: request))
            let value = try JSONDecoder().decode(JSONValue.self, from: body)
            let object = try XCTUnwrap(value.objectValue)
            XCTAssertEqual(object["type"], .string("client-request"))
            XCTAssertEqual(object["method"], .string("session/list"))
            XCTAssertEqual(
                object["payload"]?.objectValue?["args"]?.objectValue?["_request"],
                .object([:])
            )
            let rpcId = try XCTUnwrap(object["rpcId"]?.stringValue)
            let response: JSONValue = .object([
                "type": .string("server-response"),
                "rpcId": .string(rpcId),
                "result": .object([
                    "ok": .bool(true),
                    "value": .object(["items": .array([])])
                ])
            ])
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try JSONEncoder().encode(response)
            )
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = HostClient(session: URLSession(configuration: configuration))

        let baseURL = try await client.configure(
            address: "https://host.example/?token=one-time"
        )
        XCTAssertEqual(baseURL.absoluteString, "https://host.example")
        let value: SessionListValue = try await client.call(
            "session/list",
            args: ["_request": .object([:])]
        )
        XCTAssertEqual(value.items, [])

        let suite = "HostClientTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = await AppStore(client: client, defaults: defaults)
        await store.connect(address: "https://host.example/?token=one-time")
        let connected = await store.connectionState
        XCTAssertEqual(connected, .connected)
        await store.applicationDidEnterBackground()
        let suspended = await store.connectionState
        let backgroundError = await store.conversationError
        XCTAssertEqual(suspended, .suspended)
        XCTAssertNil(backgroundError)
        await store.applicationDidBecomeActive()
        let resumed = await store.connectionState
        XCTAssertEqual(resumed, .connected)
    }

    func testClassifiesConnectionAbortAsTransient() {
        XCTAssertTrue(HostClientError.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(HostClientError.isTransient(NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNABORTED)
        )))
        XCTAssertTrue(HostClientError.isTransient(NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOTCONN)
        )))
        XCTAssertFalse(HostClientError.isTransient(
            HostClientError.remote(code: "session/not-found", message: "gone")
        ))
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: HostClientError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
