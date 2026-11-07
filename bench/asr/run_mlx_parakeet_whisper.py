#!/usr/bin/env python3
"""MLX runners: Parakeet TDT 0.6b v2 (parakeet-mlx) and Whisper large-v3-turbo (mlx-whisper).

    .venv-mlx/bin/python run_mlx_parakeet_whisper.py --engine parakeet-mlx-v2 [--vocab vocab.txt] clips/*.wav

--engine is parakeet-mlx-v2 or whisper-turbo. With --vocab the engine is the -vocab variant:
Parakeet switches to beam decoding with a word booster over every term (greedy has no booster),
Whisper gets the terms as initial_prompt. Output follows the contract in README.md.
"""
import argparse, json, sys, time
from pathlib import Path

PARAKEET_REPO = "mlx-community/parakeet-tdt-0.6b-v2"
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
PATIENCE = 50.0
BOOST = 4.0  # log-prob bonus per boosted word; the value parakeet-mlx's own README example uses


def parakeet(vocab):
    from parakeet_mlx import Beam, DecodingConfig, boost, from_pretrained

    model = from_pretrained(PARAKEET_REPO)
    config = DecodingConfig()
    if vocab:
        # Beam stops once beam_size * patience hypotheses reach the end of the audio, and TDT
        # hypotheses that skip the tail with a long duration get there first: at the default
        # patience of 1 almost every clip lost its last word ("...run the build." -> "...run the bu"),
        # booster or not. 50 recovered all of them on the TTS clips for ~0.1-0.2 s.
        weights = {t: BOOST for t in vocab}
        config = DecodingConfig(decoding=Beam(patience=PATIENCE, booster=boost.lift(
            boost.words(weights, boundary=True), model.vocabulary)))
    return lambda path: model.transcribe(path, decoding_config=config).text


def whisper(vocab):
    import mlx.core as mx
    import mlx_whisper
    from mlx_whisper.transcribe import ModelHolder

    ModelHolder.get_model(WHISPER_REPO, mx.float16)  # the cache transcribe() reads, fp16 is its default
    prompt = f"Terms: {', '.join(vocab)}." if vocab else None
    return lambda path: mlx_whisper.transcribe(
        path, path_or_hf_repo=WHISPER_REPO, language="en", initial_prompt=prompt)["text"].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=["parakeet-mlx-v2", "whisper-turbo"])
    ap.add_argument("--vocab")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    vocab = [v.strip() for v in Path(args.vocab).read_text().splitlines() if v.strip()] if args.vocab else []

    t = time.perf_counter()
    run = {"parakeet-mlx-v2": parakeet, "whisper-turbo": whisper}[args.engine](vocab)
    print(f"load_ms={round((time.perf_counter() - t) * 1000)}", file=sys.stderr)

    run(args.files[0])  # warm-up on a throwaway pass, per the contract
    for f in args.files:
        t = time.perf_counter()
        text = run(f)
        ms = round((time.perf_counter() - t) * 1000)
        print(json.dumps({"file": Path(f).name, "text": text.strip(), "ms": ms}), flush=True)


if __name__ == "__main__":
    main()
