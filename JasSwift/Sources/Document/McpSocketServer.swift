import Foundation
import Darwin

/// A4 (ii): the local socket the RUNNING app owns, carrying the MCP exchange
/// to one attached client (docs/AGENT_API.md section 4). A stdio MCP client
/// spawns a fresh process and cannot reach a running app any other way, so
/// the client runs `jas_mcp --attach <path>` (A4 (iii)), which pipes its
/// stdio to this socket.
///
/// ⛔ THE CALLER OWNS THE THREAD. Every read, every `McpSession.handle` and
/// every write runs on `queue`, and the app passes the MAIN queue, because the
/// session's `Model` is main-thread-only (the same choice `TestFifo` makes for
/// the same reason). `push` must be called on that queue too.
///
/// ONE CLIENT AT A TIME. At most one proposal is pending per document, so a
/// second agent attached to the same document could only be refused at its
/// first propose. It is refused at connect instead: closed with no session.
/// When the client disconnects, the next one may attach and gets a NEW
/// session from `makeSession`.
public final class McpSocketServer {
    public let path: String
    private let queue: DispatchQueue
    private let makeSession: () -> McpSession?
    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientFd: Int32 = -1
    private var clientSource: DispatchSourceRead?
    private var session: McpSession?
    private var buffer = Data()

    public enum Failure: Error { case path, socket(Int32), bind(Int32), listen(Int32) }

    /// Listen on `path` (a stale socket file there is removed first).
    public init(path: String, queue: DispatchQueue, makeSession: @escaping () -> McpSession?) throws {
        self.path = path
        self.queue = queue
        self.makeSession = makeSession
        // So `stop()` can tell whether it is already on `queue` (the app calls
        // it on main, and a `sync` onto the queue you are on deadlocks).
        queue.setSpecific(key: Self.key, value: ObjectIdentifier(self))
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure.path }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let e = errno; close(fd); throw Failure.bind(e) }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { let e = errno; close(fd); unlink(path); throw Failure.listen(e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFd = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        acceptSource = src
    }

    /// Send lines the session produced outside a request (an artist act's
    /// notifications). A no-op when no client is attached. Call on `queue`.
    public func push(_ lines: String...) {
        for l in lines { writeLine(l) }
    }

    /// The attached client's session, if any (the app reports artist acts
    /// through it, then `push`es what it returns).
    public var attachedSession: McpSession? { session }

    /// Stop listening, drop the client and remove the socket file.
    public func stop() {
        let work = {
            self.dropClient()
            self.acceptSource?.cancel()
            self.acceptSource = nil
            if self.listenFd >= 0 { close(self.listenFd); self.listenFd = -1 }
            unlink(self.path)
        }
        if DispatchQueue.getSpecific(key: Self.key) == ObjectIdentifier(self) { work() } else { queue.sync(execute: work) }
    }

    private static let key = DispatchSpecificKey<ObjectIdentifier>()

    private func acceptOne() {
        let fd = accept(listenFd, nil, nil)
        guard fd >= 0 else { return }
        guard clientFd < 0, let s = makeSession() else { close(fd); return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        clientFd = fd
        session = s
        buffer = Data()
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.resume()
        clientSource = src
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(clientFd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { dropClient() }
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let s = session, !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            for out in s.handle(line) { writeLine(out) }
        }
    }

    private func writeLine(_ line: String) {
        guard clientFd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        var off = 0
        while off < bytes.count {
            let w = bytes[off...].withUnsafeBytes { write(clientFd, $0.baseAddress, $0.count) }
            if w > 0 { off += w; continue }
            if w < 0 && (errno == EAGAIN || errno == EINTR) {
                var p = pollfd(fd: clientFd, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, 1000) > 0 { continue }
            }
            dropClient()
            return
        }
    }

    private func dropClient() {
        clientSource?.cancel()
        clientSource = nil
        if clientFd >= 0 { close(clientFd); clientFd = -1 }
        session = nil
        buffer = Data()
    }
}
