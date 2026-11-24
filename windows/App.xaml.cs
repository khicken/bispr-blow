using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Windows;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace BisprBlow;

// Owns the app's lifetime: the tray icon, the single running copy, the dictation controller, and
// the pill. Program.cs holds the mutex and the CLI seams; this is the Mac's AppDelegate.
public partial class App : Application
{
    // What the first launch was started with, so a sign-in link that starts the app is not lost.
    public string[] StartupArgs { get; init; } = [];

    DictationController controller = null!;
    RecordingPill pill = null!;
    PillToast toast = null!;
    Forms.NotifyIcon tray = null!;
    readonly CancellationTokenSource stopListening = new();

    static string PipeName => $"bisprblow-{WindowsIdentity.GetCurrent().User!.Value}";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            Log.Line($"unhandled: {args.Exception}");
            args.Handled = true;
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Line($"unobserved: {args.Exception}");
            args.SetObserved();
        };
        WatchSystemAppearance();
        Theme.Apply();
        controller = new DictationController();
        pill = new RecordingPill(controller);
        toast = new PillToast(controller);

        SetupTray();
        _ = ListenForSecondLaunchAsync();
        CloudClient.RegisterUrlScheme();
        controller.Start();
        // Wiring only: cloud sync wakes on new history entries and a slow timer, and touches the
        // network only while someone is signed in with a sync switch on.
        SyncEngine.Shared.Start();
        // One shot at launch, and silent about every failure — see UpdateChecker.
        if (AppSettings.Shared.CheckForUpdates) _ = UpdateChecker.Shared.CheckAsync();

        HandleArgs(StartupArgs, reopen: false);
        // First run: open the dashboard so setup is visible. The marker file is the Mac's
        // hasLaunchedBefore, since settings.json only exists once a setting has changed.
        var marker = Path.Combine(AppPaths.Support, "launched");
        if (!File.Exists(marker))
        {
            File.WriteAllText(marker, "");
            DashboardWindow.Show();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        stopListening.Cancel();
        ShortcutMonitor.Shared.Stop();
        tray.Dispose();
        base.OnExit(e);
    }

    // Keeps `SystemIsDark` true to the OS so the System theme follows it. The setter repaints only
    // when the theme is System, so every other look ignores the flip.
    void WatchSystemAppearance() =>
        SystemEvents.UserPreferenceChanged += (_, _) =>
            Dispatcher.BeginInvoke(() => AppSettings.Shared.SystemIsDark = AppSettings.ReadSystemIsDark());

    // ---- Tray

    void SetupTray()
    {
        using var icon = Application.GetResourceStream(new Uri("pack://application:,,,/Resources/AppIcon.ico"))!.Stream;
        var menu = new Forms.ContextMenuStrip();
        // Rebuilt on each open so the status line names the shortcut as it is now.
        menu.Opening += (_, _) => FillStatusMenu(menu);
        tray = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(icon, Forms.SystemInformation.SmallIconSize),
            ContextMenuStrip = menu,
            Visible = true,
        };
        tray.MouseUp += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) DashboardWindow.Show();
        };
        // Rebuilt when a shortcut is rebound, since the tooltip names it.
        AppSettings.Shared.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppSettings.Bindings)) Dispatcher.BeginInvoke(RefreshTooltip);
        };
        RefreshTooltip();
    }

    void RefreshTooltip()
    {
        var settings = AppSettings.Shared;
        var hint = settings.HoldHint;
        var lockHint = settings.Shortcuts(ShortcutAction.PushToTalk).Count == 0 ? "" : ", double-tap to lock";
        tray.Text = $"BisprBlow · {char.ToLowerInvariant(hint[0])}{hint[1..]}{lockHint}.";
    }

    static void FillStatusMenu(Forms.ContextMenuStrip menu)
    {
        menu.Items.Clear();
        var status = AppSettings.Shared.HoldPhrase is { } phrase ? $"{phrase} to dictate" : "Set a shortcut in Settings";
        menu.Items.Add(new Forms.ToolStripMenuItem(status) { Enabled = false });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Open Dashboard", null, (_, _) => DashboardWindow.Show());
        menu.Items.Add("Settings…", null, (_, _) => DashboardWindow.Show(DashboardSection.Settings));
        menu.Items.Add("Check for Updates…", null, async (_, _) =>
        {
            await UpdateChecker.Shared.CheckAsync();
            UpdateChecker.Shared.OpenRelease();
        });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem(UpdateChecker.Current is { } v ? $"BisprBlow {v}" : "BisprBlow (dev build)") { Enabled = false });
        menu.Items.Add("Quit BisprBlow", null, (_, _) => Current.Shutdown());
    }

    // ---- One copy at a time

    // A second launch (a Start-menu click, or the bisprblow:// sign-in callback) hands its arguments
    // to the running copy over a pipe named for the user.
    public static void SignalRunningCopy(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            client.Connect(2000);
            using var writer = new StreamWriter(client, Encoding.UTF8);
            writer.Write(string.Join('\n', args));
        }
        catch (Exception e) when (e is IOException or TimeoutException) { }
    }

    async Task ListenForSecondLaunchAsync()
    {
        while (!stopListening.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(stopListening.Token);
                using var reader = new StreamReader(server, Encoding.UTF8);
                var args = (await reader.ReadToEndAsync()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
                await Dispatcher.InvokeAsync(() => HandleArgs(args, reopen: true));
            }
            catch (OperationCanceledException) { return; }
            catch (Exception e)
            {
                Log.Line($"pipe: {e.Message}");
                await Task.Delay(500);
            }
        }
    }

    // Both sign-in callbacks land here, `bisprblow://auth-callback` with the tokens in the fragment
    // (registered by `CloudClient.RegisterUrlScheme`). A plain second launch is the Mac's reopen: it
    // shows the dashboard. A first launch with no link shows nothing, as the Mac's does.
    void HandleArgs(string[] args, bool reopen)
    {
        var link = args.Select(a => Uri.TryCreate(a, UriKind.Absolute, out var uri) ? uri : null)
                       .FirstOrDefault(u => u?.Scheme == CloudConfig.CallbackScheme);
        if (link != null) _ = CloudClient.Shared.HandleCallbackAsync(link);
        else if (reopen) DashboardWindow.Show();
    }
}
