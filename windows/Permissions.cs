using System.Diagnostics;
using Microsoft.Win32;

namespace BisprBlow;

// The one permission Windows has for what this app does: the microphone privacy switch. There is no
// Accessibility or Input Monitoring equivalent (a low-level hook and SendInput need no consent) and
// no Speech Recognition one (recognition runs in-process), so unlike the Mac there is no checklist.
// Nothing asks at launch, and nothing can prompt: a denied switch does not make capture fail, it
// makes WASAPI deliver silence, so this is the only way to tell "denied" from "quiet room".
public static class Permissions
{
    const string Consent = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    // "Deny" in any of the three places Settings writes it: the user's master switch, the one for
    // desktop apps, and the machine-wide one an administrator or policy sets. A missing value is the
    // Windows default, which is allowed.
    public static bool MicrophoneAllowed =>
        !Denied(Registry.CurrentUser, Consent) && !Denied(Registry.CurrentUser, Consent + @"\NonPackaged")
        && !Denied(Registry.LocalMachine, Consent);

    static bool Denied(RegistryKey hive, string path)
    {
        using var key = hive.OpenSubKey(path);
        return key?.GetValue("Value") is string v && v.Equals("Deny", StringComparison.OrdinalIgnoreCase);
    }

    public static void OpenMicrophoneSettings() =>
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true });
}
