import Foundation
import Security

// TypeSafe System One: one request asks several questions at once, and every answer is a choice
// among options we wrote, a yes probability, or a score. Nothing in a reply is free text.
enum Jev {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-1.13.0"
    static let requestTimeout: TimeInterval = 3
    // TypeSafe rejects a choice question with more options than this.
    static let maxChoices = 255
    private static let keychainService = "typesafe-api-key"

    enum QuestionType: String { case choice, noul, score }

    struct Question {
        let name: String
        let type: QuestionType
        let instructions: String
        let criteria: [(key: String, value: String?)]
    }

    struct Answer: Sendable {
        let choice: String?
        let confidence: Double?
        let probabilities: [String: Double]
        let yes: Double?
    }

    enum Failure: Error { case noKey, keyRejected, badReply }

    // A request's own timeout only bounds the gaps between packets; this caps the whole exchange.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(configuration: configuration)
    }()

    static func ask(state: [(key: String, value: String)], questions: [Question]) async throws -> [String: Answer] {
        guard let key = apiKey() else { throw Failure.noKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(state: state, questions: questions)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 || status == 403 { throw Failure.keyRejected }
        guard status == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = reply["answers"] as? [String: Any]
        else { throw Failure.badReply }
        return answers.compactMapValues { ($0 as? [String: Any]).map(answer(from:)) }
    }

    // Set with `security add-generic-password -a "$USER" -s typesafe-api-key -w`; never in defaults
    // or the repo, and never logged.
    static func apiKey() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A noul reply is `{"type":"noul","noul":0.71}`, measured against the live API.
    private static func answer(from reply: [String: Any]) -> Answer {
        let probabilities = (reply["probabilities"] as? [String: Any])?.compactMapValues { ($0 as? NSNumber)?.doubleValue } ?? [:]
        let yes = (reply["noul"] as? NSNumber ?? reply["probability"] as? NSNumber)?.doubleValue ?? probabilities["yes"]
        return Answer(choice: reply["choice"] as? String, confidence: (reply["confidence"] as? NSNumber)?.doubleValue,
                      probabilities: probabilities, yes: yes)
    }

    // Written by hand because a Swift Dictionary's key order changes per process, and Jev leans
    // toward the first option: the order we choose has to be the order it reads.
    static func body(state: [(key: String, value: String)], questions: [Question]) -> Data {
        let stateJSON = object(state.map { ($0.key, string($0.value)) })
        let questionsJSON = object(questions.map { question in
            var fields = [("type", string(question.type.rawValue)), ("instructions", string(question.instructions))]
            // A noul question takes no options; a choice question without them is rejected.
            if question.type != .noul || !question.criteria.isEmpty {
                fields.append(("criteria", object(question.criteria.map { ($0.key, $0.value.map(string) ?? "null") })))
            }
            return (question.name, object(fields))
        })
        let json = object([("model", string(model)), ("state", stateJSON), ("questions", questionsJSON)])
        return Data(json.utf8)
    }

    private static func object(_ fields: [(String, String)]) -> String {
        "{" + fields.map { string($0.0) + ":" + $0.1 }.joined(separator: ",") + "}"
    }

    private static func string(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
