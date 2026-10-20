import Foundation
import Security

// Jay's commands sent to Raindrop (raindrop.ai) for monitoring: what was said, what Jay did, and how it
// decided. Raindrop has no Swift SDK, so this is its HTTP API. Opt-in, and silent without a write key.
enum Raindrop {
    private static let base = URL(string: "https://api.raindrop.ai/v1/")!
    private static let keychainService = "raindrop-write-key"
    private static let installIDKey = "raindropInstallID"
    private static let attempts = 3

    @MainActor
    static var isOn: Bool { AppSettings.shared.sendJayToRaindrop }

    // The signed-in account, or this Mac's own install id: Raindrop drops events with no user.
    @MainActor
    static var userID: String {
        if let account = CloudClient.shared.session?.userID { return account.uuidString }
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: installIDKey) { return saved }
        let made = UUID().uuidString
        defaults.set(made, forKey: installIDKey)
        return made
    }

    @MainActor
    static func trackCommand(eventID: UUID, conversationID: UUID, said: String, did: String, properties: [String: Any]) {
        guard isOn else { return }
        post("events/track", [[
            "event_id": eventID.uuidString, "user_id": userID, "event": "Jay command",
            "timestamp": timestamp(),
            "ai_data": ["model": Jev.model, "input": said, "output": did, "convo_id": conversationID.uuidString],
            "properties": properties,
        ]])
    }

    @MainActor
    static func signal(_ name: String, on eventID: UUID, isNegative: Bool, properties: [String: Any] = [:]) {
        guard isOn else { return }
        post("signals/track", [[
            "event_id": eventID.uuidString, "signal_name": name, "timestamp": timestamp(),
            "signal_type": "default", "sentiment": isNegative ? "NEGATIVE" : "POSITIVE", "properties": properties,
        ]])
    }

    // One step of a command, for its trace. `parent` is the index of the enclosing span; nil is the command itself.
    struct Span {
        let name: String
        let kind: String
        let start: Date
        let end: Date
        var input: String? = nil
        var output: String? = nil
        var parent: Int? = nil
    }

    // The command's steps as an OTLP trace. Every span carries the event's id, which is how Raindrop
    // hangs the trace on that event (and so on its conversation); it is the attribute Raindrop's own SDKs set.
    @MainActor
    static func trackTrace(eventID: UUID, command: Span, steps: [Span]) {
        guard isOn else { return }
        let traceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanIDs = (0...steps.count).map { _ in String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)) }
        func otlp(_ span: Span, id: String, parent: String?) -> [String: Any] {
            var attributes: [[String: Any]] = [
                attribute("ai.telemetry.metadata.raindrop.eventId", eventID.uuidString),
                attribute("traceloop.span.kind", span.kind),
                attribute("traceloop.entity.name", span.name),
                ["key": "traceloop.entity.duration_ms", "value": ["intValue": String(Int(span.end.timeIntervalSince(span.start) * 1000))]],
            ]
            if let input = span.input { attributes.append(attribute("traceloop.entity.input", input)) }
            if let output = span.output { attributes.append(attribute("traceloop.entity.output", output)) }
            var row: [String: Any] = ["traceId": traceID, "spanId": id, "name": span.name, "kind": 1,
                                      "startTimeUnixNano": nanoseconds(span.start), "endTimeUnixNano": nanoseconds(span.end),
                                      "attributes": attributes]
            if let parent { row["parentSpanId"] = parent }
            return row
        }
        let rows = [otlp(command, id: spanIDs[0], parent: nil)]
            + steps.enumerated().map { index, step in otlp(step, id: spanIDs[index + 1], parent: spanIDs[(step.parent ?? -1) + 1]) }
        post("traces", ["resourceSpans": [["resource": ["attributes": [attribute("service.name", "bisprblow-jay")]],
                                           "scopeSpans": [["scope": ["name": "jay"], "spans": rows]]]]])
    }

    private static func attribute(_ key: String, _ value: String) -> [String: Any] { ["key": key, "value": ["stringValue": value]] }

    private static func nanoseconds(_ date: Date) -> String { String(UInt64(date.timeIntervalSince1970 * 1_000_000_000)) }

    private static func post(_ path: String, _ body: Any) {
        guard let key = writeKey() else {
            logLine("raindrop skipped path=\(path) reason=no write key")
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        // event_id makes a resend harmless, so a dropped connection is retried rather than losing the event.
        Task.detached {
            for attempt in 1...attempts {
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let status = (response as? HTTPURLResponse)?.statusCode {
                    if (200..<300).contains(status) {
                        logLine("raindrop sent path=\(path) status=\(status)")
                        return
                    }
                    logLine("raindrop rejected path=\(path) status=\(status)")
                    if status < 500 { return }
                }
                if attempt < attempts { try? await Task.sleep(for: .seconds(attempt)) }
            }
            logLine("raindrop gave up path=\(path)")
        }
    }

    private static func writeKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timestamp() -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: Date())
    }
}
