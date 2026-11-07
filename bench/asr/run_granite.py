#!/usr/bin/env python3
"""ibm-granite/granite-speech-4.1-2b via transformers. Runner contract: see README.md.

    .venv-granite/bin/python run_granite.py [--device mps|cpu] [--vocab vocab.txt] clips/*.wav

--vocab appends " Keywords: a, b, ..." to the prompt, the model's own keyword-biasing form.
"""
import argparse, json, sys, time
from pathlib import Path

import soundfile as sf
import torch
from transformers import AutoModelForSpeechSeq2Seq, AutoProcessor

MODEL = "ibm-granite/granite-speech-4.1-2b"
PROMPT = "transcribe the speech with proper punctuation and capitalization."

ap = argparse.ArgumentParser()
ap.add_argument("--vocab")
ap.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
ap.add_argument("files", nargs="+")
args = ap.parse_args()

prompt = PROMPT
if args.vocab:
    terms = [v.strip() for v in Path(args.vocab).read_text().splitlines() if v.strip()]
    prompt += " Keywords: " + ", ".join(terms)

s = time.perf_counter()
processor = AutoProcessor.from_pretrained(MODEL)
tok = processor.tokenizer
model = AutoModelForSpeechSeq2Seq.from_pretrained(MODEL, dtype=torch.bfloat16).to(args.device).eval()
chat = tok.apply_chat_template([{"role": "user", "content": "<|audio|>" + prompt}],
                               tokenize=False, add_generation_prompt=True)
print(f"load_ms={round((time.perf_counter() - s) * 1000)} device={args.device}", file=sys.stderr)


def transcribe(path):
    wav, sr = sf.read(path, dtype="float32")
    assert sr == 16000 and wav.ndim == 1, path
    inputs = processor(chat, torch.from_numpy(wav).unsqueeze(0), device=args.device,
                       return_tensors="pt").to(args.device)
    with torch.inference_mode():
        out = model.generate(**inputs, max_new_tokens=400, do_sample=False, num_beams=1)
    n = inputs["input_ids"].shape[-1]
    return tok.decode(out[0, n:], skip_special_tokens=True).strip()


transcribe(args.files[0])
for f in args.files:
    s = time.perf_counter()
    text = transcribe(f)
    ms = round((time.perf_counter() - s) * 1000)
    print(json.dumps({"file": Path(f).name, "text": text, "ms": ms}), flush=True)
