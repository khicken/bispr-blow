using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;

namespace BisprBlow;

// Asks GitHub once at launch whether a newer release exists, and shows the dashboard banner. There
// is no Sparkle on Windows, so this is the whole update story: it names the new version and
// OpenRelease sends the user to the release page to install it.
//
// Every failure is silence. Offline is the normal case for this app, and an app whose pitch is that
// nothing leaves your machine cannot answer a dropped connection with an error.
public sealed class UpdateChecker : INotifyPropertyChanged
{
    public static readonly UpdateChecker Shared = new();

    public event PropertyChangedEventHandler? PropertyChanged;

    // Set only while it is genuinely newer than this build, so the banner's existence *is* the
    // answer and no view has to compare anything.
    string? latest;
    public string? Latest
    {
        get => latest;
        private set
        {
            latest = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Latest)));
        }
    }

    public static readonly Uri ReleasePage = new("https://github.com/khicken/bispr-blow/releases/latest");
    static readonly Uri Api = new("https://api.github.com/repos/khicken/bispr-blow/releases/latest");

    // What build.ps1 stamped from the tag the build sits on, minus the "+commit" the SDK appends. A binary
    // with no version is never behind anything.
    public static string? Current =>
        typeof(UpdateChecker).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion.Split('+')[0] is { Length: > 0 } version ? version : null;

    // With no argument this is the launch check, which honours the setting. `--update-check <version>`
    // passes one to drive the real request: a build has the version of its own tag, so without an
    // argument to stand in for one this path could only be exercised by cutting a second release.
    public async Task CheckAsync(string? current = null)
    {
        if (current == null && !AppSettings.Shared.CheckForUpdates) return;
        current ??= Current;
        if (current == null) return;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, Api);
            request.Headers.Add("Accept", "application/vnd.github+json");
            // GitHub refuses a request with no User-Agent.
            request.Headers.Add("User-Agent", "BisprBlow");
            using var response = await CloudClient.Http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return;
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            if (json.RootElement.GetProperty("tag_name").GetString() is not { } tag || !IsNewer(tag, current)) return;
            // The mac job publishes the release before the windows job attaches the zip, and a release
            // from before the Windows app has none at all. No zip means nothing to install yet.
            if (!json.RootElement.GetProperty("assets").EnumerateArray()
                    .Any(a => a.GetProperty("name").GetString() == "BisprBlow-Windows.zip")) return;
            Latest = Number(tag);
            Log.Line($"update: {current} -> {Latest} available");
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException
                                      or KeyNotFoundException or InvalidOperationException) { }
    }

    public void OpenRelease()
    {
        try { Process.Start(new ProcessStartInfo(ReleasePage.AbsoluteUri) { UseShellExecute = true }); }
        catch (Win32Exception) { }
    }

    // Numerically per component, so 0.10.0 beats 0.9.0 — a string compare gets that backwards, and
    // the first release past .9 is exactly when nobody would be looking. Anything unparseable
    // compares as not newer: a tag we do not understand is not worth nagging about.
    public static bool IsNewer(string latest, string current)
    {
        static int[]? Parts(string text)
        {
            var fields = Number(text).Split('.');
            var numbers = new int[fields.Length];
            for (var i = 0; i < fields.Length; i++)
                if (!int.TryParse(fields[i], NumberStyles.None, CultureInfo.InvariantCulture, out numbers[i])) return null;
            return numbers;
        }
        if (Parts(latest) is not { } now || Parts(current) is not { } old) return false;
        for (var i = 0; i < Math.Max(now.Length, old.Length); i++)
        {
            var (a, b) = (i < now.Length ? now[i] : 0, i < old.Length ? old[i] : 0);
            if (a != b) return a > b;
        }
        return false;
    }

    // "v0.2.0" and "0.2.0" are the same release; the tag carries the v and the assembly version cannot.
    public static string Number(string tag) => tag.StartsWith('v') ? tag[1..] : tag;
}
