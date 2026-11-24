using System.Text.Json;
using System.Text.Json.Serialization;

namespace BisprBlow;

// Where a release lands the pill (checkAnchors) belongs to the pill's own file.
static class SelfCheckInput
{
    public static void Run()
    {
        CheckShortcuts();
        CheckGestures();
    }

    // Virtual-key codes the checks press.
    const int LCtrl = 0xA2, RCtrl = 0xA3, LShift = 0xA0, LWin = 0x5B, KeyD = 0x44, KeyF = 0x46, KeyG = 0x47, Space = 0x20;

    // Bindings are serialized into settings.json and rendered as key caps in Settings, so a break
    // here either loses the user's shortcut or shows them the wrong one.
    static void CheckShortcuts()
    {
        var combo = new Shortcut(TriggerKind.Key, KeyD, Mods.Ctrl | Mods.Alt);
        var mouse4 = new Shortcut(TriggerKind.Mouse, 3);

        Check.Equal(Shortcut.CtrlWin.Display, "Ctrl+Win");
        Check.Equal(Shortcut.Escape.Display, "Esc");
        Check.Equal(combo.Display, "Ctrl+Alt+D");
        Check.Equal(mouse4.Display, "Mouse 4");  // button 3 is what every UI calls mouse 4
        Check.Equal(new Shortcut(TriggerKind.Key, Space).Display, "Space");

        // Modifiers have to match exactly.
        Check.That(combo.Matches(KeyD, Mods.Ctrl | Mods.Alt));
        Check.That(!combo.Matches(KeyD, Mods.Ctrl));
        Check.That(!combo.Matches(KeyD, Mods.Ctrl | Mods.Alt | Mods.Shift));
        Check.That(!combo.Matches(KeyF, Mods.Ctrl | Mods.Alt));
        // A standalone modifier matches on its key code whatever else is held, which is what makes
        // "hold Right Ctrl" work while shift is down.
        var rightCtrl = new Shortcut(TriggerKind.Key, RCtrl);
        Check.That(rightCtrl.Matches(RCtrl, Mods.Ctrl | Mods.Shift));
        Check.That(!rightCtrl.Matches(LCtrl, Mods.Ctrl));
        Check.That(mouse4.MatchesMouse(3) && !mouse4.MatchesMouse(2));

        // Recording a binding: hold the combination, let go, and what was down is what is saved. The
        // key-down carries a floor of flags that is deliberately short a modifier: that is the bug the
        // recorder's own tracking exists for.
        static Shortcut? Record(params (ShortcutMonitor.CaptureEvent, int, Mods)[] steps)
        {
            var state = new ShortcutMonitor.CaptureState();
            foreach (var (type, code, flags) in steps)
                if (ShortcutMonitor.CaptureStep(type, code, flags, state) is { } shortcut) return shortcut;
            return null;
        }
        const ShortcutMonitor.CaptureEvent Down = ShortcutMonitor.CaptureEvent.KeyDown, Up = ShortcutMonitor.CaptureEvent.KeyUp;
        // Ctrl+Shift+G, with the key-down carrying only shift, then everything released.
        Check.Equal(Record((Down, LCtrl, Mods.None), (Down, LShift, Mods.None), (Down, KeyG, Mods.Shift), (Up, KeyG, Mods.Shift),
                           (Up, LShift, Mods.None), (Up, LCtrl, Mods.None))?.Display, "Ctrl+Shift+G");
        // Nothing is recorded until the last key is up: the same sequence, stopped early.
        Check.That(Record((Down, LCtrl, Mods.None), (Down, LShift, Mods.None), (Down, KeyG, Mods.Shift), (Up, KeyG, Mods.Shift)) == null);
        // Modifiers with no key is a binding in its own right — hold Ctrl+Win to talk. It has no key code,
        // so it can only be recorded on release, hence release-to-finalize rather than first-key-wins.
        Check.Equal(Record((Down, LCtrl, Mods.None), (Down, LWin, Mods.None), (Up, LWin, Mods.None), (Up, LCtrl, Mods.None)),
                    Shortcut.CtrlWin);
        // A lone modifier stays a key code, so left Ctrl and right Ctrl remain different bindings.
        Check.Equal(Record((Down, RCtrl, Mods.None), (Up, RCtrl, Mods.None))?.Display, "Right Ctrl");
        // A plain key with no modifiers at all.
        Check.Equal(Record((Down, KeyG, Mods.None), (Up, KeyG, Mods.None))?.Display, "G");
        Check.Equal(Record((ShortcutMonitor.CaptureEvent.MouseDown, 3, Mods.None), (ShortcutMonitor.CaptureEvent.MouseUp, 3, Mods.None)), mouse4);

        // A modifiers-only binding fires when its set completes and stops when it breaks — the
        // set is the whole gesture, so it matches exactly rather than as a subset.
        var ctrlShift = new Shortcut(TriggerKind.Modifiers, 0, Mods.Ctrl | Mods.Shift);
        Check.That(ctrlShift.MatchesModifiers(Mods.Ctrl | Mods.Shift));
        Check.That(!ctrlShift.MatchesModifiers(Mods.Ctrl));
        Check.That(!ctrlShift.MatchesModifiers(Mods.Ctrl | Mods.Shift | Mods.Win));
        Check.That(!ctrlShift.MatchesModifiers(Mods.None));
        // It carries no key, so the key path must never claim it as well.
        Check.That(!ctrlShift.Matches(LCtrl, Mods.Ctrl | Mods.Shift));

        // Round trip: bindings live in settings.json.
        var options = new JsonSerializerOptions { Converters = { new JsonStringEnumConverter() } };
        var saved = new Dictionary<string, List<Shortcut>> { ["pushToTalk"] = [Shortcut.CtrlWin, combo], ["handsFree"] = [mouse4] };
        var back = JsonSerializer.Deserialize<Dictionary<string, List<Shortcut>>>(JsonSerializer.Serialize(saved, options), options)!;
        Check.That(back.Keys.OrderBy(k => k).SequenceEqual(saved.Keys.OrderBy(k => k)) && saved.All(p => back[p.Key].SequenceEqual(p.Value)));

        // Ctrl+Win stays the shipped push-to-talk default; Esc stays cancel.
        Check.That(ShortcutAction.PushToTalk.Defaults().SequenceEqual([Shortcut.CtrlWin]));
        Check.That(ShortcutAction.Cancel.Defaults().SequenceEqual([Shortcut.Escape]));

        // Assigning a binding steals it: two actions on one key means one never fires.
        var stolen = AppSettings.Adding(mouse4, ShortcutAction.Cancel, saved);
        Check.That(stolen["handsFree"].Count == 0);
        Check.That(stolen["cancel"].SequenceEqual([mouse4]));
        Check.That(stolen["pushToTalk"].SequenceEqual([Shortcut.CtrlWin, combo]));
        // Re-adding the same binding to the same action must not duplicate it.
        Check.That(AppSettings.Adding(Shortcut.CtrlWin, ShortcutAction.PushToTalk, saved)["pushToTalk"].SequenceEqual([combo, Shortcut.CtrlWin]));
    }

    // The hold-versus-double-tap machine, on real timings, so this costs a few seconds. Every branch
    // here either drops a dictation or starts one nobody asked for, and none of it can be exercised
    // without physically pressing a key.
    static void CheckGestures()
    {
        // Hold past the threshold: start on press, insert on release.
        Run((monitor, log) =>
        {
            Check.That(monitor.Simulate(ShortcutAction.PushToTalk, true));
            Thread.Sleep(320);
            Check.That(monitor.Simulate(ShortcutAction.PushToTalk, false));
            Check.Equal(log(), "start stop");
        });

        // Short tap on its own: the session started, so it has to be thrown away — but only
        // after the double-tap window has passed with no second tap.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            monitor.Simulate(ShortcutAction.PushToTalk, false);
            Check.Equal(log(), "start");
            Thread.Sleep(450);
            Check.Equal(log(), "start cancel");
        });

        // Double tap locks hands-free, and cancels the discard the first tap queued up.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            monitor.Simulate(ShortcutAction.PushToTalk, false);
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            monitor.Simulate(ShortcutAction.PushToTalk, false);
            Thread.Sleep(450);
            Check.Equal(log(), "start lock");
            // A tap while locked finishes the session.
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            Check.Equal(log(), "start lock stop-locked");
        });

        // "Dictate and send" is push to talk that asks for an Enter afterwards.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.PressEnter, true);
            Thread.Sleep(320);
            monitor.Simulate(ShortcutAction.PressEnter, false);
            Check.Equal(log(), "start+enter stop");
        });

        // Releasing a different binding must not end someone else's hold.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            monitor.Simulate(ShortcutAction.PressEnter, false);
            Thread.Sleep(320);
            Check.Equal(log(), "start");
            monitor.Simulate(ShortcutAction.PushToTalk, false);
            Check.Equal(log(), "start stop");
        });

        // Cancelling mid-hold discards it, and the trigger's own release is then a no-op
        // rather than a second stop that would insert the text anyway.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.PushToTalk, true);
            Check.That(monitor.Simulate(ShortcutAction.Cancel, true));
            monitor.Simulate(ShortcutAction.Cancel, false);
            monitor.Simulate(ShortcutAction.PushToTalk, false);
            Thread.Sleep(450);
            Check.Equal(log(), "start cancel");
        });

        // Nothing to cancel: Esc has to reach the app the user is actually typing in.
        Run((monitor, log) =>
        {
            Check.That(!monitor.Simulate(ShortcutAction.Cancel, true));
            Check.That(!monitor.Simulate(ShortcutAction.Cancel, false));
            Check.Equal(log(), "");
        });

        // Hands-free binding: press to start, press again to finish.
        Run((monitor, log) =>
        {
            monitor.Simulate(ShortcutAction.HandsFree, true);
            Check.Equal(log(), "start lock");
            monitor.Simulate(ShortcutAction.HandsFree, true);
            Check.Equal(log(), "start lock stop-locked");
        });

        // Through the key path, with the default bindings: Ctrl then Win completes the combo and
        // starts, passing both keys through; letting go of either stops it.
        Run((monitor, log) =>
        {
            monitor.bindings = [(ShortcutAction.PushToTalk, Shortcut.CtrlWin), (ShortcutAction.Cancel, Shortcut.Escape)];
            Check.That(!monitor.HandleKey(LCtrl, true));
            Check.Equal(log(), "");
            Check.That(!monitor.HandleKey(LWin, true));
            Check.Equal(log(), "start");
            Thread.Sleep(320);
            Check.That(!monitor.HandleKey(LCtrl, false));
            Check.Equal(log(), "start stop");
            monitor.HandleKey(LWin, false);
            // Auto-repeat of Esc while it is the cancel key must not cancel twice, and it is only
            // swallowed while there was something to cancel.
            Check.That(!monitor.HandleKey(Shortcut.VkEscape, true));
            monitor.HandleKey(Shortcut.VkEscape, false);
        });

        // A key binding keeps its action through the release even if a modifier let go first, and
        // its auto-repeats are swallowed without firing again.
        Run((monitor, log) =>
        {
            monitor.bindings = [(ShortcutAction.HandsFree, new Shortcut(TriggerKind.Key, KeyD, Mods.Ctrl))];
            monitor.HandleKey(LCtrl, true);
            Check.That(monitor.HandleKey(KeyD, true));
            Check.That(monitor.HandleKey(KeyD, true));
            Check.Equal(log(), "start lock");
            monitor.HandleKey(LCtrl, false);
            Check.That(monitor.HandleKey(KeyD, false));
        });
    }

    // A fresh monitor per scenario — no hooks, no shared state carried over, callbacks inline.
    static void Run(Action<ShortcutMonitor, Func<string>> body)
    {
        var monitor = new ShortcutMonitor(inline: true);
        var log = new List<string>();
        monitor.OnStart = action => log.Add(action == ShortcutAction.PressEnter ? "start+enter" : "start");
        monitor.OnStop = locked => log.Add(locked ? "stop-locked" : "stop");
        monitor.OnCancel = () => log.Add("cancel");
        monitor.OnLock = () => log.Add("lock");
        body(monitor, () => string.Join(" ", log));
    }
}
