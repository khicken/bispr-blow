# Prompt sweep 1: explicit mishear repair rules (lowTouch)

Hypothesis: name the classes of mishear the recognizer makes (a technical compound
split into two ordinary words, a tool or environment name pulled to a common word,
spoken symbols) and the 0.6B model will repair them.

All runs: Qwen3-0.6B-MLX-4bit, 30 cases, 2 reps, `--engine inprocess`. Only the
lowTouch prompt changed; the default prompt came from the binary.

## Variants

| variant | prompt file | what changed |
|---|---|---|
| baseline | app binary | current shipped prompt |
| mishear-open | bench/prompts/1-mishear-open.json | named repair classes, any correct word allowed, plus a repair example and a control example |
| mishear-vocab | bench/prompts/1-mishear-vocab.json | repair allowed only toward a term on the custom vocabulary list or in the typed draft, plus the same two examples |
| mishear-tight | bench/prompts/1-mishear-tight.json | the same rule as mishear-vocab compressed into one bullet |

## Results

| variant | quality | recall | median | p95 | lossy | reworded | frontend_link | dev_prod | control | identifier_symbols |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline | 83% | 97% | 0.26s | 1.31s | 9/30 | 2/30 | 20% | 43% | 100% | 50% |
| mishear-open | 82% | 97% | 0.27s | 1.58s | 9/30 | 3/30 | 20% | 38% | 100% | 50% |
| mishear-vocab | 83% | 97% | 0.30s | 2.15s | 8/30 | 3/30 | 20% | 50% | 100% | 50% |
| mishear-vocab (rerun) | 83% | 96% | 0.28s | 1.47s | 7/30 | 3/30 | 20% | 50% | 100% | 50% |
| mishear-tight | 82% | 97% | 0.27s | 1.78s | 8/30 | 2/30 | 20% | 43% | 100% | 50% |

The control, mishear_control_plain, scored 100% in every run. No variant touched it.

## Why the ceiling is not in the prompt

The app's own reworded guard decides this, not the model. On the coding path
`rewordsContent` demands every output word trace back to the transcript in spoken
order, or sit in the allowed set, which is the user's vocabulary list plus the
typed draft. A rejected result ships rule-based text, which is the raw transcript.

Checked directly through `--finish`, with no model in the loop:

- "Push it to prod, not dev, and then check the middleware Sentry." is rejected as
  reworded. `prod` and `middleware` are not on the vocabulary list, and "mid" plus
  "where" does not concatenate to "middleware".
- "What's the frontend link to run this locally?" is rejected the same way.
  `frontend`, `link` and `locally` are all outside the allowed set.
- "Push it to proud, not dev, and then check the mid where Sentry." passes, because
  `dev` is on the vocabulary list.

So the perfect answer to both repair cases is thrown away by the app before it
reaches the cursor. mishear_frontend_link cannot score above about 20% through any
prompt, and mishear_dev_prod is capped at the one word the vocabulary list covers.

mishear-open shows the cost of ignoring this. It did repair dev_prod, the guard
rejected the repair, the case fell to 38%, below baseline, and reworded rose to
3/30.

## Verdict

The hypothesis does not work as stated. Naming the mishear classes does not lift
overall quality: 82% to 83% against a baseline of 83%, which is inside the run to
run noise these variants show. The only real movement is mishear_dev_prod, 43% to
50%, from the single word `dev` being on the vocabulary list, and that is the
narrow vocabulary-scoped variant, not the open one. Open repair is a small
regression because it trips the guard.

Winner, weakly: bench/prompts/1-mishear-vocab.json. It is the only variant that
beat baseline on a mishear case without losing anything elsewhere, and it reduced
lossy from 9/30 to 8 and 7. It is not worth shipping for that alone.

The real fix is not a prompt. Either the vocabulary list has to carry the terms the
user actually dictates (prod, frontend, middleware, localhost, repo), which widens
the allowed set and lets a repair survive the guard, or the guard needs a repair
channel that admits a small closed table of sound-alikes the way `digitHomophones`
already admits digits. Until one of those lands, telling the model to repair
mishears on the coding path makes the app slightly worse, not better.
