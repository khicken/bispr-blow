using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;

namespace BisprBlow;

// Global shortcut detection: watches `AppSettings.Bindings` and turns them into dictation gestures.
// On a push-to-talk binding: hold (>= HoldThreshold) starts on key-down and stops on release;
// double-tap locks hands-free until the next tap or a cancel binding; a single short tap cancels and
// discards what key-down started.
//
// Two low-level hooks (keyboard and mouse) on a thread of their own that does nothing but pump
// messages: a hook proc that answers slowly gets its events dropped by the system, so the procs only
// run the state machine, and every callback to the app is posted to the thread that called Start.
// Each hook CONSUMES the events a binding claims, so a Ctrl+Alt+D binding never reaches the app
// underneath. Everything unbound passes through. Needs no permission.
public sealed class ShortcutMonitor
{
    // One monitor per process by construction — two hook sets would fight over the same events.
    // Shared so Settings can arm the recorder without threading the controller through the UI.
    public static readonly ShortcutMonitor Shared = new();

    // The binding that started this session, so "Dictate and send" and "Voice command" can end it their way.
    public Action<ShortcutAction>? OnStart;
    // locked == true when stopping a hands-free session.
    public Action<bool>? OnStop;
    public Action? OnCancel;
    // Fired when a double-tap upgrades the session to hands-free.
    public Action? OnLock;

    const double HoldThreshold = 0.30;
    const double DoubleTapWindow = 0.40;

    readonly object gate = new();
    // Callbacks leave the hook thread through here. `--self-check` runs them inline.
    readonly bool inline;
    SynchronizationContext? ui;

    bool triggerIsDown;
    double triggerDownAt;
    double lastTapAt = -10;
    bool locked;
    Timer? pendingCancel;
    // Which action is holding the current session: a release only counts from the same binding,
    // so letting go of "dictate and send" can't end a push-to-talk hold.
    ShortcutAction? heldAction;
    // Set when we swallowed a cancel key-down, so its key-up gets swallowed to match.
    bool swallowedCancelDown;
    // The modifiers-only binding currently held, so the release edge knows what broke.
    (ShortcutAction Action, Shortcut Shortcut)? heldCombo;

    internal List<(ShortcutAction Action, Shortcut Shortcut)> bindings = [];
    bool started;

    // Windows sends no "modifiers changed" event, so the held set is kept here from the keys that
    // went down and up.
    readonly HashSet<int> modsDown = [];
    // A key that fired a binding, so its repeats and its release go to the same action whatever
    // modifiers are held by then, and whether it was swallowed.
    readonly Dictionary<int, (ShortcutAction Action, bool Swallowed)> active = [];
    // The Win key has already been masked this hold.
    bool startMasked;

    Thread? hookThread;
    uint hookThreadId;
    Hook? keyboardHook, mouseHook;

    ShortcutMonitor() { }
    internal ShortcutMonitor(bool inline) => this.inline = inline;

    public void Start()
    {
        lock (gate)
        {
            if (started) return;
            started = true;
            ui = SynchronizationContext.Current;
            Reload();
        }
        using var ready = new ManualResetEventSlim();
        hookThread = new Thread(() => RunHooks(ready)) { IsBackground = true, Name = "ShortcutMonitor" };
        hookThread.SetApartmentState(ApartmentState.STA);
        hookThread.Start();
        if (!ready.Wait(3000)) Log.Line("shortcut hooks did not install in time");
    }

    // Pick up edited bindings.
    public void Reload()
    {
        lock (gate)
        {
            bindings = AppSettings.Shared.AllBindings.ToList();
            // The combo that was held may not exist anymore; without this its release edge never
            // comes and the next press is read as a release.
            heldCombo = null;
        }
    }

    public void Stop()
    {
        lock (gate) started = false;
        if (hookThread is not { } thread) return;
        PostThreadMessage(hookThreadId, 0x0012, 0, 0);  // WM_QUIT ends the pump, which unhooks
        thread.Join(1000);
        hookThread = null;
    }

    // Stop a hands-free session from the UI (pill stop button).
    public void EndLockedSession()
    {
        lock (gate)
        {
            if (!locked) return;
            locked = false;
            Post(() => OnStop?.Invoke(true));
        }
    }

    // The controller turned a start down or ended on its own, so no hands-free session is live.
    public void Reset()
    {
        lock (gate)
        {
            CancelPending();
            locked = false;
            lastTapAt = -10;
        }
    }

    // Start a hands-free session from the UI (pill buttons) — same as double-tapping.
    public void BeginLockedSession()
    {
        lock (gate)
        {
            if (locked || triggerIsDown) return;
            locked = true;
            Post(() => OnStart?.Invoke(ShortcutAction.HandsFree));
            Post(() => OnLock?.Invoke());
        }
    }

    void Post(Action callback)
    {
        if (inline) callback();
        else ui!.Post(_ => callback(), null);
    }

    // ---- Recording a new binding

    Action<Shortcut>? captureHandler;
    Action<Shortcut?>? capturePreview;
    CaptureState captureState = new();

    // The recorder's bookkeeping, kept apart from the monitor so `--self-check` can drive the whole
    // state machine with no hook in the way.
    //
    // Press-and-release, not first-key-wins: the binding is whatever was down when you let go. That
    // is the only model in which Ctrl+Shift can be recorded at all, and it is what makes Ctrl+Shift+G
    // one shortcut. Every modifier is tracked from its own key events, since while armed they are
    // swallowed and never reach the app that would otherwise report them.
    internal sealed class CaptureState
    {
        // Modifiers physically down right now.
        public Mods Held;
        // Every modifier this combination has contained, so releasing them in any order still
        // records what was pressed.
        public Mods Peak;
        // The first modifier down. A single modifier records as `Key` so left Ctrl stays distinct
        // from right Ctrl; two or more can only be `Modifiers`, which has no key code.
        public int? FirstModifier;
        // The ordinary key or mouse button, once one joins.
        public (TriggerKind Kind, int Code)? Trigger;
        public bool TriggerIsDown;

        // The binding as it stands — what the editor draws while you hold the keys down.
        public Shortcut? Preview
        {
            get
            {
                if (Trigger is { } t) return new Shortcut(t.Kind, t.Code, Peak);
                if (Peak == Mods.None) return null;
                if (BitOperations.PopCount((uint)Peak) == 1 && FirstModifier is { } code) return new Shortcut(TriggerKind.Key, code);
                return new Shortcut(TriggerKind.Modifiers, 0, Peak);
            }
        }

        public bool EverythingReleased => Held == Mods.None && !TriggerIsDown;
    }

    internal enum CaptureEvent { KeyDown, KeyUp, MouseDown, MouseUp }

    // Arm the recorder: keys and mouse buttons go to the recorder instead of firing any binding, and
    // never reach the app underneath. `preview` fires as the combination is held, `captured` on release.
    public void Record(Action<Shortcut> captured, Action<Shortcut?>? preview = null)
    {
        lock (gate)
        {
            captureState = new();
            capturePreview = preview;
            captureHandler = captured;
        }
    }

    public void CancelRecord()
    {
        lock (gate)
        {
            captureHandler = null;
            capturePreview = null;
            captureState = new();
        }
    }

    // One armed event, as a pure function of the state. Every branch returns, because while armed the
    // event is consumed either way and only a non-null result ends the capture. `flags` is what the
    // monitor sees held, a floor for the combination under a key.
    internal static Shortcut? CaptureStep(CaptureEvent type, int code, Mods flags, CaptureState state)
    {
        Shortcut? Finish()
        {
            if (!state.EverythingReleased || state.Preview is not { } shortcut) return null;
            state.Held = state.Peak = Mods.None;
            state.FirstModifier = null;
            state.Trigger = null;
            return shortcut;
        }
        switch (type)
        {
            case CaptureEvent.KeyDown when Shortcut.ModifierFlags.TryGetValue(code, out var flag):
                state.FirstModifier ??= code;
                state.Held |= flag;
                state.Peak |= flag;
                return null;
            case CaptureEvent.KeyUp when Shortcut.ModifierFlags.TryGetValue(code, out var flag):
                state.Held &= ~flag;
                return Finish();
            case CaptureEvent.KeyDown:
                state.Trigger = (TriggerKind.Key, code);
                state.TriggerIsDown = true;
                state.Peak |= flags;
                return null;
            case CaptureEvent.KeyUp when state.Trigger == (TriggerKind.Key, code):
                state.TriggerIsDown = false;
                return Finish();
            case CaptureEvent.MouseDown:
                state.Trigger = (TriggerKind.Mouse, code);
                state.TriggerIsDown = true;
                return null;
            case CaptureEvent.MouseUp when state.Trigger == (TriggerKind.Mouse, code):
                state.TriggerIsDown = false;
                return Finish();
            default:
                return null;
        }
    }

    // Feeds the shortcut editor. Returns true when the event was consumed by it.
    bool Capture(CaptureEvent type, int code, Mods held)
    {
        if (captureHandler is not { } handler) return false;
        var capturePreview = this.capturePreview;
        var state = captureState;
        // Both hops go off the hook thread: they touch UI state and persist settings, and a hook
        // that takes too long to answer loses its events.
        if (CaptureStep(type, code, held, state) is { } shortcut)
        {
            CancelRecord();
            Post(() => handler(shortcut));
        }
        else if (capturePreview != null)
        {
            var inProgress = state.Preview;
            Post(() => capturePreview(inProgress));
        }
        return true;
    }

    // ---- Hooks

    // One hook's handle and the delegate that must stay alive as long as it is installed.
    sealed class Hook(int kind, HookProc proc)
    {
        readonly HookProc keep = proc;
        readonly IntPtr handle = SetWindowsHookEx(kind, proc, GetModuleHandle(null), 0);
        public bool Installed => handle != IntPtr.Zero;
        public void Remove() { if (Installed) UnhookWindowsHookEx(handle); }
    }

    delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    void RunHooks(ManualResetEventSlim ready)
    {
        hookThreadId = GetCurrentThreadId();
        keyboardHook = new Hook(13, KeyboardProc);
        mouseHook = new Hook(14, MouseProc);
        if (!keyboardHook.Installed || !mouseHook.Installed) Log.Line("shortcut hook failed: " + Marshal.GetLastWin32Error());
        ready.Set();
        var message = new byte[48];  // a MSG, which nothing here reads
        while (GetMessage(message, IntPtr.Zero, 0, 0) > 0) { }
        keyboardHook.Remove();
        mouseHook.Remove();
    }

    // What the hook is allowed to see: events a program injected (our own paste, the Win-key mask)
    // never trip a binding.
    const uint KeyInjected = 0x10;
    const uint MouseInjected = 0x01;

    [StructLayout(LayoutKind.Sequential)]
    struct KeyboardEvent { public uint Vk, Scan, Flags, Time; public IntPtr Extra; }

    [StructLayout(LayoutKind.Sequential)]
    struct MouseEvent { public int X, Y; public uint Data, Flags, Time; public IntPtr Extra; }

    unsafe IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var e = *(KeyboardEvent*)lParam;
            var message = (int)wParam;
            if ((e.Flags & KeyInjected) == 0)
            {
                try
                {
                    var down = message is 0x100 or 0x104;
                    bool swallow;
                    lock (gate)
                    {
                        DropReleasedModifiers((int)e.Vk);
                        swallow = HandleKey((int)e.Vk, down);
                    }
                    if (swallow) return 1;
                }
                catch (Exception ex) { Log.Line("shortcut hook error: " + ex.Message); }
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    unsafe IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
    {
        var message = (int)wParam;
        if (code >= 0 && message is 0x207 or 0x208 or 0x20B or 0x20C)
        {
            var e = *(MouseEvent*)lParam;
            if ((e.Flags & MouseInjected) == 0)
            {
                try
                {
                    // Middle is button 2, the side buttons 3 and 4, numbered the way Settings shows them.
                    var button = message is 0x207 or 0x208 ? 2 : 2 + (int)(e.Data >> 16 & 0xFFFF);
                    bool swallow;
                    lock (gate) swallow = HandleMouse(button, message is 0x207 or 0x20B);
                    if (swallow) return 1;
                }
                catch (Exception ex) { Log.Line("shortcut hook error: " + ex.Message); }
            }
        }
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    // A release the hook never saw (the Win key let go on the lock screen) would leave a modifier
    // held forever, so a modifier the system says is up is dropped.
    void DropReleasedModifiers(int current)
    {
        foreach (var vk in modsDown.ToArray())
            if (vk != current && (GetAsyncKeyState(vk) & 0x8000) == 0 && !active.ContainsKey(vk))
                modsDown.Remove(vk);
    }

    Mods Held => modsDown.Aggregate(Mods.None, (all, vk) => all | Shortcut.ModifierFlags[vk]);

    ShortcutAction? ActionMatching(Func<Shortcut, bool> predicate) =>
        bindings.Where(b => predicate(b.Shortcut)).Select(b => (ShortcutAction?)b.Action).FirstOrDefault();

    // Returns true when the key should be swallowed rather than passed to the app underneath.
    internal bool HandleKey(int vk, bool down)
    {
        var isModifier = Shortcut.ModifierFlags.ContainsKey(vk);
        if (isModifier)
        {
            if (down) modsDown.Add(vk); else modsDown.Remove(vk);
            if (!Held.HasFlag(Mods.Win)) startMasked = false;
        }
        var held = Held;
        if (Capture(down ? CaptureEvent.KeyDown : CaptureEvent.KeyUp, vk, held)) return true;

        if (isModifier && ComboEdge(held) is var (comboAction, comboDown))
        {
            if (comboDown && heldCombo is { } combo && combo.Shortcut.Flags.HasFlag(Mods.Win)) MaskStartMenu();
            Dispatch(comboAction, comboDown);
            // Passed through even though the binding claimed it: a modifiers-only combo is only
            // recognised once its LAST modifier arrives, so the earlier ones already reached the
            // system and swallowing the rest would leave them stuck down everywhere else.
            return false;
        }

        if (active.TryGetValue(vk, out var started))
        {
            if (down) return started.Swallowed;  // auto-repeat
            active.Remove(vk);
            return Dispatch(started.Action, false);
        }
        if (ActionMatching(s => s.Matches(vk, held)) is not { } action) return false;
        var swallow = Dispatch(action, down);
        if (down) active[vk] = (action, swallow);
        if (down && swallow && held.HasFlag(Mods.Win)) MaskStartMenu();
        return swallow;
    }

    internal bool HandleMouse(int button, bool down) =>
        Capture(down ? CaptureEvent.MouseDown : CaptureEvent.MouseUp, button, Mods.None)
        || ActionMatching(s => s.MatchesMouse(button)) is { } action && Dispatch(action, down);

    // Win released with nothing typed in between opens the Start menu, and a binding that used the Win
    // key must not do that. A key the system ignores, sent while Win is down, counts as "something was
    // typed".
    void MaskStartMenu()
    {
        if (startMasked) return;
        startMasked = true;
        TextInserter.SendKeys((0xE8, true), (0xE8, false));
    }

    // Press and release edges for a modifiers-only binding (Ctrl+Shift held alone). It has no key, so
    // the press is the held set completing and the release is it breaking — only the previous state says.
    (ShortcutAction Action, bool Down)? ComboEdge(Mods held)
    {
        if (heldCombo is { } current)
        {
            if (current.Shortcut.MatchesModifiers(held)) return null;
            heldCombo = null;
            return (current.Action, false);
        }
        foreach (var binding in bindings)
        {
            if (!binding.Shortcut.MatchesModifiers(held)) continue;
            heldCombo = binding;
            return (binding.Action, true);
        }
        return null;
    }

    // ---- Dispatch

    bool SessionIsLive => locked || triggerIsDown;

    // Returns true when the event should be swallowed rather than passed to the app underneath.
    bool Dispatch(ShortcutAction action, bool down)
    {
        switch (action)
        {
            case ShortcutAction.PushToTalk or ShortcutAction.PressEnter or ShortcutAction.Command:
                HandleHold(action, down);
                return true;
            case ShortcutAction.HandsFree:
                if (!down) return true;
                if (locked)
                {
                    locked = false;
                    Post(() => OnStop?.Invoke(true));
                }
                else BeginLockedSession();
                return true;
            default:
                if (!down)
                {
                    var swallowed = swallowedCancelDown;
                    swallowedCancelDown = false;
                    return swallowed;
                }
                // Esc is the shipped default: only eat it while there is something to throw away.
                if (!SessionIsLive) return false;
                CancelSession();
                swallowedCancelDown = true;
                return true;
        }
    }

    void CancelSession()
    {
        CancelPending();
        locked = false;
        // Clear the hold too, so the physical release of a still-held trigger is a no-op
        // rather than a second stop.
        triggerIsDown = false;
        heldAction = null;
        lastTapAt = -10;
        Post(() => OnCancel?.Invoke());
    }

    void CancelPending()
    {
        pendingCancel?.Dispose();
        pendingCancel = null;
    }

    // Test seam for `--self-check`: drives the gesture machine with no hook in the way.
    // Returns whether the event would have been swallowed.
    internal bool Simulate(ShortcutAction action, bool down)
    {
        lock (gate) return Dispatch(action, down);
    }

    // ---- Gesture state machine

    static double Now => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    void HandleHold(ShortcutAction action, bool down)
    {
        var now = Now;

        if (down && !triggerIsDown)
        {
            triggerIsDown = true;
            triggerDownAt = now;
            heldAction = action;
            CancelPending();

            if (locked)
            {
                // Tap while locked → stop and process.
                locked = false;
                Post(() => OnStop?.Invoke(true));
                lastTapAt = -10;
                return;
            }
            if (now - lastTapAt <= DoubleTapWindow)
            {
                // Second tap of a double-tap → lock hands-free mode (already recording).
                locked = true;
                lastTapAt = -10;
                Post(() => OnLock?.Invoke());
                return;
            }
            Post(() =>
            {
                ActivationTrace.Begin();
                OnStart?.Invoke(action);
            });
        }
        else if (!down && triggerIsDown && heldAction == action)
        {
            triggerIsDown = false;
            heldAction = null;
            if (locked) return;  // release of the second tap; session stays live
            if (now - triggerDownAt >= HoldThreshold)
            {
                Post(() => OnStop?.Invoke(false));
                lastTapAt = -10;
                return;
            }
            // Short tap: wait out the double-tap window before discarding.
            lastTapAt = now;
            Timer? timer = null;
            timer = new Timer(_ =>
            {
                lock (gate)
                {
                    if (pendingCancel != timer || locked) return;
                    pendingCancel = null;
                    Post(() => OnCancel?.Invoke());
                }
            }, null, (int)(DoubleTapWindow * 1000), Timeout.Infinite);
            pendingCancel = timer;
        }
    }

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int kind, HookProc proc, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetMessage(byte[] message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int vk);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string? name);
}
