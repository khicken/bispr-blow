#!/usr/bin/env python3
"""Score results/<engine>.jsonl against prompts.txt.

Each results line: {"file": "c01.wav", "text": "...", "ms": 123}. ms is wall time to transcribe the
whole clip after it is complete, i.e. the wait after release for a batch engine.
WER is on lowercased, punctuation-free words. Term recall asks whether each dictionary term that is
in the reference came back spelled exactly (case-insensitive) - the failure the user reports.
"""
import json, os, re, sys, statistics
from pathlib import Path

HERE = Path(__file__).parent
RESULTS = Path(os.environ.get("RESULTS_DIR", HERE / "results"))


def norm(text):
    return re.sub(r"[^a-z0-9' ]+", " ", text.lower().replace("-", " ")).split()


def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
    return d[len(h)], len(r)


def terms_in(text, vocab):
    low = " " + " ".join(norm(text)) + " "
    return [t for t in vocab if " " + " ".join(norm(t)) + " " in low]


def main():
    refs = {}
    for line in (HERE / "prompts.txt").read_text().splitlines():
        if line and not line.startswith("#"):
            cid, text = line.split("|", 1)
            refs[cid] = text
    vocab = [v for v in (HERE / "vocab.txt").read_text().splitlines() if v.strip()]
    engines = sys.argv[1:] or sorted(p.stem for p in RESULTS.glob("*.jsonl"))

    rows = []
    for engine in engines:
        hyps = {}
        for line in (RESULTS / f"{engine}.jsonl").read_text().splitlines():
            if line.strip():
                rec = json.loads(line)
                hyps[Path(rec["file"]).stem] = rec
        errs = words = hit = want = 0
        ms_short, ms_long, misses = [], [], []
        for cid, ref in refs.items():
            if cid not in hyps:
                continue
            e, n = wer(ref, hyps[cid]["text"])
            errs, words = errs + e, words + n
            got = set(t.lower() for t in terms_in(hyps[cid]["text"], vocab))
            for t in terms_in(ref, vocab):
                want += 1
                if t.lower() in got:
                    hit += 1
                else:
                    misses.append(t)
            (ms_long if cid.startswith("l") else ms_short).append(hyps[cid]["ms"])
        if not words:
            continue
        rows.append((engine, len(hyps), 100 * errs / words, 100 * hit / max(want, 1),
                     statistics.median(ms_short) if ms_short else 0,
                     max(ms_long) if ms_long else 0, sorted(set(misses))))

    rows.sort(key=lambda r: (r[2], -r[3]))
    print("| engine | clips | WER % | term recall % | median ms (short) | max ms (long) |")
    print("|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r[0]} | {r[1]} | {r[2]:.1f} | {r[3]:.0f} | {r[4]:.0f} | {r[5]:.0f} |")
    print()
    for r in rows:
        print(f"- **{r[0]}** missed: {', '.join(r[6]) or 'none'}")


if __name__ == "__main__":
    main()
