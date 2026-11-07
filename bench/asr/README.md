# ASR bench

Compares speech-to-text engines against Apple's SpeechTranscriber (what the app ships) on the
user's own voice, reading `prompts.txt`. Speed after release matters as much as accuracy.

- `prompts.txt`: clip id and reference text. `c*` are short dictations, `l*` are 45-60 s.
- `vocab.txt`: the user's dictionary plus the app's built-in terms, one per line.
- `record.sh`: records `clips/<id>.wav` (16 kHz mono) from the mic.
- `apple_transcribe.swift`: the baseline, configured like `Transcriber.swift`.
- `run_<engine>.*`: one runner per engine.
- `score.py [engine ...]`: WER, dictionary-term recall and latency from `results/<engine>.jsonl`.

## Runner contract

Every runner takes `[--vocab vocab.txt] file1.wav file2.wav ...` and prints one JSON line per file
to stdout: `{"file": "c01.wav", "text": "...", "ms": 123}`. `ms` is wall time from complete audio
to final text, with the model already loaded and warmed on one throwaway clip: the wait after
release. Print the model load time once to stderr as `load_ms=<n>`. Engines with a vocabulary hook
get a second engine name with a `-vocab` suffix.

Time engines one at a time. Two models sharing the GPU or Neural Engine make both look slow.

```bash
./record.sh
swift apple_transcribe.swift --vocab vocab.txt clips/*.wav > results/apple.jsonl
python3 score.py
```
