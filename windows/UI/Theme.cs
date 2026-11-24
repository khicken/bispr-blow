using System.Windows;
using System.Windows.Media;

namespace BisprBlow;

// Which look is in use. Add a case, add a palette, and it appears in Settings.
public enum Appearance { System, Light, Dark, World, Unhinged }

// A whole look, in one value. Every colour, image and type face the app draws comes from here.
public sealed record Palette(
    Color Cream, Color Surface, Color SurfaceActive, Color TableHeader, Color Border,
    Color Ink, Color InkSecondary, Color InkTertiary, Color InkSubtle,
    Color Blue, Color Red, Color Green,
    Color Field, Color PillBackground, Color PillWave,
    Color OnAccent, Color AccentText, Color HeroFrom, Color HeroTo,
    string? SidebarImage = null, string? PanelImage = null, string[]? FontNames = null);

// The colours in play right now, published as `Bj.*` resources on the Application. Views read them with
// {DynamicResource Bj.Ink}, so switching appearance repaints everything with no per-view bookkeeping —
// the job `themeID` does on the Mac. Keys are `Bj.` plus the palette field name, plus `Bj.BlueSoft`,
// `Bj.OnHero`, `Bj.HeroGradient`, and `Bj.Font` (a FontFamily). Nothing draws a literal colour or font.
public static class Theme
{
    static Color Hex(uint rgb, double alpha = 1) =>
        Color.FromArgb((byte)Math.Round(alpha * 255), (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);

    public static bool IsDark(this Appearance a) =>
        a == Appearance.Dark || a == Appearance.System && AppSettings.Shared.SystemIsDark;

    public static Palette PaletteFor(this Appearance a) => a switch
    {
        Appearance.System => AppSettings.Shared.SystemIsDark ? Dusk : Paper,
        Appearance.Light => Paper,
        Appearance.Dark => Dusk,
        Appearance.World => BrandWorld,
        _ => Carnival,
    };

    public static Palette Current => AppSettings.Shared.Appearance.PaletteFor();

    // Matches bluejay_frontend_v2 globals.css. The pill is dark glass over any wallpaper, and 0.70 is
    // the floor where its white bars stop disappearing into a bright desktop.
    static readonly Palette Paper = new(
        Hex(0xFDFDFB), Hex(0xF9FAF8), Hex(0xECEEE9), Hex(0xF4F5F1), Hex(0xD7DCDA),
        Hex(0x2D2D2D), Hex(0x404040), Hex(0x5C5C5C), Hex(0x8C8C8C),
        Hex(0x1FA2FF), Hex(0xEF4444), Hex(0x15803D),
        Colors.White, Hex(0x1C1D1F, 0.70), Colors.White,
        Hex(0x10131A), Hex(0x0A6CB0), Hex(0x0B2A45), Hex(0x123A5C));

    // The light palette turned over, charcoal rather than black so every surface gets a visible step.
    static readonly Palette Dusk = new(
        Hex(0x1D1F22), Hex(0x24272B), Hex(0x353A40), Hex(0x282C30), Hex(0x3D4249),
        Hex(0xECEEF1), Hex(0xCED2D7), Hex(0x9CA3AB), Hex(0x7A818A),
        Hex(0x3DB2FF), Hex(0xF87171), Hex(0x4ADE80),
        Hex(0x2E3238), Hex(0x1C1D1F, 0.70), Colors.White,
        Hex(0x10131A), Hex(0x5CBEFF), Hex(0x0F3350), Hex(0x1B4E7A));

    // Sampled from the brand world renders: cyan skies, lavender clouds, magenta light.
    static readonly Palette BrandWorld = new(
        Hex(0xFBF8FF), Hex(0xF5F0FF), Hex(0xE7DDFB), Hex(0xF0EAFD), Hex(0xDDD1F4),
        Hex(0x241A47), Hex(0x3A2C68), Hex(0x5B4C8A), Hex(0x9086B0),
        Hex(0x2BC4DE), Hex(0xF0479B), Hex(0x1FAE9C),
        Colors.White, Hex(0x241638, 0.72), Hex(0xB8F0FA),
        Hex(0x1B1233), Hex(0x066577), Hex(0x2A1B4A), Hex(0x4A2F86),
        SidebarImage: "World_Secondary.jpg", PanelImage: "World_Abstract.jpg");

    // The joke. Contrast is the one thing it does not joke about: near-black violet ink on every
    // surface, so it stays as readable as Light. Someone will leave this on.
    static readonly Palette Carnival = new(
        Hex(0xFFF0FA), Hex(0xDDFB9E), Hex(0xFDE047), Hex(0xCBF7FF), Hex(0x8B27C9),
        Hex(0x1B0033), Hex(0x4A0D7A), Hex(0x7C1FBF), Hex(0x9B2FA8),
        Hex(0xFF00A8), Hex(0xFF0054), Hex(0x2FBF14),
        Hex(0xFFFBD6), Hex(0x7C1FBF, 0.74), Hex(0xC6FF3D),
        Hex(0x1B0033), Hex(0xB80078), Hex(0x3D0066), Hex(0x7C1FBF),
        FontNames: ["Comic Sans MS", "Segoe Print"]);

    // Writes the current palette into Application resources. Safe to call before the App exists
    // (the CLI paths), where it does nothing.
    public static void Apply()
    {
        if (Application.Current?.Resources is not { } res) return;
        var p = Current;
        foreach (var prop in typeof(Palette).GetProperties().Where(x => x.PropertyType == typeof(Color)))
            res["Bj." + prop.Name] = Frozen(new SolidColorBrush((Color)prop.GetValue(p)!));
        res["Bj.BlueSoft"] = Frozen(new SolidColorBrush(Color.FromArgb(31, p.Blue.R, p.Blue.G, p.Blue.B)));
        res["Bj.OnHero"] = Brushes.White;
        res["Bj.HeroGradient"] = Frozen(new LinearGradientBrush(p.HeroFrom, p.HeroTo, 45));
        res["Bj.Font"] = Font(p);
        ThemeChanged?.Invoke();
    }

    // For the few things that cannot take a resource (window chrome, the tray menu).
    public static event Action? ThemeChanged;

    // First installed face wins; none means Segoe UI, the system face.
    static FontFamily Font(Palette p)
    {
        var installed = Fonts.SystemFontFamilies.Select(f => f.Source).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var name = p.FontNames?.FirstOrDefault(installed.Contains);
        return new FontFamily(name ?? "Segoe UI Variable Text, Segoe UI");
    }

    static T Frozen<T>(T f) where T : Freezable
    {
        f.Freeze();
        return f;
    }
}
