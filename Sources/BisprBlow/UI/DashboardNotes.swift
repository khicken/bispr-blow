import AppKit
import SwiftUI

// MARK: - Notes

// Call notes from the pill's Notes button, newest first, read straight from the files NoteTaker
// writes (the same ones bluejay_callpr watches). A note opens as a transcript grouped by speaker.
struct NotesView: View {
    struct Line { let you: Bool; let text: String }
    struct Note: Identifiable {
        let id: String
        let date: Date
        let lines: [Line]
        let seconds: Int
        var title: String { "Call on " + date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }
        var speakers: Int { Set(lines.map(\.you)).count }
        var duration: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
        var transcript: String { lines.map { "\($0.you ? "You" : "Them"): \($0.text)" }.joined(separator: "\n") }
        // Consecutive lines from one side read as one speaker's turn.
        var turns: [(you: Bool, texts: [String])] {
            lines.reduce(into: []) { turns, line in
                if turns.last?.you == line.you { turns[turns.count - 1].texts.append(line.text) } else { turns.append((line.you, [line.text])) }
            }
        }
    }

    @State private var notes: [Note] = []
    @State private var open: String?

    var body: some View {
        Group {
            if let note = notes.first(where: { $0.id == open }) {
                TranscriptView(note: note) { open = nil }
            } else {
                Page(title: "Notes") {
                    if notes.isEmpty {
                        EmptyHint(text: "No notes yet. Click the record button on the bar during a call.")
                    } else {
                        VStack(spacing: 6) { ForEach(notes) { note in NoteRow(note: note) { open = note.id } } }
                    }
                }
            }
        }
        .onAppear { notes = Self.load() }
        .onReceive(NotificationCenter.default.publisher(for: .notesSaved)) { _ in notes = Self.load() }
    }

    static func load() -> [Note] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: NoteTaker.root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir -> Note? in
            guard let text = try? String(contentsOf: dir.appendingPathComponent("live.ndjson"), encoding: .utf8) else { return nil }
            let rows = text.split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }.sorted { ($0["startEpochMs"] as? Int ?? 0) < ($1["startEpochMs"] as? Int ?? 0) }
            let lines = rows.compactMap { row -> Line? in
                guard let text = row["text"] as? String else { return nil }
                return Line(you: (row["speaker"] as? [String: Any])?["source"] as? String == "mic", text: text)
            }
            let span = (rows.last?["startEpochMs"] as? Int ?? 0) - (rows.first?["startEpochMs"] as? Int ?? 0)
            let date = (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Note(id: dir.lastPathComponent, date: date, lines: lines, seconds: max(span / 1000, 0))
        }.sorted { $0.date > $1.date }
    }
}

private struct NoteRow: View {
    let note: NotesView.Note
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.bj(14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(note.lines.first?.text ?? "Nothing was heard.")
                    .font(.bj(12.5)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
            Spacer()
            Text("\(note.speakers) \(note.speakers == 1 ? "speaker" : "speakers") · \(note.duration)")
                .font(.bj(11, weight: .medium)).foregroundStyle(Theme.inkSubtle)
        }
        .card(padding: 13)
        .contentShape(Rectangle())
        .handCursor()
        .onTapGesture(perform: open)
    }
}

// Speaker name above a stack of bubbles, one bubble per spoken segment.
private struct TranscriptView: View {
    let note: NotesView.Note
    let back: () -> Void
    @State private var copied = false
    private static let orange = Color(red: 0.89, green: 0.58, blue: 0.2)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: back) {
                    Image(systemName: "chevron.left").font(.bj(12, weight: .semibold))
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.tableHeader))
                }
                .buttonStyle(.plain).handCursor()
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.title).font(.bj(30, weight: .bold)).tracking(-0.6).foregroundStyle(Theme.ink)
                    Text(note.date.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.bj(12)).foregroundStyle(Theme.inkTertiary)
                }
                Text("Transcript").font(.bj(13, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.bottom, 4)
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.ink).frame(height: 2) }
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.bj(12))
                    Text("\(note.speakers) \(note.speakers == 1 ? "SPEAKER" : "SPEAKERS") · \(note.duration)")
                        .font(.bj(12, weight: .medium)).tracking(0.6)
                    Spacer()
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.bj(13))
                        .handCursor()
                        .onTapGesture {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(note.transcript, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                }
                .foregroundStyle(Theme.inkTertiary)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tableHeader))
                if note.lines.isEmpty {
                    Text("Nothing was heard.").font(.bj(13)).foregroundStyle(Theme.inkSubtle)
                }
                ForEach(Array(note.turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(turn.you ? "You" : "Them").font(.bj(13, weight: .medium))
                            .foregroundStyle(turn.you ? Self.orange : Theme.green)
                        ForEach(Array(turn.texts.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.bj(14)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.tableHeader))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

extension Notification.Name {
    static let notesSaved = Notification.Name("BisprBlowNotesSaved")
}
