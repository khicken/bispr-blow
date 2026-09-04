#!/usr/bin/env python3
"""Latency vs quality benchmark for Bluejay Wispr's cleanup stage.

Runs every case in cases.json through each model on the local OpenAI-compatible
server, using the app's own prompts (read from the binary via --print-prompt, so
the bench can never drift from what ships). Cases whose app is "(coding)" get the
low-touch prompt and the subsequence guard, exactly as the app picks them.

Recall is the headline number: the fraction of the speaker's content words that
survive. `quality` counts per-case assertions and `retain` counts words, and a
rewrite that swaps words while keeping the count scores full marks on both.

  python3 bench/bench.py                            # every loaded model
  python3 bench/bench.py --models qwen3-4b-2507     # the shipped default
  python3 bench/bench.py --nothink off              # measure the reasoning cost
  python3 bench/bench.py --deadline-per-word 10      # try a looser budget
"""
import argparse
import json
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BINARY = ROOT / ".build/release/BisprBlow"
BASE = "http://127.0.0.1:1234/v1"


def post(path, payload, timeout):
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


class InProcessEngine:
    """Drives the binary's --complete NDJSON loop: one process, model loaded once, every case
    warm — the same conditions the app runs in. A process per case would measure cold loads."""

    def __init__(self):
        self.proc = subprocess.Popen([str(BINARY), "--complete"], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     text=True, bufsize=1)

    def models(self):
        out = subprocess.run([str(BINARY), "--list-models"], capture_output=True, text=True)
        return [line for line in out.stdout.splitlines() if line.strip()]

    def chat(self, payload):
        self.proc.stdin.write(json.dumps({"model": payload["model"],
                                          "messages": payload["messages"]}) + "\n")
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["content"]


def app_prompts():
    """Both prompt variants the app sends, {"default": [...], "lowTouch": [...]}."""
    if not BINARY.exists():
        raise SystemExit(f"build first: ./build.sh  (missing {BINARY})")
    out = subprocess.run([str(BINARY), "--print-prompt"], capture_output=True, text=True)
    return json.loads(out.stdout)


def is_low_touch(case):
    """The category the app switches prompts on is already encoded in `app`."""
    return "(coding)" in case["app"]


# Fillers belong here alongside the function words: cleanup is *supposed* to delete them, and
# counting them as lost content marks a correct cleanup down by the transcript's filler share.
# Spoken symbol names likewise: "underscore" rendered as "_" is correct, not a lost word.
STOPWORDS = set("""
underscore hyphen dash dot paren parens period colon semicolon slash
um umm uh uhh er erm ah like know okay so yeah just really actually maybe
the a an and or but if then that this these those there here it its it's is are was were be been
being have has had do does did doing done will would should could can cannot may might must
i i'm i've me my we we're we've our you you're your he she they them their as at by for from in
into of off on onto out over to too under up with without not no nor
""".split())


def content_words(text):
    words = [w.strip(".,;:!?\"'()[]{}-—").lower() for w in text.split()]
    return {w for w in words if len(w) >= 3 and w not in STOPWORDS and any(c.isalnum() for c in w)}


def recall(raw, cleaned):
    """Fraction of the speaker's content words that survived. A rewrite that swaps words while
    keeping the word count scores 100% on `retain` and badly here."""
    spoken = content_words(raw)
    if not spoken:
        return 1.0
    return len(spoken & content_words(cleaned)) / len(spoken)


def loaded_models():
    with urllib.request.urlopen(BASE + "/models", timeout=5) as response:
        ids = [m["id"] for m in json.load(response)["data"]]
    return [i for i in ids if not any(s in i.lower() for s in ("embed", "whisper"))]


def app_tail(model_output, case):
    """The text the app would actually insert. Runs in the binary (`--finish`) instead of being
    reimplemented here, so unwrapping, the guards and the deterministic filler pass cannot drift
    from LLMCleaner. Returns (text, lossy, reworded, reason)."""
    done = subprocess.run([str(BINARY), "--finish"], capture_output=True, text=True,
                          input=json.dumps({"raw": case["raw"], "cleaned": model_output,
                                            "lowTouch": is_low_touch(case),
                                            "draftTerms": case.get("draft", "").split()}))
    result = json.loads(done.stdout)
    return result["text"], result["lossy"], result["reworded"], result.get("reason")


def score(case, cleaned, lossy, reworded, reason=None):
    """Fraction of the case's checks that passed, plus what failed."""
    checks, failures = [], []
    low = cleaned.lower()
    if reworded:
        failures.append("REWORDED: subsequence guard rejected it, rules ran instead")
    for needle in case["must_include"]:
        ok = needle.lower() in low
        checks.append(ok)
        if not ok:
            failures.append(f"missing {needle!r}")
    for needle in case["must_exclude"]:
        ok = needle.lower() not in low
        checks.append(ok)
        if not ok:
            failures.append(f"kept {needle!r}")
    ratio = len(cleaned.split()) / max(1, len(case["raw"].split()))
    ok = ratio >= case["retain"]
    checks.append(ok)
    if not ok:
        failures.append(f"retained {ratio:.0%} < {case['retain']:.0%}")
    if lossy:
        checks.append(False)
        failures.append(f"LOSSY ({reason}): guard rejected it, rules ran instead")
    return (sum(checks) / len(checks) if checks else 0.0), failures


def run_case(model, prompts, case, nothink, timeout, engine=None):
    prefix = prompts["lowTouch" if is_low_touch(case) else "default"]
    user = f"App: {case['app']}"
    if case.get("draft"):
        user += f"\nAlready typed (context only, do not clean or repeat): {case['draft']}"
    user += f"\nTranscript: {case['raw']}"
    if nothink == "on" or (nothink == "auto" and "qwen3" in model.lower()):
        user += "\n/no_think"  # own line: glued to the transcript the coding path copies it
    payload = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 2048,
        "messages": prefix + [{"role": "user", "content": user}],
    }
    started = time.monotonic()
    if engine:
        # Timed by wall clock like the HTTP path, not the binary's own ms, so the
        # transports are compared honestly.
        text = engine.chat(payload)
        usage = {}
    else:
        data = post("/chat/completions", payload, timeout)
        message = data["choices"][0]["message"]
        # Mirrors LLMCleaner: LM Studio files a /no_think answer under reasoning_content.
        text = message.get("content") or message.get("reasoning_content") or ""
        usage = data.get("usage", {}).get("completion_tokens_details", {})
    elapsed = time.monotonic() - started
    cleaned, lossy, reworded, reason = app_tail(text, case)
    return {
        "seconds": elapsed,
        "cleaned": cleaned,
        "lossy": lossy,
        "reworded": reworded,
        "reason": reason,
        "recall": recall(case["raw"], cleaned),
        "reasoning_tokens": usage.get("reasoning_tokens", 0),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="*", help="default: every loaded chat model")
    parser.add_argument("--reps", type=int, default=3, help="timed runs per case")
    parser.add_argument("--nothink", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--deadline-base", type=int, default=900,
                        help="latency budget floor in ms; must match LLMCleaner.deadlineMs")
    parser.add_argument("--deadline-per-word", type=int, default=6,
                        help="ms added per spoken word; must match LLMCleaner.deadlineMs")
    parser.add_argument("--engine", choices=["http", "inprocess"], default="http",
                        help="inprocess drives the binary's --complete loop instead of LM Studio")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--out", default=str(Path(__file__).parent / "results.md"))
    args = parser.parse_args()

    cases = json.loads((Path(__file__).parent / "cases.json").read_text())
    prompts = app_prompts()
    engine = InProcessEngine() if args.engine == "inprocess" else None
    models = args.models or (engine.models() if engine else loaded_models())
    def deadline(case):
        return min(2500, args.deadline_base + args.deadline_per_word * len(case["raw"].split()))

    print(f"{len(models)} model(s), {len(cases)} cases, {args.reps} reps, nothink={args.nothink}, "
          f"deadline={args.deadline_base}ms+{args.deadline_per_word}ms/word\n")

    rows, details = [], []
    for model in models:
        latencies, all_times, scores, recalls = [], [], [], []
        lossy, reworded, over, reasoning = 0, 0, 0, []
        try:
            run_case(model, prompts, cases[0], args.nothink, args.timeout, engine)  # load + warm cache
        except Exception as error:
            print(f"{model}: unavailable ({error})")
            continue
        for case in cases:
            times, rep_scores, rep_recalls, last, failures = [], [], [], None, []
            for _ in range(args.reps):
                try:
                    result = run_case(model, prompts, case, args.nothink, args.timeout, engine)
                except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as error:
                    print(f"  {model} / {case['name']}: {error}")
                    break
                times.append(result["seconds"])
                reasoning.append(result["reasoning_tokens"])
                # Every rep is scored: these models are not deterministic at temperature 0.2,
                # and scoring one sample per case made quality swing 30 points between runs.
                rep_score, rep_failures = score(case, result["cleaned"], result["lossy"],
                                               result["reworded"], result["reason"])
                rep_scores.append(rep_score)
                rep_recalls.append(result["recall"])
                failures = rep_failures or failures
                last = result
            if not times or last is None:
                continue
            case_score = statistics.mean(rep_scores)
            case_recall = statistics.mean(rep_recalls)
            median = statistics.median(times)
            latencies.append(median)
            all_times.extend(times)
            scores.append(case_score)
            recalls.append(case_recall)
            if any(f.startswith("LOSSY") for f in failures):
                lossy += 1
            if any(f.startswith("REWORDED") for f in failures):
                reworded += 1
            if median * 1000 > deadline(case):
                over += 1
            # A case over the deadline has not passed however good it scored: it ships as rules.
            missed = " MISSED DEADLINE" if median * 1000 > deadline(case) else ""
            print(f"  {model:34} {case['name']:24} {median:5.2f}s  {case_score:4.0%}"
                  f"  r{case_recall:4.0%}  {'; '.join(failures) if failures else 'ok'}{missed}")
            details.append((model, case["name"], median, case_score, case_recall,
                            deadline(case), failures, last["cleaned"]))
        if latencies:
            ordered = sorted(all_times)
            rows.append({
                "model": model,
                "median_s": statistics.median(latencies),
                "p95_s": ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))],
                "worst_s": max(latencies),
                "quality": statistics.mean(scores),
                "recall": statistics.mean(recalls),
                "over": over,
                "lossy": lossy,
                "reworded": reworded,
                "reasoning": statistics.median(reasoning) if reasoning else 0,
            })
        print()

    # Recall leads the sort: it is the only metric that sees a word-for-word swap.
    rows.sort(key=lambda r: (-r["recall"], -r["quality"], r["median_s"]))
    lines = [f"# Cleanup benchmark (nothink={args.nothink}, reps={args.reps}, "
             f"deadline={args.deadline_base}ms+{args.deadline_per_word}ms/word)", "",
             "| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |",
             "|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        lines.append(f"| {row['model']} | {row['recall']:.0%} | {row['quality']:.0%} | "
                     f"{row['median_s']:.2f}s | {row['p95_s']:.2f}s | {row['worst_s']:.2f}s | "
                     f"{row['over']}/{len(cases)} | {row['lossy']}/{len(cases)} | "
                     f"{row['reworded']}/{len(cases)} |")
    lines += ["", "## Per case", ""]
    for model, name, seconds, case_score, case_recall, budget, failures, cleaned in details:
        flag = f" **over {budget}ms budget**" if seconds * 1000 > budget else ""
        lines += [f"**{model} / {name}** {seconds:.2f}s {case_score:.0%} recall {case_recall:.0%}"
                  f"{flag} {'; '.join(failures) if failures else 'ok'}", "", f"> {cleaned}", ""]
    Path(args.out).write_text("\n".join(lines) + "\n")

    print("\n".join(lines[:4 + len(rows)]))
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
