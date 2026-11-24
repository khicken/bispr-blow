# BisprBlow for Windows

The same app as the Mac one, built for Windows 10/11 (x64). Hold your shortcut (Ctrl+Win by default),
speak, release, and cleaned-up text lands at your cursor. Everything runs on the machine.

## Build

Windows 10 1903+ and the .NET 10 SDK. `build.ps1` does the rest, including the one-time model downloads
(about 1.3 GB: the speech model and the model that cleans your words).

```powershell
git clone https://github.com/khicken/bispr-blow
cd bispr-blow\windows
.\build.ps1
```

It installs one copy to `%LOCALAPPDATA%\Programs\BisprBlow` and relaunches it. One copy on purpose:
two copies means two keyboard hooks fighting over one shortcut. Run
`BisprBlow.exe --self-check` after touching the cleanup or dictionary text logic.

## Architecture

Same shape as `Sources/BisprBlow/`: one C# file per Swift file, same type names, same responsibilities.
When you change one platform, the file to change on the other has the same name. The repo-root
`CLAUDE.md` is the rulebook for both; what follows is only what is different here.

| Mac (Swift) | Windows (C#) | What changes |
|---|---|---|
| `App.swift` | `Program.cs`, `App.xaml(.cs)` | Tray icon instead of menu bar item; same CLI seams |
| `AppSettings.swift` | `AppSettings.cs` | JSON in `%APPDATA%\BisprBlow\settings.json` instead of a defaults suite |
| `AudioRecorder.swift` | `AudioRecorder.cs` | WASAPI (NAudio) instead of AVCaptureSession |
| `Parakeet.swift`, `Transcriber.swift` | same names | Parakeet TDT through sherpa-onnx instead of FluidAudio/CoreML |
| `LocalEngine.swift` | `LocalEngine.cs` | GGUF through llama.cpp (LLamaSharp) instead of MLX |
| `LLMCleaner*.swift` | `LLMCleaner*.cs` | Ported as-is: prompts, guards, rules, respeller |
| `ShortcutMonitor.swift`, `SystemFnKey.swift` | `ShortcutMonitor.cs` | Low-level keyboard/mouse hooks instead of a CGEvent tap; no fn key exists |
| `TextInserter.swift` | `TextInserter.cs` | Clipboard + SendInput Ctrl+V, clipboard restored |
| `ContextDetector.swift`, `ScreenElements.swift`, `CorrectionWatcher.swift` | same names | UI Automation instead of the AX API |
| `CloudClient.swift`, `SyncEngine.swift`, … | same names | Ported as-is over HttpClient |
| `UI/*.swift` | `UI/*.xaml(.cs)` | WPF; theme is `Bj.*` DynamicResources (see `UI/Theme.cs`) |
| `AppUpdater.swift` (Sparkle) | — | Not ported. `UpdateChecker` names the new version on Home and opens the release |
| `Permissions.swift` | `Permissions.cs` | Only the microphone privacy switch exists on Windows |

What does not come across, on purpose:

- **No fn key.** Windows handles it in the keyboard's firmware, so no program can see it. Push to talk
  defaults to holding Ctrl+Win.
- **No Apple fallback recognizer.** Until Parakeet has loaded the pill says so instead.
- **Heard-as is typed, not learned.** The Mac offers "Hear X as Y next time?" only when the CTC
  log-probs support it (`Parakeet.supports`). sherpa-onnx does not expose those, and offering without
  the evidence teaches the over-correction the guard exists to stop, so the prompt is left out.
  Heard-as entries typed on the Dictionary page work the same as on the Mac.
- **MLX weights.** The cleanup model is the same Qwen3 family as GGUF. CLAUDE.md records GGUF Q4_K_M
  losing quality on the bench, so the Windows build ships Q8_0 and the numbers in `bench/results.md`
  describe the Mac. Re-bench before trusting them here.

## Data

| What | Where |
|---|---|
| Settings | `%APPDATA%\BisprBlow\settings.json` |
| History | `%APPDATA%\BisprBlow\history.json` (same format as the Mac) |
| Models | `%LOCALAPPDATA%\BisprBlow\models` |
| Log | `%LOCALAPPDATA%\BisprBlow\log.txt` |
