namespace BisprBlow;

[Flags]
public enum Mods { None = 0, Shift = 1, Ctrl = 2, Alt = 4, Win = 8 }

public enum TriggerKind { Key, Mouse, Modifiers }

// One bindable trigger: a key (with optional modifiers), a mouse button, or a set of modifiers held on
// their own. A standalone modifier key — Right Ctrl — is stored as Key with no flags and matched on its
// virtual-key code alone, whatever else is held down, which is what makes "hold Right Ctrl" work while
// typing. Windows has no fn key a program can see (it is handled in the keyboard's firmware), so the
// default push to talk is Ctrl+Win held, a Modifiers binding.
public sealed record Shortcut(TriggerKind Kind, int Code = 0, Mods Flags = Mods.None)
{
    public const int VkEscape = 0x1B;

    public static readonly Shortcut CtrlWin = new(TriggerKind.Modifiers, 0, Mods.Ctrl | Mods.Win);
    public static readonly Shortcut Escape = new(TriggerKind.Key, VkEscape);

    // Modifier keys that can stand alone as a trigger, and the flag each one raises. The generic
    // VK_SHIFT/VK_CONTROL/VK_MENU codes never reach a low-level hook; it reports the sided ones.
    public static readonly IReadOnlyDictionary<int, Mods> ModifierFlags = new Dictionary<int, Mods>
    {
        [0xA0] = Mods.Shift, [0xA1] = Mods.Shift,
        [0xA2] = Mods.Ctrl, [0xA3] = Mods.Ctrl,
        [0xA4] = Mods.Alt, [0xA5] = Mods.Alt,
        [0x5B] = Mods.Win, [0x5C] = Mods.Win,
    };

    public bool Matches(int vk, Mods held) =>
        Kind == TriggerKind.Key && Code == vk && (ModifierFlags.ContainsKey(vk) || held == Flags);

    public bool MatchesMouse(int button) => Kind == TriggerKind.Mouse && Code == button;

    // Exact rather than "contains", so Ctrl+Win and Ctrl+Shift+Win stay different bindings.
    public bool MatchesModifiers(Mods held) => Kind == TriggerKind.Modifiers && held != Mods.None && held == Flags;

    // Key-cap text: "Ctrl+Win", "Ctrl+Alt+D", "Mouse 4".
    public string Display => Kind switch
    {
        TriggerKind.Mouse => $"Mouse {Code + 1}",  // 0 is left, so button 3 is what everyone calls mouse 4
        TriggerKind.Modifiers => Glyphs(Flags).TrimEnd('+'),
        _ => ModifierNames.TryGetValue(Code, out var name) ? name : Glyphs(Flags) + KeyName(Code),
    };

    // Windows' order: Ctrl, Alt, Shift, Win.
    static string Glyphs(Mods flags) =>
        (flags.HasFlag(Mods.Ctrl) ? "Ctrl+" : "") + (flags.HasFlag(Mods.Alt) ? "Alt+" : "") +
        (flags.HasFlag(Mods.Shift) ? "Shift+" : "") + (flags.HasFlag(Mods.Win) ? "Win+" : "");

    static readonly Dictionary<int, string> ModifierNames = new()
    {
        [0xA0] = "Left Shift", [0xA1] = "Right Shift",
        [0xA2] = "Left Ctrl", [0xA3] = "Right Ctrl",
        [0xA4] = "Left Alt", [0xA5] = "Right Alt",
        [0x5B] = "Left Win", [0x5C] = "Right Win",
    };

    static string KeyName(int vk) => vk switch
    {
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        >= 0x70 and <= 0x87 => $"F{vk - 0x6F}",
        0x08 => "Backspace", 0x09 => "Tab", 0x0D => "Enter", 0x1B => "Esc", 0x20 => "Space",
        0x21 => "Page Up", 0x22 => "Page Down", 0x23 => "End", 0x24 => "Home",
        0x25 => "←", 0x26 => "↑", 0x27 => "→", 0x28 => "↓", 0x2D => "Insert", 0x2E => "Delete",
        0xBA => ";", 0xBB => "=", 0xBC => ",", 0xBD => "-", 0xBE => ".", 0xBF => "/", 0xC0 => "`",
        0xDB => "[", 0xDC => "\\", 0xDD => "]", 0xDE => "'",
        _ => $"Key {vk}",
    };
}

// What a binding does. Every action takes a list of bindings, so Ctrl+Win and mouse 4 can both start
// a dictation. Stored by name, the same strings the Mac uses, so a bindings blob reads the same.
public enum ShortcutAction { PushToTalk, HandsFree, PressEnter, Command, Cancel }

public static class ShortcutActionInfo
{
    public static string Key(this ShortcutAction a) => char.ToLowerInvariant(a.ToString()[0]) + a.ToString()[1..];

    public static string Title(this ShortcutAction a) => a switch
    {
        ShortcutAction.PushToTalk => "Push to talk",
        ShortcutAction.HandsFree => "Hands-free",
        ShortcutAction.PressEnter => "Dictate and send",
        ShortcutAction.Command => "Voice command",
        _ => "Cancel",
    };

    // One line each. This sits above the list you came here to edit, so it says what the action
    // does and stops.
    public static string Blurb(this ShortcutAction a) => a switch
    {
        ShortcutAction.PushToTalk => "Hold or double-tap to dictate.",
        ShortcutAction.HandsFree => "Press to start, again to finish. Or double-tap push to talk.",
        ShortcutAction.PressEnter => "Push to talk, then presses Enter.",
        ShortcutAction.Command => "Hold, say what to do in the app in front, release.",
        _ => "Throw away the current dictation.",
    };

    public static IReadOnlyList<Shortcut> Defaults(this ShortcutAction a) => a switch
    {
        ShortcutAction.PushToTalk => [Shortcut.CtrlWin],
        ShortcutAction.Cancel => [Shortcut.Escape],
        _ => [],
    };
}
