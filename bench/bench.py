#!/usr/bin/env python3
"""Latency vs quality benchmark for Bluejay Wispr's cleanup stage.

Runs every case in cases.json through each model on the local OpenAI-compatible
server, using the app's own prompt (read from the binary via --print-prompt, so
the bench can never drift from what ships).

  python3 bench/bench.py                          # every loaded model
  python3 bench/bench.py --models qwen3-0.6b-mlx  # one model
  python3 bench/bench.py --nothink off            # measure the reasoning cost
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
BINARY = ROOT / ".build/release/BluejayWispr"
BASE = "http://127.0.0.1:1234/v1"


def post(path, payload, timeout):
    request = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def app_prompt():
    """The system prompt + few-shot the app actually sends."""
    if not BINARY.exists():
        raise SystemExit(f"build first: ./build.sh  (missing {BINARY})")
    out = subprocess.run([str(BINARY), "--print-prompt"], capture_output=True, text=True)
    return json.loads(out.stdout)


def loaded_models():
    with urllib.request.urlopen(BASE + "/models", timeout=5) as response:
        ids = [m["id"] for m in json.load(response)["data"]]
    return [i for i in ids if not any(s in i.lower() for s in ("embed", "whisper"))]


def app_tail(model_output, raw):
    """The text the app would actually insert. Runs in the binary (`--finish`) instead of being
    reimplemented here, so unwrapping, the truncation guard and the deterministic filler pass
    cannot drift from LLMCleaner. Returns (text, lossy)."""
    done = subprocess.run([str(BINARY), "--finish"], capture_output=True, text=True,
                          input=json.dumps({"raw": raw, "cleaned": model_output}))
    result = json.loads(done.stdout)
    return result["text"], result["lossy"]


def score(case, cleaned, lossy):
    """Fraction of the case's checks that passed, plus what failed."""
    checks, failures = [], []
    low = cleaned.lower()
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
        failures.append("LOSSY: guard rejected it, rules ran instead")
    return (sum(checks) / len(checks) if checks else 0.0), failures


def run_case(model, prefix, case, nothink, timeout):
    user = f"App: {case['app']}"
    if case.get("draft"):
        user += f"\nAlready typed (context only, do not clean or repeat): {case['draft']}"
    user += f"\nTranscript: {case['raw']}"
    if nothink == "on" or (nothink == "auto" and "qwen3" in model.lower()):
        user += " /no_think"
    payload = {
        "model": model,
        "temperature": 0.2,
        "max_tokens": 2048,
        "messages": prefix + [{"role": "user", "content": user}],
    }
    started = time.monotonic()
    data = post("/chat/completions", payload, timeout)
    elapsed = time.monotonic() - started
    message = data["choices"][0]["message"]
    # Mirrors LLMCleaner: LM Studio files a /no_think answer under reasoning_content.
    text = message.get("content") or message.get("reasoning_content") or ""
    usage = data.get("usage", {}).get("completion_tokens_details", {})
    cleaned, lossy = app_tail(text, case["raw"])
    return {
        "seconds": elapsed,
        "cleaned": cleaned,
        "lossy": lossy,
        "reasoning_tokens": usage.get("reasoning_tokens", 0),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", nargs="*", help="default: every loaded chat model")
    parser.add_argument("--reps", type=int, default=3, help="timed runs per case")
    parser.add_argument("--nothink", choices=["auto", "on", "off"], default="auto")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--out", default=str(Path(__file__).parent / "results.md"))
    args = parser.parse_args()

    cases = json.loads((Path(__file__).parent / "cases.json").read_text())
    prefix = app_prompt()
    models = args.models or loaded_models()
    print(f"{len(models)} model(s), {len(cases)} cases, {args.reps} reps, nothink={args.nothink}\n")

    rows, details = [], []
    for model in models:
        latencies, scores, lossy, reasoning = [], [], 0, []
        try:
            run_case(model, prefix, cases[0], args.nothink, args.timeout)  # load + warm cache
        except Exception as error:
            print(f"{model}: unavailable ({error})")
            continue
        for case in cases:
            times, rep_scores, last, failures = [], [], None, []
            for _ in range(args.reps):
                try:
                    result = run_case(model, prefix, case, args.nothink, args.timeout)
                except (urllib.error.URLError, TimeoutError, OSError) as error:
                    print(f"  {model} / {case['name']}: {error}")
                    break
                times.append(result["seconds"])
                reasoning.append(result["reasoning_tokens"])
                # Every rep is scored: these models are not deterministic at temperature 0.2,
                # and scoring one sample per case made quality swing 30 points between runs.
                rep_score, rep_failures = score(case, result["cleaned"], result["lossy"])
                rep_scores.append(rep_score)
                failures = rep_failures or failures
                last = result
            if not times or last is None:
                continue
            case_score = statistics.mean(rep_scores)
            latencies.append(statistics.median(times))
            scores.append(case_score)
            if any(f.startswith("LOSSY") for f in failures):
                lossy += 1
            print(f"  {model:34} {case['name']:24} {statistics.median(times):5.2f}s  {case_score:4.0%}"
                  f"  {'; '.join(failures) if failures else 'ok'}")
            details.append((model, case["name"], statistics.median(times), case_score,
                            failures, last["cleaned"]))
        if latencies:
            rows.append({
                "model": model,
                "median_s": statistics.median(latencies),
                "worst_s": max(latencies),
                "quality": statistics.mean(scores),
                "lossy": lossy,
                "reasoning": statistics.median(reasoning) if reasoning else 0,
            })
        print()

    rows.sort(key=lambda r: (-r["quality"], r["median_s"]))
    lines = [f"# Cleanup benchmark (nothink={args.nothink}, reps={args.reps})", "",
             "| model | median | worst case | quality | lossy cases | reasoning tokens |",
             "|---|---|---|---|---|---|"]
    for row in rows:
        lines.append(f"| {row['model']} | {row['median_s']:.2f}s | {row['worst_s']:.2f}s | "
                     f"{row['quality']:.0%} | {row['lossy']}/{len(cases)} | {row['reasoning']:.0f} |")
    lines += ["", "## Per case", ""]
    for model, name, seconds, case_score, failures, cleaned in details:
        lines += [f"**{model} / {name}** {seconds:.2f}s {case_score:.0%} "
                  f"{'; '.join(failures) if failures else 'ok'}", "", f"> {cleaned}", ""]
    Path(args.out).write_text("\n".join(lines) + "\n")

    print("\n".join(lines[:4 + len(rows)]))
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
