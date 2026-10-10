import Testing
import Foundation
import Darwin
@testable import JasLib

/// A blocking Unix-domain client for the tests: connect, send lines, read
/// lines with a timeout. A read that times out returns nil, never hangs.
private final class LineClient {
    let fd: Int32
    var buffer = Data()

    init?(path: String) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count))) }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
    }

    func send(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    func readLine(timeoutMs: Int32 = 2000) -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, timeoutMs) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    deinit { close(fd) }
}

private func tempSocketPath() -> String {
    // sun_path holds 104 bytes on Darwin, so keep the path short.
    "/tmp/jas-mcp-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
}

private func emptyModel() -> Model {
    Model(document: Document(layers: [Layer(children: [])], artboards: []))
}

/// A4 (ii): the socket the running app owns carries the MCP exchange. A
/// client connects, sends `initialize`, and reads the session's answer.
@Test func mcpSocketServerAnswersARequestOverTheSocket() throws {
    let path = tempSocketPath()
    let queue = DispatchQueue(label: "mcp-socket-test")
    let server = try McpSocketServer(path: path, queue: queue) { McpSession(model: emptyModel()) }
    defer { server.stop() }
    let client = try #require(LineClient(path: path), "the client connects to \(path)")
    client.send(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
    let line = try #require(client.readLine(), "an answer arrives within the timeout")
    let msg = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
    #expect((msg["id"] as? Int) == 7 && msg["result"] != nil, "\(line)")
}

/// A4 (ii): an artist act in the app reaches the attached client. The server
/// pushes the lines the session's `artistAccept` returns.
@Test func mcpSocketServerPushesAnArtistActToTheClient() throws {
    let path = tempSocketPath()
    let queue = DispatchQueue(label: "mcp-socket-test")
    let session = McpSession(model: emptyModel())
    let server = try McpSocketServer(path: path, queue: queue) { session }
    defer { server.stop() }
    let client = try #require(LineClient(path: path))
    client.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    _ = try #require(client.readLine(), "attached")
    queue.sync { server.push(#"{"jsonrpc":"2.0","method":"notifications/jas/proposal","params":{"proposal":"p-0","state":"accepted"}}"#) }
    let line = try #require(client.readLine(), "the push arrives")
    #expect(line.contains("notifications/jas/proposal"), "\(line)")
}

/// A4 (ii): ONE agent at a time, as at most one proposal is pending. A second
/// client is closed rather than given a second session over the same document.
@Test func mcpSocketServerRefusesASecondClient() throws {
    let path = tempSocketPath()
    let queue = DispatchQueue(label: "mcp-socket-test")
    let server = try McpSocketServer(path: path, queue: queue) { McpSession(model: emptyModel()) }
    defer { server.stop() }
    let first = try #require(LineClient(path: path))
    first.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
    _ = try #require(first.readLine(), "the first client is attached")
    let second = try #require(LineClient(path: path), "the connect itself succeeds")
    second.send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
    #expect(second.readLine(timeoutMs: 500) == nil, "the second client gets no session")
    first.send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
    #expect(first.readLine() != nil, "and the first is undisturbed")
}

/// A4 (ii): stop() removes the socket file, so a stale path never answers.
@Test func mcpSocketServerStopRemovesTheSocket() throws {
    let path = tempSocketPath()
    let server = try McpSocketServer(path: path, queue: DispatchQueue(label: "mcp-socket-test")) { McpSession(model: emptyModel()) }
    #expect(FileManager.default.fileExists(atPath: path), "the control: the socket exists while serving")
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}

/// A4 (iv)(b), end to end over the socket: an ORDINARY edit to the model (not
/// through the session) withdraws the client's proposal, and the client is told.
@Test func mcpSocketServerTellsTheClientAnOrdinaryEditWithdrewItsProposal() throws {
    let path = tempSocketPath()
    let queue = DispatchQueue(label: "mcp-socket-test")
    let model = Model(document: svgToDocument(#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><g><rect x="10" y="10" width="20" height="20" fill="red"/></g></svg>"#))
    let server = try McpSocketServer(path: path, queue: queue) { McpSession(model: model) }
    defer { server.stop() }
    let client = try #require(LineClient(path: path))
    client.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose","arguments":{"name":"nudge","ops":[{"op":"select_rect","x":0,"y":0,"width":50,"height":50,"extend":false},{"op":"move_selection","dx":5,"dy":0}]}}}"#)
    let answer = try #require(client.readLine(), "the propose is answered")
    #expect(answer.contains("p-0"), "\(answer)")
    queue.sync {
        model.withTxn {
            let c = Controller(model: model)
            _ = opApply(model, c, ["op": "select_rect", "x": 0, "y": 0, "width": 50, "height": 50, "extend": false])
            _ = opApply(model, c, ["op": "move_selection", "dx": 1, "dy": 1])
        }
    }
    let line = try #require(client.readLine(), "the withdrawal reaches the client")
    #expect(line.contains("withdrawn") && line.contains("p-0"), "\(line)")
}

/// A4 (iv)(a), end to end: the bar's Accept, with the proposing client
/// attached, goes through that client's session, so the client is told.
@Test func theBarsAcceptReachesTheAttachedClient() throws {
    let path = tempSocketPath()
    let queue = DispatchQueue(label: "mcp-socket-test")
    let model = Model(document: svgToDocument(#"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><g><rect x="10" y="10" width="20" height="20" fill="red"/></g></svg>"#))
    let server = try McpSocketServer(path: path, queue: queue) { McpSession(model: model) }
    defer { server.stop() }
    let client = try #require(LineClient(path: path))
    client.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"propose","arguments":{"name":"nudge","ops":[{"op":"select_rect","x":0,"y":0,"width":50,"height":50,"extend":false},{"op":"move_selection","dx":5,"dy":0}]}}}"#)
    _ = try #require(client.readLine(), "the propose is answered")
    queue.sync { ProposalBar.accept(model: model, server: server) }
    let line = try #require(client.readLine(), "the accept reaches the client")
    #expect(line.contains("accepted") && line.contains("p-0"), "\(line)")
    #expect(model.journal.last?.actor == "ai")
}
