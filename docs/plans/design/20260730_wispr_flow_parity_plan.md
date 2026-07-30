# Wispr Flow parity and post-release latency, 2026-07-30

## Goal

Two things, in this order of user-visible value.

First, configurable shortcuts. Right now dictation is hardwired to the fn key. Wispr Flow lets you
bind several actions, with more than one binding per action, to keys or mouse buttons. We want the
same, because fn is not everyone's key and some people want a mouse button.

Second, close the remaining latency gap after fn is released. Cleanup is already fast (0.22s median,
see the numbers below). What we have never measured is the transcription tail, and there are a few
structural wins available that do not depend on a faster model.

Alongside both, match Wispr Flow's window layout more closely. Their sidebar is noticeably wider,
grouped under headers, and their shortcut editor is a modal sheet.

## Where the app is today

All of this is committed and installed. `./build.sh` builds, signs, installs to /Applications, and
relaunches. `.build/release/BluejayWispr --self-check` asserts the cleanup and dictionary text logic.
Read CLAUDE.md first: it holds the UI conventions this app follows, several of which were learned
painfully in the last session.

Cleanup latency was fixed by a single discovery. Qwen3 models are hybrid reasoners and think by
default, and LM Studio's MLX runtime silently ignores both `reasoning_effort` and
`chat_template_kwargs.enable_thinking`. Only the `/no_think` switch appended to the last user message
works. Measured on qwen3-0.6b-mlx over 8 cases (bench/results.md, bench/README.md):

| | median | worst | quality | lossy |
|---|---|---|---|---|
| reasoning on | 2.28s | 8.69s | 75% | 2 of 8 |
| /no_think | 0.22s | 0.58s | 89% | 0 of 8 |

qwen3-1.7b is worse on both axes: 0.62s median, 84% quality, because it leaves fillers in that the
0.6b strips. An earlier recommendation in this project's history to install a 4B instruct model is
superseded. The 0.6b with `/no_think` is the pick. Do not re-litigate this without running the bench.

Two bugs found by that benchmark and already fixed, both worth knowing because they will look like
model problems if they recur. LM Studio files the answer under `reasoning_content` and leaves
`content` empty when a `/no_think` turn emits an empty think block, so a perfect cleanup was being
discarded (LLMCleaner.swift, in `complete`). And `AppSettings` now names its preferences suite
explicitly, because a bare binary has no bundle id and `UserDefaults.standard` resolved to a
different domain, which meant the benchmark read a different dictionary than the app used.

The dictionary now biases the recognizer, not just the cleanup prompt. See Transcriber.swift:154 for
`AnalysisContext.contextualStrings` on the SpeechAnalyzer path and the same for
`SFSpeechRecognizer.contextualStrings` on the fallback. Whatever is already typed in the focused
field also feeds both stages, with secure fields never read (ContextDetector.swift, `focusedText`
and `draftTerms`).

## Shortcuts: what has to change

FnKeyMonitor.swift is 209 lines built specifically around fn. It watches `flagsChanged` through a
CGEventTap, runs a hold versus double-tap state machine, and carries a watchdog plus retry timer for
when the tap gets disabled by the system. SystemFnKey.swift (43 lines) separately suppresses the
macOS fn behaviour so the emoji picker does not fire.

The generalisation, roughly in build order:

1. A binding model in AppSettings: a list of bindings per action, where a binding is a key code plus
   modifier flags, or a mouse button number. Persisted as Codable. Keep fn as the shipped default for
   push to talk so existing users notice nothing.

2. Widen the event tap. It currently only subscribes to `flagsChanged`. It needs `keyDown`/`keyUp`
   for ordinary keys and combos, and `otherMouseDown`/`otherMouseUp` for mouse buttons 3 and up.
   The hold versus tap state machine in FnKeyMonitor is the part worth preserving: keep it, and make
   what triggers it configurable rather than rewriting it.

3. Only suppress the system fn behaviour when fn is actually bound. Right now
   `SystemFnKey.suppressWhileRunning()` fires unconditionally at launch (App.swift).

4. Actions to bind. Wispr Flow shows push to talk, hands-free mode, and press Enter, each with a
   pencil to edit and a plus to add a second binding, plus a reset to default. Ours should cover push
   to talk (hold), hands-free (toggle), and press Enter after insert. A fourth for cancel is the
   obvious candidate but is an open question below.

5. A recorder control in Settings: click to arm, capture the next key or mouse combination, show it
   as key caps. This is new UI with no existing pattern in the app to copy, so budget for it.

Note that `startQuickNote` in DictationController is now unreachable: the pill's third button was
repointed at History. Either bind it to a shortcut as part of this work or delete it and its
`noteMode` branches. Do not leave it dangling.

## Latency: measure before optimising

The app already logs both stages (DictationController.swift:189, transcribeMs and llmMs). We have
never read those numbers, because `log show` queries returned nothing for this process in the last
session. First job: confirm the logging actually surfaces, switching NSLog to os_log with a subsystem
if it does not. Optimising the transcription tail blind is guesswork, and the LLM half is already
measured at 0.22s.

The sequence after fn is released is in `finishRecording`: stop the recorder, set state to
processing, `transcriber.finishSession()`, then `cleaner.clean`, then paste. `finishSession` calls
`finalizeAndFinishThroughEndOfInput()` and awaits the results task, so any finalisation tail is
serial with everything else (Transcriber.swift:115).

Candidates, best expected return first:

Warm on fn press rather than only at launch. The keepalive is a 20 minute timer, but LM Studio idle
unloads and the prompt prefix cache can go cold. Firing a warm call the moment recording starts costs
nothing, because the user is still speaking.

Speculative cleanup on the partial transcript. SpeechAnalyzer already emits volatile results
(`Transcriber.onPartial`). Sending a cleanup call on the partial mid-speech means the final call's
prefill is nearly free, since the server has the prefix cached. This is the biggest structural win if
prefill turns out to dominate, and the measurement above should tell you.

Skip the model entirely for short clean utterances. If the raw transcript has no fillers, no stutters
and is under roughly eight words, `LLMCleaner.ruleClean` produces the same answer instantly and saves
the whole round trip. Gate on a cheap heuristic and verify against bench cases so quality does not
regress.

Do not wait for full finalisation. `finishSession` already concatenates `finalizedText +
volatileText`, so if finalisation exceeds a threshold the volatile text is usable. Needs the tail
measurement first to know whether this is worth anything.

Insert immediately, then upgrade. Paste the rule-cleaned text at once and replace it with the model's
version when it lands. This is what makes Wispr feel instant. It is also the riskiest item here,
because replacing text in someone else's app can go wrong, so treat it as opt-in and last.

Smaller items: `stream: true` for perceived latency, and trimming the few-shot from three pairs to two
(721 prompt tokens today) which only matters on a cache miss. Both are measurable with the bench.

## Window layout

Our sidebar is 192pt (Dashboard.swift:115) with a flat list of five items and a footer that reads
"Hold fn to dictate" in the idle state (Dashboard.swift:222). Wispr's is visibly wider, around 250pt,
with uppercase group headers (SETTINGS, ACCOUNT), taller rows, and a version string pinned at the
bottom.

Changes wanted:

Drop the "Hold fn to dictate" text. It stops being true the moment shortcuts are configurable. The
live states (Listening, Cleaning up) stay, and the idle state should either show nothing or show the
user's actual binding.

Widen the sidebar and group the nav under headers. `SectionLabel` in Theme.swift is already the
uppercase micro-label style to reuse. Remember the alignment rule from CLAUDE.md: nav icons sit 18pt
from the edge and their labels start at 45pt, and BrandLockup matches those numbers deliberately, so
widening means re-checking both.

The same "Hold fn to dictate. Double-tap to go hands-free." string is also the Home page subtitle
(Dashboard.swift:331) and needs the same treatment.

Consider following Wispr and putting the shortcut editor in a modal sheet rather than inline in
Settings. It is a lot of controls for a settings section, and the Advanced section is already the
agreed home for plumbing.

## Open questions for the user

Which four actions get bindings? Push to talk, hands-free, and press Enter are settled by parity.
The fourth is a guess: cancel, or quick note if that feature stays.

Are mouse buttons in scope for the first pass, or keys only? Wispr supports them and the event tap
work differs.

Is instant insert then replace acceptable behaviour? Text appearing and then changing under the
cursor is a real tradeoff, and it is the single biggest perceived-latency win available.

## Pointers

Repo /Users/kaleb/Documents/Bluejay/bluejay-wispr, private at github.com/khicken/bluejay-wispr.
CLAUDE.md for UI and cleanup conventions. bench/README.md for the benchmark and its findings,
`python3 bench/bench.py` to run it. Recent history from 7d068cc back to ce8e9cb covers the cleanup
latency work, the recognizer biasing, and the UI pass.
