import Foundation

extension SelfCheck {
    static func checkJayDecide() {
        // A section header and the page link it reveals share a name but never a vote: pressing the header navigates nowhere.
        let header = ScreenElement(label: "Simulations (button)", kind: .press, role: "web:button", detail: "button in the navigation. closes this open \(ScreenElements.revealsWhat)",
                                   context: "", shortcut: nil, frame: nil)
        let link = ScreenElement(label: "Simulations (link)", kind: .press, role: "web:link", detail: "link in the navigation", context: "", shortcut: nil, frame: nil)
        precondition(JayDecide.group(of: header) != JayDecide.group(of: link))
        // Jev leans toward the first option, so the order we write must survive serialization.
        let bodyData = Jev.body(state: [("app", "Mail")], questions: [
            Jev.Question(name: "q", type: .choice, instructions: "pick", criteria: [("b", nil), ("a", "the first letter")]),
            Jev.Question(name: "fits", type: .noul, instructions: "yes?", criteria: []),
        ])
        let body = String(decoding: bodyData, as: UTF8.self)
        precondition((try? JSONSerialization.jsonObject(with: bodyData)) != nil, body)
        precondition(body.range(of: "\"b\"")!.lowerBound < body.range(of: "\"a\"")!.lowerBound, body)
        precondition(body.contains("\"b\":null"), body)

        let crowded = decideScreen((0..<300).map { decideElement("Item \($0) (button)") })
        let options = JayDecide.candidates(screen: crowded)
        precondition(options.count <= Jev.maxChoices)
        precondition(Set(options.map(\.key)).count == options.count)
        precondition(options.suffix(2).map(\.key) == [JayDecide.appOption, JayDecide.webOption])
        precondition(options.dropLast(2).suffix(SystemAction.all.count).map(\.key) == SystemAction.all.map(\.title))

        // The phase-0 miss: one thing listed twice must not lose to a single wrong option.
        let search = JayDecide.candidates(screen: decideScreen([
            decideElement("Search (button)"), decideElement("Search (menu item)", role: "AXMenuItem"),
            decideElement("Find (menu item)", role: "AXMenuItem"),
        ]))
        let searchRanked = JayDecide.ranked(search, probabilities: ["Search (button)": 0.3, "Search (menu item)": 0.3, "Find (menu item)": 0.4])
        precondition(searchRanked.first?.candidate.key == "Search (button)")
        precondition(abs((searchRanked.first?.total ?? 0) - 0.6) < 0.001)

        // A menu item and the catalog's shortcut are the same keystroke; the catalog is the direct route.
        let save = JayDecide.candidates(screen: decideScreen([decideElement("Save (menu item)", role: "AXMenuItem", shortcut: "⌘S")]))
        precondition(JayDecide.ranked(save, probabilities: ["Save (menu item)": 0.7]).first?.candidate.key == SystemAction.named("save")?.title)
        guard case .keys(let saveKeys)? = SystemAction.named("save")?.mechanism else { preconditionFailure("save is not a shortcut") }
        precondition(ScreenElements.shortcutText(cmdChar: "S", modifiers: 0) == saveKeys.display)

        precondition(JayDecide.isSure(top: 0.6, second: 0.3))
        precondition(!JayDecide.isSure(top: 0.6, second: 0.31))
        precondition(!JayDecide.isSure(top: 0.59, second: 0.1))

        precondition(JayDecide.textSpans(in: "type hello world").contains("hello world"))
        precondition(JayDecide.textSpans(in: "say \"on my way\"").contains("on my way"))
        precondition(JayDecide.textSpans(in: "scroll down").isEmpty)
        precondition(JayDecide.textSpans(in: "type pr reviews in the channel search box").contains("pr reviews"))
        precondition(JayDecide.textSpans(in: "make a new document and type hello from jay").contains("hello from jay"))
        let listSpans = JayDecide.textSpans(in: "make a new document, write shopping list and center it")
        precondition(listSpans.first == "shopping list and center it" && listSpans.contains("shopping list"))
        precondition(JayDecide.withDigits("Calculate twelve times eight.") == "Calculate 12 times 8")
        precondition(JayDecide.withDigits("add twenty five and ninety") == "25 plus 90")
        precondition(JayDecide.withDigits("subtract three from ten") == "10 minus 3")
        precondition(JayDecide.withDigits("add salt and pepper") == "add salt and pepper")

        // Calculator's "9" key and View > Decimal Places > 9: the key on screen is what "nine" means
        let digits = JayDecide.candidates(screen: decideScreen([decideElement("9 (menu item)", role: "AXMenuItem"), decideElement("9 (button)")]),
                                          command: "calculate nine times seven")
        precondition(digits.first?.key == "9 (button)")
        precondition(JayDecide.ranked(digits, probabilities: ["9 (menu item)": 0.6, "9 (button)": 0.2]).first?.candidate.key == "9 (button)")

        let recent = decideElement("~/Desktop/bluejay/bluejay_middleware (menu item)", role: "AXMenuItem")
        let recentFit = JayDecide.candidates(screen: decideScreen([decideElement("Open Folder… (menu item)", role: "AXMenuItem"), recent]),
                                             command: "open the bluejay middleware project")
        precondition(recentFit.first?.key == recent.label && recentFit.first?.detail.hasPrefix("\"bluejay middleware\"") == true)
        precondition(JayDecide.spokenName("Input/Output") == "Input/Output")
        guard let firstStep = VoiceCommand.steps(in: "go to github.com and search for swift").first,
              VoiceCommand.webAddress(for: firstStep)?.host() == "github.com"
        else { preconditionFailure("a chained web step searched the whole sentence") }

        // A long sidebar must not crowd out what the command names, the fields, or every menu.
        let rows = (0..<240).map { decideElement("Channel \($0) (outline row)") }
        let menuItems = [decideElement("Copy (menu item)", role: "AXMenuItem", shortcut: "⌘C")]
            + (0..<80).map { decideElement("Menu item \($0) (menu item)", role: "AXMenuItem") }
        let composer = ScreenElement(label: "Message (text entry area)", kind: .field, role: "AXTextArea", detail: "", context: "", shortcut: nil, frame: nil)
        let crowdedApp = decideScreen(rows + [composer] + menuItems + [decideElement("Sign Out (menu item)", role: "AXMenuItem")])
        let fit = JayDecide.candidates(screen: crowdedApp, command: "sign out of slack").map(\.key)
        precondition(fit.first == "Sign Out (menu item)" && fit.contains(composer.label) && fit.contains("Menu item 59 (menu item)")
                     && !fit.contains("Copy (menu item)"))
        let sayingOrder = JayDecide.fitted([decideElement("bold (checkbox)"), decideElement("Select All (menu item)", role: "AXMenuItem"),
                                            decideElement("Open… (menu item)", role: "AXMenuItem")],
                                           room: Jev.maxChoices, command: "open it, select all the text and make it bold")
        precondition(sayingOrder.map(\.label) == ["Select All (menu item)", "bold (checkbox)", "Open… (menu item)"])
        precondition(ScreenElements.interleaved([[1, 2, 3], [4], [5, 6]]) == [1, 4, 5, 2, 6, 3])

        precondition(JayDecide.localIntent("never mind") == .stop)
        precondition(JayDecide.localIntent("Undo that.") == .undo)
        precondition(JayDecide.localIntent("jay sleep") == .sleep)
        precondition(JayDecide.localIntent("Jay, go to sleep.") == .sleep)
        precondition(JayDecide.localIntent("scroll down") == nil)
        precondition(JayDecide.plainName("Send (button) #2") == "Send")

        let safari = InstalledApp(name: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        let screen = decideScreen([])
        guard case .system(let scroll)? = JayDecide.quick("Scroll down.", screen: screen, apps: [safari])?.action, scroll.id == "scrollDown"
        else { preconditionFailure("scroll down skipped the fast path") }
        guard case .openApp(let opened)? = JayDecide.quick("open Safari", screen: screen, apps: [safari])?.action, opened == safari
        else { preconditionFailure("open Safari skipped the fast path") }
        precondition(JayDecide.quick("open the file", screen: screen, apps: [safari]) == nil)
        guard case .openURL(let site)? = JayDecide.quick("open railway.app", screen: screen, apps: [safari])?.action, site.host() == "railway.app"
        else { preconditionFailure("a spoken web address went to Jev, which reads .app as an app") }
        precondition(JayDecide.quick("open notes.txt", screen: screen, apps: [safari]) == nil)
        let prompt = ScreenElement(label: "Prompt (text entry area)", kind: .field, role: "AXTextArea", detail: "", context: "", shortcut: nil, frame: nil)
        let focusOnButton = ScreenSnapshot(bundleID: "com.example.front", appName: "Example", pid: 1, windowTitle: "Window", url: nil,
                                           focused: "Stop (button)", selected: nil, elements: [decideElement("Stop (button)"), prompt],
                                           source: .accessibility, readMs: 0, takenAt: Date())
        guard case .type("fix the flaky test", into: let typedInto)? = JayDecide.quick("type fix the flaky test", screen: focusOnButton, apps: [])?.action,
              typedInto?.label == prompt.label
        else { preconditionFailure("typing skipped the only field on screen") }
        precondition(JayDecide.quick("type hi in the search box", screen: focusOnButton, apps: []) == nil)
        precondition(JayDecide.quick("write shopping list and center it", screen: focusOnButton, apps: []) == nil)

        let ids = SystemAction.all.map(\.id), titles = SystemAction.all.map(\.title), phrases = SystemAction.all.flatMap(\.phrases)
        precondition(Set(ids).count == ids.count && Set(titles).count == titles.count && Set(phrases).count == phrases.count)
        precondition(SystemAction.all.count <= 60)
        precondition(phrases.allSatisfy { JayDecide.normalized($0) == $0 }, "a phrase the fast path can never match")

        let manyApps = (0..<300).map { InstalledApp(name: "App \($0)", bundleID: "com.example.app\($0)", path: "/Applications/App \($0).app") }
        let appChoices = InstalledApps.choices(manyApps + [safari], excluding: "com.apple.Safari")
        precondition(appChoices.count == Jev.maxChoices && !appChoices.contains(safari))
        precondition(InstalledApps.named("the Safari.app", in: [safari]) == safari)

        precondition(VoiceCommand.hasRiskyWord("Move to Trash"))
        precondition(VoiceCommand.hasRiskyWord("forward this to Sam"))
        precondition(!VoiceCommand.hasRiskyWord("go forward"))
        precondition(!VoiceCommand.hasRiskyWord("resend"))
        precondition(VoiceCommand.steps(in: "open the command palette and run format document") == ["open the command palette", "run format document"])
        precondition(VoiceCommand.isUnfinished("open it with"))
    }

    private static func decideElement(_ label: String, role: String = "AXButton", shortcut: String? = nil) -> ScreenElement {
        ScreenElement(label: label, kind: .press, role: role, detail: "", context: "", shortcut: shortcut, frame: nil)
    }

    private static func decideScreen(_ elements: [ScreenElement]) -> ScreenSnapshot {
        ScreenSnapshot(bundleID: "com.example.front", appName: "Example", pid: 1, windowTitle: "Window", url: nil, focused: nil,
                       selected: nil, elements: elements, source: .accessibility, readMs: 0, takenAt: Date())
    }
}
