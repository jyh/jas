using System.Collections.Concurrent;
using System.IO.Pipes;

namespace SbWinUi;

/// <summary>
/// (A) W1b: the agent pipe, `\\.\pipe\jas-mcp-&lt;pid&gt;` (A6 F2 (a)), as the
/// Mac's app serves its socket. ONE CLIENT AT A TIME. `CurrentUserOnly`: only a
/// process of the user who runs the shell may connect, which is what the accept
/// bar exists to keep (any local process driving the canvas is the property F2
/// refused TCP for).
///
/// THE THREADS, AND WHY THERE ARE TWO. The reader thread accepts a client and
/// splits its bytes into whole lines (McpWire.LineSplitter), posting each to
/// the render queue; the engine is the render thread's (BL2), so no line is
/// handled here. The engine's answers come back on the render thread and are
/// put in an OUTBOX, which a writer thread drains to the pipe: a client that
/// stops reading blocks that writer, never the render thread (the plan's
/// 10-09 caveat: a reply owed while the render thread is busy).
/// </summary>
internal sealed class McpPipe : IDisposable
{
    /// <summary>The longest line a client may send, in bytes; a longer one is refused by name.</summary>
    internal const int LineCap = 1 << 20;

    private readonly string _name;
    private readonly Action<bool> _attached;
    private readonly Action<byte[]> _line;
    private readonly Action<string> _report;
    private readonly BlockingCollection<byte[]> _outbox = new();
    private volatile NamedPipeServerStream? _client;
    private volatile bool _stopping;
    private Thread? _reader;
    private Thread? _writer;

    internal McpPipe(string name, Action<bool> attached, Action<byte[]> line, Action<string> report)
    {
        _name = name;
        _attached = attached;
        _line = line;
        _report = report;
    }

    /// <summary>The full pipe path a client opens.</summary>
    internal string Path => @"\\.\pipe\" + _name;

    internal void Start()
    {
        _reader = new Thread(ReadLoop) { IsBackground = true, Name = "mcp-pipe-reader" };
        _writer = new Thread(WriteLoop) { IsBackground = true, Name = "mcp-pipe-writer" };
        _reader.Start();
        _writer.Start();
        _report($"MCP LISTENING pipe={Path} one-client current-user-only");
    }

    /// <summary>Owed to the client; called on the render thread. Dropped when no client is attached.</summary>
    internal void Write(byte[] bytes)
    {
        if (_client is null || _stopping) { return; }
        _outbox.Add(bytes);
    }

    private void ReadLoop()
    {
        var buf = new byte[64 * 1024];
        while (!_stopping)
        {
            NamedPipeServerStream server;
            try
            {
                // ASYNCHRONOUS IS LOAD-BEARING (measured 11-11): on a synchronous
                // handle Windows serializes I/O, so the writer's Write waited
                // behind the reader's blocked Read and every reply was dropped
                // at detach. An overlapped handle lets the two run at once.
                server = new NamedPipeServerStream(_name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
                                                   PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                server.WaitForConnection();
            }
            catch (Exception ex)
            {
                _report($"RUSTFAIL MCP PIPE REFUSED pipe={Path} -- {ex.GetType().Name}: {ex.Message}");
                return;
            }
            _client = server;
            _attached(true);
            var split = new McpWire.LineSplitter(LineCap);
            try
            {
                while (!_stopping)
                {
                    var n = server.Read(buf, 0, buf.Length);
                    if (n <= 0) { break; }
                    foreach (var line in split.Feed(buf.AsSpan(0, n)))
                    {
                        if (line is null)
                        {
                            _report($"RUSTFAIL MCP LINE REFUSED -- longer than {LineCap} bytes; the next line still reads");
                            continue;
                        }
                        _line(line);
                    }
                }
            }
            catch (IOException) { /* the client went away mid-read: a detach, said below */ }
            _client = null;
            _attached(false);
            try { server.Dispose(); } catch (IOException) { }
        }
    }

    private void WriteLoop()
    {
        foreach (var bytes in _outbox.GetConsumingEnumerable())
        {
            var c = _client;
            if (c is null) { continue; }
            try
            {
                c.Write(bytes, 0, bytes.Length);
                c.Flush();
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidOperationException)
            {
                _report($"MCP OUT DROPPED bytes={bytes.Length} -- the client is gone ({ex.GetType().Name})");
            }
        }
    }

    public void Dispose()
    {
        _stopping = true;
        _outbox.CompleteAdding();
        try { _client?.Dispose(); } catch (IOException) { }
    }
}
