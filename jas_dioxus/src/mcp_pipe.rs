//! `jas_mcp --attach` on Windows (O25 A6 R3): relay a stdio MCP client to a
//! RUNNING Windows shell's named pipe, as `mcp::relay_attached` relays one to
//! the Mac app's Unix socket.
//!
//! The shell serves `\\.\pipe\jas-mcp-<pid>`: byte mode, overlapped, the
//! current user only, one client at a time, LF-terminated lines both ways.
//!
//! ⛔ WHY THIS IS NOT `std::fs::File`, AND IT IS THE WHOLE DESIGN. A relay reads
//! the pipe on one thread (the shell's pushes must reach the client while no
//! request is in flight) and writes it on another. A handle opened WITHOUT
//! `FILE_FLAG_OVERLAPPED` is synchronous, and Windows serialises every I/O on
//! a synchronous file object: the write waits behind the blocked read, the
//! shell never receives the request it is waiting for, and both sides wait
//! for ever. `File::try_clone` duplicates the handle, not the file object, so
//! it does not help. So the pipe is opened overlapped and each direction owns
//! its own `OVERLAPPED` and event. The functions are declared here from
//! kernel32 rather than through a crate: nine calls do not earn a dependency.
//!
//! ⛔ AND THE PIPE CANNOT BE HALF-CLOSED. On the Mac, stdin's end shuts the
//! socket's write half; the app reads EOF, finishes, and closes. A pipe has no
//! half-close, so here the relay counts the REQUESTS it forwarded (a line with
//! an `id` and a `method`) and the RESPONSES it relayed back (an `id` and no
//! `method`). After stdin ends it waits for every request to be answered, then
//! closes. A piped one-shot (`printf '<request>' | jas_mcp --attach`) therefore
//! gets its answer.

use std::ffi::c_void;
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};

type Handle = *mut c_void;
type Bool = i32;

const INVALID_HANDLE_VALUE: Handle = -1isize as Handle;
const GENERIC_READ: u32 = 0x8000_0000;
const GENERIC_WRITE: u32 = 0x4000_0000;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_OVERLAPPED: u32 = 0x4000_0000;
const ERROR_FILE_NOT_FOUND: i32 = 2;
const ERROR_HANDLE_EOF: i32 = 38;
const ERROR_BROKEN_PIPE: i32 = 109;
const ERROR_PIPE_BUSY: i32 = 231;
const ERROR_OPERATION_ABORTED: i32 = 995;
const ERROR_IO_PENDING: i32 = 997;

/// `OVERLAPPED`, with its offset union written as the two `u32`s a pipe uses
/// (the union is the same size and alignment either way).
#[repr(C)]
struct Overlapped {
    internal: usize,
    internal_high: usize,
    offset: u32,
    offset_high: u32,
    h_event: Handle,
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateFileW(name: *const u16, access: u32, share: u32, security: *mut c_void,
                   disposition: u32, flags: u32, template: Handle) -> Handle;
    fn ReadFile(h: Handle, buf: *mut u8, len: u32, read: *mut u32, ov: *mut Overlapped) -> Bool;
    fn WriteFile(h: Handle, buf: *const u8, len: u32, written: *mut u32, ov: *mut Overlapped) -> Bool;
    fn GetOverlappedResult(h: Handle, ov: *mut Overlapped, n: *mut u32, wait: Bool) -> Bool;
    fn CreateEventW(security: *mut c_void, manual_reset: Bool, initial: Bool, name: *const u16) -> Handle;
    fn CancelIoEx(h: Handle, ov: *mut Overlapped) -> Bool;
    fn CloseHandle(h: Handle) -> Bool;
}

/// The pipe's handle. Shared by the two directions, closed once by whoever
/// drops the last reference. Each direction does its OWN overlapped I/O on
/// it, so sharing it is what the overlapped open is for.
struct Pipe(Handle);
// SAFETY: a Win32 handle may be used from any thread; each direction's
// OVERLAPPED and event are its own, so no I/O state is shared.
unsafe impl Send for Pipe {}
unsafe impl Sync for Pipe {}

impl Drop for Pipe {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

/// One direction of the pipe: its own manual-reset event for its own
/// `OVERLAPPED`, so a completion in the other direction never wakes it.
struct Half {
    pipe: Arc<Pipe>,
    event: Handle,
    /// Set once the relay is closing: a read not yet started returns EOF
    /// instead of starting (the close's cancel cannot reach a read that has
    /// not begun).
    closing: Arc<AtomicBool>,
}
unsafe impl Send for Half {}

impl Half {
    fn new(pipe: Arc<Pipe>, closing: Arc<AtomicBool>) -> std::io::Result<Self> {
        let event = unsafe { CreateEventW(std::ptr::null_mut(), 1, 0, std::ptr::null()) };
        if event.is_null() {
            return Err(std::io::Error::last_os_error());
        }
        Ok(Half { pipe, event, closing })
    }

    fn overlapped(&self) -> Overlapped {
        Overlapped { internal: 0, internal_high: 0, offset: 0, offset_high: 0, h_event: self.event }
    }

    /// Wait for an operation `started` began. `Ok(None)` is the far end gone.
    fn finish(&self, started: Bool, ov: &mut Overlapped) -> std::io::Result<Option<u32>> {
        if started == 0 {
            let e = std::io::Error::last_os_error();
            match e.raw_os_error() {
                Some(ERROR_IO_PENDING) => {}
                Some(ERROR_BROKEN_PIPE | ERROR_HANDLE_EOF | ERROR_OPERATION_ABORTED) => return Ok(None),
                _ => return Err(e),
            }
        }
        let mut n = 0u32;
        if unsafe { GetOverlappedResult(self.pipe.0, ov, &mut n, 1) } == 0 {
            let e = std::io::Error::last_os_error();
            return match e.raw_os_error() {
                Some(ERROR_BROKEN_PIPE | ERROR_HANDLE_EOF | ERROR_OPERATION_ABORTED) => Ok(None),
                _ => Err(e),
            };
        }
        Ok(Some(n))
    }
}

impl Drop for Half {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.event) };
    }
}

impl std::io::Read for Half {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.closing.load(Ordering::SeqCst) {
            return Ok(0);
        }
        let mut ov = self.overlapped();
        let len = buf.len().min(u32::MAX as usize) as u32;
        let started = unsafe { ReadFile(self.pipe.0, buf.as_mut_ptr(), len, std::ptr::null_mut(), &mut ov) };
        Ok(self.finish(started, &mut ov)?.unwrap_or(0) as usize)
    }
}

impl Write for Half {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let mut ov = self.overlapped();
        let len = buf.len().min(u32::MAX as usize) as u32;
        let started = unsafe { WriteFile(self.pipe.0, buf.as_ptr(), len, std::ptr::null_mut(), &mut ov) };
        match self.finish(started, &mut ov)? {
            Some(n) => Ok(n as usize),
            None => Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "the shell closed the pipe")),
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Why an attach failed, in the words a person at the command line needs.
fn open_error(path: &str, e: std::io::Error) -> std::io::Error {
    let why = match e.raw_os_error() {
        Some(ERROR_FILE_NOT_FOUND) => "no such pipe (is the shell running with SB_MCP_PIPE=1?)",
        Some(ERROR_PIPE_BUSY) => "another client is attached (the shell serves one at a time)",
        _ => "",
    };
    std::io::Error::new(e.kind(), format!("cannot attach to {path}: {e} {why}").trim_end().to_string())
}

/// Open the shell's pipe for overlapped reading and writing.
fn open(path: &str) -> std::io::Result<Arc<Pipe>> {
    let wide: Vec<u16> = path.encode_utf16().chain(std::iter::once(0)).collect();
    let h = unsafe {
        CreateFileW(wide.as_ptr(), GENERIC_READ | GENERIC_WRITE, 0, std::ptr::null_mut(),
                    OPEN_EXISTING, FILE_FLAG_OVERLAPPED, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(open_error(path, std::io::Error::last_os_error()));
    }
    Ok(Arc::new(Pipe(h)))
}

/// The one pipe a running shell serves, when `--attach` is given no path:
/// the single `jas-mcp-*` entry under `\\.\pipe\`. None, or more than one,
/// is an error that names what it found.
pub fn discover() -> std::io::Result<String> {
    let mut found: Vec<String> = std::fs::read_dir(r"\\.\pipe\")?
        .filter_map(|e| e.ok())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.starts_with("jas-mcp-"))
        .collect();
    found.sort();
    match found.as_slice() {
        [one] => Ok(format!(r"\\.\pipe\{one}")),
        [] => Err(std::io::Error::new(std::io::ErrorKind::NotFound,
            "no jas-mcp-* pipe: is the shell running with SB_MCP_PIPE=1?")),
        many => Err(std::io::Error::other(format!(
            "{} jas-mcp-* pipes ({}): pass one to --attach", many.len(), many.join(", ")))),
    }
}

/// What a relayed line is to the request/response count.
enum Kind {
    Request(String),
    Response(String),
    Other,
}

fn kind(line: &str) -> Kind {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(line) else { return Kind::Other };
    match (v.get("id"), v.get("method")) {
        (Some(id), Some(_)) if !id.is_null() => Kind::Request(id.to_string()),
        (Some(id), None) => Kind::Response(id.to_string()),
        _ => Kind::Other,
    }
}

/// The requests forwarded and not yet answered, and whether the shell has
/// gone (so a wait for answers that will never come ends).
#[derive(Default)]
struct Outstanding {
    ids: Vec<String>,
    gone: bool,
}

/// Relay `input` (the client's stdin) to the shell's pipe at `path`, and the
/// pipe to `output` (its stdout), until `input` ends and every request it
/// carried is answered, or the shell closes the pipe. Returns `output`.
pub fn relay_attached<R, W>(path: &str, input: R, output: W) -> std::io::Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
{
    let pipe = open(path)?;
    relay_pipe(pipe, input, output)
}

fn relay_pipe<R, W>(pipe: Arc<Pipe>, input: R, output: W) -> std::io::Result<W>
where
    R: BufRead,
    W: Write + Send + 'static,
{
    let state = Arc::new((Mutex::new(Outstanding::default()), Condvar::new()));
    let closing = Arc::new(AtomicBool::new(false));
    let reader = Half::new(pipe.clone(), closing.clone())?;
    let down_state = state.clone();
    let down = std::thread::spawn(move || -> std::io::Result<W> {
        let mut output = output;
        let result = (|| {
            for line in BufReader::new(reader).lines() {
                let line = line?;
                writeln!(output, "{line}")?;
                output.flush()?;
                if let Kind::Response(id) = kind(&line) {
                    let (lock, cv) = &*down_state;
                    let mut o = lock.lock().unwrap();
                    if let Some(i) = o.ids.iter().position(|x| *x == id) {
                        o.ids.remove(i);
                    }
                    cv.notify_all();
                }
            }
            Ok(())
        })();
        let (lock, cv) = &*down_state;
        lock.lock().unwrap().gone = true;
        cv.notify_all();
        result.map(|()| output)
    });
    let mut up = Half::new(pipe.clone(), closing.clone())?;
    let up_result = forward(input, &mut up, &state);
    // Stdin ended (or the pipe broke): wait for every forwarded request's
    // answer, then cancel the pending read so the reader thread returns.
    {
        let (lock, cv) = &*state;
        let mut o = lock.lock().unwrap();
        while !o.gone && !o.ids.is_empty() {
            o = cv.wait(o).unwrap();
        }
    }
    // A cancel reaches only a read already pending, so repeat it until the
    // reader thread has returned; `closing` stops it starting another.
    closing.store(true, Ordering::SeqCst);
    while !down.is_finished() {
        unsafe { CancelIoEx(pipe.0, std::ptr::null_mut()) };
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    let out = down.join().map_err(|_| std::io::Error::other("the pipe reader panicked"))?;
    up_result?;
    out
}

/// Forward the client's lines to the pipe, counting each request.
fn forward<R: BufRead>(input: R, up: &mut Half, state: &(Mutex<Outstanding>, Condvar)) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if let Kind::Request(id) = kind(&line) {
            state.0.lock().unwrap().ids.push(id);
        }
        up.write_all(line.as_bytes())?;
        up.write_all(b"\n")?;
    }
    Ok(())
}

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    const PIPE_ACCESS_DUPLEX: u32 = 3;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn CreateNamedPipeW(name: *const u16, open_mode: u32, pipe_mode: u32, max_instances: u32,
                            out_buf: u32, in_buf: u32, timeout: u32, security: *mut c_void) -> Handle;
        fn ConnectNamedPipe(h: Handle, ov: *mut Overlapped) -> Bool;
    }

    struct Server(Handle);
    unsafe impl Send for Server {}

    /// A synchronous one-client pipe server standing in for the shell.
    fn server(name: &str) -> Server {
        let wide: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        let h = unsafe { CreateNamedPipeW(wide.as_ptr(), PIPE_ACCESS_DUPLEX, 0, 1, 4096, 4096, 0,
                                          std::ptr::null_mut()) };
        assert_ne!(h, INVALID_HANDLE_VALUE, "{}", std::io::Error::last_os_error());
        Server(h)
    }

    fn server_read_line(s: &Server) -> Option<String> {
        let mut line = Vec::new();
        let mut b = [0u8; 1];
        loop {
            let mut n = 0u32;
            if unsafe { ReadFile(s.0, b.as_mut_ptr(), 1, &mut n, std::ptr::null_mut()) } == 0 || n == 0 {
                return None;
            }
            if b[0] == b'\n' {
                return Some(String::from_utf8(line).unwrap());
            }
            line.push(b[0]);
        }
    }

    fn server_write(s: &Server, text: &str) {
        let mut n = 0u32;
        let ok = unsafe { WriteFile(s.0, text.as_ptr(), text.len() as u32, &mut n, std::ptr::null_mut()) };
        assert!(ok != 0 && n as usize == text.len(), "{}", std::io::Error::last_os_error());
    }

    /// Run the relay on its own thread, bounded: a deadlocked relay must FAIL
    /// this test, not hang the lane (a hung test is not a red one).
    fn relay_bounded(path: String, stdin: &'static [u8]) -> String {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(relay_attached(&path, std::io::Cursor::new(stdin), Vec::<u8>::new()));
        });
        let out = rx.recv_timeout(std::time::Duration::from_secs(20))
            .expect("the relay returned within 20 s (a synchronous pipe handle deadlocks here)")
            .expect("the relay finishes");
        String::from_utf8(out).unwrap()
    }

    /// The case that deadlocks a synchronous handle: the relay's reader is
    /// already blocked in a read when the client's request must be written.
    /// The server waits before it reads, so the relay's read is pending first,
    /// then it answers the request, pushes a line of its own (an artist act),
    /// and closes only after the client does.
    #[test]
    fn attach_writes_while_a_read_is_pending_and_relays_both_ways() {
        let name = format!(r"\\.\pipe\jas-mcp-test-{}-a", std::process::id());
        let s = server(&name);
        let app = std::thread::spawn(move || {
            let s = s;
            unsafe { ConnectNamedPipe(s.0, std::ptr::null_mut()) };
            std::thread::sleep(std::time::Duration::from_millis(300));
            let req = server_read_line(&s).expect("the request reaches the shell");
            assert!(req.contains(r#""id":1"#), "{req}");
            server_write(&s, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/jas/proposal\",\"params\":{}}\n");
            server_write(&s, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n");
            // Read until the relay closes its end.
            while server_read_line(&s).is_some() {}
            unsafe { CloseHandle(s.0) };
        });
        let out = relay_bounded(name, b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n");
        app.join().unwrap();
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 2, "{out}");
        assert!(lines[0].contains("notifications/jas/proposal"), "the shell's push is relayed: {out}");
        assert!(lines[1].contains(r#""id":1"#), "the answer is relayed: {out}");
    }

    /// A piped one-shot: stdin ends right after the request, and the relay
    /// still waits for the answer (a pipe has no half-close to say so).
    #[test]
    fn attach_waits_for_the_answer_after_stdin_ends() {
        let name = format!(r"\\.\pipe\jas-mcp-test-{}-b", std::process::id());
        let s = server(&name);
        let app = std::thread::spawn(move || {
            let s = s;
            unsafe { ConnectNamedPipe(s.0, std::ptr::null_mut()) };
            let _ = server_read_line(&s).expect("the request reaches the shell");
            std::thread::sleep(std::time::Duration::from_millis(500));
            server_write(&s, "{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"result\":{\"ok\":true}}\n");
            while server_read_line(&s).is_some() {}
            unsafe { CloseHandle(s.0) };
        });
        let out = relay_bounded(name, b"{\"jsonrpc\":\"2.0\",\"id\":\"r\",\"method\":\"ping\"}\n");
        app.join().unwrap();
        assert_eq!(out.lines().count(), 1, "{out}");
        assert!(out.contains(r#""ok":true"#), "{out}");
    }

    /// No such pipe: the error names the knob that serves one.
    #[test]
    fn attach_to_a_missing_pipe_names_the_shell_knob() {
        let path = format!(r"\\.\pipe\jas-mcp-test-{}-absent", std::process::id());
        let e = relay_attached(&path, std::io::Cursor::new(Vec::<u8>::new()), Vec::<u8>::new())
            .err().expect("no pipe, no relay");
        assert!(e.to_string().contains("SB_MCP_PIPE=1"), "{e}");
    }

    /// The request/response count reads JSON-RPC's own shapes.
    #[test]
    fn a_line_is_a_request_a_response_or_neither() {
        assert!(matches!(kind(r#"{"id":1,"method":"ping"}"#), Kind::Request(id) if id == "1"));
        assert!(matches!(kind(r#"{"id":"a","result":{}}"#), Kind::Response(id) if id == "\"a\""));
        assert!(matches!(kind(r#"{"method":"notifications/x"}"#), Kind::Other));
        assert!(matches!(kind("not json"), Kind::Other));
    }
}
