# Variant 3: give the model the user's vocabulary and say what app it is

Qwen3-0.6B-MLX-4bit, 30 cases, 2 reps, inprocess engine, nothink=auto.

The idea under test was that the cleanup stage fails the mishear cases because it
does not know what the user works on. Put the user's own terms in the prompt, name
the app, and the model should match a misheard word to a known term instead of
guessing.

## What was measured

| run | recall | quality | median | p95 | lossy | reworded | frontend_link | dev_prod | control | identifier_symbols |
|---|---|---|---|---|---|---|---|---|---|---|
| baseline (run 0) | 97% | 83% | 0.26s | 1.31s | 9/30 | 2/30 | 20% | 43% | 100% | 50% |
| baseline repeated | 97% | 83% | 0.26s | 1.94s | 11/30 | 4/30 | 20% | 43% | 100% | 50% |
| sysvocab | 96% | 83% | 0.31s | 1.62s | 8/30 | 3/30 | 20% | 43% | 100% | 67% |
| uservocab | 97% | 82% | 0.35s | 1.77s | 6/30 | 2/30 | 20% | 43% | 100% | 67% |
| repair | 97% | 81% | 0.33s | 1.97s | 7/30 | 4/30 | 20% | 38% | 100% | 67% |
| terms | 96% | 83% | 0.27s | 1.60s | 8/30 | 2/30 | 20% | 43% | 100% | 67% |

The variants:

sysvocab puts a 300 word block in the system message: who the speaker is, four
groups of terms, a short list of sound-alikes seen in real dictations, and a rule
saying repair only inside a sentence about software.

uservocab is the same block moved out of the system message into an extra user
turn at the end of the fixed prefix, just before the real transcript.

repair cuts the block to about 90 words, folds it into the low-touch rule list as
an explicit exception to "change nothing else", and adds two worked examples: one
that repairs proud to prod and devin to dev, and one that leaves the front door
sentence alone.

terms keeps the shipped prompt exactly and only swaps the term list for a better
one, with prod, middleware, frontend and Sentry added. This separates the quality
of the list from the length of the block.

## The result

No variant moved either mishear case. Not the long block, not the short block, not
moving it between the system and user message, and not a worked example that spells
out the exact repair the case asks for. The hypothesis is wrong for this model on
this path.

The repeated baseline explains why the other columns should be ignored. With the
identical prompt, lossy went from 9 to 11 and reworded from 2 to 4 between two
runs, and p95 from 1.31s to 1.94s. Every difference in those columns across the
variants sits inside that spread. uservocab's 6 lossy is the only number close to
being outside it, and one run is not enough to call it.

The one real gain is identifier_symbols, 50% to 67%, in all four variants and in
neither baseline. The better term list makes the model render "dot env" as ".env".
It still misses --force and app.log.

The control never broke. mishear_control_plain scored 100% in every run including
the one that named the front door sentence in the prompt. The fear that a
vocabulary list forces "front door" into "frontend" did not happen here, but note
the reason below: on this path the model is not allowed to change that word anyway,
so the control was never really at risk.

## Why the mishears cannot be fixed from the prompt

All three mishear cases are coding cases, so they run the low-touch prompt and the
subsequence guard. The guard rejects any output word that is not traceable to the
transcript or to a closed allowed set. A mishear repair is a swapped word by
definition, so the guard rejects it and ships rule-based text with the mishear back
in.

The repair variant proves it. Its dev_prod score went down, to 38%, and the failure
line changed to REWORDED. The model did make the repair; the app threw it away.

Fed straight into the app's own --finish seam:

    raw:     push it to proud not devin and then check the mid where sentry
    cleaned: Push it to prod, not dev, and then check the middleware Sentry.
    allowed: none        -> rejected, reworded, ships the raw text
    allowed: prod dev middleware Sentry -> accepted unchanged

The allowed set is built by allowedTerms from the user's vocabulary setting plus
the words on screen. The shipped vocabulary has dev but not prod, middleware,
frontend or Sentry. So the lever is the vocabulary setting, not the prompt text,
because that one list is both what the prompt shows the model and what the guard
will let through. Adding a word to the prompt alone can never land.

mishear_frontend_link is a different problem again and is unreachable on this path
at any setting. Going from "what's the front number through on the cycle" to
"what's the frontend link to run this locally" invents four words. That is a
reconstruction, not a respelling, and the guard forbids changing the word count on
the coding path. Whitelisting every target word still leaves it rejected, which was
checked. That case is a recognizer problem, not a cleanup problem.

## Latency

The long block adds about 1450 characters to a 5977 character prefix and cost
roughly 50ms of median. The short block cost about 10ms. The prefix is fixed, so
prompt caching covers all of it either way and position inside the prefix makes no
difference to caching at all: the only uncached part of the request is the real
user message, which comes after everything. The choice between the system message
and a trailing user turn is therefore a pure attention question, and it did not
matter.

Long blocks did not damage the unrelated cases. Quality moved 83 to 81 across the
four variants, inside the noise the repeated baseline shows.

## Verdict

The prompt is the wrong place for this. The model already follows a vocabulary
instruction when the output is allowed to ship; the app's own coding-path guard is
what blocks the repair, and that guard is unblocked by the vocabulary setting
rather than by any wording.

What to ship from this sweep: bench/prompts/3-terms.json. It is the shipped prompt
with a better term list, it is the cheapest of the four in latency, and it is the
only change with a repeatable gain (identifier_symbols). Its sound-alike examples
and its do-not-repair rule cost nothing and read correctly.

What would actually fix the mishear cases is not a prompt at all. Add prod,
middleware, frontend, Sentry and the rest of the terms in 3-terms.json to the
user's vocabulary setting, so they enter the guard's allowed set as well as the
prompt. The app needs to gather nothing new to do this: ContextDetector already
captures the app name, category, window title, the draft in the field and the field
label, and settings.vocabulary already exists and is already learned from the
user's own corrections. The gap is only that the shipped list is short and holds
junk entries such as "product names" and "jargon".

One honest caveat on the repair variant: its worked example uses the same words as
the dev_prod case, which is overfitting to the suite. It is reported because it is
the strongest possible version of the hypothesis and it still failed, not because
it should ship.
