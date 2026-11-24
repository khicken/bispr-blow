using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Windows.Automation;

namespace BisprBlow;

// A spoken command acted out on the app in front: Jev (TypeSafe System One) picks which on-screen
// element the command is about, and the element's own kind decides the action — press it, type
// into it, or switch to it. Jev only ever chooses from the list it is given, which is the point:
// it cannot invent a click on something that is not there.
static partial class VoiceCommand
{
    // Below this Jev is guessing; on real screens every wrong pick but one sat under it.
    public const double ConfidentEnough = 0.6;
    // TypeSafe rejects a choice question with more options than this.
    public const int MaxChoices = 255;
    const string Endpoint = "https://api.typesafe.ai/v1/systemone";
    const string Model = "jev-1.13.0";
    const string CredentialTarget = "typesafe-api-key";

    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(5) };

    public record Pick(ScreenElement Element, double Confidence);

    public enum Failure { NoKey, KeyRejected, BadReply }

    public sealed class FailureException(Failure kind) : Exception(kind.ToString())
    {
        public Failure Kind { get; } = kind;
    }

    // Screen text is not the user: a page or a message can show a "Delete account" button. A press
    // that would be hard to take back is asked about, however sure Jev is.
    static readonly string[] RiskyWords =
    [
        "delete", "remove", "send", "pay", "purchase", "buy", "transfer", "submit",
        "archive", "discard", "quit", "sign out", "log out", "close account", "merge",
    ];

    public static bool NeedsConfirmation(ScreenElement element)
    {
        var label = element.Label.ToLowerInvariant();
        return element.Kind == ScreenElement.ElementKind.Press && RiskyWords.Any(label.Contains);
    }

    public static async Task<Pick> PickAsync(string spoken, IReadOnlyList<ScreenElement> elements, string appName)
    {
        var key = ApiKey() ?? throw new FailureException(Failure.NoKey);
        var byLabel = elements.GroupBy(e => e.Label).ToDictionary(g => g.Key, g => g.First());
        var criteria = new JsonObject();
        foreach (var label in byLabel.Keys) criteria[label] = null;
        var body = new JsonObject
        {
            ["model"] = Model,
            ["state"] = $"The user is in {appName} on Windows and said: \"{spoken}\". The choices are the elements on screen, the app's menu items, and the other open apps.",
            ["questions"] = new JsonObject
            {
                ["target"] = new JsonObject
                {
                    ["type"] = "choice",
                    ["instructions"] = "Which on-screen element, menu item, or other app should be acted on to carry out the command?",
                    ["criteria"] = criteria,
                },
            },
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var response = await Http.SendAsync(request);
        if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden) throw new FailureException(Failure.KeyRejected);
        var target = JsonNode.Parse(await response.Content.ReadAsStringAsync())?["answers"]?["target"];
        if (target?["choice"]?.GetValue<string>() is not { } choice || !byLabel.TryGetValue(choice, out var element)
            || target["confidence"]?.GetValue<double>() is not { } confidence)
            throw new FailureException(Failure.BadReply);
        return new Pick(element, confidence);
    }

    // "open Slack" needs no model: a running app named in the command is the whole answer.
    public static ScreenElement? AppNamed(string spoken, IReadOnlyList<ScreenElement> elements)
    {
        var words = spoken.ToLowerInvariant().Trim().Trim(AppContext.Punctuation);
        var prefix = new[] { "open ", "switch to ", "go to " }.FirstOrDefault(words.StartsWith);
        if (prefix == null) return null;
        var rest = words[prefix.Length..];
        return elements.FirstOrDefault(e => e.Kind == ScreenElement.ElementKind.App && e.App?.Name.ToLowerInvariant() == rest);
    }

    // Invoking a button that opens a dialog does not return until the dialog closes, so a call still running after a second counts as done.
    public static async Task<bool> PerformAsync(ScreenElement element, string spoken)
    {
        var task = Task.Run(() => PerformCore(element, spoken));
        return await Task.WhenAny(task, Task.Delay(1000)) != task || task.Result;
    }

    static async Task<bool> PerformCore(ScreenElement element, string spoken)
    {
        try
        {
            switch (element.Kind)
            {
                case ScreenElement.ElementKind.App:
                    if (element.App is not { } app) return false;
                    if (IsIconic(app.Window)) ShowWindow(app.Window, 9);
                    return SetForegroundWindow(app.Window);
                case ScreenElement.ElementKind.Press:
                    if (element.Element is not { } node) return false;
                    foreach (var pattern in new[] { InvokePattern.Pattern, TogglePattern.Pattern, SelectionItemPattern.Pattern, ExpandCollapsePattern.Pattern })
                    {
                        if (!node.TryGetCurrentPattern(pattern, out var found)) continue;
                        switch (found)
                        {
                            case InvokePattern p: p.Invoke(); break;
                            case TogglePattern p: p.Toggle(); break;
                            case SelectionItemPattern p: p.Select(); break;
                            case ExpandCollapsePattern p: p.Expand(); break;
                        }
                        return true;
                    }
                    return false;
                default:
                    if (element.Element is not { } field) return false;
                    field.SetFocus();
                    if (TextToType(spoken) is not { } text) return true;
                    // Setting focus can report success without moving it, and the paste goes wherever focus is.
                    return ContextDetector.FocusedElement() is { } focused && Automation.Compare(focused.Element, field)
                        && await TextInserter.InsertAsync(text);
            }
        }
        catch (Exception) { return false; }
    }

    // The words to put in a field: everything after "type", "write" or "search for". A command that
    // only names the field ("click into the message box") focuses it and types nothing.
    public static string? TextToType(string spoken) =>
        TypedText().Match(spoken) is { Success: true } match ? match.Groups[1].Value : null;

    [GeneratedRegex(@"^\s*(?:type|write|search(?:\s+\w+)?\s+for)\s+(.+?)[.!]?\s*$", RegexOptions.IgnoreCase)]
    private static partial Regex TypedText();

    // Set with `cmdkey /generic:typesafe-api-key /user:key /pass:<key>`; never in settings or the
    // repo, and never logged.
    public static string? ApiKey()
    {
        if (!CredRead(CredentialTarget, 1, 0, out var pointer)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            var blob = new byte[credential.BlobSize];
            Marshal.Copy(credential.Blob, blob, 0, blob.Length);
            // cmdkey stores UTF-16; another tool may have stored UTF-8, which has no zero bytes.
            var key = (Array.IndexOf(blob, (byte)0) >= 0 ? Encoding.Unicode : Encoding.UTF8).GetString(blob).Trim();
            return key.Length == 0 ? null : key;
        }
        finally { CredFree(pointer); }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Credential
    {
        public uint Flags, Type;
        public IntPtr TargetName, Comment;
        public long LastWritten;
        public uint BlobSize;
        public IntPtr Blob;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
}
