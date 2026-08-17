# BisprBlow

A local dictation app for macOS. Hold your shortcut, speak, release, and
cleaned-up text lands at your cursor. Everything runs on the machine.

BisprBlow is the name the user sees. Everything else is still `BluejayWispr`:
the SwiftPM package, target and binary, `Sources/BluejayWispr/`, the bundle id
`ai.getbluejay.wispr` and the UserDefaults suite of that name. Renaming the
suite wipes the user's dictionary, bindings, theme and pill anchor, so the two
names are load-bearing separately — rename the copy, never the identifiers.

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

**Plumbing gets no section at all, not even a last one.** There used to be an
Advanced group holding a provider menu, a model menu, and three fields for a
custom endpoint. It is gone. Which server is running and which model id it holds
are things the app finds out by asking, so putting them on screen only handed
the user a way to get it wrong, and "Auto / LM Studio / Ollama / Custom / Off"
asked them to have an opinion about five words describing our implementation.
What survives is the one axis they can actually judge: Fast or Accurate
(`AppSettings.Cleanup`), which picks the model and the deadline together. Before
adding a setting, ask whether it is a decision the user has any basis for
making. Nothing in this app collapses, and nothing hides.

**The section is "Writing", and it is not "Transcription".** Fast/Accurate and
the lowercase switch share one card because both decide how the app writes what
it heard. Nothing in it reaches the recognizer, so a heading naming transcription
would promise that Accurate mishears fewer words — it does not; "prod" heard as
"proud" comes back wrong in both. "Cleanup" is the other wrong answer: accurate,
but it is our name for our second stage, and the user did not know there were
stages.

**A preview shows the thing, not a picture of it.** The theme swatches draw the
window in miniature — sidebar, nav, content cards, pill — every fill read from
the `Palette` being offered, so a swatch cannot promise a look the app will not
draw. They used to show a brand render on one card and a bare gradient on the
other, which is how you end up choosing a photograph and getting a settings
page. Names carry no accent dot and no one-line blurb: the picture is the
description, and a dot that only repeats a colour already on screen is
decoration.

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

**A theme is a `Palette`, and that includes the type face.** Five of them:
System, Light, Dark, World, Unhinged. Nothing draws a colour, an image or a font
that did not come out of the table in Theme.swift — `.white` behind a text field
is how you ship a flashbang in Dark, so even that is a token (`field`), and every
`.font(.system(size:))` is `.font(.bj(size:))` so one theme can be in Comic Sans
without any view knowing. Adding a look is a case plus a palette; it appears in
Settings on its own.

System is not a sixth palette, it is Light or Dark chosen by the OS. It reads
`AppSettings.systemIsDark`, which App.swift keeps current by KVO on
`NSApp.effectiveAppearance` — published, because `Theme` is static and a view
repaints only when something it *observes* changes, so reading NSApp at draw time
would leave the window in whatever mode it launched in. Do not switch to the
AppleInterfaceThemeChanged notification: it fires before the app adopts the new
appearance, so reading it back lands on the old value about half the time. And
`Theme.applyToNativeControls()` has to run on every change, because switches,
menus, scrollbars and the traffic lights are AppKit's and it has never heard of
`Palette`.

**Anything that draws a palette colour stores `var themeID = Appearance.current`.**
`Theme` is a table of statics, so such a view holds nothing that depends on the
theme, and SwiftUI skips redrawing a view whose stored properties compare equal.
Switching to Dark left the section cards cream with white text on them, while
the page and sidebar around them went dark — the views that happened to redraw
were the ones storing a closure, which never compares equal. `@ObservedObject`
is not the fix: `Card` is a ViewModifier and the button styles are ButtonStyles,
and neither can observe anything.

**The joke theme is not an excuse.** Unhinged keeps near-black violet ink on
every one of its surfaces, so it is exactly as readable as Light. Somebody will
turn it on and leave it on. A theme nobody can read is not funny, it is a bug.

**Brand color is an accent, not a surface.** Blue for the selected nav row, the
mic glyph, links. Text stays ink. Do not put gradients on the logo or the
wordmark, and do not bake shadows into the app icon since macOS draws its own.

**Measure the pill before theorising about it — `--pill-demo <anchor>`.** It replays a real
release (recording → processing → idle, with the measured 476ms insertion gap) with no mic, model
or event tap, and prints the pill's drawn top, bottom and centre in screen points every 8ms. It
measures pixels plus the panel's own origin, because `rotationEffect` leaves the layout size
unrotated and the panel is resized by AppKit on a clock of its own, so a layout probe misses
whichever is at fault. Screen capture is not an option: `CGWindowListCreateImage` is gone in
macOS 26 and ScreenCaptureKit wants a permission this app deliberately does not hold. Take the
anchor as an argument — the CLI binary is not the installed bundle, so it has its own defaults
domain and never sees the real `pillAnchor`. Three sessions tried to fix "the pill jumps" by
reading code and asking Kaleb what he saw, and two shipped a regression; the first run of this
found the cause in minutes.

**The pill's outer frame moves on the same spring as the capsule, and the panel is not involved.**
The capsule is centred in that frame, so any point by which the two disagree lands as *half* that
much displacement on screen — and on a side anchor a width disagreement is vertical travel.
Measured on `leftCentre`: sizing the frame from the incoming state snapped it ahead of the spring
and threw the pill 19pt up, exactly (106−68)/2, where it sat for 400ms. Two plausible fixes are
both wrong and both were measured: sizing the frame from the *panel* reproduces the same 19pt
(the panel is not what the capsule is positioned against), and filling the panel outright does
too. Only `.animation(Self.grow, value: targetSize)` on the frame holds — centre travel 22pt →
2.75pt on both side anchors.

**`NSHostingView.sizingOptions` must stay empty, or the panel resizes itself.** By default the
hosting view pushes SwiftUI's ideal size up to the window as its content min/max, and AppKit
applies it the instant the state changes — keeping the *top-left* corner, and without the
`reposition()` a deliberate resize carries. That made `resize`'s deferred shrink a fiction: the
panel shrank in 10ms anyway, and the 0.4s deferral only delayed the origin correction, which then
landed as a discrete 19pt drop. It is also why the deferral looked innocent in code review — it
was deferring the wrong half.

**Reach for the plainest control that works.** SwiftUI has sharp edges on
macOS: `DisclosureGroup` with a custom label has almost no hit target, so a
Button plus a rotating chevron beats it. When a native control misbehaves, drop
to AppKit rather than layering workarounds.

## Packaging rules

`./package.sh` builds `.build/BisprBlow.pkg`. `./build.sh` is still the local iteration path and
package.sh calls it, so the bundle is assembled in exactly one place.

**It is a .pkg because the weights are a question, and a .dmg cannot ask one.** A disk image is
drag-and-drop with no UI. `customize="always"` in the distribution XML is what makes Installer show
the choice pane instead of a bare Install button; without it the choices exist but nobody sees them.
A literal drop-down needs a custom Installer plugin, which is an ObjC bundle for one question.

**The Fast weights are not deselectable, and that is not timidity.** Fast means the smallest model
installed, so a machine holding only the 1.7B resolves *Fast* to it as well — the Writing setting
becomes a label with one model behind both sides. Shipping the 335M always is what keeps that
setting honest, and it is also what keeps the app from launching into silent `ruleClean`.

**Weights install to `/Library/Application Support/BluejayWispr/models`, not `~/Library`.** A .pkg
cannot write to a home directory without moving the whole install to the user domain, which drags
the app out of /Applications with it. `LocalEngine.searchRoots` scans both, home first, so a
hand-placed model still wins over the installed one.

**The choice saves disk, not download.** Both payloads are inside the one package, so it is ~1.9 GB
whichever way the box is ticked. Making the download smaller means either two separate packages (no
choice) or fetching over the network at first run (no code for it exists — `LocalEngine`'s comment
about "the download-on-setup step" describes something that was never written).

**package.sh fails the build when the bundle has no metallib**, because MLX aborts the process
rather than throwing and there is no degraded mode to notice later. Verify payloads with
`lsbom -s` on the extracted component BOMs; the weights are worth diffing against the source, since
a truncated safetensors is invisible until first dictation.

**After a .pkg install, `./build.sh` refuses to run until you hand the bundle back.** Installer
leaves `/Applications/BisprBlow.app` owned by root, and build.sh's `rm -rf` then fails part-way
through it rather than at the start. The guard prints the `sudo rm -rf` plus `pkgutil --forget` to
run; testing the installer and then iterating locally is the normal cycle, so expect it.

**Nothing is notarized: the Apple account is free, so there is no Developer ID cert.** The app is
signed with the self-signed `Bluejay Wispr Dev` identity and installs behind a right-click > Open.
Moving to a paid membership and a Developer ID is the only thing that makes it open cleanly on a
stranger's Mac — and it will re-prompt Accessibility, Microphone and Speech Recognition on every
machine including Kaleb's, because TCC keys grants to the signing identity.

## Cleanup rules

Losing the user's words is the worst outcome, worse than leaving fillers in.
`looksTruncated` rejects any cleanup that elides content (an ellipsis anywhere,
or under 55% of the transcript) and falls back to rule-based cleaning of the full
text. Add a case to SelfCheck.swift whenever a new failure shows up.

**The recognizer writes an ellipsis where the speaker paused, and it is stripped at
the source** (`Transcriber.withoutPauseMarks`, applied at all four points a
transcript leaves the recognizer). Do not treat an ellipsis in `raw` as something
the speaker dictated: that assumption put "to see... If we already offloaded" at
the cursor, and it disarmed `looksTruncated`'s elision check on every dictation
containing a pause. Fixing it at the source is what keeps that check armed.

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

**The LAST few-shot demonstration in a category is copied, not generalised from.** At 0.6b the
nearest same-category demo dominates, and for a while the final `(general)` demo was a question —
so every short general *imperative*, a shape with no demo of its own, came back as that question.
"send the invoice to finance" and "add a note about the pricing change" both shipped the literal
string "Did the Kubernetes deploy work?"; "cancel the meeting" became "did the meeting cancel?".
Six of these reached Kaleb's history. Questions, long dictations, coding and chat were all fine,
because each had its own nearest demo. Nothing caught it: every guard is floored at 12 content
words, so a short dictation has none at all — the floors are right for their own false-positive
rates, and the fix belongs in the prompt. `fewShot` therefore ends with a short `(general)`
imperative, and the vocabulary demo must not drift back to being last. When you add a demo, ask
what shape is now nearest to the shapes that have none.

**The dictionary must never respell a word the recognizer got right.** `near` matches at one edit
and, unlike `loose`, fires without neighbour evidence — so `levenshtein("code", "xcode") == 1` put
"just put a Xcode Vite for it" at the cursor, the corrected "code" then licensing the phonetic tier
on "fix". Across the shipped dictionary: "git" ate gift/gist/grit, "Vite" ate site/cite/bite,
"Swift" ate shift, "linter" ate liner/linger/linker, "Claude" ate clause. The gate is
`LLMCleaner.englishWords`, macOS's own `/usr/share/dict/words` — being real English is the
discriminator. A length floor is the obvious fix and the wrong one: "Parik" → "Parikh" is five
letters and is the case the dictionary exists for. The set is empty when the file is missing, which
restores the old behaviour rather than disabling respelling, and `warmUp` builds it so the first
dictation does not spend its deadline on it.

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
misses the budget on 19/25. That is the real content of the Fast/Accurate setting;
do not relabel either one without re-running the bench.

**Fast and Accurate are a model *and* a deadline, never one alone.** Fast takes
the smallest model installed (`smallFamilies`); Accurate takes the careful order
(`carefulFamilies`, led by qwen3-4b-2507) and a budget scaled to match — see
`deadlineMs`, which owns both numbers. Give the careful model the fast budget and
it is not more accurate, it just misses the deadline and ships the same
`ruleClean` text later: the worst of both, and invisible from outside. Benched on
qwen3-1.7b over the 25 cases, the careful budget leaves 2/25 over, both of them
cold-load outliers of the kind `warmUp()` exists to absorb. Fast falls through to
the careful order when the machine has no small model, because "Fast" still has
to mean cleanup rather than nothing.

**Selecting Accurate without a careful model on disk does not crash — it silently writes with Fast.**
Measured: `--clean` returns normally, exit 0, `provider` still "On-device". `firstModel` ends in
`return chatIDs.first`, and generic `"qwen"` in `carefulFamilies` matches the 0.6b before that, so
the setting moves and nothing about the writing changes. This became reachable the moment the
installer made the Accurate weights optional, so `LLMCleaner.accurateNeedsModel` detects the collapse
(Accurate and Fast resolving to the same id) and Settings offers the download instead of pretending.
Both sides call `LLMCleaner.pick`, so what is offered and what would be resolved cannot drift apart.

**`ModelDownloader` stages into a dot-prefixed directory, and that is the whole safety mechanism.**
`installedModels()` enumerates with `.skipsHiddenFiles`, so `.incoming-<name>` is invisible to the
scanner and a half-written model can never be loaded — MLX aborts the process on a truncated
safetensors rather than throwing, at first dictation rather than at download time. Files are also
size-checked against the Hugging Face listing before the directory is moved into place. The repo is
`lmstudio-community/Qwen3-1.7B-MLX-8bit`, the same weights package.sh installs and bench/results.md
was measured on; downloading anything else makes those numbers describe a different app.

**Name every model size before the family that contains it.** `carefulFamilies`
ended in a generic `"qwen"`, and on a machine holding only qwen3-0.6b and
qwen3-1.7b that matched the 0.6b — so Accurate resolved to the same model as Fast
and the setting silently did nothing. A pattern loose enough to match a family
will match its smallest member.

**Output style is a post-pass, not a prompt rule.** Both settled cases — no em
dashes, and the optional lowercase sentence starts (`AppSettings.lowercaseSentences`)
— are substitutions applied after cleanup. A 0.6b model obeys a style instruction
unreliably, the prompt prefix is cached for latency so every added line costs, and
a post-pass holds on the rule-based fallback path too, where there is no model to
instruct. Sentence casing is applied in `clean` around `cleaned`, because all six
of that function's exits end at the cursor.

**No em dash ever lands at the cursor.** It is a model tic rather than something
the speaker said, and a comma carries the same break. Enforced in `sanitize` as a
substitution, not asked for in the prompt: a 0.6b model obeys a style rule
unreliably, the prompt prefix is cached for latency so every line costs, and the
low-touch guards are blind to punctuation by design. The few-shot demonstrates the
comma too, since demonstrations outweigh instructions at this size.

**A guard rejection escalates once to the careful model before falling back to rules.**
The guards are the app's own signal that a dictation was too disfluent for the fast
model, and shipping `ruleClean` on that signal is what "chunky" feels like. The retry
runs on the careful budget plus a cold-prefill allowance, only in Fast mode, and only
when the careful order resolves to a genuinely different model. Exercise it with
`--clean` (stdin `{"raw"}` → the full resolution/guards/escalation path against the
live endpoint); the long agent-prompt bench cases trip it reliably.

**The in-process engine holds ONE resident model and ONE cached prompt sequence.**
Consequences, all load-bearing: warmUp warms only the resolved model (warming the
careful one too would swap the fast one back out and hand the first real dictation a
cold load); of warmUp's two prefix warms only the LAST survives, so lowTouch goes
last on purpose — coding is the dominant context, and a category switch costs a
prefix re-prefill (~0.3-0.9s, inside every deadline) rather than a model load; every
escalation swaps models and pays the careful model's load plus a full prefill, which
is why its deadline carries a +6s allowance; and after an escalation the fast model
is re-warmed in the background or the next ordinary dictation pays the reload and
misses its deadline, turning one bad dictation into two. (LM Studio, retired, had
the same shape for a different reason: its MLX prompt cache held one prefix
globally across models.)

Qwen3 models are hybrid reasoners and LM Studio's MLX runtime ignores both
`reasoning_effort` and `chat_template_kwargs`. The `/no_think` switch on the
last user message is what actually works: 8s and 1400 reasoning tokens becomes
0.2s and 1. Append per-dictation content to the last message only so the
server's cached prompt prefix survives.

Cross-platform note: SpeechAnalyzer, Foundation Models, and SwiftUI are all
Apple-only. Anything aimed at Windows or Linux needs llama.cpp and either
whisper.cpp or sherpa-onnx instead.

## Audio capture rules

**Measure the signal before blaming the model.** A weak or clipped mic comes back
as confident wrong words, never as silence, so it is indistinguishable from a
cleanup problem from the outside. `AudioRecorder.logSignal` writes one line per
dictation — sample rate, channels, seconds, mean RMS and peak in dBFS, clipped
sample count. Speech wants roughly -30 to -12 dBFS mean; under about -45 is a gain
problem no prompt or model work will fix. Measured on this machine with the macOS
input volume at 30/100: mean -33 to -42 dBFS with peaks as low as -22, i.e. 20 dB
of unused headroom, which is the likeliest remaining source of proper-noun mishears
("pork tree", "blue jet bottles"). Check `osascript -e 'input volume of (get volume
settings)'` before touching recognition code.

**Capture is AVCaptureSession, and going back to AVAudioEngine breaks every ordinary
mic.** AVAudioEngine wants one device supplying both input *and* output. Point its
input node at an input-only device — which is the built-in mic, and every USB mic
that is not also a speaker — and the graph gets a 0ch/0Hz output format and fails to
initialise with `-10868`; `installTap` then *raises* on the dead chain and SIGABRTs
the app, because Swift cannot catch an ObjC exception. `setDeviceID` does not fix it
and neither does anything else: the node latches its format when it is created and
never renegotiates, so a selected device is simply never heard. Measured across
twelve variants (tap-before-start, tap-after-start, `format: nil`, `reset`,
`deallocateRenderResources`, the raw `kAudioOutputUnitProperty_CurrentDevice`,
waiting out the configuration change, a fresh engine): the USB PnP mic and the
built-in mic captured 0 frames on all of them, and the EarPods captured only because
they carry speakers. `AVCaptureDeviceInput` takes an arbitrary device by design —
95744 frames from the same USB mic, same ~150ms startup.

This is what the device picker was silently doing for its whole life, and it is why
"the model can't understand me" was worth checking against the signal first.

**Run `--mic-check` after touching capture.** It drives the real `AudioRecorder` for
two seconds against the *selected* device and prints the frame count, so the capture
path is testable without the keyboard — before it existed, an input-only mic
capturing nothing could only be caught by asking Kaleb, and it shipped twice. It also
caught a `frameLength`-set-after-copy bug that the standalone harness did not have.

**The mic opens ~150ms after the shortcut, and `AudioRecorder.start` is where it
goes.** The pill shows "recording" the instant the gesture fires, but speech before
the mic opens is captured by nothing. Measured with `ActivationTrace` (see
`Log.swift`) over warm dictations: `onStart=0ms pill=4-10ms session=13-21ms
mic=165-177ms`, and ~270ms on the first dictation after launch. `startSession` is the
small half — about 15ms; the rest is the capture session starting, 145-152ms measured
directly by `--mic-check`. Reordering around `startSession` would buy 15ms, not 150.

The 30s warm window is what skips that cost across a burst, and it is a product
decision rather than a free win: a running session holds the microphone, so the macOS
mic indicator stays lit between dictations. `isRunning` gates delivery, so a warm
session's buffers are dropped rather than fed. Still no pending-buffer queue without
re-measuring.

**Build the audio converter from the buffer, never from a format read earlier** —
and more generally, never from any format read before the samples exist.
`beginRecording` used to read `recorder.inputFormat` and hand it to the transcriber
*before* `AudioRecorder.start` applied the selected input device, so on any
non-default mic at a different sample rate the `AVAudioConverter` was constructed
for a format the buffers never had — and AVAudioConverter does not recover, it
silently yields nothing for the whole dictation. `Transcriber.feed` now builds it
lazily, keyed on `buffer.format`, which also survives a device change mid-session.
That is why `startSession` takes no `inputFormat`. The same mistake one call later is
what aborted the app: a `format:` handed to `installTap` that the hardware no longer
had.

**A capture that produced nothing must never reach the recognizer.**
`finalizeAndFinishThroughEndOfInput()` does not return on an analyzer that was never
fed, so `finishRecording` hung in `.processing` and the pill spun on the dots until
the app was force-quit — the user-visible face of the bug above. It now checks
`recorder.capturedFrames` first and shows which mic produced nothing. Silence is a
failure the user has to be told about; the alternative is dictating into nothing and
not finding out.

**`Result.alternatives` IS populated.** Measured from real dictations: N ranges 1
to 5, usually 2-3 on short spans. n-best rescoring against the dictionary has real
raw material — this was an open question and the answer is yes.

## Inference runtime rules

**Upstream LocalLLMClient's prompt cache was structurally broken, twice over, and the
fix lives in our local copy.** The known bug: the KV trim ran inside
`assert(llama_memory_seq_rm(...))`, which Swift compiles out under `-O`. The deeper
bug, found by instrumenting rather than trusting the first fix: at EOS the generated
reply is merged into the cached prompt *text*, so the next prompt — which never
contains the previous reply — fails the `hasPrefix` match and the cache NEVER hits.
Every call was a full re-prefill on a context that never shrank; in the real app,
where no two dictations render the same prompt, `onDevice` would have died after ~6
dictations no matter what the assert did. The local copy replaces the text cache with
a token-level one (diff the new prompt's tokens against what the KV holds, trim at
the divergence, decode only the tail) — the same mechanism llama-server uses.
Measured after the fix: flat 192ms warm on identical prompts, 150ms median on varied
transcripts against the warm static prefix, vs LM Studio's 0.33s. Watch for it
climbing monotonically across calls; that is the signature of the cache not matching.

The dependency is the published fork `github.com/khicken/LocalLLMClient`, pinned to revision
`7741fbcd` (tag 0.5.0 plus both KV-cache fixes) — not the local checkout an earlier version of
this file described, so a clone needs nothing on disk beside it. No upstream PR yet, at the
user's request. **If you switch it back to a local path, that clone needs
`git submodule update --init`**: its C sources are symlinks into a llama.cpp
submodule, and without it `swift build` fails on `build-info.h` — while the previous
binary keeps sitting in `.build/release`, silently passing self-check. Check
`strings .build/release/BluejayWispr` for something you just added if a change seems
to have no effect.

`LLMCleaner.endpoints` lists `onDevice` **first**, earned on a bench run: the MLX
backend running the same Qwen3-0.6B-MLX-4bit weights LM Studio served reads 96%/85%
recall/quality at 0.19s median over the 26 cases, against LM Studio's 96%/85% at
0.33s — parity by construction, since it is the same runtime and the same weights.
LM Studio was uninstalled on that result; the weights moved to
`Application Support/BluejayWispr/models`. GGUF quants were tried first and lost on
quality, not speed (Q4_K_M 77%, Q8_0 78-81% — the quantization itself, not sampling;
repeat-penalty was tested and ruled out). The llama.cpp backend still reads any GGUF on
disk, and is what a machine without the metallib falls back to — but no GGUF ships in the
installer and none is left on this machine, so that path is code without weights behind it.
A machine that loses its metallib gets `ruleClean`, not a slower model.

**MLX aborts the process — no throw, no fallback — without `mlx.metallib` beside the
executable.** The name is `mlx.metallib`, NOT `default.metallib`: the first path
`load_colocated_library` tries is `<binary dir>/mlx.metallib` (device.cpp:140); the
"default" name only resolves inside a SwiftPM resource bundle. SwiftPM cannot compile
.metal sources, so build.sh compiles mlx-swift's eight JIT kernels with `xcrun metal`
(needs the Metal Toolchain component, ~700MB one-time download) and copies the result
beside the binary in both .build/release and the app bundle. `LocalEngine.mlxAvailable`
gates MLX model discovery on that file existing.

**Never cancel an MLX generation.** Metal asserts — and aborts the whole app — when a
generation is cancelled mid command-buffer commit; the deadline race used to do
exactly that on every miss (reproduced ~1 in 3). `LocalEngine.complete` drains the
MLX stream in a detached task that outer cancellation cannot reach, so a deadline
miss returns rules while the abandoned generation finishes quietly and is discarded.
The cost is that the actor stays busy until it settles, which the 16k-char runaway
ceiling bounds.

The fork carries prompt-prefix KV caches for BOTH backends now (token-level diff,
trim at divergence, prefill only the tail): llama.cpp got it first, MLX measured
363ms → 39ms on identical calls and ~70-100ms on varied transcripts.

**mlx-swift cannot be built by `swift build`.** Its own README says SwiftPM on the
command line cannot compile the Metal shaders. Worse, a missing `default.metallib`
makes MLX **abort the process** rather than throw, so the fallback to LM Studio or
rules never runs and the app dies on the first dictation — any `onDevice` endpoint
backed by MLX has to be gated on the metallib existing. Getting MLX working needs
Xcode's multi-GB Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
plus a metallib step in build.sh, re-run on every MLX bump. MLX looks for it beside
the executable first, so that step is a file copy rather than a bundle. This is the
trade to weigh: MLX is the fast runtime, llama.cpp is the portable one that builds.

**The in-process dependency is pinned by revision, not version, and must be.**
LocalLLMClient's llama.cpp C target uses `unsafeFlags`, which SwiftPM refuses in a
dependency resolved by version ("contains unsafe build flags"). A revision carries
the same permission with none of the drift their README's `branch: "main"` would
bring. Its umbrella header also hard-errors unless the importing target sets
`.interoperabilityMode(.Cxx)`, so C++ interop propagates to the whole app target.
It works with SwiftUI and AppKit; do not remove that setting.

**Never block the main thread waiting on a `Task` in a CLI path.** `main()` on a
`@main` type is MainActor-isolated, so a plain `Task` inherits that isolation and
can never run while a semaphore holds the main thread. It deadlocks outright with no
log output, which reads exactly like a hung model. `App.swift`'s `awaitSync` uses
`Task.detached` for this reason.

Known rough edges before `onDevice` can ship: the `--complete` process exits with
SIGABRT inside ggml's `ggml_metal_device` destructor, and a 10-request run returned
only 6 replies. Both land after the output for the CLI seam, but neither is
acceptable inside the app.
