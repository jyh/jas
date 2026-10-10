import Foundation

/// The agent API's transport core (docs/AGENT_API.md section 4, node A4 (i)):
/// an MCP server over newline-delimited JSON-RPC 2.0. The twin of Rust's
/// `mcp::Session`, held to it by `test_fixtures/operations/mcp_exchanges.json`,
/// which both ports replay.
///
/// This is the PURE core, `handle(line) -> lines`, with no I/O. The socket the
/// running Mac app owns, and the stdio shim that attaches to it, are A4 (ii)
/// and (iii).
///
/// Edit tools return PROPOSALS and never commit: the model's proposal seam
/// (`Model.propose`) is the only door. ACCEPT and REJECT are the ARTIST's, so
/// they are not tools; the app calls `artistAccept` / `artistReject`, and every
/// artist act that changes the document is reported to a subscribed client,
/// including the withdrawal of its pending proposal.
public final class McpSession {
    /// The MCP revision this core speaks (Rust: `mcp::PROTOCOL_VERSION`).
    public static let protocolVersion = "2025-06-18"
    /// The one resource (Rust: `mcp::DOCUMENT_URI`).
    public static let documentUri = "jas://document"
    /// The journal actor a client's proposals land under (Rust: `mcp::CLIENT_ACTOR`).
    public static let clientActor = "ai"

    public let model: Model
    private var subscribed = false
    private var nextProposal = 0

    public init(model: Model) {
        self.model = model
    }

    /// Answer one incoming JSON-RPC line. Returns the outgoing lines: the
    /// response (if the message was a request) followed by any notifications.
    public func handle(_ line: String) -> [String] {
        guard let data = line.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [Self.error(NSNull(), -32700, "parse error")]
        }
        let method = msg["method"] as? String ?? ""
        // A notification: nothing is owed back.
        guard let id = msg["id"] else { return [] }
        let params = msg["params"] as? [String: Any] ?? [:]
        let uri = params["uri"] as? String
        switch method {
        case "initialize":
            return [Self.result(id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any](), "resources": ["subscribe": true]],
                "serverInfo": ["name": "jas", "version": "0.1.0"],
            ])]
        case "ping":
            return [Self.result(id, [String: Any]())]
        case "tools/list":
            return [Self.result(id, ["tools": Self.toolList()])]
        case "tools/call":
            return callTool(id, params)
        case "resources/list":
            return [Self.result(id, ["resources": [[
                "uri": Self.documentUri, "name": "document", "mimeType": "application/json",
                "description": "The settled document (without any pending preview) and the pending proposal's id.",
            ]]])]
        case "resources/read" where uri == Self.documentUri:
            return [Self.result(id, ["contents": [[
                "uri": Self.documentUri, "mimeType": "application/json", "text": documentResource(),
            ]]])]
        case "resources/read":
            return [Self.error(id, -32602, "unknown resource uri")]
        case "resources/subscribe", "resources/unsubscribe":
            guard uri == Self.documentUri else { return [Self.error(id, -32602, "unknown resource uri")] }
            subscribed = method == "resources/subscribe"
            return [Self.result(id, [String: Any]())]
        default:
            return [Self.error(id, -32601, "method not found: \(method)")]
        }
    }

    /// The artist accepts the pending proposal `id`.
    public func artistAccept(_ id: String) -> [String] {
        artistAct({ $0.acceptProposal(id) == nil }, fate: "accepted")
    }

    /// The artist rejects the pending proposal `id`.
    public func artistReject(_ id: String) -> [String] {
        artistAct({ $0.rejectProposal(id) == nil }, fate: "rejected")
    }

    /// The artist edits the document by hand: `body` runs inside one
    /// transaction. A pending proposal is withdrawn by the model first.
    public func artistEdit(_ body: @escaping (Model) -> Void) -> [String] {
        artistAct({ m in m.withTxn { body(m) }; return false }, fate: "withdrawn")
    }

    /// The artist undoes. A pending proposal is withdrawn first.
    public func artistUndo() -> [String] {
        artistAct({ $0.undo(); return false }, fate: "withdrawn")
    }

    /// Run one artist act and report it: the fate of a proposal that was
    /// pending before the act, and a resource update when the settled document
    /// changed and the client subscribed (Rust: `Session::artist_act`).
    private func artistAct(_ act: (Model) -> Bool, fate: String) -> [String] {
        let beforePending = model.pendingProposalId
        let before = documentToTestJson(model.documentWithoutPreview)
        let decided = act(model)
        var out: [String] = []
        if let p = beforePending, model.pendingProposalId != p {
            out.append(Self.notification("notifications/jas/proposal",
                                         ["proposal": p, "state": decided ? fate : "withdrawn"]))
        }
        if subscribed && documentToTestJson(model.documentWithoutPreview) != before {
            out.append(Self.notification("notifications/resources/updated", ["uri": Self.documentUri]))
        }
        return out
    }

    private func documentResource() -> String {
        let doc = (try? JSONSerialization.jsonObject(
            with: Data(documentToTestJson(model.documentWithoutPreview).utf8))) ?? NSNull()
        let obj: [String: Any] = ["document": doc, "pending_proposal": model.pendingProposalId ?? NSNull()]
        return Self.encode(obj)
    }

    private func callTool(_ id: Any, _ params: [String: Any]) -> [String] {
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String ?? "" {
        case "propose":
            guard let name = args["name"] as? String, let ops = args["ops"] as? [Any] else {
                return [Self.error(id, -32602, "propose needs `name` (string) and `ops` (array)")]
            }
            let pid = "p-\(nextProposal)"
            if let r = model.propose(id: pid, actor: Self.clientActor, name: name,
                                     ops: ops.map { $0 as? [String: Any] ?? [:] }) {
                return [Self.toolResult(id, true, Self.refusalText(r), ["refused": Self.refusalText(r)])]
            }
            nextProposal += 1
            return [Self.toolResult(id, false,
                                    "proposal \(pid) is shown to the artist; it lands only if the artist accepts it",
                                    ["proposal": pid])]
        case "withdraw_proposal":
            let pid = args["proposal"] as? String ?? ""
            if let r = model.rejectProposal(pid) {
                return [Self.toolResult(id, true, Self.refusalText(r), ["refused": Self.refusalText(r)])]
            }
            return [Self.toolResult(id, false, "proposal \(pid) withdrawn", ["proposal": pid])]
        case let other:
            return [Self.error(id, -32602, "unknown tool: \(other)")]
        }
    }

    /// The tool list (Rust: `mcp::tool_list`). The edit vocabulary is the
    /// primitive ops, validated by the model.
    private static func toolList() -> [[String: Any]] {
        [
            [
                "name": "propose",
                "description": "Propose an edit to the artist. The edit is shown on the canvas and is NOT applied: it lands as one undoable step only if the artist accepts it. Returns a proposal id. At most one proposal is pending; an artist edit withdraws it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "the action verb that names this edit"],
                        "ops": ["type": "array", "items": ["type": "object", "required": ["op"]],
                                "description": "primitive document ops, applied in order"],
                    ],
                    "required": ["name", "ops"],
                ],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
            [
                "name": "withdraw_proposal",
                "description": "Withdraw your own pending proposal before the artist decides.",
                "inputSchema": ["type": "object", "properties": ["proposal": ["type": "string"]],
                                "required": ["proposal"]],
                "annotations": ["readOnlyHint": false, "destructiveHint": false],
            ],
        ]
    }

    private static func refusalText(_ r: ProposalRefusal) -> String {
        switch r {
        case .anotherPending(let p): return "refused: proposal \(p) is still pending"
        case .transactionOpen: return "refused: the document is mid-edit"
        case .notPending(let p): return "refused: proposal \(p) is not pending"
        case .opFailed(let e): return "refused: an op failed: \(e)"
        }
    }

    private static func encode(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    private static func result(_ id: Any, _ r: Any) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": r])
    }

    private static func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func notification(_ method: String, _ params: Any) -> String {
        encode(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private static func toolResult(_ id: Any, _ isError: Bool, _ text: String, _ structured: Any) -> String {
        result(id, ["content": [["type": "text", "text": text]], "structuredContent": structured, "isError": isError])
    }
}
