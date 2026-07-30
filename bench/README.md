# Cleanup benchmark

Measures the tradeoff between latency and quality for the cleanup stage, against
whatever models LM Studio has loaded.

```bash
./build.sh                                        # bench reads the prompt from the binary
python3 bench/bench.py                            # every loaded model
python3 bench/bench.py --models qwen3-0.6b-mlx
python3 bench/bench.py --nothink off              # measure what reasoning costs
```

The prompt comes from `BluejayWispr --print-prompt`, so the benchmark always
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
| /no_think | 0.23s | 0.56s | 92% | 0 of 7 |

Ten times faster and better at the job, because a small model spends its
reasoning budget talking itself out of a correct answer.

Bigger is not better here. qwen3-1.7b costs 2.4x the latency for 87% quality,
losing points by leaving fillers in that the 0.6b removes. The 0.6b is the pick.

Both models still miss two things: applying self-corrections ("at 2 actually 3"
should become "at 3") and rendering spoken filenames (".env"). Those are prompt
problems, not capacity problems, and this suite is how to tell whether a prompt
change actually fixed them.
