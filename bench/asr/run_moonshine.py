#!/usr/bin/env python3
"""Moonshine streaming medium (moonshine-voice, ONNX on CPU). Runner contract: see README.md.

    .venv-moonshine/bin/python run_moonshine.py [--vocab vocab.txt] clips/*.wav

Each clip runs twice. `ms`/`text` is the batch decode of the whole clip. `tail_ms`/`stream_text` is
the streaming path: chunks fed as fast as the engine takes them (its own passes run along the way, as
they would live), then `tail_ms` is stop() alone, i.e. the wait after release when streaming.
--vocab sets Moonshine's key-term bias.
"""
import argparse, json, sys, time, wave
from pathlib import Path

import numpy as np
from moonshine_voice import ModelArch, Transcriber, get_model_for_language

CHUNK = 1600


def load(path):
    with wave.open(path) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, path
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        return (pcm.astype(np.float32) / 32768).tolist(), w.getframerate()


def text_of(transcript):
    return " ".join(l.text.strip() for l in transcript.lines if l.text.strip())


def run(t, path):
    audio, sr = load(path)
    s = time.perf_counter()
    batch = text_of(t.transcribe_without_streaming(audio, sr))
    ms = round((time.perf_counter() - s) * 1000)

    stream = t.create_stream()
    stream.start()
    for i in range(0, len(audio), CHUNK):
        stream.add_audio(audio[i:i + CHUNK], sr)
    s = time.perf_counter()
    final = stream.stop()
    tail_ms = round((time.perf_counter() - s) * 1000)
    stream.close()
    return {"file": Path(path).name, "text": batch, "ms": ms,
            "tail_ms": tail_ms, "stream_text": text_of(final)}


ap = argparse.ArgumentParser()
ap.add_argument("--vocab")
ap.add_argument("files", nargs="+")
args = ap.parse_args()

model_path, arch = get_model_for_language("en", ModelArch.MEDIUM_STREAMING)
s = time.perf_counter()
t = Transcriber(model_path, arch)
if args.vocab:
    t.set_keyterms([v.strip() for v in Path(args.vocab).read_text().splitlines() if v.strip()])
print(f"load_ms={round((time.perf_counter() - s) * 1000)}", file=sys.stderr)
run(t, args.files[0])

for f in args.files:
    print(json.dumps(run(t, f)), flush=True)
