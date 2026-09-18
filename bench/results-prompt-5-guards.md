# Prompt sweep 5: steering the model past the guards

Qwen3-0.6B-MLX-4bit, 30 cases, 2 reps, nothink=auto, deadline 900ms + 6ms/word.
Five bench runs, all through `bench/run-locked.sh`.

Hypothesis under test: the largest single loss is the guard rejections, not the wording.
Result: half true. Four of the nine lossy cases were the model dropping content, and a
prompt fixed them. Two cases can never pass, whatever the prompt says.

## Variants

All variants keep the shipped system message and the shipped few-shot examples. They add a
block of hard output constraints that names the failure mode in the app's own terms: keep
the length, keep the ending, keep every content word, on the coding path keep the word order.

- guards: the constraint block appended to the system message, before the few shots.
- guardslast: the same text, moved to a second system message placed after the few shots,
  so it sits immediately before the transcript.
- split: guardslast, but the two paths get different blocks. The coding path keeps the
  strict word-order block. The chat and writing path gets a length/ending/no-summary block
  plus an explicit line saying that deleting a false start or the discarded half of a
  self-correction is still required and does not count as losing content.
- split2: split, with worked self-correction examples added to the chat block and a worked
  inserted-connective example added to the coding block.
- split3: split's chat block with split2's coding block.

## Results

| variant | quality | recall | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| baseline (shipped) | 83% | 97% | 0.26s | 1.31s | 2.24s | 1/30 | 9/30 | 2/30 |
| guards | 82% | 97% | 0.33s | 1.78s | 1.92s | 0/30 | 9/30 | 3/30 |
| guardslast | 79% | 97% | 0.31s | 1.63s | 1.91s | 0/30 | 6/30 | 3/30 |
| split | 83% | 97% | 0.33s | 1.67s | 2.01s | 0/30 | 5/30 | 2/30 |
| split2 | 81% | 99% | 0.33s | 1.61s | 1.82s | 0/30 | 6/30 | 3/30 |
| split3 | 84% | 97% | 0.32s | 1.53s | 1.85s | 0/30 | 5/30 | 3/30 |

## The three mishear cases and the control, scored per variant

| variant | mishear_frontend_link | mishear_dev_prod | mishear_control_plain |
|---|---|---|---|
| baseline | 20% | 43% | 100% |
| guards | 20% | 43% | 100% |
| guardslast | 20% | 43% | 100% |
| split | 20% | 43% | 100% |
| split2 | 20% | 43% | 100% |
| split3 | 20% | 43% | 100% |

The control came back untouched in every run. No variant moved either mishear case, and the
next section says why that is not a prompt problem.

Fillers still go. No variant kept an "um" or an "uh" on any case. The two filler-shaped
failures that remain, "like closer" on discourse_like and "like center" on false_start, are
in the baseline too and are unchanged.

## Which cases stopped being lossy

Baseline lossy set, nine cases: long_ramble, discourse_like, stacked_fillers,
long_meeting_notes, agent_prompt_streaming, agent_prompt_ui_options, agent_prompt_council,
enumerated_options, design_doc_polish_long.

split and split3 lossy set, five cases: long_ramble, discourse_like, stacked_fillers,
agent_prompt_streaming, enumerated_options.

Stopped being lossy, four cases:

- long_meeting_notes, was dropped content, now 100%.
- agent_prompt_council, was dropped content, now 100%.
- design_doc_polish_long, was dropped content and over the 2034ms budget, now 100% and inside it.
- agent_prompt_ui_options, was reworded on the coding path, now 86%.

These four are all long transcripts. The model was stopping early or compressing them, and
telling it plainly that a short answer gets thrown away stopped that.

## Where the guards, not the prompt, are the wall

I probed the guards offline with `--finish`, feeding hand-written correct cleanups rather
than model output. That answers the question the bench cannot: would a perfect answer be
accepted?

Eleven of the thirteen probed cases accept a correct hand-written cleanup, including all
four that the prompt went on to fix and the three that are still lossy. On those the guards
are not the wall and the model is simply weak.

Two cases reject every correct answer:

- mishear_dev_prod. The case demands "proud" to "prod", "devin" to "dev", "mid where" to
  "middleware". It is a coding case, so `rewordsContent` runs. That guard allows an output
  word only if it appears in the transcript in spoken order, or is in
  `allowedTerms(vocabulary:draftTerms:)`. "dev" is in the user vocabulary and passes.
  "prod" and "middleware" are not in it, so they fail. Probed: transcript with only "dev"
  swapped is accepted; either other swap is rejected as "reworded content on the coding path".
- mishear_frontend_link. Same guard. "frontend" and "locally" are not in the vocabulary, so
  both required swaps are rejected. Probed individually, each one fails on its own.

Both cases currently score 20% and 43% because the model does not attempt the swap. If a
prompt did make it attempt them, they would turn into two new lossy rows and the score would
not improve, because the rule-based fallback ships either way. The fix is not in the prompt.
It is either adding prod, middleware, frontend and locally to the vocabulary, or letting
`rewordsContent` accept a sound-alike substitution the way `digitHomophones` already does
for numbers.

One more guard finding, smaller. long_ramble is a coding case whose transcript is loose
enough that almost any readable cleanup inserts a connective. A cleanup that inserts one
"it" into "dev or prod keeps saying devin" is rejected. A strictly faithful cleanup passes.
Naming that exact insertion in the prompt, which split2 and split3 do, did not stop the model
doing it.

## Winner

bench/prompts/5-split3.json

Quality 84% against the baseline's 83%, recall unchanged at 97%, lossy 9/30 down to 5/30,
deadline misses 1/30 down to 0/30, p95 1.31s up to 1.53s but worst case 2.24s down to 1.85s.
bench/prompts/5-split.json is the same story at 83% quality with one fewer reworded row, and
the two are inside the run-to-run noise of each other.

## Verdict

The hypothesis is half right and the half that is wrong matters.

Naming the guard failure in the prompt does work, and it works best when the constraint block
sits immediately before the transcript rather than in the system message. That placement alone
took lossy from 9 to 6. But the same block applied to both paths costs more than it earns,
because "keep every content word" fights the chat path's job of deleting the discarded half of
a self-correction. guardslast lost 4 quality points that way. Splitting the block per path
recovered them and kept the gain.

Quality barely moved, 83% to 84%, and that is the honest headline. Four long cases went from
shipping rule-based text to shipping model text, which is a real improvement in what the user
sees, but the bench's per-case checks were already passing on most of those cases through the
rule fallback, so the summary number hardly registers it. Latency got worse in the middle and
better in the tail: a longer prompt costs about 60ms on the median, and the deadline miss went
away because the long cases stopped rambling.

Three cases stay lossy under the winner and are model weakness, not guard strictness, since a
correct answer is accepted for all three: long_ramble, discourse_like, stacked_fillers.

Two cases are guard-blocked and no prompt can win them: mishear_dev_prod and
mishear_frontend_link, both stopped by `rewordsContent` in LLMCleanerGuards.swift, because the
words the case requires are not in the transcript and not in the allowed vocabulary. That is
the one place where the answer is that the guard is too strict, and it is a code or vocabulary
change, not a prompt change.
