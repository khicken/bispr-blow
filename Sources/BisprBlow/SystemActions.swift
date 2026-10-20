import Carbon.HIToolbox
import CoreGraphics

// What any app answers to without being on screen: shortcuts, scrolling, media keys. Each is an
// option in Jev's target list next to the screen's own elements, and its phrases skip Jev entirely.
struct SystemAction: Sendable, Equatable {
    enum Mechanism: Sendable, Equatable {
        case keys(Shortcut)
        case scroll(Int32)
        case media(Int32)
        case script(String)
        case launch(String)
    }

    let id: String
    let title: String
    let detail: String
    let phrases: [String]
    let mechanism: Mechanism
    let isVerifiable: Bool

    private static let scrollStep: Int32 = 600

    // NX_KEYTYPE_* from IOKit's ev_keymap.h.
    private static let soundUpKey: Int32 = 0
    private static let soundDownKey: Int32 = 1
    private static let brightnessUpKey: Int32 = 2
    private static let brightnessDownKey: Int32 = 3
    private static let muteKey: Int32 = 7
    private static let playKey: Int32 = 16
    private static let nextKey: Int32 = 17
    private static let previousKey: Int32 = 18

    // The ones whose effect shows in the focused window, its title, focus or URL.
    private static let verifiableIDs: Set<String> = [
        "back", "forward", "reload", "newTab", "closeTab", "reopenTab", "nextTab", "previousTab", "newWindow",
        "minimize", "fullScreen", "hideApp", "quitApp", "appSettings", "find", "print", "enter", "escape",
    ]

    private init(_ id: String, _ title: String, _ detail: String, _ phrases: [String], _ mechanism: Mechanism) {
        self.id = id
        self.title = title + " (system)"
        self.detail = detail
        self.phrases = phrases
        self.mechanism = mechanism
        isVerifiable = Self.verifiableIDs.contains(id)
    }

    private static func keys(_ keyCode: Int, _ modifiers: CGEventFlags = []) -> Mechanism {
        .keys(Shortcut(trigger: .key(keyCode), flags: modifiers.rawValue))
    }

    static func named(_ id: String) -> SystemAction? { all.first { $0.id == id } }

    // "Undo" is not here: it is an intent, and the executor knows what it last did.
    static let all: [SystemAction] = [
        SystemAction("scrollUp", "Scroll up", "Scrolls the page or list up.", ["scroll up", "page up", "up"], .scroll(-scrollStep)),
        SystemAction("scrollDown", "Scroll down", "Scrolls the page or list down.", ["scroll down", "page down", "down"], .scroll(scrollStep)),
        SystemAction("scrollTop", "Scroll to the top", "Jumps to the top of the page or document.",
                     ["scroll to the top", "scroll to top", "go to the top", "top of the page"], keys(kVK_Home)),
        SystemAction("scrollBottom", "Scroll to the bottom", "Jumps to the bottom of the page or document.",
                     ["scroll to the bottom", "scroll to bottom", "go to the bottom", "bottom of the page"], keys(kVK_End)),
        SystemAction("back", "Go back", "Goes back to the previous page.", ["go back", "back"],
                     keys(kVK_ANSI_LeftBracket, .maskCommand)),
        SystemAction("forward", "Go forward", "Goes forward to the next page in history.", ["go forward"],
                     keys(kVK_ANSI_RightBracket, .maskCommand)),
        SystemAction("reload", "Reload", "Reloads the page.", ["reload", "refresh", "reload the page", "refresh the page"],
                     keys(kVK_ANSI_R, .maskCommand)),
        SystemAction("newTab", "New tab", "Opens a new tab.", ["new tab", "open a new tab", "open new tab"], keys(kVK_ANSI_T, .maskCommand)),
        SystemAction("closeTab", "Close tab or window", "Closes the current tab, or the window when it has none.",
                     ["close tab", "close this tab", "close the tab", "close window", "close this window", "close the window"],
                     keys(kVK_ANSI_W, .maskCommand)),
        SystemAction("reopenTab", "Reopen closed tab", "Brings back the tab closed last.",
                     ["reopen tab", "reopen the tab", "reopen closed tab", "undo close tab"], keys(kVK_ANSI_T, [.maskShift, .maskCommand])),
        SystemAction("nextTab", "Next tab", "Switches to the tab on the right.", ["next tab", "tab right"], keys(kVK_Tab, .maskControl)),
        SystemAction("previousTab", "Previous tab", "Switches to the tab on the left.", ["previous tab", "last tab", "tab left"],
                     keys(kVK_Tab, [.maskControl, .maskShift])),
        SystemAction("newWindow", "New window", "Opens a new window, document or message in the app in front.",
                     ["new window", "open a new window"], keys(kVK_ANSI_N, .maskCommand)),
        SystemAction("minimize", "Minimize window", "Minimizes the window to the Dock.", ["minimize", "minimize window", "minimize this window"],
                     keys(kVK_ANSI_M, .maskCommand)),
        SystemAction("fullScreen", "Full screen", "Turns full screen on or off for the window.",
                     ["full screen", "fullscreen", "go full screen", "exit full screen"], keys(kVK_ANSI_F, [.maskControl, .maskCommand])),
        SystemAction("hideApp", "Hide app", "Hides the app in front.", ["hide app", "hide this app", "hide this"], keys(kVK_ANSI_H, .maskCommand)),
        SystemAction("quitApp", "Quit app", "Quits the app in front.", ["quit app", "quit this app", "quit"], keys(kVK_ANSI_Q, .maskCommand)),
        SystemAction("appSettings", "App settings", "Opens the settings of the app in front.",
                     ["settings", "preferences", "open settings", "open preferences"], keys(kVK_ANSI_Comma, .maskCommand)),
        SystemAction("copy", "Copy", "Copies the selection.", ["copy", "copy that", "copy this"], keys(kVK_ANSI_C, .maskCommand)),
        SystemAction("paste", "Paste", "Pastes the clipboard.", ["paste", "paste that", "paste it"], keys(kVK_ANSI_V, .maskCommand)),
        SystemAction("cut", "Cut", "Cuts the selection.", ["cut", "cut that", "cut this"], keys(kVK_ANSI_X, .maskCommand)),
        SystemAction("selectAll", "Select all", "Selects everything in the field or document.", ["select all", "select everything"],
                     keys(kVK_ANSI_A, .maskCommand)),
        SystemAction("redo", "Redo", "Redoes what was just undone.", ["redo", "redo that"], keys(kVK_ANSI_Z, [.maskShift, .maskCommand])),
        SystemAction("save", "Save", "Saves the document.", ["save", "save it", "save this", "save the file"], keys(kVK_ANSI_S, .maskCommand)),
        SystemAction("find", "Find", "Opens find in the page or document.", ["find", "find on page", "find in page"],
                     keys(kVK_ANSI_F, .maskCommand)),
        SystemAction("print", "Print", "Opens the print dialog.", ["print", "print this"], keys(kVK_ANSI_P, .maskCommand)),
        SystemAction("zoomIn", "Zoom in", "Makes the content bigger.", ["zoom in", "bigger", "make it bigger"],
                     keys(kVK_ANSI_Equal, .maskCommand)),
        SystemAction("zoomOut", "Zoom out", "Makes the content smaller.", ["zoom out", "smaller", "make it smaller"],
                     keys(kVK_ANSI_Minus, .maskCommand)),
        SystemAction("actualSize", "Actual size", "Resets the zoom.", ["actual size", "reset zoom"], keys(kVK_ANSI_0, .maskCommand)),
        SystemAction("enter", "Press Return", "Presses the Return key.", ["enter", "press enter", "hit enter", "return", "press return", "hit return"],
                     keys(kVK_Return)),
        SystemAction("escape", "Press Escape", "Presses the Escape key, which closes a dialog or menu.",
                     ["escape", "press escape", "hit escape"], keys(kVK_Escape)),
        SystemAction("tab", "Press Tab", "Moves to the next field.", ["press tab", "hit tab", "next field"], keys(kVK_Tab)),
        SystemAction("shiftTab", "Press Shift Tab", "Moves to the previous field.", ["shift tab", "previous field"],
                     keys(kVK_Tab, .maskShift)),
        SystemAction("arrowUp", "Arrow up", "Presses the up arrow key.", ["arrow up", "up arrow", "press up"], keys(kVK_UpArrow)),
        SystemAction("arrowDown", "Arrow down", "Presses the down arrow key.", ["arrow down", "down arrow", "press down"],
                     keys(kVK_DownArrow)),
        SystemAction("volumeUp", "Volume up", "Turns the sound up.", ["volume up", "louder", "turn it up", "turn up the volume"],
                     .media(soundUpKey)),
        SystemAction("volumeDown", "Volume down", "Turns the sound down.", ["volume down", "quieter", "turn it down", "turn down the volume"],
                     .media(soundDownKey)),
        SystemAction("mute", "Mute", "Mutes or unmutes the sound.", ["mute", "unmute", "mute sound"], .media(muteKey)),
        SystemAction("playPause", "Play or pause", "Plays or pauses music or video.", ["play", "pause", "play pause", "resume", "pause music"],
                     .media(playKey)),
        SystemAction("nextTrack", "Next track", "Skips to the next song.", ["next track", "next song", "skip", "skip song"], .media(nextKey)),
        SystemAction("previousTrack", "Previous track", "Goes back to the previous song.", ["previous track", "previous song", "last song"],
                     .media(previousKey)),
        SystemAction("brightnessUp", "Brightness up", "Makes the screen brighter.", ["brightness up", "brighter"], .media(brightnessUpKey)),
        SystemAction("brightnessDown", "Brightness down", "Makes the screen dimmer.", ["brightness down", "dimmer"], .media(brightnessDownKey)),
        SystemAction("screenshot", "Screenshot", "Takes a screenshot of the whole screen.",
                     ["screenshot", "take a screenshot", "take screenshot"], keys(kVK_ANSI_3, [.maskShift, .maskCommand])),
        SystemAction("screenshotArea", "Screenshot of an area", "Takes a screenshot of an area you drag out.",
                     ["screenshot area", "screenshot an area", "screenshot a region"], keys(kVK_ANSI_4, [.maskShift, .maskCommand])),
        SystemAction("lockScreen", "Lock screen", "Locks the Mac.", ["lock screen", "lock the screen", "lock my mac"],
                     keys(kVK_ANSI_Q, [.maskControl, .maskCommand])),
        SystemAction("darkMode", "Dark mode", "Switches the Mac between dark and light appearance.",
                     ["dark mode", "light mode", "toggle dark mode"],
                     .script("tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode")),
        SystemAction("missionControl", "Mission Control", "Shows every open window and space.",
                     ["mission control", "show all windows", "app switcher", "show windows"], .launch("com.apple.exposelauncher")),
        SystemAction("appWindows", "App windows", "Shows the windows of the app in front.", ["app windows", "show app windows"],
                     keys(kVK_DownArrow, .maskControl)),
        SystemAction("emoji", "Emoji picker", "Opens the emoji and symbols picker.", ["emoji", "emoji picker", "open emoji"],
                     keys(kVK_Space, [.maskControl, .maskCommand])),
    ]
}
