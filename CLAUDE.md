# Bluejay Wispr

A local dictation app for macOS. Hold your shortcut, speak, release, and
cleaned-up text lands at your cursor. Everything runs on the machine.

Shortcuts are configurable per action — push to talk, hands-free, dictate and
send, cancel — bound to a key plus modifiers or to a mouse button, and stored in
`AppSettings.bindings`. fn is the shipped default for push to talk and Esc for
cancel, so "hold fn" is a default rather than the mechanic. Never write user
copy that names fn; read `AppSettings.holdPhrase` or `holdHint` instead.

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

**Advanced goes last, as an ordinary section.** Provider and model live there,
along with anything a normal user never touches. It is the final section on the
page, never the first, and it never gets a topic-specific header like "AI
cleanup" wrapped around it. It used to start collapsed; it does not any more.
Three rows behind a disclosure nobody else on the page had cost a click and read
as a different kind of control, when the point was only "you can ignore this".
Order is what says a section is secondary. Nothing in this app collapses.

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
or under 55% of the transcript) and falls back to rule-based cleaning of the full
text. Add a case to SelfCheck.swift whenever a new failure shows up.

That 55% is measured against the transcript with its fillers **already removed**,
not the raw one. Measuring against the raw count builds in a bias exactly as large
as the share of the transcript that was filler, so the more disfluent the speech,
the likelier a correct cleanup is thrown away — backwards. It cost us a real one:
"um um so uh uh i think we should just ship it um today and see what breaks" came
back correctly cleaned in nine words and was discarded, because 55% of the raw
eighteen is ten.

**There are two prompts, not one.** `systemPrompt(vocabulary:lowTouch:)` picks by
category: coding gets the low-touch pass, everything else gets polish. They exist
because the doctrine above and "rewrite disfluent speech into complete, coherent
sentences" cannot both be true, and on the coding path — a terminal, an editor, a
prompt for an AI coding agent — the reader is a machine that parses disfluency
fine, so rewriting is all risk and no reward. Each variant has its own few-shot
array: a low-touch *rule* paired with rewriting *demonstrations* loses, because in
a 4B model the demonstrations win. Both prefixes stay static so each keeps its own
KV cache entry, and `warmUp()` primes both — miss one and the first dictation on
that path pays full prefill (~3.5s) and silently falls back to rules.

**Low touch means delete, repunctuate, respell — and it is checked, not trusted.**
`rewordsContent` requires every output word to be a subsequence of the transcript,
or to come from the closed set the user gave us (dictionary + on-screen words).
Digit-leading tokens and two-words-as-one compounds are exempt. It catches the
failure `looksTruncated` structurally cannot: a swap keeps the word count
identical. It is deliberately blind to deletion and capitalization, so the two
guards complement rather than replace each other, and it only runs on the coding
path — a good polish rewrite fails it by design.

Do NOT resolve self-corrections on the coding path. "X, or actually Y, or maybe Z"
is a speaker listing three options and is indistinguishable from a correction
without knowing what they meant. Leaving both halves in is recoverable; deleting
the wrong one is not.

**The cleanup deadline scales with the transcript** (`deadlineMs(words:)`,
400ms + 6ms/word). A flat budget is wrong in both directions: measured on
qwen3-0.6b, twelve words clean in 0.20s and 240 words in 1.51s, so a flat 450ms
sent every long dictation — the content that most needs the model — to the rules
path. Nobody minds 1.5s after speaking for ninety seconds. Missing the deadline
ships `ruleClean` and leaves `resolved` alone: slow is not the same as broken.

Measured over 25 cases (`bench/results.md`), the tradeoff to know: qwen3-0.6b
holds 0/25 inside the budget but rewords all four long agent-prompt cases, so the
guard fires and rules ship. qwen3-1.7b rewords none of them at 100% recall and
misses the budget on 19/25. That is the real content of a fast-vs-careful setting;
do not label one "more accurate" without re-running the bench.

Qwen3 models are hybrid reasoners and LM Studio's MLX runtime ignores both
`reasoning_effort` and `chat_template_kwargs`. The `/no_think` switch on the
last user message is what actually works: 8s and 1400 reasoning tokens becomes
0.2s and 1. Append per-dictation content to the last message only so the
server's cached prompt prefix survives.

Cross-platform note: SpeechAnalyzer, Foundation Models, and SwiftUI are all
Apple-only. Anything aimed at Windows or Linux needs llama.cpp and either
whisper.cpp or sherpa-onnx instead.
