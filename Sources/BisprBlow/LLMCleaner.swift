import Foundation

// Cleans raw dictation via a local LLM, with a deterministic rule-based fallback so dictation
// always produces output even with no model available.
final class LLMCleaner {
    struct Endpoint {
        // Empty baseURL means in-process inference rather than HTTP. Only `complete` cares;
        // prompts, guards, deadline and bench are transport-independent.
        let baseURL: String
        let name: String

        var isInProcess: Bool { baseURL.isEmpty }
    }

    // onDevice leads on a bench run, not on the integration existing: the same MLX weights read
    // 96%/85% recall/quality at 0.19s median over 26 cases, against LM Studio's 96%/85% at 0.33s.
    // The HTTP entry is an escape hatch for any OpenAI-compatible server; nothing starts one.
    static let onDevice = Endpoint(baseURL: "", name: "On-device")
    static let localServer = Endpoint(baseURL: "http://localhost:1234/v1", name: "Local server")
    private static let endpoints = [onDevice, localServer]

    private let settings: AppSettings
    // Resolved once per launch, re-resolved when the mode changes or the endpoint fails.
    private var resolved: (endpoint: Endpoint, model: String, cleanup: AppSettings.Cleanup)?

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    // Fast/Accurate has to take effect on the next dictation: the modes resolve to different models.
    private var resolutionIsStale: Bool {
        guard let resolved else { return false }
        return resolved.cleanup != settings.cleanup
    }

    // Logged, so a silently-swapped model or a fall back to rules is visible rather than just slow.
    var activeDescription: String {
        guard let resolved else { return "Rule-based (no local model reachable)" }
        return "\(resolved.cleanup.rawValue) · \(resolved.endpoint.name) · \(resolved.model)"
    }

    // Returns (cleaned text, provider). Never throws — falls back to rules. Casing is applied out
    // here because all six exits of `cleaned` end at the cursor.
    func clean(_ raw: String, context: AppContext) async -> (text: String, provider: String) {
        let result = await cleaned(raw, context: context)
        var text = Self.applyVocabulary(result.text, vocabulary: settings.vocabulary)
        if settings.lowercaseSentences {
            text = Self.lowercaseSentenceStarts(text, keeping: settings.vocabulary)
        }
        if !settings.endWithPeriod {
            text = Self.droppingTrailingPeriod(text)
        }
        return (text, result.provider)
    }

    private func cleaned(_ raw: String, context: AppContext) async -> (text: String, provider: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "none") }

        // At or below 8 words the model never runs: it is measurably worse than the rules there, and
        // the way it is worse is what users report as "it cuts off my words". Measured over 100 real
        // dictations (45 of them this short) on qwen3-0.6b: model and rules agree on 33 of 45, and of
        // the 12 disagreements the model loses content in 8 and improves 2. A skip rather than another
        // guard because none can fire here — looksTruncated's short branch allows a 50% drop above 3
        // words, and losesContent/dropsTail are floored at 12 content words. Re-derive from
        // history.json, not by feel. `applyVocabulary` runs in `clean`, so respelling still happens.
        if trimmed.split(whereSeparator: \.isWhitespace).count <= Self.verbatimWords {
            return (Self.ruleClean(trimmed), "rules")
        }

        if resolutionIsStale { resolved = nil }
        if resolved == nil {
            resolved = await resolveEndpoint()
        }
        guard let (endpoint, model, _) = resolved else {
            return (Self.ruleClean(trimmed), "rules")
        }

        // Coding gets the low-touch prompt: prose polish buys nothing and a reworded identifier costs
        // everything.
        let lowTouch = context.category == .coding
        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        let deadline = Self.deadlineMs(words: words, careful: settings.cleanup == .accurate)

        switch await attempt(endpoint: endpoint, model: model, trimmed: trimmed,
                             context: context, lowTouch: lowTouch, deadline: deadline) {
        case .ok(let text):
            return (text, endpoint.name)
        case .deadline:
            // Not an endpoint failure, so `resolved` stands — the model is there, it was just slow. No
            // escalation either: a bigger model is slower, and slow was the problem.
            logLine("cleanup exceeded \(deadline)ms; using rules")
            return (Self.ruleClean(trimmed), "rules")
        case .failed(let error):
            logLine("LLM cleanup failed (\(error)); using rule-based fallback")
            resolved = nil
            return (Self.ruleClean(trimmed), "rules")
        case .rejected:
            // A guard refused: the dictation was too disfluent for the fast model, and rules would ship
            // barely-cleaned text. One retry on the careful model — the bench says it pays.
            guard settings.cleanup == .fast,
                  let careful = await firstModel(at: endpoint, for: .accurate),
                  careful != model else {
                return (Self.ruleClean(trimmed), "rules")
            }
            logLine("cleanup escalating to \(careful)")
            // Careful budget plus a cold-load allowance: LocalEngine holds one resident model, so
            // escalating swaps it out and pays that model's load plus a full prefill.
            let outcome = await attempt(endpoint: endpoint, model: careful, trimmed: trimmed,
                                        context: context, lowTouch: lowTouch,
                                        deadline: Self.deadlineMs(words: words, careful: true) + 6000)
            // Re-warm: the escalation just swapped the fast model out, and without this the next
            // ordinary dictation pays the reload and misses its deadline.
            Task { await self.warmUp() }
            switch outcome {
            case .ok(let text):
                logLine("escalation cleaned it")
                return (text, endpoint.name)
            case .rejected:
                logLine("escalation rejected too; using rules")
            case .deadline:
                logLine("escalation exceeded its deadline; using rules")
            case .failed(let error):
                logLine("escalation failed (\(error)); using rules")
            }
            return (Self.ruleClean(trimmed), "rules")
        }
    }

    private enum AttemptOutcome {
        case ok(String)
        // A guard refused the output. Unlike `deadline` and `failed`, a stronger model may pass.
        case rejected
        case deadline
        case failed(Error)
    }

    // One model's shot at the transcript: complete, sanitize, and run every guard.
    private func attempt(endpoint: Endpoint, model: String, trimmed: String, context: AppContext,
                         lowTouch: Bool, deadline: UInt64) async -> AttemptOutcome {
        do {
            var messages = Self.staticPrefix(vocabulary: settings.vocabulary, lowTouch: lowTouch)
            messages.append(["role": "user", "content": Self.userMessage(context: context, transcript: trimmed)])
            let cleaned = try await Self.beforeDeadline(ms: deadline) {
                try await self.complete(endpoint: endpoint, model: model, messages: messages)
            }
            // Empty output falls back to rule-cleaned text, not the bare transcript.
            let result = Self.sanitize(cleaned, fallback: Self.ruleClean(trimmed))
            if let why = Self.rejection(result, raw: trimmed, lowTouch: lowTouch,
                                        allowed: Self.allowedTerms(vocabulary: settings.vocabulary,
                                                                   draftTerms: context.draftTerms)) {
                logLine("cleanup \(why.rawValue) (\(result.count) of \(trimmed.count) chars)")
                return .rejected
            }
            // Whatever fillers the model left in, take out deterministically.
            return .ok(Self.stripFillers(result))
        } catch is DeadlineExceeded {
            return .deadline
        } catch {
            return .failed(error)
        }
    }

    private struct DeadlineExceeded: Error {}

    // The `/no_think` switch, on its own LINE at the end of the last user message. Internal so
    // `--self-check` can assert the placement; see `complete` for the measurements.
    static func withThinkingOff(_ messages: [[String: String]], model: String) -> [[String: String]] {
        guard model.lowercased().contains("qwen3"),
              let last = messages.indices.last, messages[last]["role"] == "user"
        else { return messages }
        var messages = messages
        messages[last]["content"] = (messages[last]["content"] ?? "") + "\n/no_think"
        return messages
    }

    // Cleanup's share of the latency budget; missing it ships ruleClean, so the budget is a guarantee
    // rather than an average. It scales with the transcript because a flat one is wrong both ways:
    // on qwen3-0.6b twelve words clean in 0.20s and 240 words in 1.51s, so a flat 450ms sent every
    // long dictation to the rules path. Fast's base is 900ms and not 400 because real cleanup runs
    // 280-729ms — a 400ms floor sat inside that spread and coin-flipped, four misses in five minutes
    // by 14-47ms each. Accurate carries the same headroom over a model several times the size
    // (qwen3-4b-2507 ~0.6s warm vs qwen3-0.6b ~0.2s), so both bases move together. The caps are
    // backstops for a pathological transcript, not tuned numbers.

    // At or below this many spoken words the model is skipped; see the comment in `cleaned`.
    static let verbatimWords = 8

    static func deadlineMs(words: Int, careful: Bool = false) -> UInt64 {
        careful
            ? min(6000, 2000 + 15 * UInt64(max(0, words)))
            : min(2500, 900 + 6 * UInt64(max(0, words)))
    }

    // Races `body` against the deadline, cancelling the loser rather than leaving it running.
    private static func beforeDeadline<T>(ms: UInt64,
                                          _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: ms * 1_000_000)
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // Resolves the endpoint and fires a tiny completion so the model loads and both prompt prefixes
    // enter the KV cache at launch instead of on the first dictation.
    func warmUp() async {
        // Build the English word list now rather than inside the first dictation's deadline.
        _ = Self.englishWords
        if resolutionIsStale { resolved = nil }
        if resolved == nil { resolved = await resolveEndpoint() }
        guard let (endpoint, model, _) = resolved else { return }
        // No deadline here: this call is the one that loads the model. Only the resolved model —
        // LocalEngine holds ONE resident model, so warming the careful one would swap it back out and
        // hand the first real dictation a cold load. It also keeps ONE cached prompt sequence, so of
        // these two warms only the last survives: lowTouch goes last because coding is the dominant
        // context and a category switch costs only a prefix re-prefill (~0.3-0.9s), not a model load.
        for lowTouch in [false, true] {
            var messages = Self.staticPrefix(vocabulary: settings.vocabulary, lowTouch: lowTouch)
            messages.append(["role": "user", "content": "App: Notes (general)\nTranscript: ok"])
            _ = try? await complete(endpoint: endpoint, model: model, messages: messages)
        }
        logLine("warmed up \(endpoint.name) / \(model)")
    }

    // MARK: - Endpoint resolution

    private func resolveEndpoint() async -> (Endpoint, String, AppSettings.Cleanup)? {
        let mode = settings.cleanup
        for endpoint in Self.endpoints {
            if let model = await firstModel(at: endpoint, for: mode) { return (endpoint, model, mode) }
        }
        return nil
    }

    private func models(at endpoint: Endpoint) async -> [String]? {
        if endpoint.isInProcess {
            let installed = LocalEngine.installedModels().map(\.id)
            return installed.isEmpty ? nil : installed
        }
        guard let url = URL(string: endpoint.baseURL + "/models") else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 2)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["id"] as? String }
    }

    // Auto-pick an instruct chat model sized by the mode. With the deadline, this is the whole
    // mechanical content of Fast vs Accurate.
    private func firstModel(at endpoint: Endpoint, for mode: AppSettings.Cleanup) async -> String? {
        guard let ids = await models(at: endpoint) else { return nil }
        return Self.pick(from: ids, for: mode)
    }

    // Shared with `accurateNeedsModel` so what is offered to download and what would resolve cannot
    // drift apart.
    static func pick(from ids: [String], for mode: AppSettings.Cleanup) -> String? {
        let chatIDs = ids.filter {
            let id = $0.lowercased()
            // Reasoning variants burn seconds thinking before every dictation. Small models stay
            // eligible — looksTruncated() catches the ones that summarize instead of cleaning.
            return !id.contains("embed") && !id.contains("whisper")
                && !id.contains("thinking") && !id.contains("reason") && !id.contains("-r1")
        }
        for family in mode == .fast ? Self.smallFamilies + Self.carefulFamilies : Self.carefulFamilies {
            if let match = chatIDs.first(where: { $0.lowercased().contains(family) }) { return match }
        }
        return chatIDs.first
    }

    // Accurate is on screen with nothing behind it: it would land on the model Fast already uses.
    // Not a crash — `pick` falls through — which is the invisible failure this makes visible.
    static var accurateNeedsModel: Bool {
        let ids = LocalEngine.installedModels().map(\.id)
        return !ids.isEmpty && pick(from: ids, for: .accurate) == pick(from: ids, for: .fast)
    }

    // Fast, smallest first. qwen3-0.6b (bench/results.md): 0.38s median, 0/25 over budget, paid for
    // by rewording long agent-prompt cases often enough that the low-touch guard fires.
    private static let smallFamilies = ["qwen3-0.6b", "qwen3-1.7b", "llama-3.2-1b", "gemma-3-1b"]

    // Accurate, and Fast's fallback when the machine has no small model. qwen3-4b-2507 ≈ 0.6s warm
    // and matches gpt-oss-20b (~2-3s) on quality, so it leads. Every size that matters is named
    // BEFORE the family containing it: a generic "qwen" matches the 0.6b, which silently collapses
    // Accurate onto Fast. Qwen3.5's DeltaNet runs ~14x slower on llama.cpp Metal.
    private static let carefulFamilies =
        ["qwen3-4b-2507", "qwen3-4b", "gpt-oss", "ministral", "qwen3-1.7b",
         "qwen", "llama", "mistral", "gemma"]

    // Dictionary terms for a topic (e.g. "Kubernetes and cloud infra"). [] if no provider is reachable.
    func generateTerms(topic: String) async -> [String] {
        if resolved == nil { resolved = await resolveEndpoint() }
        guard let (endpoint, model, _) = resolved else { return [] }
        let messages: [[String: String]] = [
            ["role": "system", "content": "You output vocabulary lists for a dictation app's custom dictionary. Respond with ONLY a comma-separated list of terms — product names, tools, jargon, acronyms — with their canonical spelling and capitalization. No explanations, no numbering."],
            ["role": "user", "content": "List 30 technical terms, product names, and jargon someone would say while working with: \(topic)"],
        ]
        guard let output = try? await complete(endpoint: endpoint, model: model, messages: messages) else {
            resolved = nil
            return []
        }
        let cleaned = Self.sanitize(output, fallback: "")
        var seen = Set<String>()
        return cleaned
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert($0.lowercased()).inserted }
    }

    // MARK: - Chat call

    private func complete(endpoint: Endpoint, model: String, messages: [[String: String]]) async throws -> String {
        // Qwen3 is a hybrid reasoner and the MLX runtimes ignore reasoning_effort and
        // chat_template_kwargs. Measured on qwen3-0.6b: without /no_think it burns ~1400 reasoning
        // tokens and 8s per dictation; with it, 1 token and 0.2s. Last message only, so the cached
        // prefix survives.
        //
        // On its OWN LINE, and that is not cosmetic: appended with a space it lands inside
        // "Transcript: <words>", and the low-touch path copies every spoken word out. Measured over 15
        // short terminal dictations: 10 of 15 wrong glued, 0 of 15 on its own line, same latency
        // (134ms vs 141ms). Adding a coding demonstration does not fix it (9 of 15 still bad).
        // Applied before the transport split, so both transports send the same prompt.
        let messages = Self.withThinkingOff(messages, model: model)

        if endpoint.isInProcess {
            return try await LocalEngine.shared.complete(id: model, messages: messages)
        }

        guard let url = URL(string: endpoint.baseURL + "/chat/completions") else {
            throw URLError(.badURL)
        }
        // Generous timeout: LM Studio JIT-loads big models on the first call (~20s cold).
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Ignored by the MLX runtimes, honoured by the ones that support them (gpt-oss).
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 2048,
            "messages": messages,
            "reasoning_effort": "low",
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        let content = message["content"] as? String ?? ""
        guard content.isEmpty else { return content }
        // A /no_think turn can emit an empty think block, after which the server files the answer
        // under reasoning_content and leaves content empty (measured on qwen3-1.7b: a perfectly
        // cleaned transcript thrown away). A real reasoning trace is rejected by the length guard.
        return message["reasoning_content"] as? String ?? ""
    }
}
