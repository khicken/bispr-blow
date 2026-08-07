# Council transcript — Wispr transcription quality on long technical dictation

**Date:** 2026-07-30 15:22
**Subject:** `~/Documents/Bluejay/bluejay-wispr` — cleanup stage over-rewrites long technical dictation, especially AI-agent prompts.

---

## Original question

> We have two other agents working on Blue Jay Whisper, but I want you to mainly be
> concerned about the quality of how our transcription works, because there's a lot of
> times where I say a lot of text, and it doesn't take into account that I'm trying to
> prompt — maybe I'm trying to prompt code — and it just changes my text too much, and
> it doesn't fully understand my intent. Council our quality issues: our system prompt,
> and how our design works, to give the best transcription quality. Imagine Wispr Flow —
> we're trying to replicate Wispr Flow one to one.

## Framed question given to all five advisors

Full architecture as read from source: pipeline (shortcut → AudioRecorder → Transcriber →
LLMCleaner → TextInserter → HistoryStore, all local); `Transcriber.swift` (SpeechAnalyzer +
SpeechTranscriber on-device, SFSpeechRecognizer fallback, biased via
`AnalysisContext.contextualStrings[.general]` = custom vocabulary + `draftTerms`);
`ContextDetector.swift` (snapshot at recording START — bundleID, app name, focused window
title, 600 tail chars of focused field via Accessibility, hard-coded category buckets,
`draftTerms` capped at 50); `LLMCleaner.swift` (LM Studio/Ollama, model priority leading with
`qwen3-4b-2507`, temp 0.2, `/no_think`, KV-prefix-cache layout with static system prompt + 4
static few-shots and all per-dictation context in the FINAL user message only, ~6x prefill
saving). Full verbatim system prompt. All four post-processing guards (`sanitize`,
`looksTruncated`, `stripFillers`, `ruleClean`). Benchmark numbers and known failures.
Doctrine: "Losing the user's words is the worst outcome, worse than leaving fillers in."

Pressure-test items (a)–(g): always-on rewrite rule as root cause; sound-alike substitution
rule danger vs value; self-correction rule vs enumerated options; 4B model fitness /
chunking / two-pass / constrained decoding / edit-distance guards; KV-cache layout cost;
recognizer-side vs cleanup-side priority; what Wispr Flow does differently.

---

## Advisor responses

### The Contrarian (anonymized as Response B)

The complaint is unfalsifiable with your current eval, and that's the fatal flaw. 17 short
cases, self-scored "90% quality," and *not one* of them is a 300-word dictated agent prompt —
the exact input he's complaining about. Every prompt tweak below this line is guesswork until
the benchmark contains 10 real long technical dictations scored by content-word edit distance
vs. his own hand-corrected reference. Fix the ruler before the thing being measured.

Second: your guards don't enforce your doctrine. `looksTruncated` catches *length* collapse
only. A model that returns 1:1 word count while swapping "quarry"→"query", "prod"→"proud",
and silently deleting one of three enumerated options passes every guard you have. That's
precisely the reported failure. Add a content-word Jaccard/edit-distance guard — reject if
>15% of non-stopword tokens changed — or admit the doctrine is decorative.

Third, the uncomfortable one: for `coding`, don't call the LLM. `ruleClean` + punctuation +
symbol expansion is a ~40-line Swift function, 0ms, and cannot mangle `FLAG_RETRY_V2`. Ship
that behind the category check, measure it against the 4B, and I suspect it wins on the cases
he cares about. You are paying 300ms and all your fidelity risk for polish he explicitly
doesn't want.

On (b): "Only where the fit is obvious" is not a computable instruction for a 4B model — it's
a licence. Move sound-alike correction into Swift as a phonetic match *restricted to
draftTerms + custom vocabulary*. Closed set, auditable, no drift.

On (e): you optimized 300ms in a pipeline where "neither is the bottleneck." That KV layout
is premature optimization that demonstrably degrades the coding path. Delete it.

And (g): Flow uses a frontier cloud model. 4B local won't match it. Pick fidelity, not parity.

### The First Principles Thinker (anonymized as Response D)

You're asking how to tune a rewriter. The prior question is: **who consumes this text?** When
he dictates a prompt for an AI coding agent, the consumer is another LLM that does not care
about "um." Cleanup there has ~zero upside and unbounded downside. You are running a lossy
generative transform to serve a reader who doesn't exist.

So the root cause isn't the rewrite instruction, the self-correction rule, or model size.
It's that **one stage is doing two categorically different jobs**: *deletion* (fillers,
stutters, false starts, spoken-symbol mapping) and *generation* (re-wording into sentences the
speaker didn't say). Deletion is verifiable and provably lossless-in-meaning. Generation is
unverifiable, and no prompt sentence makes a 4B model reliably self-police it. All your
guards — looksTruncated, edit-distance ideas, ellipsis bans — are attempts to *detect*
generation after the fact. Stop detecting it. Make it structurally impossible.

Also note your prompt contradicts your own doctrine. Doctrine: losing words is the worst
outcome. Prompt: "rewrite disfluent speech… should read like text the speaker would have
typed." Those cannot both be true. Pick, per context.

Ranked:

1. **Coding/AI-prompt category → delete-only mode.** Same model, different prompt: remove
   fillers and abandoned restarts, add punctuation/capitalization, map spoken symbols.
   *Change no other word.* Then validate: cleaned tokens must be a subsequence of raw tokens
   (modulo punctuation/case/symbol map). Fail → emit raw. That guard is one function and
   replaces three heuristics.
2. **Ship raw-vs-cleaned undo** (hotkey restores verbatim). This dissolves the aggressiveness
   question — you stop needing to be right.
3. **Then** spend on recognition, which you measured as the bottleneck.
4. Prompt-tuning the current rewriter: last. You're polishing the wrong stage.

### The Expansionist (anonymized as Response A)

**The undervalued asset is HistoryStore, and it's sitting there doing nothing.**

Every dictation already stores raw + cleaned. Add "user edited the inserted text within 30s"
capture and you own a paired corpus of *his* speech → *his* preferred text. That is the one
thing Wispr Flow cannot have: personalization. Two payoffs, escalating:

1. **Autolearn vocabulary** (ship this week). Any token the user typed that wasn't in the
   transcript, and any correction pair, goes into contextualStrings permanently. This fixes
   `.env`/`FLAG_RETRY_V2` at the recognizer, where it belongs. Raise the cap to whatever
   SpeechAnalyzer tolerates — test 200, 500. Nobody measured 50; it's a guess.
2. **Fine-tune a 0.6b LoRA on 500 of his own pairs** (this quarter). Then the prompt shrinks
   to nothing, the KV-cache debate evaporates, latency halves, and over-editing stops being a
   prompt-wrestling problem because the model has *learned his register*. A local dictation
   app with a self-training cleanup model is a category nobody occupies.

**Expand the sound-alike rule, don't retreat from it.** It's the highest-value line in the
prompt and it's crippled by being a vibe instead of a mechanism. SFSpeechRecognizer gives you
n-best alternatives — score them against draftTerms/open-file symbols and pick the winner
deterministically. Recognition is the measured bottleneck; this is where the ceiling is.

**Then go bigger than parity.** Dictating prompts for coding agents is a fast-growing use with
zero purpose-built tooling. Ship two modes on the same pipeline: **Verbatim** (delete-and-
repunctuate only, edit-distance-gated) for code, and opt-in **Agent Prompt** that structures a
ramble into goal/constraints/files. Users want *less* rewriting for code and *more* for
specs — one setting, two products.

Also: capture the draft at END, add coding few-shots (free), and surface the guard as a
visible "revert to raw" hotkey — that's trust, not plumbing.

### The Outsider (anonymized as Response E)

**The framing itself is what confuses me.** You call this a "cleanup stage" but the prompt
says "rewrite disfluent speech into complete, coherent sentences… read like text the speaker
would have typed." That is not cleanup, that's ghostwriting. And your doctrine says losing the
user's words is the worst outcome. The prompt and the doctrine say opposite things. The model
isn't misbehaving — it's obeying rule 3. Everything downstream (guards, edit-distance ideas,
two-pass) is compensating for an instruction you chose to give.

Second confusion: **why does a prompt for a coding agent need to be a well-formed sentence at
all?** The recipient is a machine that reads disfluency better than a human does. Nobody is
judging your grammar. So for that context the right output is: fillers gone, punctuation
added, words untouched. That's the whole feature. You don't need a smarter model, you need a
smaller job.

Third: **"coding" as one bucket is the actual bug.** A terminal (short, symbol-heavy, wants
"dash dash force") and a Claude Code chat box (long prose, wants zero rewriting) have opposite
needs and share a category. Split them. `agent_prompt` gets: "Remove fillers and stutters. Add
punctuation and capitalization. Change nothing else. Do not reorder, merge, or reword. Do not
resolve self-corrections."

Fourth, and biggest: **your benchmark doesn't test the complaint.** 17 cases, short ones, "90%
quality" scored by whom? The owner's pain is long technical dictation and you have no long
technical dictation case. Record ten real 200-word agent-prompt dictations, and score one
number: fraction of the speaker's content words that survive. Optimize that. Right now you're
tuning against a test that can't see the failure.

Sound-alike rule: keep it, but only for terms present in draftTerms or vocabulary. Unbounded,
it's a licence.

### The Executor (anonymized as Response C)

**Monday morning, in order. Each item is a diff you can ship the same day.**

**1. Write the 6 long AI-prompt bench cases first (2 hours).** You have 17 cases and zero of
the failure mode you're complaining about. Every change below is unmeasurable until this
exists. Score by content-word recall, not vibes: fraction of raw content words present in
output. That's the metric, not "quality 90%."

**2. Two system prompts, selected by category (30 lines of Swift).** Not a
runtime-configurable aggressiveness dial — one `if category == .coding` picking one of two
static strings. Both prefixes stay cache-warm; you get category at the *top* of the prompt for
free, fixing (e). The coding variant:

> Cleanup rules (low-touch mode): Remove fillers, stutters, and immediately-repeated words.
> Add punctuation and capitalization. Fix only clearly-wrong word forms. Do NOT reorder words,
> do NOT merge or split sentences, do NOT rephrase. Every content word in the transcript
> appears in the output unless it is a filler or a stutter. When unsure, leave it alone.

Delete the self-correction rule and the "rewrite into coherent sentences" rule from this
variant entirely. "Judge it by whether the speaker replaced it" is not a thing a 4B model
does — it's an instruction you'd write for yourself.

**3. Constrain the sound-alike rule to a closed set.** "Only substitute a word that appears in
the already-typed text or the user's vocabulary list." Enforce it in Swift: reject any output
token not in `raw ∪ draftTerms ∪ vocab ∪ punctuation`. That's your edit-distance guard and
it's cheap.

**4. Add two coding few-shots** to the coding prefix: one spoken AI-agent prompt with
enumerated options preserved, one with `--force`/`.env`.

**5. Snapshot draft at recording END.** One-line move of the ContextDetector call.

Skip chunking, two-pass, constrained decoding, bigger models. Re-run the bench after 1–4
before touching architecture.

---

## Peer reviews

Anonymization mapping: **A = Expansionist, B = Contrarian, C = Executor,
D = First Principles Thinker, E = Outsider.**

### Review 1

**1. Strongest: D.** It's the only one that names the real defect as a *category* error rather
than a tuning error: one stage doing deletion (verifiable) and generation (unverifiable). Its
subsequence check — cleaned tokens must be a subsequence of raw modulo case/punct/symbol-map —
is one function that replaces `looksTruncated`, the edit-distance guard B wants, and the
closed-set guard C/E want. E has the same diagnosis but stops at rhetoric; C is the best
execution plan and should be D's diff.

**2. Biggest blind spot: A.** It's the only response that fixes nothing this week. Autolearn is
fine, but a LoRA on 500 self-collected pairs to dodge a prompt bug is the most expensive path
to "stop rewriting my words," and A never questions the rewrite rule at all. It also cites
`SFSpeechRecognizer` n-best when the pipeline is SpeechAnalyzer — the alternatives API it
hangs its highest-value claim on may not exist there.

**3. All five missed:** the complaint is *length*-specific, every proposed fix is
*category*-specific. Nobody proposed measuring degradation as a function of input length. If
quality collapses past ~150 words, per-utterance segmented cleanup fixes it and category
prompts won't. B and C dismissed chunking without measuring the one variable the owner
actually named.

### Review 2

**1. Strongest: D.** It's the only one that identifies the actual structural fault — one stage
doing *deletion* (verifiable, lossless) and *generation* (unverifiable) — and replaces three
heuristics with one guard: cleaned tokens must be a subsequence of raw tokens modulo
case/punctuation/symbol map. It also catches the prompt/doctrine contradiction and correctly
ranks prompt-tuning last. C is the best diff-level plan; steal its coding prompt text and
bench work, but D's ordering.

**2. Biggest blind spot: A.** It answers a fidelity bug with a data-flywheel roadmap — LoRA on
500 pairs, autolearn corpus, a new "Agent Prompt" product — none of which help this week, all
on n=1 user. It also cites `SFSpeechRecognizer` n-best; the stack is SpeechAnalyzer, so the
deterministic-rescoring plan may not have the API it assumes. Most work, least confidence.

**3. All five missed:** the four static few-shots. Every response rewrites prose rules while
leaving demonstrations that *show* heavy rewriting — few-shots beat instructions in a 4B model,
so a "low-touch" coding prompt paired with rewriting exemplars loses. Also unexamined: length
itself (no one tests whether the same prompt degrades at 300 words vs 30 — that, not the rules,
may be the bug), temp 0.2 instead of greedy, and nobody proposed running identical audio
through Flow to see what it actually returns.

### Review 3

**1. Strongest: D.** It's the only one that reframes the pipeline as two different jobs
(deletion = verifiable, generation = unverifiable) and lands on a single invariant that
replaces three heuristics: cleaned tokens must be a subsequence of raw tokens modulo
punctuation/case/symbol-map. Fail → emit raw. That's one function, kills the whole
guard-tuning treadmill, and enforces the doctrine instead of decorating it. C is the better
Monday checklist; D is the better diagnosis. E duplicates D with less rigor.

**2. Biggest blind spot: A.** It answers a product-strategy question nobody asked. A LoRA on
500 self-collected pairs is a quarter away and does nothing about today's over-editing; the
"Agent Prompt" structuring mode is *more* rewriting aimed at the exact context that wants
less. It also never notices the prompt/doctrine contradiction, and skips the benchmark gap
that B, C, E all flag as blocking. Its one good idea (n-best alternatives scored against
draftTerms) is buried.

**3. All five missed:** chunking — explicitly asked in (d), engaged by nobody. A 4B model's
instruction-following degrades across a 300-word input; segmenting at pause boundaries and
cleaning each span independently attacks over-editing at its actual cause. Also: nobody
proposed running the same audio through Flow and diffing. That's the only real parity metric.

### Review 4

1. **D is strongest.** It names the actual root cause structurally rather than as a
   prompt-wording complaint: one stage is doing deletion (verifiable) and generation
   (unverifiable) at once. Its subsequence check — cleaned tokens must be a subsequence of
   raw, modulo punctuation/case/symbol map — replaces looksTruncated, the edit-distance idea,
   and the ellipsis ban with one function. C is the best execution plan; D is the better
   diagnosis. Pair them.

2. **A has the biggest blind spot.** It answers "how do we beat Flow long-term" instead of
   "why is my text mangled today" — LoRA fine-tuning on 500 pairs, autolearn corpora, an Agent
   Prompt product. None of that fixes over-editing this week, and it needs an edit-capture
   pipeline that doesn't exist. It also cites SFSpeechRecognizer n-best; the stack is
   SpeechAnalyzer.

3. All five missed that **the benchmark measures 0.6b and 1.7b while production runs 4b** —
   the eval doesn't test the shipped model at all. Also unraised: the 600-char draft in the
   final user message actively invites imitation/continuation and may be causing the
   rewriting; temp 0.2 should be 0; and the only real parity ruler is running the same ten
   dictations through Wispr Flow and diffing, which nobody proposed.

### Review 5

**1. Strongest: D.** It's the only one that names the actual defect — one stage doing
*deletion* (verifiable) and *generation* (unverifiable) — and replaces three heuristics with
one computable guard: cleaned tokens must be a subsequence of raw tokens modulo
case/punctuation/symbol map. E diagnoses the same prompt/doctrine contradiction but stops at
diagnosis; C is the best shippable diff and should be the execution plan under D's frame.

**2. Biggest blind spot: A.** It answers "how do we win a category" instead of "why does his
text get mangled." A LoRA fine-tune on 500 self-collected pairs is the single most over-built
proposal here, and it's unvalidatable because A never notices the benchmark can't see the
failure — you'd be training against a ruler B, C, and E all flagged as broken. It also asserts
n-best alternatives from an API the pipeline doesn't use (SpeechAnalyzer, not
SFSpeechRecognizer).

**3. All five missed:** the four few-shot pairs are all *short*. On a 300-word dictation the
model imitates the demonstrated output length and condenses — that's in-context length bias,
not rule 3, and no prompt wording fixes it. Length is the reported trigger and nobody
explained why length itself breaks it. Add one long few-shot, or chunk per sentence so each
call stays in-distribution.

---

## Verified after the review round

Two peer-review claims were checked against the source rather than taken on faith:

1. **Benchmark/production model mismatch — CONFIRMED.** `bench/bench.py` defaults to "every
   loaded chat model" and `bench/results.md` covers only `qwen3-0.6b-mlx` and `qwen3-1.7b`.
   `LLMCleaner.firstModel(at:)` has a priority list led by `qwen3-4b-2507`. The shipped model
   has never appeared in a committed benchmark run.
2. **Few-shot length bias — CONFIRMED.** The longest demonstrated output in `LLMCleaner.fewShot`
   is the bug-report example at roughly 55 words. The reported failures are 200–300 word
   dictations, i.e. 4–6x the longest thing the model has been shown.

---

## Chairman synthesis

### Where the council agrees

1. **The prompt contradicts the doctrine, and the model is obeying the prompt.** CLAUDE.md says
   losing the user's words is the worst outcome; rule 3 says "rewrite disfluent speech into
   complete, coherent sentences… should read like text the speaker would have typed." Four of
   five advisors independently identified this. There is no bug to fix — rule 3 is being
   followed correctly, and it is the wrong rule for technical dictation.

2. **The benchmark cannot see the reported failure.** Every advisor except the Expansionist led
   with this. 17 cases, none over ~170 words, none an AI-agent prompt, scored by an LLM judge
   emitting a percentage. The one thing the owner is complaining about is untested. Confirmed
   worse than stated: the shipped model was never benchmarked at all.

3. **The guards enforce length, not fidelity.** `looksTruncated` catches collapse and inflation.
   It cannot catch the actual failure — a 1:1-length output that swapped content words or
   silently dropped one of three enumerated options. Under the current guards, the doctrine is
   decorative.

4. **"Only where the fit is obvious" is not a computable instruction.** Unanimous on constraining
   sound-alike substitution to a closed set (`draftTerms ∪ vocabulary`) rather than leaving it to
   a 4B model's judgment. The disagreement is only about whether the enforcement lives in the
   prompt or in Swift.

5. **Capture the draft at recording END, not START.** Nobody dissented. One-line change.

### Where the council clashes

**Clash 1 — is sound-alike substitution the best rule or the worst?** The Contrarian calls it a
licence to rewrite correct words and wants it out of the prompt entirely, reimplemented as
phonetic matching in Swift. The Expansionist calls it the single highest-value line and wants it
*expanded* via n-best rescoring. Both are right about different halves: the *goal* is the highest
value (recognition is the measured bottleneck) and the *mechanism* is the worst (unbounded model
discretion). Resolution: keep the goal, close the set.

**Clash 2 — LLM or no LLM on the coding path?** The Contrarian says skip the model entirely for
`coding`: `ruleClean` + symbol expansion is ~40 lines and cannot mangle `FLAG_RETRY_V2`. First
Principles and the Executor keep the model but shrink its job to delete-and-repunctuate. The
Contrarian's version is cheaper and strictly safe but gives up the one thing regex can't do:
"dash dash verbose" → `--verbose` across arbitrary phrasings, and sentence boundaries in a 250-word
run-on. Resolution: keep the model, constrain it structurally — but the Contrarian's version is
the correct fallback when the subsequence check fails.

**Clash 3 — is the KV-cache layout costing quality?** The Contrarian wants it deleted as premature
optimization in a pipeline where "neither stage is the bottleneck." The Executor points out this
is a false tradeoff: two static prefixes selected by category keep the cache *and* put the
category at the top. The Executor is right and the Contrarian's framing was wrong — the cache
costs nothing here.

**Clash 4 — where does the effort go: recognizer or cleanup?** The Expansionist and the
transcription measurements say recognizer. The other four say the over-editing complaint is a
cleanup-stage problem that recognizer work does not touch. Both are true because they are
answering different questions: recognition quality is the higher long-term ceiling, over-editing
is the reported pain. Fix the reported pain first; it's a day of work against a quarter.

### Blind spots the council caught

1. **The few-shots undercut any low-touch prompt you write.** Every advisor rewrote prose rules
   and left the demonstrations alone. In a 4B model, demonstrations beat instructions — a
   "change nothing else" instruction paired with four exemplars showing heavy rewriting loses.
   Two reviewers caught this independently.

2. **In-context length bias is the mechanism behind the length-specific complaint.** The longest
   demonstrated output is ~55 words (verified). The failing inputs are 200–300 words. The model
   imitates demonstrated output length and condenses. This explains why the complaint is
   *length*-specific while every proposed fix is *category*-specific — and it means chunking,
   which four advisors dismissed, is back on the table as the mechanism-matched fix.

3. **The eval never ran the shipped model** (verified). Every tuning decision in `results.md`
   was made on 0.6b/1.7b evidence and applied to a 4B production path.

4. **The 600-char draft in the final user message may itself be causing rewriting.** Handing a
   model a block of polished prose immediately before the transcript invites imitation and
   continuation, whatever the label says. Nobody raised this in the advisor round.

5. **Nobody proposed the only real parity ruler:** run the same ten dictations through Wispr Flow
   and diff. The stated goal is 1:1 parity and there is no measurement of the target.

6. **temp 0.2 should be 0** for a deterministic transform. Free variance reduction, and it makes
   the benchmark reproducible (bench.py currently scores every rep precisely because output isn't
   deterministic).

### The recommendation

Adopt **First Principles' diagnosis** with **the Executor's diff**, and add the two mechanisms
the reviewers surfaced. The council's near-unanimous choice of D was correct: this is not a
prompt-wording problem, it's one stage doing two jobs with different verifiability properties.
Deletion is checkable. Generation is not. Stop trying to detect bad generation and make it
structurally impossible on the paths that don't want it.

Ranked, with what to measure:

1. **Bench cases that contain the failure.** 6–8 real 200–300 word dictations — agent prompts,
   design-doc rambles, enumerated options. Metric: content-word recall (fraction of raw
   non-stopword tokens surviving) plus a substitution count. Also run the bench against
   `qwen3-4b-2507` so the eval finally covers production. *Nothing below is measurable without
   this.*

2. **Two static prefixes selected by category.** `if category == .coding` picks a low-touch
   prefix; everything else keeps today's. Cache survives, category lands at the top of the
   prompt, (e) is fixed for free. Delete the self-correction rule and the "rewrite into coherent
   sentences" rule from the low-touch variant entirely. Measure: content-word recall on the new
   cases, before/after.

3. **The subsequence guard.** Cleaned tokens must be a subsequence of raw tokens, modulo case,
   punctuation, and the spoken-symbol map. Fail → emit `ruleClean(raw)`. One function that
   replaces `looksTruncated`'s ratio heuristics on the low-touch path and enforces the doctrine
   instead of decorating it. Measure: how often it fires (should be near-zero if the prompt
   works; a high rate means the prompt isn't landing).

4. **Long + coding few-shots.** At least one demonstration whose output is 200+ words, and one
   spoken AI-agent prompt with enumerated options preserved intact. This addresses the length
   bias the reviewers identified, which no prompt wording can fix. Measure: whether recall on the
   long cases moves independently of the prompt change in (2).

5. **Close the sound-alike set.** Prompt: substitute only words present in the already-typed text
   or the vocabulary list. Enforce in Swift on the low-touch path via the same subsequence guard,
   whose allowed alphabet becomes `raw ∪ draftTerms ∪ vocab ∪ punctuation`. Measure: substitution
   count on cases with correct-but-unusual words.

6. **Cheap wins, same afternoon:** capture the draft at recording END; temperature 0; split
   `coding` into `terminal` (short, symbol-heavy) and `agent_prompt` (long prose, zero
   rewriting) — a Claude Code chat box and a shell prompt want opposite things and currently
   share a bucket.

7. **Then, and only then:** length-conditional chunking (if recall still degrades with length
   after 1–4, segment at pause boundaries), recognizer work (raise the 50-term cap and measure —
   nobody has), and vocabulary autolearning from HistoryStore edits, which is the Expansionist's
   one genuinely cheap idea.

**Explicitly rejected:** the LoRA fine-tune (all five reviewers flagged it as the most expensive
path to "stop rewriting my words," and it would train against a ruler that can't see the
failure); the "Agent Prompt" structuring mode (more rewriting aimed at the context that wants
less); deleting the KV-cache layout (the Executor showed it's a false tradeoff); and n-best
rescoring as described (`SpeechAnalyzer` is the primary path, and the alternatives API the
Expansionist assumed belongs to `SFSpeechRecognizer` — verify before planning on it).

One correction to the framing that started this: "replicate Wispr Flow 1:1" is the wrong target
if Flow is running a frontier cloud model, as the Contrarian argues. The winnable game is
*fidelity* on technical dictation — being the tool that never mangles a prompt — not matching
Flow's prose polish with a 4B local model.

### The one thing to do first

Record 6–8 real 200–300 word dictations — the exact kind that fail, dictated normally into Claude
Code and a terminal — hand-correct each one into a reference, add them to `bench/cases.json`, and
run the bench against `qwen3-4b-2507` scoring content-word recall. You will learn in an afternoon
whether the failure is the rewrite rule, the length bias, or the model — and every other change
on this list becomes measurable instead of plausible.
