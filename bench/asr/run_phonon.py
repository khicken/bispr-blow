#!/usr/bin/env python3
"""Phonon-2.5-English (fermion-research, MLX). Runner contract: see README.md.

    .venv-phonon/bin/python run_phonon.py [--vocab vocab.txt] clips/*.wav

--vocab uses Phonon's hotword bias, which takes at most 25 words: the first 25 of the file are used.
"""
import argparse, json, sys, time
from pathlib import Path

from fermion import transcribe as T
from fermion._speech import backends, fetch

ap = argparse.ArgumentParser()
ap.add_argument("--vocab")
ap.add_argument("files", nargs="+")
args = ap.parse_args()

t0 = time.perf_counter()
repo, key, pin, _ = T._resolve("phonon-2.5-en")
engine_kind = backends.resolve("run_phonon")
model_dir = fetch.ensure(repo, key, pin)
t1 = time.perf_counter()
speech = backends.load(engine_kind, model_dir, profile=key, backend=pin["backend"], quiet=True)
if args.vocab:
    n = speech.set_hotwords(T._read_hotword_file(args.vocab))
    print(f"hotwords={n}", file=sys.stderr)
print(f"load_ms={round((time.perf_counter() - t1) * 1000)} fetch_ms={round((t1 - t0) * 1000)}", file=sys.stderr)
speech.transcribe_detailed(args.files[0])

for f in args.files:
    s = time.perf_counter()
    text = speech.transcribe_detailed(f).triple()[0]
    ms = round((time.perf_counter() - s) * 1000)
    print(json.dumps({"file": Path(f).name, "text": text, "ms": ms}), flush=True)
