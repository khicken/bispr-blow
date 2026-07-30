# Bluejay Wispr

A local dictation app for macOS. Hold fn, speak, release, and cleaned-up text
lands at your cursor. Everything runs on the machine.

Build, install, and relaunch with `./build.sh`. It installs one copy to
/Applications on purpose: two copies means two fn event taps fighting.
Run `.build/release/BluejayWispr --self-check` after touching the cleanup or
dictionary text logic.

## UI rules

The person using this app is dictating, not administering it. Most of them will
open the window once, look at their history, and close it. Design for that.

**Say what a thing does, not how it works.** "Respells mishears: work tree to
worktree" belongs in a tooltip on the toggle. Endpoint names, model ids, and
fallback states are not information a user acts on, so they do not get UI. If
you need them for debugging, log them.

**Advanced always goes last and starts collapsed.** Provider and model live
there. Anything a normal user never touches goes there too. It is the final
section on the page, never the first, and it never gets a topic-specific header
like "AI cleanup" wrapped around it.

**One control per job.** A field that accepts a list does not need a separate
Bulk Add button. A row that can be clicked does not need a copy icon. Before
adding a second control, check whether the first one can absorb it.

**Whole rows are the hit target.** History rows copy on click across the entire
card, not just on an icon. Sidebar items are clickable across the full width.
Use `.contentShape(Rectangle())` so the padding counts.

**Everything clickable gets `handCursor()`.** It is in Theme.swift. Do not
reach for `pointerStyle` (no-ops inside NSHostingView) or `NSCursor.set()` in
an onHover (flickers on every redraw, because the window owns cursor updates).
The modifier installs a real AppKit cursor rect.

**Align to the columns that already exist.** Nav icons sit 18pt from the
sidebar edge and their labels start at 45pt. The wordmark uses the same two
numbers. When something feels off, measure it before restyling it.

**Motion comes from Theme.** Use `.bjSnap` for state changes, `.bjSoft` for
transitions and reveals, `.bjHover` for hover. `appearIn(delay:)` staggers
content in. Do not invent new spring constants per view.

**Animate the thing that changed, nothing else.** A symbolEffect keyed on
`selected` fires on the row you left as well as the one you clicked. Key it on
a counter you bump only in the direction you care about.

**Brand color is an accent, not a surface.** Blue for the selected nav row, the
mic glyph, links. Text stays ink. Do not put gradients on the logo or the
wordmark, and do not bake shadows into the app icon since macOS draws its own.

**Reach for the plainest control that works.** SwiftUI has sharp edges on
macOS: `DisclosureGroup` with a custom label has almost no hit target, so a
Button plus a rotating chevron beats it. When a native control misbehaves, drop
to AppKit rather than layering workarounds.

## Cleanup rules

Losing the user's words is the worst outcome, worse than leaving fillers in.
`looksTruncated` rejects any cleanup that elides content (an ellipsis anywhere,
or under 55% of the transcript length) and falls back to rule-based cleaning of
the full text. Add a case to SelfCheck.swift whenever a new failure shows up.

Qwen3 models are hybrid reasoners and LM Studio's MLX runtime ignores both
`reasoning_effort` and `chat_template_kwargs`. The `/no_think` switch on the
last user message is what actually works: 8s and 1400 reasoning tokens becomes
0.2s and 1. Append per-dictation content to the last message only so the
server's cached prompt prefix survives.

Cross-platform note: SpeechAnalyzer, Foundation Models, and SwiftUI are all
Apple-only. Anything aimed at Windows or Linux needs llama.cpp and either
whisper.cpp or sherpa-onnx instead.
