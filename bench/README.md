# Cleanup benchmark

Measures the tradeoff between latency and quality for the cleanup stage, against
whatever models LM Studio has loaded.

```bash
./build.sh                                        # bench reads the prompt from the binary
python3 bench/bench.py                            # every loaded model
python3 bench/bench.py --models qwen3-0.6b-mlx
python3 bench/bench.py --nothink off              # measure what reasoning costs
```

The prompt comes from `BisprBlow --print-prompt`, so the benchmark always
tests what the app actually sends. `sanitize` and `looksTruncated` in bench.py
mirror LLMCleaner and need to stay in sync with it.

Each case in cases.json carries its own checks: words that must survive, fillers
that must be gone, and a minimum share of the transcript to retain. Quality is
the fraction of checks passed. A case is lossy when the app's own guard would
reject the result and fall back to rule-based cleaning.

## Findings

Reasoning is the whole ballgame. Qwen3 models think by default, and LM Studio's
MLX runtime ignores both `reasoning_effort` and `chat_template_kwargs`. Only the
`/no_think` switch on the last user message works.

| qwen3-0.6b-mlx | median | worst | quality | lossy |
|---|---|---|---|---|
| reasoning on | 2.28s | 8.69s | 75% | 2 of 7 |
| /no_think | 0.22s | 0.58s | 89% | 0 of 8 |

Ten times faster and better at the job, because a small model spends its
reasoning budget talking itself out of a correct answer.

Bigger is not better here. qwen3-1.7b costs 2.8x the latency for 84% quality,
losing points by leaving fillers in that the 0.6b removes. The 0.6b is the pick.

Quality is averaged over every rep, not read off one sample. These models are not
deterministic at temperature 0.2, and single-sample scoring swung a case by 30
points between identical runs.

The suite only exercises cleanup. Recognizer biasing (contextualStrings) cannot
be measured here, because cases start from text that was never spoken. The
draft_context case is a partial proxy: it checks whether an identifier present
only in the draft survives cleanup.

Both models still miss two things: applying self-corrections ("at 2 actually 3"
should become "at 3") and rendering spoken filenames (".env"). Those are prompt
problems, not capacity problems, and this suite is how to tell whether a prompt
change actually fixed them.
