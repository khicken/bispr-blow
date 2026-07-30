import SwiftUI

/// The Shortcuts section of Settings: one row per action, whole row opens the editor.
/// The editor is a sheet rather than inline because recording a binding takes over the
/// keyboard, and a modal is the honest way to say so.
struct ShortcutRows: View {
    @ObservedObject var settings: AppSettings
    @State private var editing: ShortcutAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ShortcutAction.allCases) { action in
                ShortcutRow(action: action, bindings: settings.shortcuts(for: action)) {
                    editing = action
                }
            }
        }
        // Cancels the row's own inset so the hover fill reaches the card's edges.
        .padding(.horizontal, -6)
        .sheet(item: $editing) { action in
            ShortcutSheet(action: action, settings: settings)
        }
    }
}

/// One action. The whole row is the hit target, per the UI rules.
private struct ShortcutRow: View {
    let action: ShortcutAction
    let bindings: [Shortcut]
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                if bindings.isEmpty {
                    Text("Not set")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkSubtle)
                } else {
                    ForEach(bindings) { KeyCap(text: $0.display) }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.inkSubtle)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hovering ? Theme.surfaceActive.opacity(0.7) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.bjHover, value: hovering)
    }
}

/// A single keyboard cap: "fn", "⌃⌥D", "Mouse 4".
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
            )
    }
}

/// Editor for one action's bindings: remove, record another, reset.
struct ShortcutSheet: View {
    let action: ShortcutAction
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var armed = false

    private var bindings: [Shortcut] { settings.shortcuts(for: action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(action.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(action.blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.inkTertiary)
            }

            // The list is the control. Adding lives as its last row rather than as a button below,
            // so there is one place to click to change a binding instead of a dead box plus a
            // button beside it.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bindings) { shortcut in
                    HStack(spacing: 8) {
                        KeyCap(text: shortcut.display)
                        Spacer()
                        Button {
                            settings.remove(shortcut, from: action)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(QuietButtonStyle())
                        .help("Remove this shortcut")
                    }
                }
                if !bindings.isEmpty { Divider().opacity(0.5) }
                if armed {
                    HStack(spacing: 10) {
                        Text("Press any key, combination, or mouse button…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.blue)
                        Spacer()
                        Button("Cancel") { disarm() }
                            .buttonStyle(QuietButtonStyle())
                    }
                    .padding(.vertical, 4)
                    .transition(.opacity)
                } else {
                    Button(action: arm) {
                        HStack(spacing: 7) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text(bindings.isEmpty ? "Record a shortcut" : "Add another")
                                .font(.system(size: 12.5))
                            Spacer()
                        }
                        .foregroundStyle(Theme.blue)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .handCursor()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 12)

            // One primary action, bottom right, where every macOS sheet puts it.
            HStack(spacing: 8) {
                if bindings != action.defaults {
                    Button("Reset to default") {
                        settings.resetToDefault(action)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
        .animation(.bjSnap, value: armed)
        .animation(.bjSnap, value: bindings)
        .padding(22)
        .frame(width: 400)
        .background(Theme.cream)
        .onDisappear { ShortcutMonitor.shared.endCapture() }
    }

    /// The monitor's own event tap does the capturing: it already sees every key and mouse
    /// button system-wide, and while armed it swallows them so nothing else reacts.
    private func arm() {
        armed = true
        ShortcutMonitor.shared.beginCapture { shortcut in
            settings.add(shortcut, to: action)
            armed = false
        }
    }

    private func disarm() {
        armed = false
        ShortcutMonitor.shared.endCapture()
    }
}
