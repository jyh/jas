using Windows.ApplicationModel.DataTransfer;

namespace SbWinUi;

/// <summary>
/// The system clipboard, as plain text (jas §364, plan § 5 slice 8). Every
/// call is made ON THE UI THREAD: the clipboard is the UI thread's.
///
/// It lives outside <see cref="Canvas"/> because that class is `unsafe`, and
/// an `await` cannot be written in an unsafe context.
/// </summary>
internal static class ClipboardShell
{
    /// <summary>Put <paramref name="text"/> on the clipboard, unchanged, and
    /// flush it so it outlives this process.</summary>
    internal static void Write(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Clipboard.Flush();
    }

    /// <summary>
    /// Read the clipboard's text and hand it to <paramref name="done"/> with a
    /// one-word outcome: the text and `chars=N`, or null and `no-text` when it
    /// holds none, or null and `threw=&lt;type&gt;` when the read throws.
    /// <paramref name="done"/> runs on the UI thread.
    /// </summary>
    internal static async void Read(Action<string?, string> done)
    {
        string? text;
        string outcome;
        try
        {
            var view = Clipboard.GetContent();
            if (view.Contains(StandardDataFormats.Text))
            {
                text = await view.GetTextAsync();
                outcome = $"chars={text.Length}";
            }
            else
            {
                text = null;
                outcome = "no-text";
            }
        }
        catch (Exception ex)
        {
            text = null;
            outcome = $"threw={ex.GetType().Name}";
        }
        done(text, outcome);
    }
}
