# Prompt sweep 2: worked examples instead of rules (low-touch path)

Qwen3-0.6B-MLX-4bit, 30 cases, in-process engine. Every variant changes only the
`lowTouch` prompt; the `default` prompt is the one in the binary, so the chat and
writing cases are the same text in every row.

| variant | reps | quality | recall | median | p95 | lossy | reworded | identifier_symbols | mishear_dev_prod | mishear_frontend_link | mishear_control_plain |
|---|---|---|---|---|---|---|---|---|---|---|---|
| baseline (shipped prompt) | 2 | 83% | 97% | 0.26s | 1.31s | 9/30 | 2/30 | 50% | 43% | 20% | 100% |
| A: rules cut, 7 examples | 2 | 81% | 97% | 0.27s | 1.51s | 9/30 | 3/30 | 58% | 43% | 20% | 100% |
| B: rules kept, 4 examples added | 2 | 84% | 98% | 0.27s | 1.62s | 6/30 | 3/30 | 67% | 43% | 20% | 100% |
| C: rules kept, 6 examples added | 2 | 85% | 97% | 0.30s | 1.54s | 6/30 | 3/30 | 92% | 43% | 20% | 100% |
| C again | 3 | 84% | 98% | 0.16s | 1.53s | 7/30 | 4/30 | 94% | 43% | 20% | 100% |

Prompt files: A is `bench/prompts/2-fewshot.json`, B is
`bench/prompts/2-fewshot-plus-rules.json`, C is
`bench/prompts/2-fewshot-plus-six.json`. Per-case detail is in
`bench/results-prompt-2-fewshot-run1.md` through `-run4.md`.

Winner: `bench/prompts/2-fewshot-plus-six.json`.

## Verdict

The hypothesis as written is wrong. Replacing the rule list with examples (A)
made the model worse: quality fell from 83% to 81%, `spoken_underscore` and
`meaningful_like` broke, and `snap_regions` started tripping the rewording
guard. The 0.6B needs both. Keeping the full rule list and adding examples on
top (B and C) is the version that helps, and the gain is small: one to two
points of quality, inside the run-to-run noise of this suite except for the one
case the examples directly address.

The real gain is `identifier_symbols`, which goes from 50% to 92-94% once two
extra examples show spoken symbols inside a path (`.npmrc`, `logs/server.log`).
Everything else moves by less than the noise. Lossy dropped from 9 of 30 to 6-7
of 30, which is a real improvement, but reworded rose from 2 to 3-4, so some of
that is the rejection moving between guards rather than going away.

## The two mishear cases cannot be fixed from this prompt

`mishear_dev_prod` and `mishear_frontend_link` sat at 43% and 20% in every
variant, and no prompt can move them. The correct answer is rejected by the
app's own rewording guard before it is scored. Checked directly:

    raw:     push it to proud not devin and then check the mid where sentry
    perfect: Push it to prod, not dev, and then check the middleware Sentry.
    --finish: reworded content on the coding path, rules ran instead

`prod`, `middleware`, `frontend` and `locally` are not in the custom vocabulary
and not in the draft, so `rewordsContent` has nothing to trace them to. The same
is true of `dragon` in `snap_regions`. Fixing these needs a change to the
allowed-terms set, not a change to the prompt.

## The negative control

`mishear_control_plain` scored 100% in all four runs, including variant A, which
had the fewest rules and an example showing an ordinary sentence being left
alone. The control is safe here, but for the reason above: the guard blocks
mishear repair on this path in either direction, so the prompt was never really
tested against it.

## Leakage

No example text appeared in any case output. The nearest thing to leakage is my
own doing, not the model's: the discourse example in variant C was written from
the `discourse_like` case's own wording, so that case's 100% in run 3 is partly
teaching to the test, and run 4 put it back at 81%. Treat the `discourse_like`
number in variant C as unproven.

## Cost

Examples are cheap here. Median latency stayed between 0.16s and 0.30s and no
variant went over the deadline on any case, against 1 of 30 for the baseline.
p95 rose about 0.2s, which is the long coding cases producing longer output
rather than the prefix costing more.
