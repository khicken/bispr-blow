#!/usr/bin/env python3
"""mlx-audio runners: Qwen3-ASR 1.7B and 0.6B, Nemotron 3.5 streaming 0.6B.

    .venv-mlxaudio/bin/python run_mlx_audio.py --engine qwen3-asr-1.7b [--vocab vocab.txt] clips/*.wav

--engine is qwen3-asr-1.7b, qwen3-asr-0.6b or nemotron-stream. With --vocab, Qwen3-ASR gets the
terms through mlx-audio's `hotwords`, which it joins into the system prompt (Qwen3-ASR's free-text
context field); the engine is then the -vocab variant. Nemotron has no vocabulary hook.

nemotron-stream reports `ms` as a batch transcription of the whole file, per the contract, and adds
`tail_ms`: the same audio fed through a streaming session one native encoder chunk at a time, every
chunk but the last fully decoded first, then the time to feed the last chunk, close and drain. That
is the wait after release for a live-streaming integration. Its `stream_text` is the streamed
transcript, so the two paths can be compared.

Cohere Transcribe is supported by mlx-audio but not run here: the official weights are 4.1 GB.
"""
import argparse, json, sys, time
from pathlib import Path

REPOS = {
    "qwen3-asr-1.7b": "mlx-community/Qwen3-ASR-1.7B-8bit",
    "qwen3-asr-0.6b": "mlx-community/Qwen3-ASR-0.6B-8bit",
    "nemotron-stream": "mlx-community/nemotron-3.5-asr-streaming-0.6b",
}


def qwen(model, vocab):
    return lambda path: {"text": model.generate(path, language="English", hotwords=vocab or None).text}


def nemotron(model):
    import numpy as np
    from mlx_audio.stt.utils import load_audio

    rate = model.preprocessor_config.sample_rate

    def drain(session):
        out = []
        while session._audio or session._encoded:
            out += session.step(max_decode_tokens=1 << 20)
        return out

    def stream(path):
        audio = np.array(load_audio(path, rate))
        session = model.create_streaming_session(language="en-US")
        size = session._encoder.chunk_mel * model.preprocessor_config.hop_length
        chunks = [audio[i:i + size] for i in range(0, len(audio), size)]
        out = []
        for chunk in chunks[:-1]:
            session.feed(chunk)
            out += drain(session)
        t = time.perf_counter()
        session.feed(chunks[-1])
        session.close()
        while not session.done:
            out += session.step(max_decode_tokens=1 << 20)
        return "".join(out), round((time.perf_counter() - t) * 1000)

    def run(path):
        text = model.generate(path, language="en-US").text
        return {"text": text, "stream": stream}

    return run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=list(REPOS))
    ap.add_argument("--vocab")
    ap.add_argument("files", nargs="+")
    args = ap.parse_args()
    vocab = [v.strip() for v in Path(args.vocab).read_text().splitlines() if v.strip()] if args.vocab else []
    if vocab and args.engine == "nemotron-stream":
        sys.exit("nemotron-stream has no vocabulary hook")

    from mlx_audio.stt import load

    t = time.perf_counter()
    model = load(REPOS[args.engine])
    run = nemotron(model) if args.engine == "nemotron-stream" else qwen(model, vocab)
    print(f"load_ms={round((time.perf_counter() - t) * 1000)}", file=sys.stderr)

    warm = run(args.files[0])  # warm-up on a throwaway pass, per the contract
    if "stream" in warm:
        warm["stream"](args.files[0])
    for f in args.files:
        t = time.perf_counter()
        res = run(f)
        rec = {"file": Path(f).name, "text": res["text"].strip(), "ms": round((time.perf_counter() - t) * 1000)}
        if "stream" in res:
            rec["stream_text"], rec["tail_ms"] = res["stream"](f)
            rec["stream_text"] = rec["stream_text"].strip()
        print(json.dumps(rec), flush=True)


if __name__ == "__main__":
    main()
