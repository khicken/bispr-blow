using System.Runtime.InteropServices;

namespace BisprBlow;

// Inserts text into the focused field of the frontmost app via the clipboard + a synthetic Ctrl+V,
// then restores the previous clipboard contents.
static class TextInserter
{
    // Completes with false when the clipboard could not be written; otherwise as soon as the text is
    // on it, with the paste and the clipboard restore finishing in the background. A target running
    // as administrator ignores synthetic keys from this process, which cannot be told apart from
    // success, so the text is on the clipboard either way.
    // `thenReturn` presses Enter once the paste has landed — the "dictate and send" binding.
    public static Task<bool> InsertAsync(string text, bool thenReturn = false)
    {
        var staged = new TaskCompletionSource<bool>();
        _ = Task.Run(async () =>
        {
            List<(uint Format, byte[] Data)> saved;
            uint written;
            try
            {
                if (!await OpenClipboardAsync()) { staged.SetResult(false); return; }
                try
                {
                    saved = SavedItems();
                    EmptyClipboard();
                    SetBytes(13, System.Text.Encoding.Unicode.GetBytes(text + "\0"));  // CF_UNICODETEXT
                    // Hint clipboard history and sync to skip this transient write.
                    SetBytes(RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing"), [0]);
                    SetBytes(RegisterClipboardFormat("CanIncludeInClipboardHistory"), new byte[4]);
                    SetBytes(RegisterClipboardFormat("CanUploadToCloudClipboard"), new byte[4]);
                }
                finally { CloseClipboard(); }
                written = GetClipboardSequenceNumber();
                staged.SetResult(true);
            }
            catch (Exception e)
            {
                Log.Line($"clipboard write failed: {e.Message}");
                staged.TrySetResult(false);
                return;
            }

            try
            {
                // Let the clipboard write commit before synthesizing the paste.
                await Task.Delay(100);
                await ModifiersReleasedAsync();
                SendKeys((0x11, true), (0x56, true), (0x56, false), (0x11, false));  // Ctrl+V
                // Enter goes after the paste, on its own delay: sending before the field has the
                // text submits an empty message.
                await Task.Delay(120);
                if (thenReturn)
                {
                    await ModifiersReleasedAsync();
                    SendKeys((0x0D, true), (0x0D, false));
                }
                // Restore after the paste lands; slow Electron apps read the clipboard late. Not if the
                // user has copied something since: that is newer than what is being restored.
                await Task.Delay(480);
                if (GetClipboardSequenceNumber() != written || !await OpenClipboardAsync()) return;
                try
                {
                    EmptyClipboard();
                    foreach (var (format, data) in saved) SetBytes(format, data);
                }
                finally { CloseClipboard(); }
            }
            catch (Exception e) { Log.Line($"paste failed: {e.Message}"); }
        });
        return staged.Task;
    }

    // Edges sent in one call, so no keystroke from the user can land between them. Events sent this
    // way carry the injected flag, which is how the shortcut hooks know to ignore them.
    public static void SendKeys(params (int Vk, bool Down)[] edges)
    {
        var inputs = edges.Select(e => new Input { Type = 1, Vk = (ushort)e.Vk, Flags = e.Down ? 0u : 2u }).ToArray();
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
    }

    // The shortcut's own modifiers may still be down (a locked session stops on Ctrl+Win going down):
    // pasting then reaches the target as Win+Ctrl+V, and the injected Ctrl-up releases the user's Ctrl.
    // Gives up after a second rather than holding the text back for a user who is resting a key.
    static async Task ModifiersReleasedAsync()
    {
        var deadline = DateTime.UtcNow.AddSeconds(1);
        while (DateTime.UtcNow < deadline && new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(vk => (ShortcutMonitor.GetAsyncKeyState(vk) & 0x8000) != 0))
            await Task.Delay(15);
    }

    // Another process can hold the clipboard open for a few ms; clipboard managers do.
    static async Task<bool> OpenClipboardAsync()
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            if (OpenClipboard(DesktopWindow)) return true;
            await Task.Delay(20);
        }
        return false;
    }

    // Every format of the clipboard's one entry, so a copied image, file list or rich text survives
    // the paste. Handle-based formats (bitmaps, metafiles) are skipped: Windows derives them from the
    // memory formats it keeps. Over the cap, only the plain text is kept, since reading a delayed
    // format makes the source app render it now.
    static List<(uint Format, byte[] Data)> SavedItems()
    {
        const int cap = 20_000_000;
        var total = 0;
        var items = new List<(uint, byte[])>();
        for (var format = EnumClipboardFormats(0); format != 0; format = EnumClipboardFormats(format))
        {
            if (format is 2 or 3 or 9 or 14 or 0x80 or >= 0x200 and <= 0x3FF) continue;
            var handle = GetClipboardData(format);
            if (handle == IntPtr.Zero) continue;
            var size = (int)GlobalSize(handle);
            var memory = GlobalLock(handle);
            if (memory == IntPtr.Zero) continue;
            try
            {
                total += size;
                if (total > cap) return TextOnly();
                var data = new byte[size];
                Marshal.Copy(memory, data, 0, size);
                items.Add((format, data));
            }
            finally { GlobalUnlock(handle); }
        }
        return items;
    }

    static List<(uint Format, byte[] Data)> TextOnly()
    {
        var handle = GetClipboardData(13);
        var memory = handle == IntPtr.Zero ? IntPtr.Zero : GlobalLock(handle);
        if (memory == IntPtr.Zero) return [];
        try
        {
            var data = new byte[(int)GlobalSize(handle)];
            Marshal.Copy(memory, data, 0, data.Length);
            return [(13, data)];
        }
        finally { GlobalUnlock(handle); }
    }

    static void SetBytes(uint format, byte[] data)
    {
        var handle = GlobalAlloc(0x2, (nuint)data.Length);  // GMEM_MOVEABLE
        if (handle == IntPtr.Zero) return;
        Marshal.Copy(data, 0, GlobalLock(handle), data.Length);
        GlobalUnlock(handle);
        if (SetClipboardData(format, handle) == IntPtr.Zero) GlobalFree(handle);
    }

    // The clipboard has to be opened on behalf of some window; the desktop's will do.
    static IntPtr DesktopWindow => GetDesktopWindow();

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    struct Input
    {
        [FieldOffset(0)] public uint Type;
        [FieldOffset(8)] public ushort Vk;
        [FieldOffset(10)] public ushort Scan;
        [FieldOffset(12)] public uint Flags;
    }

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint count, Input[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr owner);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr handle);
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, nuint bytes);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr handle);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr handle);
    [DllImport("kernel32.dll")] static extern nuint GlobalSize(IntPtr handle);
}
