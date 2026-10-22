import AppKit
import SQLite3

// What Wispr Flow learned, read from its own database so switching apps does not start the
// dictionary over. Opened read-only: Wispr Flow is never written to.
enum WisprImport {
    static let database = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: database.path) }

    static var appIcon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.wispr-flow")
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    // Wispr Flow's dictionary words, then the one-word fixes in its history; nil when the database
    // cannot be read. Snippets and replacements are skipped because there is nothing here to hold
    // them, and a word Wispr Flow auto-learned but never used again is more often a typo than a name.
    // Most-used first, so that spelling wins when Wispr Flow holds two ("Livekit", "LiveKit").
    static func learnedWords(alongside vocabulary: [String]) -> [String]? {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let words = rows(db, """
                  SELECT phrase FROM Dictionary
                  WHERE isDeleted = 0 AND isSnippet = 0 AND coalesce(replacement, '') = ''
                    AND (coalesce(source, '') != 'user_edits' OR frequencyUsed > 1)
                  ORDER BY frequencyUsed DESC
                  """),
              let history = rows(db, "SELECT formattedText, editedText FROM History WHERE formattedText != ''")
        else { return nil }
        let edits = history.filter { !$0[1].isEmpty }.map { (written: $0[0], edited: $0[1]) }
        let dictations = history.map { $0[1].isEmpty ? $0[0] : $0[1] }
        return LLMCleaner.harmless(words.map { $0[0] } + corrections(in: edits), vocabulary: vocabulary, dictations: dictations)
    }

    // Wispr Flow's history is the same signal `CorrectionWatcher` waits for, after the fact, so it is
    // held to the same bar.
    static func corrections(in edits: [(written: String, edited: String)]) -> [String] {
        edits.compactMap { CorrectionWatcher.substitution(from: $0.written, to: $0.edited) }
            .flatMap(LLMCleaner.learnedWords(from:))
    }

    // Adds the words the dictionary does not already hold, and returns them. A word already known in
    // any casing is left alone, so the import never re-cases something the user settled here.
    static func add(_ words: [String], to settings: AppSettings) -> [String] {
        var known = Set(settings.vocabulary.map { $0.lowercased() })
        let added = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && known.insert($0.lowercased()).inserted }
        settings.addDictionaryWords(added)
        return added
    }

    // Nil unless every row was read: a busy or failing read must not pass for a short dictionary.
    private static func rows(_ db: OpaquePointer?, _ sql: String) -> [[String]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        var rows: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(statement)
        }
        return status == SQLITE_DONE ? rows : nil
    }
}
