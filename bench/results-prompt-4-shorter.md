# Variant 4: is prompt length a lever?

Qwen3-0.6B-MLX-4bit, 30 cases, 2 reps, in-process engine. Every run used
`./bench/run-locked.sh`. Prompt length is words in the whole message list
(system text plus few-shot pairs), written as lowTouch / default.

## What each variant is

- baseline: the prompt in the app binary today.
- short: about a quarter of the baseline. Six rules on the coding path, six on the
  general path, two few-shot pairs instead of four, trimmed vocabulary list.
- medium: about half the baseline. Short plus the digit rule, the do-not-resolve
  self-correction rule, the identifier rule, the style-by-app line, and the full
  vocabulary list with the mishear pairs spelled out.
- needed: the short body plus one extra rule, an explicit sound-alike list naming
  the exact words the failing cases need (proud, devin, mid where, front number).
  Nothing else was added, so this isolates that one rule.
- symfirst and symlast: the short body with the spoken-symbol rule moved to the
  first and the last position. Short itself has it in the middle. Same length,
  same words, three positions.

## Results

| variant | words | recall | quality | median | p95 | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| baseline | 1068 / 796 | 97% | 83% | 0.26s | 1.31s | 1/30 | 9/30 | 2/30 |
| short | 289 / 258 | 98% | 77% | 0.15s | 0.76s | 0/30 | 12/30 | 2/30 |
| medium | 561 / 412 | 96% | 84% | 0.18s | 1.28s | 0/30 | 9/30 | 4/30 |
| needed | 449 / 258 | 97% | 80% | 0.18s | 1.08s | 0/30 | 11/30 | 5/30 |
| symfirst | 289 / 258 | 98% | 78% | 0.15s | 0.68s | 0/30 | 12/30 | 2/30 |
| symlast | 289 / 258 | 98% | 78% | 0.15s | 0.66s | 0/30 | 12/30 | 3/30 |

## The watched cases, scored on their own

| variant | control | mishear_frontend_link | mishear_dev_prod | identifier_symbols | spoken_underscore |
|---|---|---|---|---|---|
| baseline | 100% | 20% | 43% | 50% | 67% |
| short | 100% | 20% | 43% | 50% | 33% |
| medium | 100% | 20% | 38% | 43% | 100% |
| needed | 100% | 20% | 38% | 67% | 100% |
| symfirst | 100% | 20% | 43% | 50% | 33% |
| symlast | 100% | 20% | 43% | 50% | 33% |

The negative control came back at 100% in all five runs. No variant made the model
touch "can you check the front door is locked before you leave". No variant is
unsafe on that axis, including the one that lists sound-alike swaps by name.

## Winner

`bench/prompts/4-medium.json`

It holds baseline quality (84% against 83%, which is inside the noise) and the
same 9 of 30 lossy count, at roughly half the words. Median drops from 0.26s to
0.18s, and the one case that blew the deadline at baseline no longer does. It also
fixed spoken_underscore outright, 67% to 100%. The cost is reworded going from 2
to 4, which is the guard doing its job and is worth watching on a longer run.

## Verdict

Prompt length is a latency lever. It is not a quality lever.

Every shorter prompt is faster and none of them missed the deadline, where the
baseline missed once. That part of the hypothesis held. The quality part did not.
Cutting to a quarter of the length cost 6 points of quality and pushed lossy from
9 to 12, so the model did get more aggressive exactly where the brief warned it
would. Cutting to half cost nothing measurable. So there is slack in the current
prompt, about 450 words of it, but the floor is higher than a quarter.

Rule order does nothing here. The spoken-symbol rule first, middle and last, at
identical length, gave 78%, 77% and 78% quality, and identifier_symbols scored 50%
in all three. If a 0.6B model is dropping rules by position, this suite cannot see
it. The idea that a small model follows the first rule and the last one is not
supported by these runs.

The interesting negative is `needed`. Spelling out the exact swaps the failing
cases want, in the shortest prompt that still names them, did not fix them.
mishear_frontend_link stayed at 20% and mishear_dev_prod dropped to 38%. It did
lift identifier_symbols to 67%, the best score any variant got there. So the
symbol rendering problem responds to prompt wording and the mishear problem does
not. Those two failures are different failures, and length is not what separates
them. mishear_frontend_link asks the model to turn "what's the front number
through on the cycle" into a sentence about a frontend running locally, which is a
guess the 0.6B cannot make from the words alone, at any prompt length, in any
order. That case needs recognizer biasing or draft context, not prompt text.

One caveat on reading this table. Quality is averaged over 2 reps and these models
are not deterministic, so the 1 point between baseline and medium, and the 1 point
between the three order runs, are not results. The 6 point drop at short, the
lossy count going 9 to 12, and the latency numbers are large enough to believe.
