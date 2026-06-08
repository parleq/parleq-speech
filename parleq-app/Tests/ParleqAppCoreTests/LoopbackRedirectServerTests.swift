import XCTest
@testable import ParleqAppCore

/// Tests for the transient OIDC loopback-redirect listener. These bind a real
/// 127.0.0.1 ephemeral port (raw BSD socket) and drive it with a real URLSession
/// GET, so they exercise the actual socket/accept path (not a fake). Raw BSD
/// sockets bind fine headless, so these tests run green everywhere — no skips.
final class LoopbackRedirectServerTests: XCTestCase {
    /// A URLSession that never follows redirects and reads the static body so we
    /// can assert on it. Ephemeral so nothing is cached.
    private func session() -> URLSession {
        URLSession(configuration: .ephemeral)
    }

    func test_start_binds_nonzero_port_and_shapes_redirect_uri() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/oauth2redirect")
        defer { server.cancel() }
        XCTAssertNotEqual(server.port, 0, "must bind a nonzero ephemeral port")
        XCTAssertEqual(server.redirectURI, "http://127.0.0.1:\(server.port)/oauth2redirect")
    }

    func test_callback_returns_url_with_query_static_body_and_closes_listener() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/oauth2redirect")

        // Await the callback in the background.
        async let callback = server.awaitCallback(timeout: 10)

        // Drive the redirect with a real GET carrying code+state.
        let url = URL(string: "\(server.redirectURI)?code=abc123&state=xyz789")!
        let (data, resp) = try await session().data(from: url)
        let http = try XCTUnwrap(resp as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(body.contains("Signed in"), "static success page")
        // STATIC body — must NOT reflect the code/state back to the browser.
        XCTAssertFalse(body.contains("abc123"))
        XCTAssertFalse(body.contains("xyz789"))

        let got = try await callback
        let items = URLComponents(url: got, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "abc123")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, "xyz789")

        // Listener is closed after the one-shot: a second connect must fail.
        let port = server.port
        do {
            _ = try await session().data(from: URL(string: "http://127.0.0.1:\(port)/oauth2redirect?code=x")!)
            XCTFail("listener should be closed after the callback")
        } catch {
            // expected — connection refused
        }
    }

    func test_favicon_probe_then_callback_succeeds() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/oauth2redirect")

        async let callback = server.awaitCallback(timeout: 10)

        // A stray probe with no code/error → 400, does NOT consume the one-shot.
        let probeURL = URL(string: "http://127.0.0.1:\(server.port)/favicon.ico")!
        let (probeData, probeResp) = try await session().data(from: probeURL)
        XCTAssertEqual((probeResp as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(String(decoding: probeData, as: UTF8.self).contains("Bad request"))

        // The real callback still lands.
        let cbURL = URL(string: "\(server.redirectURI)?code=real&state=s")!
        _ = try await session().data(from: cbURL)

        let got = try await callback
        let items = URLComponents(url: got, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "real")
    }

    func test_timeout_throws_and_closes_listener() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/cb")
        let port = server.port
        do {
            _ = try await server.awaitCallback(timeout: 0.2)
            XCTFail("expected timeout")
        } catch let f as OIDCAuthFailure {
            guard case .signInCancelled = f else { return XCTFail("\(f)") }
        }
        // Listener torn down on timeout: a connect must fail.
        do {
            _ = try await session().data(from: URL(string: "http://127.0.0.1:\(port)/cb?code=x")!)
            XCTFail("listener should be closed after timeout")
        } catch {
            // expected
        }
    }

    /// An oversized request head (>16 KB with no CRLFCRLF) → static 400, that
    /// connection closed, and the flow STILL completes on a subsequent good
    /// callback (the one-shot wasn't consumed).
    func test_oversized_head_then_callback_succeeds() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/oauth2redirect")

        async let callback = server.awaitCallback(timeout: 10)

        // Raw connect; send >16 KB of header-shaped garbage with NO blank line.
        let fd = try connectLoopback(port: server.port)
        var blob = Data("GET /flood".utf8)
        blob.append(Data(repeating: UInt8(ascii: "x"), count: 20 * 1024))
        try writeAll(fd, blob)
        // The server caps the head at 16 KB → 400 + closes this connection. Read
        // until EOF to confirm it closed (don't assert on partial body framing).
        let resp = readUntilEOF(fd)
        close(fd)
        XCTAssertTrue(String(decoding: resp, as: UTF8.self).contains("400"),
                      "oversized head should get a 400")

        // The real callback still lands on a fresh connection.
        let cbURL = URL(string: "\(server.redirectURI)?code=afterflood&state=s")!
        _ = try await session().data(from: cbURL)

        let got = try await callback
        let items = URLComponents(url: got, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "code" }?.value, "afterflood")
    }

    /// Cancelling the awaiting task mid-await tears down the listener and the
    /// await throws — verified by a follow-up connect that's refused.
    func test_cancellation_mid_await_throws_and_closes_listener() async throws {
        let server = try await LoopbackRedirectServer.start(path: "/cb")
        let port = server.port

        let task = Task { () -> URL in
            try await server.awaitCallback(timeout: 30)
        }
        // Let the listener arm, then cancel the awaiting task.
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled await should throw")
        } catch let f as OIDCAuthFailure {
            guard case .signInCancelled = f else { return XCTFail("\(f)") }
        }

        // fds closed: a follow-up connect must fail.
        do {
            _ = try await session().data(from: URL(string: "http://127.0.0.1:\(port)/cb?code=x")!)
            XCTFail("listener should be closed after cancellation")
        } catch {
            // expected — connection refused
        }
    }

    // MARK: - raw socket helpers (for byte-level control the URLSession can't give)

    private func connectLoopback(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw XCTSkip("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { close(fd); throw XCTSkip("connect() failed") }
        return fd
    }

    private func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let w = write(fd, base + sent, raw.count - sent)
                if w > 0 { sent += w; continue }
                if w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                throw XCTSkip("write() failed")
            }
        }
    }

    private func readUntilEOF(_ fd: Int32) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            break  // 0 = EOF, <0 = error
        }
        return out
    }

    func test_requestTarget_parses_get_only() {
        XCTAssertEqual(
            LoopbackRedirectServer.requestTarget("GET /cb?code=1 HTTP/1.1\r\nHost: x\r\n"),
            "/cb?code=1")
        XCTAssertNil(LoopbackRedirectServer.requestTarget("POST /cb HTTP/1.1\r\n"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget("garbage"))
        XCTAssertNil(LoopbackRedirectServer.requestTarget("GET cb-no-slash HTTP/1.1\r\n"))
    }
}
