import Foundation
import JasLib

// ── The agent API's socket (node A4 (ii)) ───────────────────────────────
// When launched with `--mcp-socket PATH`, the app listens on a Unix-domain
// socket at PATH and serves ONE MCP client at a time over the ACTIVE
// document (docs/AGENT_API.md section 4). A stdio MCP client reaches it with
// `jas_mcp --attach PATH`. Gated entirely behind the flag, like --test-fifo:
// no flag, no socket.
//
// An artist edit made through the app's ordinary paths reaches the client
// through the model's hooks (A4 (iv)(b)): a withdrawn proposal and, for a
// subscriber, a settled-document change.
// ⚠️ NOT YET WIRED, and stated so that nobody reads it as done: Accept and
// Reject. They need the overlay (A4 (iv)(a)); until it exists the first
// observable is not reachable from the app.
extension JasAppDelegate {
    /// Parse `--mcp-socket <path>`, the same shape as `--test-fifo`.
    static var mcpSocketPath: String? {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--mcp-socket"), i + 1 < args.count {
            return args[i + 1]
        }
        return nil
    }

    /// Listen on `path` with a main-queue server: the session's Model is
    /// main-thread-only. A client gets a session over the document that is
    /// active when it CONNECTS; with no document open it is refused.
    func setupMcpSocket(path: String) {
        do {
            mcpServer = try McpSocketServer(path: path, queue: .main) { [weak self] in
                guard let model = self?.workspace?.activeModel else { return nil }
                return McpSession(model: model)
            }
            NSLog("mcp-socket: listening on %@", path)
        } catch {
            NSLog("mcp-socket: cannot listen on %@ (%@)", path, String(describing: error))
        }
    }
}
