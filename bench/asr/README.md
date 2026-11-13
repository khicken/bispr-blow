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

## Streaming harness

`fluid/Sources/stream-bench` asks whether streaming would cut the wait after release. `--mode batch`
is the shipped path split into stages; `--mode stream` feeds a `SlidingWindowAsrManager` in
`--feed-ms` buffers (default 100) and computes the dictionary's CTC pass during speech. `run_all.sh`
does not call it. It applies only the built-in `mishears` table, never the user's heard-as aliases, so
its numbers are not comparable to `summary.md`'s `app` row (different dictionary).

Inputs are 48 kHz copies of the clips, so the resample path is exercised:

```bash
mkdir -p clips48
for f in clips/*.wav; do ffmpeg -y -i "$f" -ar 48000 -ac 1 -c:a pcm_f32le "clips48/$(basename "$f")"; done
cd fluid && swift build -c release --disable-keychain --product stream-bench && cd ..
SB=fluid/.build/release/stream-bench
$SB --mode batch --vocab vocab.txt clips48/*.wav > results/stream-bench-batch.jsonl
$SB --mode batch --vocab vocab.txt clips48/*.wav > results/stream-bench-batch2.jsonl
$SB --mode stream --vocab vocab.txt --chunk 11 --left 2 --right 2 clips48/*.wav > results/stream-sw11.jsonl
$SB --mode stream --vocab vocab.txt --chunk 11 --left 2 --right 2 --parallel clips48/*.wav > results/stream-sw11-par.jsonl
$SB --mode stream --vocab vocab.txt --chunk 5 --left 8 --right 2 clips48/*.wav > results/stream-sw5.jsonl
$SB --mode stream --vocab vocab.txt --chunk 5 --left 8 --right 2 --parallel clips48/*.wav > results/stream-sw5-par.jsonl
```

`stream-bench-batch2` is a repeat run of the same command, for run-to-run noise.
