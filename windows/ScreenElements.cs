using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;

namespace BisprBlow;

// What a voice command can act on: the pressable and typeable things in the front app's window and
// menu bar as UI Automation exposes them, plus the other apps that are running. Read on demand,
// never kept: it is a snapshot of someone else's screen.
public record ScreenElement(string Label, ScreenElement.ElementKind Kind, AutomationElement? Element = null,
                            (string Name, IntPtr Window)? App = null)
{
    public enum ElementKind { Press, Field, App }
}

static class ScreenElements
{
    // Enough for a busy window; past this the choice list is noise and Jev slows down.
    const int WindowLimit = 200;
    const int MenuLimit = 60;
    const int NodeBudget = 4000;
    // Notes once took 30s to walk; past this the command runs on what was read so far.
    static readonly TimeSpan TimeBudget = TimeSpan.FromSeconds(0.5);
    static readonly ControlType[] FieldTypes = [ControlType.Edit, ControlType.ComboBox];

    // Only what a walk reads, fetched in the same call that finds the element: one cross-process round
    // trip per node instead of one per property.
    static readonly CacheRequest Cache = BuildCache();

    static CacheRequest BuildCache()
    {
        var cache = new CacheRequest { AutomationElementMode = AutomationElementMode.Full, TreeScope = TreeScope.Element };
        foreach (var property in new[]
        {
            AutomationElement.NameProperty, AutomationElement.ControlTypeProperty, AutomationElement.LocalizedControlTypeProperty,
            AutomationElement.HelpTextProperty, AutomationElement.IsPasswordProperty, AutomationElement.IsOffscreenProperty,
            AutomationElement.IsInvokePatternAvailableProperty, AutomationElement.IsTogglePatternAvailableProperty,
            AutomationElement.IsSelectionItemPatternAvailableProperty, AutomationElement.IsExpandCollapsePatternAvailableProperty,
        }) cache.Add(property);
        return cache;
    }

    // The window is the one that was in front when the command was said. The Electron "open tree"
    // switch the Mac needs has no equivalent: Chromium exposes its tree to UI Automation on request.
    public static List<ScreenElement> Read(IntPtr window)
    {
        var found = new List<ScreenElement>();
        var menu = new List<ScreenElement>();
        // A hung app never answers, and UI Automation has no timeout of its own, so the walk runs on a
        // worker and whatever it had read when the wait ends is what the command gets.
        var walk = Task.Run(() =>
        {
            using var _ = Cache.Activate();
            var root = AutomationElement.FromHandle(window);
            Walk(root, found, WindowLimit, NodeBudget, DateTime.UtcNow + TimeBudget);
            // Menus get their own allowance, or a busy window leaves none.
            var bar = root.FindFirst(TreeScope.Descendants, new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.MenuBar));
            if (bar == null) return;
            var deadline = DateTime.UtcNow + TimeBudget;
            var budget = NodeBudget;
            for (var item = TreeWalker.ControlViewWalker.GetFirstChild(bar, Cache); item != null; item = TreeWalker.ControlViewWalker.GetNextSibling(item, Cache))
                budget = Walk(item, menu, MenuLimit, budget, deadline);
        });
        try { walk.Wait(TimeSpan.FromSeconds(3)); }
        catch (AggregateException e) { Log.Line("screen read failed: " + e.InnerException?.Message); }

        var self = ContextDetector.ProcessId(window);
        var others = RunningApps(self).Select(a => new ScreenElement($"{a.Name} (switch to app)", ScreenElement.ElementKind.App, App: a)).ToList();
        // Jev takes at most 255 choices; the other apps stay in, since "open Slack" has to work anywhere.
        List<ScreenElement> windowElements, menuElements;
        lock (found) windowElements = [.. found];
        lock (menu) menuElements = [.. menu];
        return UniquelyLabelled([.. windowElements.Concat(menuElements).Take(Math.Max(0, VoiceCommand.MaxChoices - others.Count)), .. others]);
    }

    // Returns the budget left, so a menu bar's items share one.
    static int Walk(AutomationElement node, List<ScreenElement> into, int limit, int budget, DateTime deadline)
    {
        int count;
        lock (into) count = into.Count;
        if (budget <= 0 || count >= limit || DateTime.UtcNow >= deadline) return budget;
        budget--;
        var type = node.Cached.ControlType;
        // The menu bar is read on its own, and a group is only the wrapper Chromium marks pressable
        // around every link and row, which listed each one twice.
        if (type == ControlType.MenuBar) return budget;
        if (type != ControlType.Group && !node.Cached.IsOffscreen && Label(node, type) is { } label)
        {
            if (FieldTypes.Contains(type))
            {
                if (!node.Cached.IsPassword) lock (into) into.Add(new ScreenElement(label, ScreenElement.ElementKind.Field, node));
            }
            else if (IsPressable(node)) lock (into) into.Add(new ScreenElement(label, ScreenElement.ElementKind.Press, node));
        }
        var walker = TreeWalker.ControlViewWalker;
        for (var child = walker.GetFirstChild(node, Cache); child != null; child = walker.GetNextSibling(child, Cache))
            budget = Walk(child, into, limit, budget, deadline);
        return budget;
    }

    static bool IsPressable(AutomationElement node) =>
        node.GetCachedPropertyValue(AutomationElement.IsInvokePatternAvailableProperty) is true
        || node.GetCachedPropertyValue(AutomationElement.IsTogglePatternAvailableProperty) is true
        || node.GetCachedPropertyValue(AutomationElement.IsSelectionItemPatternAvailableProperty) is true
        || node.GetCachedPropertyValue(AutomationElement.IsExpandCollapsePatternAvailableProperty) is true;

    static string? Label(AutomationElement node, ControlType type)
    {
        var named = new[] { node.Cached.Name, node.Cached.HelpText }.Select(s => s.Trim()).FirstOrDefault(s => s.Length > 0);
        var text = named ?? (FieldTypes.Contains(type) ? null : FirstText(node, 3));
        if (string.IsNullOrEmpty(text)) return null;
        var kind = node.Cached.LocalizedControlType is { Length: > 0 } localized ? localized : type.ProgrammaticName;
        return $"{(text.Length > 60 ? text[..60] : text)} ({kind})";
    }

    static string? FirstText(AutomationElement node, int depth)
    {
        if (depth <= 0) return null;
        var walker = TreeWalker.ControlViewWalker;
        for (var child = walker.GetFirstChild(node, Cache); child != null; child = walker.GetNextSibling(child, Cache))
        {
            if (child.Cached.ControlType == ControlType.Text && child.Cached.Name.Trim() is { Length: > 0 } name) return name;
            if (FirstText(child, depth - 1) is { } text) return text;
        }
        return null;
    }

    // Jev's choices are keyed by label, so two "Close (button)"s would collapse into one. Checked
    // against every label taken, since a real element can already be called "Close (button) #2".
    static List<ScreenElement> UniquelyLabelled(IEnumerable<ScreenElement> elements)
    {
        var taken = new HashSet<string>();
        return elements.Select(element =>
        {
            var label = element.Label;
            var count = 1;
            while (!taken.Add(label)) label = $"{element.Label} #{++count}";
            return element with { Label = label };
        }).ToList();
    }

    // One entry per other app with a window on screen, the way Alt+Tab lists them.
    static List<(string Name, IntPtr Window)> RunningApps(int exceptPid)
    {
        var apps = new Dictionary<int, (string, IntPtr)>();
        var self = Environment.ProcessId;
        EnumWindows((window, _) =>
        {
            var pid = ContextDetector.ProcessId(window);
            if (pid == exceptPid || pid == self || apps.ContainsKey(pid) || !IsWindowVisible(window)
                || GetWindow(window, 4) != IntPtr.Zero  // an owned window is a dialog of its parent
                || (PillScreen.GetWindowLong(window, -20) & 0x80) != 0  // tool window
                || DwmGetWindowAttribute(window, 14, out int cloaked, 4) == 0 && cloaked != 0  // on another desktop
                || GetWindowTextLength(window) == 0) return true;
            apps[pid] = (ContextDetector.AppName(pid), window);
            return true;
        }, IntPtr.Zero);
        return apps.Values.Where(a => a.Item1.Length > 0).ToList();
    }

    // `--dump-elements [seconds]`: what the window in front would offer a voice command, after a delay
    // to switch to it.
    public static async Task<int> DumpCliAsync(int delaySeconds)
    {
        await Task.Delay(delaySeconds * 1000);
        var window = ContextDetector.ForegroundWindow();
        if (window == IntPtr.Zero) { Console.WriteLine("no window in front"); return 1; }
        var started = Stopwatch.StartNew();
        var elements = Read(window);
        Console.WriteLine($"{elements.Count} elements in {started.ElapsedMilliseconds}ms");
        foreach (var element in elements) Console.WriteLine($"{element.Kind}\t{element.Label}");
        return 0;
    }

    delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr state);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr window);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
}
