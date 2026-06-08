import Foundation

/// A precisely-scoped, transient HTTP listener for the OIDC loopback-redirect
/// sign-in flow (Google "Desktop app" client type and any OAuth client that
/// uses an `http://127.0.0.1:<port>/<path>` redirect URI).
///
/// WHY THIS EXISTS — and the "no listening sockets" carve-out:
/// Parleq's default dictation path binds NO sockets and the OIDC custom-scheme
/// flow is intercepted by `ASWebAuthenticationSession` in-process. But Google's
/// CURRENT desktop-app guidance is a LOOPBACK redirect, which the system
/// browser-auth surface cannot intercept — the OS browser navigates to
/// `http://127.0.0.1:<port>/...` and SOMETHING must answer on that port. This
/// type is that something: a raw BSD socket bound to 127.0.0.1 ONLY, on an
/// EPHEMERAL port, for the DURATION OF A SINGLE ACTIVE SIGN-IN. It accepts one
/// successful callback, replies with a STATIC page, and tears the listener down
/// immediately (defer-based). It never binds a non-loopback interface, never
/// logs the callback URL or its query, and is provably closed after the flow
/// completes or fails.
///
/// WHY RAW BSD SOCKETS (not Network.framework):
/// The original implementation used `NWListener`. On the maintainer's macOS it
/// fails `POSIXErrorCode(22) Invalid argument` for EVERY bind shape we tried
/// (`requiredLocalEndpoint` + port `.any`, `requiredInterfaceType .loopback`,
/// plain `.tcp` on `.any`, and an explicit port). A plain `socket()/bind()/
/// listen()` against `127.0.0.1:0` works on the same host (verified live).
/// Network.framework's "headless can't bind networkd" theory was wrong — BSD
/// sockets bind fine headless, which is why the tests no longer skip.
///
/// CONCURRENCY MODEL: this is a `final class` (not an actor) marked
/// `@unchecked Sendable`. Its mutable state (fds, dispatch sources, the awaiting
/// continuation, the torndown flag) is guarded by a single `NSLock`. A class +
/// lock yields the cleanest single-resume / provable-teardown story here: the
/// GCD source callbacks and the Swift-concurrency continuation both touch the
/// same state, and an actor would force every callback hop to re-enter the
/// executor (and can't be re-entered from a `nonisolated` GCD callback without
/// another Task hop). The lock makes "resume the continuation exactly once, then
/// close every fd" a single atomic critical section.
///
/// HARD RULES (preserve through refactors):
///  - Bind 127.0.0.1 ONLY — an EXACT-address `bind()` to `INADDR_LOOPBACK`,
///    which is a kernel-level loopback-only bind (stronger than an interface-type
///    constraint: the socket is reachable ONLY via 127.0.0.1). Never a
///    wildcard/0.0.0.0 / `INADDR_ANY` bind.
///  - The HTTP response body is STATIC bytes — no query, code, token, or any
///    request-derived content is ever reflected back to the browser.
///  - Logs are code/count-only via `logStderrOIDC` — the callback URL and its
///    query (which carry `code`/`state`) are NEVER logged.
///  - The listener is torn down via `defer` the instant the awaited callback
///    resolves (success, malformed-then-success, timeout, or cancellation).
public final class LoopbackRedirectServer: @unchecked Sendable {
    /// The ephemeral port the listener bound to (nonzero once `start` returns).
    public nonisolated let port: UInt16
    /// The redirect URI to hand the IdP and the token exchange:
    /// `http://127.0.0.1:<port><path>`.
    public nonisolated let redirectURI: String

    private let path: String
    private let queue = DispatchQueue(label: "com.parleq.app.oidc-loopback", qos: .userInitiated)

    // --- State guarded by `lock` ---
    private let lock = NSLock()
    private var listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    /// Per-connection state: fd → bookkeeping so teardown can close everything.
    private var connections: [Int32: Connection] = [:]
    /// The single continuation `awaitCallback` is parked on. Resumed exactly once.
    private var continuation: CheckedContinuation<URL, Error>?
    private var resumed = false
    private var torndown = false

    private final class Connection {
        let fd: Int32
        var readSource: DispatchSourceRead?
        var idleTimer: DispatchSourceTimer?
        var head = Data()
        init(fd: Int32) { self.fd = fd }
    }

    deinit {
        // Last-resort fd hygiene (review carry-over): a server dropped
        // without awaitCallback/cancel having run still must not leak its
        // listener or connection fds. teardown() is idempotent and
        // lock-based, safe from deinit.
        teardown()
    }

    private init(port: UInt16, path: String, listenFD: Int32) {
        self.port = port
        self.path = path
        self.redirectURI = "http://127.0.0.1:\(port)\(path)"
        self.listenFD = listenFD
    }

    /// Bind a 127.0.0.1-only listener on an ephemeral port and return a ready
    /// server. `path` is the redirect path component (e.g. `/oauth2redirect`);
    /// it is matched leniently (any GET whose request-line carries a `code` or
    /// `error` query is treated as the callback) so a trailing-slash or path
    /// mismatch from the IdP can't strand the flow.
    public static func start(path: String) async throws -> LoopbackRedirectServer {
        // socket(AF_INET, SOCK_STREAM). CLOEXEC so a spawned child (gcloud/az)
        // can't inherit the listening fd.
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw OIDCAuthFailure.signInUnavailable(detail: "couldn't create loopback socket")
        }
        setCloexec(fd)
        // The LISTENER must be nonblocking: acceptPending() drains pending
        // connections in a loop until accept() returns EWOULDBLOCK. With a
        // blocking listener, the drain loop BLOCKS the serial queue inside
        // accept() after the first connection — and the queue is the same
        // one that delivers every connection's read events, so the first
        // request's bytes are never processed (live deadlock: test stuck in
        // read(), server stuck in accept()).
        setNonblocking(fd)

        // 127.0.0.1 ONLY — exact-address bind to INADDR_LOOPBACK on port 0 (the
        // kernel assigns an ephemeral port). This is a kernel-level loopback-only
        // bind: the socket is reachable solely via 127.0.0.1, never off-host.
        // SO_REUSEADDR is intentionally left OFF (default): we want a fresh,
        // exclusive ephemeral port, not address reuse.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral; network byte order irrelevant for 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        let bindOK = withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else {
            close(fd)
            throw OIDCAuthFailure.signInUnavailable(detail: "couldn't bind loopback listener")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw OIDCAuthFailure.signInUnavailable(detail: "couldn't listen on loopback socket")
        }

        // getsockname → the ephemeral port the kernel assigned.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len) == 0
            }
        }
        let boundPort = UInt16(bigEndian: bound.sin_port)
        guard nameOK, boundPort != 0 else {
            close(fd)
            throw OIDCAuthFailure.signInUnavailable(detail: "loopback listener bound no port")
        }

        logStderrOIDC("oidc loopback listener bound")
        return LoopbackRedirectServer(port: boundPort, path: path, listenFD: fd)
    }

    /// Accept connections until ONE carries a valid OAuth callback (a GET whose
    /// query has `code` or `error`), respond with a static 200 page, then close
    /// everything. Non-GET / malformed / probe requests (favicon, health checks)
    /// get a static 400 and DO NOT consume the one-shot — we keep listening for
    /// the real callback until `timeout`. On timeout or task cancellation the
    /// listener is torn down and we throw `signInCancelled`.
    ///
    /// The returned URL is reconstructed locally as
    /// `http://127.0.0.1:<port><request-target>` so `signIn` can read `code` /
    /// `state` exactly as it does for the custom-scheme path. The URL is NEVER
    /// logged.
    public func awaitCallback(timeout: TimeInterval = 300) async throws -> URL {
        // Provably close the listener the instant we leave this function for ANY
        // reason (success, throw, timeout, cancellation).
        defer { teardown() }

        // An overall-timeout timer; armed on the dedicated queue, cancelled in
        // teardown. Resumes the continuation with signInCancelled (timeout →
        // silent, the user can retry).
        let overall = DispatchSource.makeTimerSource(queue: queue)
        overall.schedule(deadline: .now() + timeout)
        overall.setEventHandler { [weak self] in
            self?.finish(.failure(OIDCAuthFailure.signInCancelled))
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                if torndown || resumed {
                    lock.unlock()
                    cont.resume(throwing: OIDCAuthFailure.signInCancelled)
                    return
                }
                continuation = cont
                self.overallTimer = overall
                lock.unlock()
                overall.resume()
                startAccepting()
            }
        } onCancel: {
            // Task cancellation → tear down (closes fds, resumes the parked
            // continuation with signInCancelled).
            finish(.failure(OIDCAuthFailure.signInCancelled))
        }
    }

    /// The overall-timeout timer, retained so teardown can cancel it.
    private var overallTimer: DispatchSourceTimer?

    /// Idempotent teardown: cancel the accept source + every connection, close
    /// all fds, cancel the overall timer. Safe to call from any thread.
    public nonisolated func cancel() {
        finish(.failure(OIDCAuthFailure.signInCancelled))
    }

    // MARK: - Accept loop (GCD)

    /// Install a DispatchSourceRead on the listening fd; its event handler accepts
    /// pending connections. Runs on the dedicated utility queue.
    private func startAccepting() {
        lock.lock()
        guard !torndown, acceptSource == nil, listenFD >= 0 else { lock.unlock(); return }
        let lfd = listenFD
        let src = DispatchSource.makeReadSource(fileDescriptor: lfd, queue: queue)
        acceptSource = src
        lock.unlock()
        src.setEventHandler { [weak self] in self?.acceptPending() }
        // The SOURCE owns the fd close (review finding): a dispatch source
        // must not have its descriptor closed until its cancel handler has
        // run — closing inline after cancel() races the still-live source
        // and, worse, lets the kernel reissue the fd number to an
        // unrelated descriptor that a queued handler then reads/writes.
        src.setCancelHandler { close(lfd) }
        src.resume()
    }

    /// Drain pending connections (the read source may coalesce several).
    private func acceptPending() {
        lock.lock()
        let lfd = listenFD
        let down = torndown
        lock.unlock()
        guard !down, lfd >= 0 else { return }

        while true {
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(lfd, sa, &len)
                }
            }
            if cfd < 0 { break }  // EWOULDBLOCK / no more pending (or torn down)
            setCloexec(cfd)
            setNonblocking(cfd)
            beginConnection(fd: cfd)
        }
    }

    /// Track a freshly-accepted connection and arm its read source + idle timer.
    private func beginConnection(fd: Int32) {
        let conn = Connection(fd: fd)
        lock.lock()
        if torndown { lock.unlock(); close(fd); return }
        connections[fd] = conn

        let readSrc = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        conn.readSource = readSrc

        // Per-connection idle timeout: a silent probe (socket opened, no request
        // line sent) self-resolves instead of wedging the flow. (Review job 5311
        // Medium in the NW version — preserve the guarantee.)
        let idle = DispatchSource.makeTimerSource(queue: queue)
        idle.schedule(deadline: .now() + 5)
        conn.idleTimer = idle
        lock.unlock()

        readSrc.setEventHandler { [weak self] in self?.readConnection(fd: fd) }
        // Source owns the close (see startAccepting's cancel-handler note).
        readSrc.setCancelHandler { close(fd) }
        idle.setEventHandler { [weak self] in
            // Idle expiry → treat as malformed: static 400, close, keep listening.
            self?.respondAndCloseConnection(fd: fd, status: "400 Bad Request",
                                             body: Self.badRequestPage)
        }
        readSrc.resume()
        idle.resume()
    }

    /// Read available bytes for a connection, accumulating its request head with a
    /// 16 KB cap. Once we see CRLFCRLF (or hit the cap / EOF) we parse + act.
    private func readConnection(fd: Int32) {
        let maxHeadBytes = 16 * 1024
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n < 0 {
            if errno == EAGAIN || errno == EWOULDBLOCK { return }  // spurious wakeup
            respondAndCloseConnection(fd: fd, status: "400 Bad Request", body: Self.badRequestPage)
            return
        }

        lock.lock()
        guard let conn = connections[fd], !torndown else { lock.unlock(); return }
        if n > 0 { conn.head.append(contentsOf: buf[0..<n]) }
        let head = conn.head
        let atCap = head.count >= maxHeadBytes
        let haveHeadEnd = head.range(of: Data("\r\n\r\n".utf8)) != nil
        let eof = (n == 0)
        lock.unlock()

        // Oversized head → static 400, close that connection, keep listening.
        if atCap && !haveHeadEnd {
            respondAndCloseConnection(fd: fd, status: "400 Bad Request", body: Self.badRequestPage)
            return
        }
        guard haveHeadEnd || eof else { return }  // need more bytes

        // We have a complete head (or peer closed). Parse the request line.
        let headStr = Self.headString(head)
        if let target = Self.requestTarget(headStr),
           let url = URL(string: "http://127.0.0.1:\(port)\(target)"),
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           items.contains(where: { $0.name == "code" || $0.name == "error" }) {
            // THE callback: static 200, then resolve + tear everything down.
            writeResponse(fd: fd, status: "200 OK", body: Self.successPage)
            finish(.success(url))
        } else {
            // Probe / favicon / non-GET / malformed: static 400, close THIS
            // connection only, keep listening for the real callback.
            respondAndCloseConnection(fd: fd, status: "400 Bad Request", body: Self.badRequestPage)
        }
    }

    /// Trim the accumulated bytes to just the head (before CRLFCRLF) and decode.
    private static func headString(_ data: Data) -> String {
        if let r = data.range(of: Data("\r\n\r\n".utf8)) {
            return String(decoding: data[data.startIndex..<r.lowerBound], as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Responses + teardown

    /// Write a static HTTP response to `fd` (best-effort, blocking write). The
    /// body is STATIC — never request-derived — so no `code`/`state`/token can be
    /// reflected. Does NOT close the fd (callers decide: callback path tears down
    /// everything; probe path closes just this connection).
    private func writeResponse(fd: Int32, status: String, body: String) {
        let bodyData = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(bodyData)
        // The fd is nonblocking; loop over partial writes. Static, small
        // payload — but EAGAIN must not busy-spin (review carry-over): a
        // stalled peer gets a bounded number of brief poll waits, then we
        // give up (the response is best-effort either way).
        response.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            var stalls = 0
            let total = raw.count
            while sent < total {
                let w = write(fd, base + sent, total - sent)
                if w > 0 { sent += w; stalls = 0; continue }
                if w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    stalls += 1
                    if stalls > 50 { break }  // ~500ms ceiling
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 10)
                    continue
                }
                break  // peer gone or hard error — give up (best-effort)
            }
        }
    }

    /// Write a static response to one connection, then close + untrack it. Keeps
    /// the listener (and the one-shot) alive for the real callback.
    private func respondAndCloseConnection(fd: Int32, status: String, body: String) {
        lock.lock()
        guard let conn = connections.removeValue(forKey: fd), !torndown else {
            lock.unlock(); return
        }
        lock.unlock()
        // Write while the fd is provably open, THEN cancel — the read
        // source's cancel handler performs the close on `queue`, after any
        // in-flight handler for this fd has drained (review finding: never
        // close a dispatch-source fd inline).
        writeResponse(fd: fd, status: status, body: body)
        conn.readSource?.cancel()
        conn.idleTimer?.cancel()
    }

    /// Resolve the parked continuation exactly once and tear everything down.
    /// The single-resume guard + teardown live in one locked critical section.
    private nonisolated func finish(_ result: Result<URL, Error>) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        let cont = continuation
        continuation = nil
        teardownLocked()
        lock.unlock()

        switch result {
        case .success(let url): cont?.resume(returning: url)
        case .failure(let err): cont?.resume(throwing: err)
        }
    }

    /// `defer`-driven teardown from `awaitCallback`. Idempotent. If the
    /// continuation was never resumed (shouldn't happen — finish() drives the
    /// resume), this still closes every fd so nothing leaks.
    private nonisolated func teardown() {
        lock.lock()
        teardownLocked()
        lock.unlock()
    }

    /// Caller MUST hold `lock`. Cancels sources, closes all fds. Idempotent.
    private func teardownLocked() {
        guard !torndown else { return }
        torndown = true
        overallTimer?.cancel(); overallTimer = nil
        // Sources own their fd closes via cancel handlers (review finding) —
        // cancel() here, close() runs on `queue` once each source finalizes.
        for (fd, conn) in connections {
            if let readSource = conn.readSource {
                readSource.cancel()
            } else {
                close(fd)  // never had a source attached
            }
            conn.idleTimer?.cancel()
        }
        connections.removeAll()
        if let src = acceptSource {
            src.cancel()  // cancel handler closes listenFD
            acceptSource = nil
            listenFD = -1
        } else if listenFD >= 0 {
            // Torn down before startAccepting attached a source.
            close(listenFD)
            listenFD = -1
        }
        logStderrOIDC("oidc loopback listener closed")
    }

    // MARK: - Parsing

    /// Extract the request target (path+query) from an HTTP request head's
    /// request line: `GET /oauth2redirect?code=... HTTP/1.1`. Returns nil unless
    /// the method is GET and a target is present.
    static func requestTarget(_ head: String) -> String? {
        guard let firstLine = head.split(separator: "\r\n", maxSplits: 1,
                                         omittingEmptySubsequences: false).first
        else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        let target = String(parts[1])
        return target.hasPrefix("/") ? target : nil
    }

    // STATIC response bodies — no interpolation, ever.
    static let successPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Parleq</title></head>
    <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:3rem;color:#1d1d1f">
    <h2>Signed in</h2><p>You can close this tab and return to Parleq.</p></body></html>
    """
    static let badRequestPage = """
    <!doctype html><html><head><meta charset="utf-8"><title>Parleq</title></head>
    <body style="font-family:-apple-system,system-ui,sans-serif;text-align:center;padding:3rem;color:#1d1d1f">
    <h2>Bad request</h2><p>This page is part of a Parleq sign-in. You can close it.</p></body></html>
    """
}

// MARK: - fd flags

/// FD_CLOEXEC: don't leak the listening/connection fds into spawned children.
private func setCloexec(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFD)
    if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
}

/// O_NONBLOCK: accepted connections read non-blocking so a partial request head
/// doesn't block the dedicated queue between DispatchSourceRead wakeups.
private func setNonblocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL)
    if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
}
