import CoreGraphics
import Foundation

// Chrome's page content over the DevTools protocol, once the user has turned on
// chrome://inspect/#remote-debugging. The app never turns it on. Chrome asks the user to allow each
// new connection, so one is opened and kept rather than one per read.
actor ChromeDevTools {
    static let shared = ChromeDevTools()
    static let unavailableRetry: TimeInterval = 60

    private static let replyTimeout: TimeInterval = 0.5
    // The first reply waits on the user answering Chrome's "Allow remote debugging?" prompt.
    private static let consentTimeout: TimeInterval = 30
    private static let worldName = "jay"
    // A "Which one?" or a confirmation can outlive the read it was asked about by a re-read or two.
    private static let keptCollections = 3
    private static let activePortFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/DevToolsActivePort")
    private static let webRoleDescriptions = [
        "textbox": "text field", "searchbox": "search field", "combobox": "pop-up button",
        "menuitem": "menu item", "radio": "radio button",
    ]

    private enum Failure: Error { case port, closed, timeout, malformed, script, reply(Int) }

    private var socket: URLSessionWebSocketTask?
    private var isConnecting = false
    private var isReady = false
    private var unavailableUntil: Date?
    private var nextID = 0
    private var replies: [Int: CheckedContinuation<Data, Error>] = [:]
    private var page: (targetID: String, sessionID: String, contextID: Int)?
    private var collections = 0

    nonisolated static var isEnabled: Bool { FileManager.default.fileExists(atPath: activePortFile.path) }

    nonisolated static func activePort(fileContents: String) -> (port: Int, path: String)? {
        let lines = fileContents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, let port = UInt16(lines[0]), port > 0, lines[1].hasPrefix("/devtools/browser/") else { return nil }
        return (Int(port), lines[1])
    }

    nonisolated static func elements(fromCollected rows: [[String: Any]], generation: Int = 0, webAreaFrame: CGRect? = nil,
                                     scale: CGFloat = 1) -> [ScreenElement] {
        rows.enumerated().compactMap { index, row in
            guard let name = (row["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let role = row["role"] as? String ?? "button"
            let roleDescription = webRoleDescriptions[role] ?? role
            // A section header or menu button shares its name with the page link it reveals, and pressing it navigates nowhere.
            let folding = ["true": "closes this open \(ScreenElements.revealsWhat)", "false": "opens a \(ScreenElements.revealsWhat)"][row["expanded"] as? String ?? ""]
            let states = (row["selected"] as? Bool == true ? [role == "checkbox" ? "checked" : "selected"] : []) + [folding].compactMap { $0 }
            return ScreenElement(
                label: "\(name.prefix(ScreenElements.labelLimit)) (\(roleDescription))",
                kind: row["kind"] as? String == "field" ? .field : .press,
                role: "web:\(role)",
                detail: ScreenElements.detail(roleDescription: roleDescription, place: row["place"] as? String,
                                              help: row["help"] as? String, shortcut: nil, states: states),
                context: "", shortcut: nil,
                frame: globalFrame(of: row, webAreaFrame: webAreaFrame, scale: scale),
                handle: .chrome(index: index, generation: generation),
                riskText: row["risk"] as? String ?? "")
        }
    }

    // nil until the connection is allowed and ready; the caller reads Accessibility instead.
    func read(windowTitle: String, url: String?, webAreaFrame: CGRect? = nil) async -> (url: String?, elements: [ScreenElement])? {
        guard unavailableUntil.map({ Date() >= $0 }) ?? true else { return nil }
        guard isReady else {
            connect()
            return nil
        }
        do {
            guard let target = try await pageTarget(windowTitle: windowTitle, url: url) else { return nil }
            collections += 1
            let collected = try await collect(targetID: target.id, generation: collections) as? [String: Any]
            // A tab in the background or another window is not what the user is looking at.
            guard collected?["isFront"] as? Bool == true else { return nil }
            let rows = collected?["rows"] as? [[String: Any]] ?? []
            let viewportWidth = collected?["vw"] as? Double ?? 0
            let scale = webAreaFrame.map { viewportWidth > 0 ? $0.width / viewportWidth : 1 } ?? 1
            return (target.url, Self.elements(fromCollected: rows, generation: collections, webAreaFrame: webAreaFrame, scale: scale))
        } catch Failure.closed {
            giveUp(Failure.closed)
            return nil
        } catch {
            // A page that will not be read (a chrome:// page, a slow reply) keeps the connection,
            // because a new one means the user answering Chrome's prompt again.
            logLine("chrome devtools fallback reason=\(error)")
            page = nil
            return nil
        }
    }

    func press(index: Int, generation: Int) async -> Bool { await perform("click", on: index, generation: generation) }

    func focus(index: Int, generation: Int) async -> Bool { await perform("focus", on: index, generation: generation) }

    // MARK: - Page

    private func pageTarget(windowTitle: String, url: String?) async throws -> (id: String, url: String)? {
        let targets = try await call("Target.getTargets")["targetInfos"] as? [[String: Any]] ?? []
        let pages = targets.filter { $0["type"] as? String == "page" }
        let byURL = url.flatMap { address in pages.first { $0["url"] as? String == address } }
        let byTitle = pages.first { page in
            let title = page["title"] as? String ?? ""
            return !title.isEmpty && (windowTitle == title || windowTitle.hasPrefix(title + " - "))
        }
        guard let match = byURL ?? byTitle, let id = match["targetId"] as? String else { return nil }
        return (id, match["url"] as? String ?? "")
    }

    // A navigation destroys the isolated world, so a failed evaluate re-attaches once.
    private func collect(targetID: String, generation: Int) async throws -> Any? {
        let collector = Self.collector(generation: generation)
        if page?.targetID == targetID, let value = try? await evaluate(collector) { return value }
        if let old = page { _ = try? await call("Target.detachFromTarget", ["sessionId": old.sessionID]) }
        page = nil
        let attached = try await call("Target.attachToTarget", ["targetId": targetID, "flatten": true])
        guard let sessionID = attached["sessionId"] as? String else { throw Failure.malformed }
        // Page scripts cannot see an isolated world's globals, so they cannot tamper with what is read.
        let world = try await call("Page.createIsolatedWorld", ["frameId": targetID, "worldName": Self.worldName], session: sessionID)
        guard let contextID = world["executionContextId"] as? Int else { throw Failure.malformed }
        page = (targetID, sessionID, contextID)
        return try await evaluate(collector)
    }

    private func evaluate(_ expression: String) async throws -> Any? {
        guard let page else { throw Failure.closed }
        let result = try await call("Runtime.evaluate", ["expression": expression, "contextId": page.contextID, "returnByValue": true],
                                    session: page.sessionID)
        guard result["exceptionDetails"] == nil else { throw Failure.script }
        return (result["result"] as? [String: Any])?["value"]
    }

    // Refused when the collection is gone (a navigation, a tab switch re-attached elsewhere) or the tab is not
    // in front, so a stale handle fails rather than pressing whatever now sits at its index.
    private func perform(_ method: String, on index: Int, generation: Int) async -> Bool {
        let script = """
        (() => { const node = ((window.__jay || {})[\(generation)] || [])[\(index)];
          if (!node || !node.isConnected || document.visibilityState !== 'visible' || !document.hasFocus()) return false;
          node.\(method)(); return true; })()
        """
        return (try? await evaluate(script)) as? Bool == true
    }

    // MARK: - Connection

    private func connect() {
        guard !isConnecting else { return }
        guard let contents = try? String(contentsOf: Self.activePortFile, encoding: .utf8),
              let port = Self.activePort(fileContents: contents),
              let address = URL(string: "ws://127.0.0.1:\(port.port)\(port.path)") else {
            giveUp(Failure.port)
            return
        }
        isConnecting = true
        let socket = URLSession.shared.webSocketTask(with: address)
        self.socket = socket
        socket.resume()
        listen(on: socket)
        Task {
            do {
                _ = try await call("Target.getTargets", timeout: Self.consentTimeout)
                isReady = true
            } catch {
                giveUp(error)
            }
            isConnecting = false
        }
    }

    private func listen(on socket: URLSessionWebSocketTask) {
        Task {
            while true {
                do {
                    deliver(try await socket.receive())
                } catch {
                    if self.socket === socket { giveUp(Failure.closed) }
                    return
                }
            }
        }
    }

    private func deliver(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = object["id"] as? Int, let reply = replies.removeValue(forKey: id) else { return }
        reply.resume(returning: data)
    }

    private func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil,
                      timeout: TimeInterval = replyTimeout) async throws -> [String: Any] {
        guard let socket else { throw Failure.closed }
        nextID += 1
        let id = nextID
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            socket.send(.string(text)) { error in
                guard error != nil else { return }
                Task { await self.expire(id, Failure.closed) }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                expire(id, Failure.timeout)
            }
        }
        guard let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed }
        if let error = reply["error"] as? [String: Any] { throw Failure.reply(error["code"] as? Int ?? 0) }
        return reply["result"] as? [String: Any] ?? [:]
    }

    private func expire(_ id: Int, _ failure: Failure) {
        replies.removeValue(forKey: id)?.resume(throwing: failure)
    }

    private func giveUp(_ error: Error) {
        logLine("chrome devtools unavailable reason=\(error)")
        unavailableUntil = Date().addingTimeInterval(Self.unavailableRetry)
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isReady = false
        page = nil
        for reply in replies.values { reply.resume(throwing: Failure.closed) }
        replies = [:]
    }

    private nonisolated static func globalFrame(of row: [String: Any], webAreaFrame: CGRect?, scale: CGFloat) -> CGRect? {
        guard let area = webAreaFrame, let x = row["x"] as? Double, let y = row["y"] as? Double,
              let width = row["w"] as? Double, let height = row["h"] as? Double else { return nil }
        return CGRect(x: area.minX + x * scale, y: area.minY + y * scale, width: width * scale, height: height * scale)
    }

    // Runs in the isolated world. Rows line up with `__jay[generation]`, so a row's index is what press and
    // focus take. A field's name never comes from its contents: what the user typed stays on the page.
    private static func collector(generation: Int) -> String { """
    (() => {
      const limit = \(ScreenElements.windowLimit), generation = \(generation), kept = \(keptCollections);
      const selector = 'a[href], button, summary, input, textarea, select, [contenteditable=""], [contenteditable="true"], '
        + '[role=button], [role=link], [role=tab], [role=menuitem], [role=checkbox], [role=radio], [role=option]';
      const places = [['dialog, [role=dialog]', 'a dialog'], ['[role=tablist]', 'the tabs'], ['nav', 'the navigation'],
        ['aside', 'the sidebar'], ['header', 'the header'], ['footer', 'the footer'], ['form', 'a form']];
      const buttonTypes = ['button', 'submit', 'reset', 'image'];
      const clean = (text) => (text || '').replace(/\\s+/g, ' ').trim().slice(0, 80);
      const isField = (node) => node.tagName === 'TEXTAREA' || node.isContentEditable
        || (node.tagName === 'INPUT' && !buttonTypes.concat(['checkbox', 'radio', 'range', 'color', 'file']).includes(node.type));
      const roleOf = (node) => {
        const explicit = node.getAttribute('role');
        if (explicit) return explicit;
        const tag = node.tagName;
        if (tag === 'A') return 'link';
        if (tag === 'SELECT') return 'combobox';
        if (tag === 'INPUT') {
          if (buttonTypes.includes(node.type)) return 'button';
          if (node.type === 'checkbox' || node.type === 'radio') return node.type;
          return node.type === 'search' ? 'searchbox' : 'textbox';
        }
        return isField(node) ? 'textbox' : 'button';
      };
      const nameOf = (node) => {
        const labelledBy = (node.getAttribute('aria-labelledby') || '').split(' ')
          .map((id) => (document.getElementById(id) || {}).innerText).join(' ');
        const own = clean(node.getAttribute('aria-label')) || clean(labelledBy)
          || clean(node.labels && node.labels[0] && node.labels[0].innerText)
          || clean(node.getAttribute('placeholder')) || clean(node.getAttribute('title'));
        if (own || isField(node)) return own || clean(node.getAttribute('name'));
        const image = node.querySelector('img[alt]');
        return clean(node.innerText) || clean(image && image.alt)
          || (node.tagName === 'INPUT' ? clean(node.value) : '');
      };
      const placeOf = (node) => {
        for (const [match, name] of places) {
          const area = node.closest(match);
          if (!area) continue;
          const label = clean(area.getAttribute('aria-label'));
          return label ? `${name} "${label}"` : name;
        }
        return 'the page';
      };
      const found = [], rows = [];
      for (const node of document.querySelectorAll(selector)) {
        if (rows.length >= limit) break;
        if (node.matches('input[type=password], input[type=hidden]') || node.disabled) continue;
        if (node.getAttribute('aria-disabled') === 'true' || (node.parentElement && node.parentElement.closest(selector))) continue;
        if (!node.checkVisibility({ visibilityProperty: true, opacityProperty: true })) continue;
        const box = node.getBoundingClientRect();
        if (box.width <= 0 || box.height <= 0 || box.bottom < 0 || box.right < 0 || box.top > innerHeight || box.left > innerWidth) continue;
        const name = nameOf(node);
        if (!name) continue;
        const title = clean(node.getAttribute('title'));
        const current = node.getAttribute('aria-current');
        found.push(node);
        rows.push({
          name, role: roleOf(node), kind: isField(node) ? 'field' : 'press', place: placeOf(node),
          help: title && title !== name ? title : clean(node.getAttribute('aria-description')),
          risk: isField(node) ? '' : [node.innerText, node.tagName === 'INPUT' ? node.value : '', node.getAttribute('aria-label'), title]
            .map(clean).join(' '),
          x: box.left, y: box.top, w: box.width, h: box.height,
          expanded: node.getAttribute('aria-expanded'),
          selected: node.getAttribute('aria-selected') === 'true' || node.getAttribute('aria-pressed') === 'true'
            || (current !== null && current !== 'false') || node.checked === true,
        });
      }
      const runs = window.__jay || (window.__jay = {});
      runs[generation] = found;
      for (const key of Object.keys(runs)) if (Number(key) <= generation - kept) delete runs[key];
      return { vw: innerWidth, rows, isFront: document.visibilityState === 'visible' && document.hasFocus() };
    })()
    """ }
}

// Chrome's bookmarks, read from its profile file on each command: "go to bluejay docs" opens the saved
// page rather than a web search, from any app. Only the names a command says are ever offered to Jev.
enum ChromeBookmarks {
    struct Bookmark: Equatable {
        let name: String
        let url: URL
    }

    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")

    static func all() -> [Bookmark] {
        guard let data = try? Data(contentsOf: fileURL),
              let roots = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["roots"] as? [String: Any]
        else { return [] }
        return roots.keys.sorted().flatMap { bookmarks(in: roots[$0]) }
    }

    static func bookmarks(in node: Any?) -> [Bookmark] {
        guard let node = node as? [String: Any] else { return [] }
        if node["type"] as? String == "url" {
            guard let name = node["name"] as? String, let url = (node["url"] as? String).flatMap(URL.init(string:)) else { return [] }
            return [Bookmark(name: name, url: url)]
        }
        return (node["children"] as? [Any] ?? []).flatMap(bookmarks(in:))
    }
}
