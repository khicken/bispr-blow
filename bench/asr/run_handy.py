#!/usr/bin/env python3
"""Handy's dictation path (github.com/cjpais/Handy @ 1472087), reproduced for the ASR bench.

Same runtime and weights Handy ships: transcribe.cpp 0.4.2 (Handy pins the Rust crate 0.4.2; this
uses the Python binding of the same release, Metal backend, default model/session options) and the
GGUF files Handy's catalog pins, from Hugging Face at the catalog's revisions. Ported line for line
from Handy's Rust, with file references:

  capture VAD  managers/audio.rs, audio_toolkit/vad/{silero,smoothed,mod}.rs, audio/sink.rs
               Silero v6.2, threshold 0.3, 450 ms pre-roll, 60 ms onset, hangover 1650 ms for a
               streaming model and 450 ms otherwise. Only frames it passes reach the model.
  decode       managers/transcription/{policy,live}.rs. A streaming model (parakeet-unified, the
               top-ranked default) is streamed with StreamOptions::default() and finalized at
               release. Any other model is cut at pauses past 40 s (audio_toolkit/chunking.rs); no
               clip here keeps that much after the VAD, so that path is not ported and a
               longer clip fails an assert rather than being decoded differently from Handy.
  custom words audio_toolkit/text.rs apply_custom_words, threshold 0.18 (settings.rs). Parakeet
               has no transcribe.cpp vocabulary slot, so Handy always takes this fuzzy fallback.
  cleanup      text.rs remove_filler_words (on by default, English) + normalize_transcription_output.

Runner contract: README.md. ms = wait after release: the stream's finalize (its feeds run while
the user speaks) or the whole decode, plus post-processing.
"""
import argparse, json, os, re, sys, time

import numpy as np
import soundfile as sf
import transcribe_cpp as tc
from huggingface_hub import hf_hub_download

MODELS = {  # catalog.json: repository, revision, default (Q8_0) file
    "unified": ("handy-computer/parakeet-unified-en-0.6b-gguf",
                "7e948f21b7bdbac698d3318db9d350f1096f3b6c", "parakeet-unified-en-0.6b-Q8_0.gguf"),
    "ultra": ("handy-computer/parakeet-ultra-gguf",
              "39eeb55181f0d354fd934f06e92fd8d5037fed8e", "parakeet-ultra-Q8_0.gguf"),
}
VAD = ("handy-computer/silero-vad-v6.2-gguf",
       "97bbd75179f535e4708bccdf61e9278b8b60dfc7", "silero-vad-v6.2-F32.gguf")
RATE = 16000


def fetch(spec):
    repo, rev, name = spec
    return hf_hub_download(repo, name, revision=rev)


def frames_for(ms, frame):  # vad/mod.rs frames_for_duration_ms
    return -(-ms * RATE // (frame * 1000))


# ---- capture VAD: SileroVad wrapped in SmoothedVad ----

class CaptureVad:
    def __init__(self, vad_model, streaming):
        self.session = vad_model.vad_session(n_threads=1)
        self.frame = vad_model.vad_info.frame_samples
        self.prefill = frames_for(450, self.frame)
        self.onset = frames_for(60, self.frame)
        self.hangover = frames_for(1650 if streaming else 450, self.frame)

    def filter(self, pcm):
        """Every frame the recording keeps, in order (sink.rs process_chunk)."""
        self.session.stream_reset()
        buf, onset_n, hang_n, in_speech, out = [], 0, 0, False, []
        for i in range(0, len(pcm), self.frame):
            f = pcm[i:i + self.frame]
            if len(f) < self.frame:  # the recorder's last chunk is padded to a whole frame
                f = np.concatenate([f, np.zeros(self.frame - len(f), np.float32)])
            buf.append([f, False])
            del buf[:max(0, len(buf) - (self.prefill + 1))]
            voice = self.session.stream_feed(f).probs[0] > 0.3
            if not in_speech and voice:
                onset_n += 1
                if onset_n >= self.onset:
                    in_speech, hang_n, onset_n = True, self.hangover, 0
                    for b in buf:
                        if not b[1]:
                            out.append(b[0]); b[1] = True
            elif in_speech and voice:
                hang_n = self.hangover; buf[-1][1] = True; out.append(f)
            elif in_speech:
                if hang_n > 0:
                    hang_n -= 1; buf[-1][1] = True; out.append(f)
                else:
                    in_speech = False
            else:
                onset_n = 0
        return out


# ---- custom words (text.rs apply_custom_words) ----

def match_key(w):
    return "".join(c.lower() for c in w if c.isalnum())


def ascii_alnum(k):
    return bool(k) and all(c.isascii() and c.isalnum() for c in k)


def ascii_alpha(k):
    return bool(k) and all(c.isascii() and c.isalpha() for c in k)


def levenshtein(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def soundex_code(w):  # natural 0.5.0 phonetics.rs, quirks included (first letter kept raw)
    digit = {**dict.fromkeys("bfpv", "1"), **dict.fromkeys("cgjkqsxz", "2"),
             **dict.fromkeys("dt", "3"), "l": "4", "m": "5", "n": "5", "r": "6", "h": "9", "w": "9"}
    enc = [w[0]] + [digit.get(c, "0") for c in w[1:]]
    no_hw = [c for c in enc if c != "9"]
    dedup = [c for i, c in enumerate(no_hw) if i == 0 or c != no_hw[i - 1]]
    out = [c for c in dedup if c != "0"]
    return (out + ["0"] * 4)[:4]


def find_best(cand, words, keys, threshold):
    if not ascii_alnum(cand) or len(cand) > 50:
        return None
    best, best_score = None, float("inf")
    for idx, key in keys:
        max_len = max(len(cand), len(key))
        if abs(len(cand) - len(key)) > max(max_len * 0.25, 2.0):
            continue
        lev = levenshtein(cand, key) / max_len if max_len else 1.0
        phon = ascii_alpha(cand) and ascii_alpha(key) and soundex_code(cand) == soundex_code(key)
        score = lev * 0.3 if phon else lev
        if score < threshold and score < best_score:
            best, best_score = words[idx], score
    return (best, best_score) if best else None


def punct(word):
    s = next((i for i, c in enumerate(word) if c.isalnum()), len(word))
    e = next((i + 1 for i in range(len(word) - 1, -1, -1) if word[i].isalnum()), 0)
    return word[:s], word[e:]


def case_like(orig, repl):
    if all(c.isupper() for c in orig):
        return repl.upper()
    if orig[:1].isupper():
        return repl[:1].upper() + repl[1:]
    return repl


def apply_custom_words(text, words, threshold=0.18):
    if not words:
        return text
    keys = []
    for i, w in enumerate(words):
        k = match_key(w)
        if ascii_alnum(k):
            keys.append((i, k))
        if "&" in w:
            k2 = match_key(w.replace("&", " and "))
            if ascii_alnum(k2) and k2 != k:
                keys.append((i, k2))
    toks, out, i = text.split(), [], 0
    while i < len(toks):
        best = None
        for n in (3, 2, 1):
            if i + n > len(toks):
                continue
            ng = toks[i:i + n]
            if any(punct(w)[1] for w in ng[:n - 1]):
                continue
            m = find_best("".join(match_key(w) for w in ng), words, keys, threshold)
            if m and (best is None or m[1] < best[2]):
                best = (n, m[0], m[1])
        if best:
            n, repl, _ = best
            out.append(punct(toks[i])[0] + case_like(toks[i], repl) + punct(toks[i + n - 1])[1])
            i += n
        else:
            out.append(toks[i]); i += 1
    return " ".join(out)


# ---- fillers and normalisation (text.rs) ----

FILLERS = ["uh", "uhm", "umm", "uhh", "uhhh", "ehh", "ehm", "ahm", "hmm", "hm", "mmm", "хм", "ммм",
           "um", "ah", "eh"]  # universal + English-gated (language known: 'en')


def remove_fillers(text):
    for w in FILLERS:
        pat = re.compile(r"\b%s\b[,.]?" % re.escape(w), re.I)
        kept, resume, owed = "", 0, False

        def push(seg):
            nonlocal kept, owed
            if owed:
                j = next((k for k, c in enumerate(seg) if c.isalnum()), None)
                if j is not None:
                    owed = False
                    kept += seg[:j] + seg[j].upper() + seg[j + 1:]
                    return
            kept += seg
        for m in pat.finditer(text):
            push(text[resume:m.start()])
            tail = kept.rstrip()
            opens = not tail or tail[-1] in ".!?…"
            owed |= m.group()[0].isupper() and opens
            resume = m.end()
        push(text[resume:])
        text = kept
    return text


def normalize(text):
    ws, out, i = text.split(), [], 0
    while i < len(ws):
        w = ws[i]
        if all(c.isalpha() for c in w.lower()):
            n = 1
            while i + n < len(ws) and ws[i + n].lower() == w.lower():
                n += 1
            out.append(w); i += n if n >= 3 else 1
        else:
            out.append(w); i += 1
    return re.sub(r"\s{2,}", " ", " ".join(out)).strip()


def post_process(text, vocab):
    text = apply_custom_words(text, vocab) if vocab else text
    text = normalize(remove_fillers(text))
    return text if any(c.isalnum() for c in text) else ""


# ---- engine ----

def transcribe(path, model, session, vad_model, streaming, vocab):
    pcm, sr = sf.read(path, dtype="float32")
    if pcm.ndim > 1:
        pcm = pcm.mean(axis=1)
    assert sr == RATE, f"{path}: {sr} Hz, Handy records at 16 kHz"
    frames = CaptureVad(vad_model, streaming).filter(pcm)
    if not frames:
        return "", 0, {}
    if streaming:
        st = session.stream(timestamps="auto")
        for f in frames:  # one feed per VAD frame, as the recorder delivers them
            st.feed(f)
        t0 = time.perf_counter()
        st.finalize()
        raw = st.text().full
    else:
        kept = np.concatenate(frames)
        assert len(kept) <= 40 * RATE, f"{path}: over 40 s kept; Handy would chunk it"
        t0 = time.perf_counter()
        raw = session.run(kept).text
    text = post_process(raw, vocab)
    ms = round((time.perf_counter() - t0) * 1000)
    return text, ms, {"kept_s": round(sum(len(f) for f in frames) / RATE, 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", choices=MODELS, default="unified")
    ap.add_argument("--vocab")
    ap.add_argument("files", nargs="+")
    a = ap.parse_args()
    vocab = [l.strip() for l in open(a.vocab) if l.strip()] if a.vocab else []
    t0 = time.perf_counter()
    vad_model = tc.Model(fetch(VAD), backend="cpu")  # silero.rs: Backend::Cpu
    model = tc.Model(fetch(MODELS[a.model]))
    session = model.session()
    streaming = model.capabilities.supports_streaming
    transcribe(a.files[0], model, session, vad_model, streaming, vocab)  # warm
    print(f"load_ms={round((time.perf_counter() - t0) * 1000)} backend={model.backend} "
          f"streaming={streaming}", file=sys.stderr)
    for f in a.files:
        text, ms, extra = transcribe(f, model, session, vad_model, streaming, vocab)
        print(json.dumps({"file": os.path.basename(f), "text": text, "ms": ms, **extra}), flush=True)


if __name__ == "__main__":
    main()
