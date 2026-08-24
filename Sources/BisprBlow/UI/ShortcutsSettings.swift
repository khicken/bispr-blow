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
    var themeID = Appearance.current
    let action: ShortcutAction
    let bindings: [Shortcut]
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(action.title)
                    .font(.bj(13))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                if bindings.isEmpty {
                    Text("Not set")
                        .font(.bj(12))
                        .foregroundStyle(Theme.inkSubtle)
                } else {
                    ForEach(bindings) { KeyCap(text: $0.display) }
                }
                Image(systemName: "chevron.right")
                    .font(.bj(9, weight: .bold))
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
    var themeID = Appearance.current
    let text: String

    var body: some View {
        Text(text)
            .font(.bj(11.5, weight: .medium))
            .foregroundStyle(Theme.inkSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Theme.field)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.border, lineWidth: 1))
            )
    }
}

/// One row of the editor's list — a bound shortcut, or the row that records a new one. Every
/// row is the same height and the same inset whatever it holds, because the list gains and
/// loses rows as you edit it and the ones that stay should not move when it does.
private struct BindingRow<Content: View>: View {
    var themeID = Appearance.current
    /// Rows that do something on click take the hover fill; a bound shortcut's row does not,
    /// since only its × is clickable.
    var hoverable = false
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(hoverable && hovering ? Theme.surfaceActive.opacity(0.7) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = hoverable && $0 }
            .animation(.bjHover, value: hovering)
    }
}

/// Editor for one action's bindings: remove, record another, reset.
///
/// Fixed size, deliberately. Every part of it grows and shrinks as you use it — the blurb runs
/// one line or three depending on the action, the list gains rows, the recorder swaps a prompt
/// in for the add row — and a sheet that resizes under the pointer moves the button you were
/// reaching for. The list is the one part that can overflow, so it is the one part that scrolls.
struct ShortcutSheet: View {
    var themeID = Appearance.current
    let action: ShortcutAction
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var armed = false
    /// The combination currently under the user's fingers, mid-record.
    @State private var holding: Shortcut?

    private var bindings: [Shortcut] { settings.shortcuts(for: action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.title)
                    .font(.bj(16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(action.blurb)
                    .font(.bj(12))
                    .foregroundStyle(Theme.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // One line of blurb, reserved: every action's is one line now, and pinning it keeps
            // the card below at the same height in all four.
            .frame(height: 40, alignment: .top)

            // The list is the control. Adding lives as its last row rather than as a button below,
            // so there is one place to click to change a binding instead of a dead box plus a
            // button beside it.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(bindings) { shortcut in
                        BindingRow {
                            HStack(spacing: 8) {
                                KeyCap(text: shortcut.display)
                                Spacer(minLength: 8)
                                Button {
                                    settings.remove(shortcut, from: action)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.bj(9, weight: .bold))
                                }
                                .buttonStyle(QuietButtonStyle())
                                .help("Remove this shortcut")
                            }
                        }
                    }
                    if armed {
                        BindingRow {
                            HStack(spacing: 8) {
                                // What is under your fingers right now, drawn in the same cap the
                                // saved binding will use, so recording shows the result rather
                                // than describing it. It lands when you let go.
                                if let holding {
                                    KeyCap(text: holding.display)
                                    Text("release to save")
                                        .font(.bj(12))
                                } else {
                                    // The dot belongs to the waiting state only: it says the app
                                    // is listening for you. Once you are holding keys the cap
                                    // says that already, and a pulsing dot beside it is decoration.
                                    Image(systemName: "record.circle")
                                        .font(.bj(11, weight: .bold))
                                        .symbolEffect(.pulse)
                                    Text("Listening…")
                                        .font(.bj(12, weight: .medium))
                                }
                                Spacer(minLength: 8)
                                Button("Cancel") { disarm() }
                                    .buttonStyle(QuietButtonStyle())
                            }
                            .foregroundStyle(Theme.blue)
                        }
                        .transition(.opacity)
                    } else {
                        Button(action: arm) {
                            BindingRow(hoverable: true) {
                                HStack(spacing: 7) {
                                    Image(systemName: "plus")
                                        .font(.bj(10, weight: .bold))
                                    Text(bindings.isEmpty ? "Record a shortcut" : "Add another")
                                        .font(.bj(12.5))
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(Theme.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .handCursor()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .card(padding: 6)

            // One primary action, bottom right, where every macOS sheet puts it.
            HStack(spacing: 8) {
                // Always present, dimmed when there is nothing to undo. It used to appear only
                // once the bindings differed, which meant the footer gained a control the first
                // time you edited anything — the row you were reading changed shape under you.
                Button("Reset to default") {
                    settings.resetToDefault(action)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(bindings == action.defaults)
                .opacity(bindings == action.defaults ? 0.35 : 1)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(CapsuleButtonStyle())
            }
        }
        .animation(.bjSnap, value: armed)
        .animation(.bjSnap, value: bindings)
        .animation(.bjSnap, value: holding)
        .padding(20)
        .frame(width: 400, height: 300)
        .background(Theme.cream)
        .onDisappear { ShortcutMonitor.shared.endCapture() }
    }

    /// The monitor's own event tap does the capturing: it already sees every key and mouse
    /// button system-wide, and while armed it swallows them so nothing else reacts.
    private func arm() {
        armed = true
        holding = nil
        ShortcutMonitor.shared.beginCapture(preview: { holding = $0 }) { shortcut in
            settings.add(shortcut, to: action)
            armed = false
            holding = nil
        }
    }

    private func disarm() {
        armed = false
        holding = nil
        ShortcutMonitor.shared.endCapture()
    }
}
