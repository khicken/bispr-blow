# BisprBlow

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

This is the supported way to install it today. There is no notarized download yet, so a
build you make yourself is the one that opens without argument.

```bash
git clone https://github.com/khicken/bispr-blow
cd bispr-blow                                  # the clone made this; build.sh lives inside it
xcodebuild -downloadComponent MetalToolchain   # once, ~700 MB, needed for MLX
./setup-signing.sh                             # once: stable identity, so permissions persist
./build.sh                                     # builds, installs to /Applications, relaunches
.build/release/BisprBlow --download-fast       # once: the 335 MB model it cleans your words with
```

**Do not skip the last line.** A fresh clone has no weights anywhere, and an app with none
falls back to rule-based cleanup silently — it looks like it works, it just stops fixing
anything. `--list-models` should print `Qwen3-0.6B-MLX-4bit` when it is done, and
`echo '{"raw":"..."}' | .build/release/BisprBlow --clean` should answer `"provider":"On-device"`
rather than `"rules"`.

Accurate is a second, larger model and is optional: `--download-accurate`, or let Settings
offer it. Until then Accurate writes the same as Fast and says so.

`build.sh` stages the bundle in `.build/` and installs a single copy to `/Applications` — two installed copies means two fn event taps fighting each other. Never launch the bare binary from a terminal: macOS attributes permissions to the terminal instead of the app.

`.build/release/BisprBlow --self-check` asserts the cleanup/dictionary text logic.

Requires macOS 26+ and Swift 6.2+ (Xcode CLT).

## Installing it on another Mac

`./package.sh` builds `.build/BisprBlow.pkg` — about 310 MB: the app, plus the fast model it cleans
up your words with. The weights live outside the bundle and an app without them quietly falls back
to rule-based cleanup, so the fast one is not optional.

The larger model behind the **Accurate** setting is 1.7 GB and is *not* in the installer. Switch to
Accurate and BisprBlow offers to fetch it; until then Accurate writes the same as Fast, and Settings
says so rather than pretending.

**Opening it takes an extra step.** BisprBlow is not notarized — that needs a paid Apple Developer
Program membership — so macOS refuses the installer on a double-click. Right-click it, choose
**Open**, then **Open** again at the warning. Same for the app's first launch. (The build scripts
are ready for the day that membership exists: they pick up a Developer ID certificate on their own
and notarize — see *Signing and notarization* below.) If Gatekeeper is stubborn:

```bash
xattr -dr com.apple.quarantine ~/Downloads/BisprBlow.pkg
```

Installing to `/Library` needs an admin password, which the installer will ask for.

## Signing and notarization

Nothing here needs doing to build or run the app locally. `./setup-signing.sh` makes a self-signed
certificate, and a stable identity is all local iteration wants — macOS keys its Accessibility and
Microphone grants to the signing identity, so a changing one re-prompts on every build.

What that identity cannot do is open on anyone else's Mac. Only a **Developer ID** signature plus a
stapled notarization ticket clears Gatekeeper, and both come with the paid Apple Developer Program
($99/year). The scripts already do the rest — `build.sh` prefers a *Developer ID Application*
certificate over the self-signed one and switches on the hardened runtime when it finds one, and
`package.sh` signs the installer with a *Developer ID Installer* certificate and notarizes when
credentials are stored. Neither changes behaviour on a machine without the certificates.

So the whole remaining task is three one-time steps:

1. Join the Apple Developer Program.
2. In Xcode → Settings → Accounts → Manage Certificates, add **both** *Developer ID Application*
   and *Developer ID Installer*. They are separate certificates and the scripts look for each by
   name — the app one is missing if `package.sh` says "no Developer ID Installer certificate".
3. Store notarization credentials once, using an [app-specific
   password](https://account.apple.com/account/manage):

   ```bash
   xcrun notarytool store-credentials bisprblow \
       --apple-id you@example.com --team-id TEAMID --password abcd-efgh-ijkl-mnop
   ```

Then `./package.sh` produces a signed, notarized, stapled installer that opens with a double-click.
`spctl -a -vvv -t install .build/BisprBlow.pkg` should say `accepted`; it says `rejected` today.

One thing to expect: the hardened runtime means a new signing identity, and **TCC keys its grants
to the identity** — so Accessibility, Microphone and Speech Recognition re-prompt once on every
machine, including the one that built it.

## First-run setup

1. **Microphone** — allow when prompted.
2. **Accessibility** (and **Input Monitoring** if prompted) — System Settings → Privacy & Security → enable BisprBlow. Needed for the fn event tap and synthetic paste. With the `setup-signing.sh` identity this is a **one-time** grant; it survives rebuilds. Until granted, dictations are still copied to the clipboard and the pill says "Copied — press ⌘V to paste".
3. **Quit Wispr Flow** if it's running — both apps grab the fn key.
4. **LLM cleanup** — works out of the box if LM Studio's server is running (`lms server start`) with any chat model downloaded (e.g. `lms get llama-3.2-3b-instruct`). Ollama is picked up automatically too. Or point Settings → Custom at any OpenAI-compatible endpoint (e.g. Groq free tier). With no provider available, a rule-based filler-stripper keeps dictation working.

The fn key needs no system changes: the app's event tap consumes bare-fn presses, so the macOS emoji/dictation popup never fires while it runs (Settings still offers the "Do Nothing" toggle as a belt-and-suspenders option).

## Layout

| Path | What |
|---|---|
| `Sources/BisprBlow/FnKeyMonitor.swift` | fn hold / double-tap gesture state machine |
| `Sources/BisprBlow/Transcriber.swift` | SpeechAnalyzer streaming + SFSpeech fallback |
| `Sources/BisprBlow/LLMCleaner.swift` | provider chain + context-aware prompts |
| `Sources/BisprBlow/ContextDetector.swift` | frontmost app + window title (AX) |
| `Sources/BisprBlow/TextInserter.swift` | clipboard-swap paste |
| `Sources/BisprBlow/UI/` | pill, dashboard, theme (Bluejay palette) |
| `make-icon.swift` | regenerates `AppIcon.icns` (Bluejay squircle + symbol) |
| `shared/plans/design/20260611_bluejay_wispr_plan.md` | design plan |
