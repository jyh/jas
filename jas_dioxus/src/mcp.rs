//! The agent API's transport core (docs/AGENT_API.md §4, node A3): an MCP
//! server over newline-delimited JSON-RPC 2.0, two-way from the start.
//!
//! This module is the PURE core — `Session::handle(line) -> lines` — with no
//! I/O, so every exchange is unit-testable without a process. The stdio loop
//! that wraps it (a reader thread beside the request loop, so notifications can
//! be pushed while no request is in flight) lives in `bin/jas_mcp.rs`.
//!
//! Edit tools return PROPOSALS and never commit: the model's proposal seam
//! (`Model::propose`) is the only door. ACCEPT and REJECT are the ARTIST's, so
//! they are not tools; the app calls [`Session::artist_accept`] /
//! [`Session::artist_reject`], and every artist act that changes the document
//! (an edit, an undo) is reported to a subscribed client, including the
//! withdrawal of its pending proposal.

use crate::document::model::{Model, ProposalRefusal};
use crate::geometry::test_json::document_to_test_json;
use serde_json::{json, Value};

/// The MCP revision this core speaks (the one VectorCraft's server also pins;
/// its newer input-request mechanism is A3's next step, not this slice's).
pub const PROTOCOL_VERSION: &str = "2025-06-18";
/// The one resource: the settled document plus the pending proposal's id.
pub const DOCUMENT_URI: &str = "jas://document";
/// The journal actor a client's proposals land under (OP_LOG.md §5).
pub const CLIENT_ACTOR: &str = "ai";

/// One MCP session over one document.
pub struct Session {
    model: Model,
    subscribed: bool,
    next_proposal: u64,
}

impl Session {
    pub fn new(model: Model) -> Self {
        Session { model, subscribed: false, next_proposal: 0 }
    }

    pub fn model(&self) -> &Model {
        &self.model
    }

    /// Answer one incoming JSON-RPC line. Returns the outgoing lines: the
    /// response (if the message was a request) followed by any notifications.
    pub fn handle(&mut self, line: &str) -> Vec<String> {
        let msg: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => return vec![error(Value::Null, -32700, &format!("parse error: {e}"))],
        };
        let method = msg["method"].as_str().unwrap_or("");
        let Some(id) = msg.get("id").cloned() else {
            // A notification: nothing is owed back (`notifications/initialized`
            // and `notifications/cancelled` need no action in a synchronous core).
            return Vec::new();
        };
        let params = &msg["params"];
        match method {
            "initialize" => vec![result(id, json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}, "resources": {"subscribe": true}},
                "serverInfo": {"name": "jas", "version": env!("CARGO_PKG_VERSION")},
            }))],
            "ping" => vec![result(id, json!({}))],
            "tools/list" => vec![result(id, json!({"tools": tool_list()}))],
            "tools/call" => self.call_tool(id, params),
            "resources/list" => vec![result(id, json!({"resources": [{
                "uri": DOCUMENT_URI, "name": "document", "mimeType": "application/json",
                "description": "The settled document (without any pending preview) and the pending proposal's id."}]}))],
            "resources/read" if params["uri"] == DOCUMENT_URI => {
                vec![result(id, json!({"contents": [{"uri": DOCUMENT_URI,
                    "mimeType": "application/json", "text": self.document_resource().to_string()}]}))]
            }
            "resources/read" => vec![error(id, -32602, "unknown resource uri")],
            "resources/subscribe" | "resources/unsubscribe" if params["uri"] == DOCUMENT_URI => {
                self.subscribed = method == "resources/subscribe";
                vec![result(id, json!({}))]
            }
            "resources/subscribe" | "resources/unsubscribe" => {
                vec![error(id, -32602, "unknown resource uri")]
            }
            _ => vec![error(id, -32601, &format!("method not found: {method}"))],
        }
    }

    /// The artist accepts the pending proposal `id`.
    pub fn artist_accept(&mut self, id: &str) -> Vec<String> {
        self.artist_act(|m| m.accept_proposal(id).is_ok(), "accepted")
    }

    /// The artist rejects the pending proposal `id`.
    pub fn artist_reject(&mut self, id: &str) -> Vec<String> {
        self.artist_act(|m| m.reject_proposal(id).is_ok(), "rejected")
    }

    /// The artist edits the document by hand: `f` runs inside one transaction.
    /// A pending proposal is withdrawn by the model before the edit applies.
    pub fn artist_edit(&mut self, f: impl FnOnce(&mut Model)) -> Vec<String> {
        self.artist_act(|m| { m.with_txn(f); false }, "withdrawn")
    }

    /// The artist undoes. A pending proposal is withdrawn first.
    pub fn artist_undo(&mut self) -> Vec<String> {
        self.artist_act(|m| { m.undo(); false }, "withdrawn")
    }

    /// Run one artist act and report what it did to the client: the fate of a
    /// proposal that was pending before the act (`fate` when the act itself
    /// decided it, else "withdrawn"), and a resource update when the settled
    /// document changed and the client subscribed.
    fn artist_act(&mut self, act: impl FnOnce(&mut Model) -> bool, fate: &str) -> Vec<String> {
        let before_pending = self.model.pending_proposal_id().map(str::to_string);
        let before = document_to_test_json(self.model.document_without_preview());
        let decided = act(&mut self.model);
        let mut out = Vec::new();
        if let Some(p) = before_pending {
            if self.model.pending_proposal_id() != Some(p.as_str()) {
                let state = if decided { fate } else { "withdrawn" };
                out.push(notification("notifications/jas/proposal",
                    json!({"proposal": p, "state": state})));
            }
        }
        if self.subscribed && document_to_test_json(self.model.document_without_preview()) != before {
            out.push(notification("notifications/resources/updated", json!({"uri": DOCUMENT_URI})));
        }
        out
    }

    fn document_resource(&self) -> Value {
        let doc: Value = serde_json::from_str(&document_to_test_json(self.model.document_without_preview()))
            .unwrap_or(Value::Null);
        json!({"document": doc, "pending_proposal": self.model.pending_proposal_id()})
    }

    fn call_tool(&mut self, id: Value, params: &Value) -> Vec<String> {
        let args = &params["arguments"];
        match params["name"].as_str().unwrap_or("") {
            "propose" => {
                let (Some(name), Some(ops)) = (args["name"].as_str(), args["ops"].as_array()) else {
                    return vec![error(id, -32602, "propose needs `name` (string) and `ops` (array)")];
                };
                let pid = format!("p-{}", self.next_proposal);
                match self.model.propose(&pid, CLIENT_ACTOR, name, ops) {
                    Ok(()) => {
                        self.next_proposal += 1;
                        vec![tool_result(id, false, &format!(
                            "proposal {pid} is shown to the artist; it lands only if the artist accepts it"),
                            json!({"proposal": pid}))]
                    }
                    Err(r) => vec![tool_result(id, true, &refusal_text(&r), json!({"refused": refusal_text(&r)}))],
                }
            }
            "withdraw_proposal" => {
                let pid = args["proposal"].as_str().unwrap_or("");
                match self.model.reject_proposal(pid) {
                    Ok(()) => vec![tool_result(id, false, &format!("proposal {pid} withdrawn"),
                        json!({"proposal": pid}))],
                    Err(r) => vec![tool_result(id, true, &refusal_text(&r), json!({"refused": refusal_text(&r)}))],
                }
            }
            other => vec![error(id, -32602, &format!("unknown tool: {other}"))],
        }
    }
}

/// The declared op vocabulary (A3b): every verb `op_apply` accepts, as data.
/// `scripts/check_op_vocabulary.py` asserts both ports' matches equal it.
const OP_VOCABULARY: &str = include_str!("../../test_fixtures/operations/op_vocabulary.json");

/// The verbs of [`OP_VOCABULARY`], sorted. Empty only if the embedded file is
/// malformed, which `propose_declares_the_op_vocabulary_as_an_enum` reds.
fn op_verbs() -> Vec<String> {
    let mut v: Vec<String> = serde_json::from_str::<Value>(OP_VOCABULARY).ok()
        .and_then(|f| f["verbs"].as_object().map(|o| o.keys().cloned().collect()))
        .unwrap_or_default();
    v.sort();
    v
}

/// The tool list. The edit vocabulary is the `op_apply` primitive ops: each
/// op's `op` is an enum of the declared verbs (A3b, docs/AGENT_API.md §4), and
/// the model still validates every op (a failing op refuses the proposal).
/// An op's ARGUMENTS are not declared yet, so the items stay open objects.
fn tool_list() -> Value {
    json!([
        {
            "name": "propose",
            "description": "Propose an edit to the artist. The edit is shown on the canvas and is NOT applied: it lands as one undoable step only if the artist accepts it. Returns a proposal id. At most one proposal is pending; an artist edit withdraws it.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "the action verb that names this edit"},
                    "ops": {"type": "array",
                            "items": {"type": "object", "required": ["op"],
                                      "properties": {"op": {"type": "string", "enum": op_verbs()}}},
                            "description": "primitive document ops, applied in order"}
                },
                "required": ["name", "ops"]
            },
            "annotations": {"readOnlyHint": false, "destructiveHint": false}
        },
        {
            "name": "withdraw_proposal",
            "description": "Withdraw your own pending proposal before the artist decides.",
            "inputSchema": {"type": "object", "properties": {"proposal": {"type": "string"}},
                            "required": ["proposal"]},
            "annotations": {"readOnlyHint": false, "destructiveHint": false}
        }
    ])
}

fn refusal_text(r: &ProposalRefusal) -> String {
    match r {
        ProposalRefusal::AnotherPending(p) => format!("refused: proposal {p} is still pending"),
        ProposalRefusal::TransactionOpen => "refused: the document is mid-edit".to_string(),
        ProposalRefusal::NotPending(p) => format!("refused: proposal {p} is not pending"),
        ProposalRefusal::OpFailed(e) => format!("refused: an op failed: {e}"),
    }
}

fn result(id: Value, r: Value) -> String {
    json!({"jsonrpc": "2.0", "id": id, "result": r}).to_string()
}

fn error(id: Value, code: i64, message: &str) -> String {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}).to_string()
}

fn notification(method: &str, params: Value) -> String {
    json!({"jsonrpc": "2.0", "method": method, "params": params}).to_string()
}

fn tool_result(id: Value, is_error: bool, text: &str, structured: Value) -> String {
    result(id, json!({"content": [{"type": "text", "text": text}],
        "structuredContent": structured, "isError": is_error}))
}

/// A4 (iii): relay a stdio MCP client to a RUNNING app's socket (the Mac app
/// owns it; `JasSwift`'s `McpSocketServer`). A stdio client always spawns a
/// fresh process, and this is how that process reaches the app instead of
/// serving a document of its own: `jas_mcp --attach <path>`.
///
/// Lines from `input` go to the socket; lines from the socket go to `output`.
/// When `input` ends, the socket's write half is shut down, so the app reads
/// EOF and closes; the relay returns once the socket's read half ends too,
/// handing back `output`. A thread owns the socket-to-output half, so the
/// app's pushes (an artist's accept or edit) reach the client while no
/// request is in flight.
#[cfg(unix)]
pub fn relay_attached<R, W>(stream: std::os::unix::net::UnixStream, input: R, output: W) -> std::io::Result<W>
where
    R: std::io::BufRead,
    W: std::io::Write + Send + 'static,
{
    use std::io::{BufRead, BufReader, Write};
    let reader = stream.try_clone()?;
    let down = std::thread::spawn(move || -> std::io::Result<W> {
        let mut output = output;
        for line in BufReader::new(reader).lines() {
            writeln!(output, "{}", line?)?;
            output.flush()?;
        }
        Ok(output)
    });
    let mut up = stream;
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        writeln!(up, "{line}")?;
        up.flush()?;
    }
    up.shutdown(std::net::Shutdown::Write)?;
    down.join().map_err(|_| std::io::Error::other("the socket reader panicked"))?
}

#[cfg(test)]
mod attach_tests {
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::net::UnixListener;

    /// A4 (iii): `jas_mcp --attach` relays the client's stdio to the app's
    /// socket and back. A real listener stands in for the app: it answers each
    /// line it reads, then keeps reading until the shim closes its write side.
    /// The relay must return (not hang) once stdin ends and the app closes.
    #[test]
    fn attach_relays_stdin_to_the_socket_and_the_socket_to_stdout() {
        let path = std::env::temp_dir().join(format!("jas-attach-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let app = std::thread::spawn(move || {
            let (conn, _) = listener.accept().unwrap();
            let mut w = conn.try_clone().unwrap();
            for line in BufReader::new(conn).lines() {
                let line = line.unwrap();
                writeln!(w, "answer:{line}").unwrap();
            }
            // stdin's EOF reached the app as a read EOF; closing here ends the
            // shim's socket-to-stdout half.
        });
        let stream = std::os::unix::net::UnixStream::connect(&path).unwrap();
        let stdin = std::io::Cursor::new(b"one\ntwo\n".to_vec());
        // Bounded: a relay that never shuts its write half HANGS rather than
        // failing, and a hung test is not a red one.
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || { let _ = tx.send(super::relay_attached(stream, stdin, Vec::<u8>::new())); });
        let out = rx.recv_timeout(std::time::Duration::from_secs(5))
            .expect("the relay returned within 5 s").expect("the relay finishes");
        app.join().unwrap();
        let _ = std::fs::remove_file(&path);
        assert_eq!(String::from_utf8(out).unwrap(), "answer:one\nanswer:two\n");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geometry::svg::svg_to_document;
    use serde_json::{json, Value};

    const TWO_RECTS: &str = include_str!("../../test_fixtures/svg/two_rects.svg");

    fn session() -> Session {
        Session::new(Model::new(svg_to_document(TWO_RECTS), None))
    }

    fn call(s: &mut Session, id: u64, method: &str, params: Value) -> Vec<Value> {
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}).to_string();
        s.handle(&line).iter().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn parse(lines: Vec<String>) -> Vec<Value> {
        lines.iter().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn move_ops() -> Value {
        json!([
            {"op": "select_rect", "x": 0, "y": 0, "width": 50, "height": 50, "extend": false},
            {"op": "move_selection", "dx": 10, "dy": 20}
        ])
    }

    fn propose(s: &mut Session, id: u64) -> Vec<Value> {
        call(s, id, "tools/call", json!({"name": "propose",
            "arguments": {"name": "move", "ops": move_ops()}}))
    }

    /// The proposal id a `propose` call returned, read from its structured content.
    fn proposal_id(out: &[Value]) -> String {
        out[0]["result"]["structuredContent"]["proposal"].as_str()
            .unwrap_or_else(|| panic!("no proposal id in {}", out[0])).to_string()
    }

    fn notifications<'a>(out: &'a [Value], method: &str) -> Vec<&'a Value> {
        out.iter().filter(|m| m["method"] == method && m.get("id").is_none()).collect()
    }

    #[test]
    fn initialize_declares_tools_and_subscribable_resources() {
        let mut s = session();
        let out = call(&mut s, 1, "initialize", json!({"protocolVersion": "2025-06-18",
            "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}));
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["id"], 1);
        let r = &out[0]["result"];
        assert!(r["protocolVersion"].is_string(), "{r}");
        assert!(r["capabilities"]["tools"].is_object(), "{r}");
        assert_eq!(r["capabilities"]["resources"]["subscribe"], true, "{r}");
    }

    #[test]
    fn tools_list_offers_propose_and_never_accept() {
        let mut s = session();
        let out = call(&mut s, 2, "tools/list", json!({}));
        let names: Vec<&str> = out[0]["result"]["tools"].as_array().unwrap()
            .iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert!(names.contains(&"propose"), "{names:?}");
        assert!(names.contains(&"withdraw_proposal"), "{names:?}");
        assert!(!names.iter().any(|n| n.contains("accept")), "accept is the artist's: {names:?}");
        let propose = out[0]["result"]["tools"].as_array().unwrap().iter()
            .find(|t| t["name"] == "propose").unwrap();
        assert_eq!(propose["inputSchema"]["required"], json!(["name", "ops"]));
    }

    /// A3b: the `op` a proposal may carry is an ENUM taken from the declared
    /// vocabulary (`test_fixtures/operations/op_vocabulary.json`), so a client
    /// sees the 51 verbs instead of an untyped object. The expectation is read
    /// from the FILE, not from the code under test, and its size is asserted so
    /// an empty file cannot agree with an empty enum.
    #[test]
    fn propose_declares_the_op_vocabulary_as_an_enum() {
        let mut s = session();
        let out = call(&mut s, 2, "tools/list", json!({}));
        let propose = out[0]["result"]["tools"].as_array().unwrap().iter()
            .find(|t| t["name"] == "propose").unwrap();
        let got: Vec<&str> = propose["inputSchema"]["properties"]["ops"]["items"]["properties"]["op"]["enum"]
            .as_array().expect("an op enum").iter().map(|v| v.as_str().unwrap()).collect();
        let file: Value = serde_json::from_str(&std::fs::read_to_string(
            concat!(env!("CARGO_MANIFEST_DIR"), "/../test_fixtures/operations/op_vocabulary.json")).unwrap()).unwrap();
        let mut want: Vec<&str> = file["verbs"].as_object().unwrap().keys().map(|k| k.as_str()).collect();
        want.sort();
        assert!(want.len() >= 40, "the vocabulary file is not vacuous: {}", want.len());
        assert_eq!(got, want);
    }

    #[test]
    fn propose_previews_and_journals_nothing() {
        let mut s = session();
        let out = propose(&mut s, 3);
        assert_eq!(out[0]["id"], 3);
        assert_eq!(out[0]["result"]["isError"], false, "{}", out[0]);
        let id = proposal_id(&out);
        assert_eq!(s.model().pending_proposal_id(), Some(id.as_str()));
        assert_eq!(s.model().journal_head(), 0, "a proposal is in no transaction");
    }

    #[test]
    fn a_failing_op_is_a_tool_error_and_leaves_nothing_pending() {
        let mut s = session();
        let out = call(&mut s, 4, "tools/call", json!({"name": "propose",
            "arguments": {"name": "bad", "ops": [{"op": "no_such_verb"}]}}));
        assert_eq!(out[0]["result"]["isError"], true, "{}", out[0]);
        assert_eq!(s.model().pending_proposal_id(), None);
    }

    #[test]
    fn document_resource_reports_the_settled_document_and_the_pending_id() {
        let mut s = session();
        let before = call(&mut s, 5, "resources/read", json!({"uri": "jas://document"}));
        let id = proposal_id(&propose(&mut s, 6));
        let during = call(&mut s, 7, "resources/read", json!({"uri": "jas://document"}));
        let body = |v: &Value| -> Value {
            serde_json::from_str(v["result"]["contents"][0]["text"].as_str().unwrap()).unwrap()
        };
        assert_eq!(body(&during[0])["document"], body(&before[0])["document"],
            "the resource is the settled document, not the preview");
        assert_eq!(body(&during[0])["pending_proposal"], json!(id));
        assert_eq!(body(&before[0])["pending_proposal"], Value::Null);
    }

    #[test]
    fn artist_accept_lands_one_ai_transaction_and_notifies() {
        let mut s = session();
        call(&mut s, 8, "resources/subscribe", json!({"uri": "jas://document"}));
        let id = proposal_id(&propose(&mut s, 9));
        let out = parse(s.artist_accept(&id));
        assert_eq!(s.model().journal_head(), 1);
        assert_eq!(s.model().journal()[0].actor, "ai");
        let p = notifications(&out, "notifications/jas/proposal");
        assert_eq!(p.len(), 1, "{out:?}");
        assert_eq!(p[0]["params"], json!({"proposal": id, "state": "accepted"}));
        assert_eq!(notifications(&out, "notifications/resources/updated").len(), 1, "{out:?}");
    }

    #[test]
    fn artist_edit_withdraws_and_tells_the_client() {
        let mut s = session();
        call(&mut s, 10, "resources/subscribe", json!({"uri": "jas://document"}));
        let id = proposal_id(&propose(&mut s, 11));
        let out = parse(s.artist_edit(|m| {
            crate::document::op_apply::op_apply(m, &json!(
                {"op": "select_rect", "x": 0, "y": 0, "width": 200, "height": 200, "extend": false}))
                .unwrap();
            crate::document::op_apply::op_apply(m, &json!({"op": "move_selection", "dx": -5, "dy": -5}))
                .unwrap();
        }));
        assert_eq!(s.model().pending_proposal_id(), None);
        assert_eq!(s.model().journal()[0].actor, "artist");
        let p = notifications(&out, "notifications/jas/proposal");
        assert_eq!(p.len(), 1, "{out:?}");
        assert_eq!(p[0]["params"], json!({"proposal": id, "state": "withdrawn"}));
        assert_eq!(notifications(&out, "notifications/resources/updated").len(), 1, "{out:?}");
    }

    #[test]
    fn artist_reject_and_client_withdraw_both_leave_no_trace() {
        let mut s = session();
        let id = proposal_id(&propose(&mut s, 12));
        let out = parse(s.artist_reject(&id));
        assert_eq!(notifications(&out, "notifications/jas/proposal")[0]["params"]["state"], "rejected");
        let id2 = proposal_id(&propose(&mut s, 13));
        let w = call(&mut s, 14, "tools/call", json!({"name": "withdraw_proposal",
            "arguments": {"proposal": id2}}));
        assert_eq!(w[0]["result"]["isError"], false, "{}", w[0]);
        assert_eq!(s.model().pending_proposal_id(), None);
        assert_eq!(s.model().journal_head(), 0);
    }

    #[test]
    fn no_notifications_without_a_subscription() {
        let mut s = session();
        let id = proposal_id(&propose(&mut s, 15));
        let out = parse(s.artist_accept(&id));
        assert!(notifications(&out, "notifications/resources/updated").is_empty(), "{out:?}");
        // The proposal's own fate is always reported: the client asked for it.
        assert_eq!(notifications(&out, "notifications/jas/proposal").len(), 1);
    }

    #[test]
    fn protocol_errors_are_json_rpc_errors() {
        let mut s = session();
        let unknown = call(&mut s, 16, "no/such/method", json!({}));
        assert_eq!(unknown[0]["error"]["code"], -32601);
        let bad = parse(s.handle("{not json"));
        assert_eq!(bad[0]["error"]["code"], -32700);
        // A notification (no id) gets no response.
        assert!(s.handle(r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).is_empty());
    }
}
