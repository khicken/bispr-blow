# Bluejay Wispr

A local, free Wispr Flow-style dictation app for macOS, Bluejay-themed. Hold **fn** to speak, release to have cleaned-up text typed into whatever app you're in. Everything runs on your machine: Apple's on-device speech engine for transcription, a local LLM for cleanup.

## How it works

```
hold fn / double-tap fn
  → mic capture (AVAudioEngine)
  → on-device transcription (macOS 26 SpeechAnalyzer; SFSpeechRecognizer fallback)
  → LLM cleanup (LM Studio → Ollama → custom endpoint → rule-based fallback)
      · tone adapts to the frontmost app: casual for Messages/Slack,
        precise & technical for terminals/IDEs (Claude Code), professional for email/docs
  → pasted at your cursor (clipboard swap + ⌘V, clipboard restored)
```

- **Hold fn** — push-to-talk: release to stop and insert.
- **Double-tap fn** — hands-free lock: tap fn again (or click the red stop on the pill) to finish, **Esc** to cancel.
- The floating pill at the bottom of the screen shows idle / waveform / processing states.
- Menu bar bird = open the dashboard (Home stats, History, Dictionary, Settings).

## Build & run

```bash
./setup-signing.sh   # once: creates a stable signing identity so permissions persist
./build.sh           # builds, installs to /Applications, relaunches
```

`build.sh` stages the bundle in `.build/` and installs a single copy to `/Applications` — two installed copies means two fn event taps fighting each other. Never launch the bare binary from a terminal: macOS attributes permissions to the terminal instead of the app.

`.build/release/BluejayWispr --self-check` asserts the cleanup/dictionary text logic.

Requires macOS 26+ and Swift 6.2+ (Xcode CLT).

## First-run setup

1. **Microphone** — allow when prompted.
2. **Accessibility** (and **Input Monitoring** if prompted) — System Settings → Privacy & Security → enable Bluejay Wispr. Needed for the fn event tap and synthetic paste. With the `setup-signing.sh` identity this is a **one-time** grant; it survives rebuilds. Until granted, dictations are still copied to the clipboard and the pill says "Copied — press ⌘V to paste".
3. **Quit Wispr Flow** if it's running — both apps grab the fn key.
4. **LLM cleanup** — works out of the box if LM Studio's server is running (`lms server start`) with any chat model downloaded (e.g. `lms get llama-3.2-3b-instruct`). Ollama is picked up automatically too. Or point Settings → Custom at any OpenAI-compatible endpoint (e.g. Groq free tier). With no provider available, a rule-based filler-stripper keeps dictation working.

The fn key needs no system changes: the app's event tap consumes bare-fn presses, so the macOS emoji/dictation popup never fires while it runs (Settings still offers the "Do Nothing" toggle as a belt-and-suspenders option).

## Layout

| Path | What |
|---|---|
| `Sources/BluejayWispr/FnKeyMonitor.swift` | fn hold / double-tap gesture state machine |
| `Sources/BluejayWispr/Transcriber.swift` | SpeechAnalyzer streaming + SFSpeech fallback |
| `Sources/BluejayWispr/LLMCleaner.swift` | provider chain + context-aware prompts |
| `Sources/BluejayWispr/ContextDetector.swift` | frontmost app + window title (AX) |
| `Sources/BluejayWispr/TextInserter.swift` | clipboard-swap paste |
| `Sources/BluejayWispr/UI/` | pill, dashboard, theme (Bluejay palette) |
| `make-icon.swift` | regenerates `AppIcon.icns` (Bluejay squircle + symbol) |
| `shared/plans/design/20260611_bluejay_wispr_plan.md` | design plan |
