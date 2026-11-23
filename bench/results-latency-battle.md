# Latency battle: Qwen vs the shipped models vs MiniCPM5-1B

Run on 2026-09-18 with `bench/bench.py --engine inprocess --reps 3`, 27 cases,
one model at a time so only one set of weights is ever resident. The engine is
the app's own binary (`--complete`), so the prompt, the guards and the
deterministic filler pass are the ones that ship. Timings are wall clock around
the whole completion, warm: the model is loaded and the prefix cached before the
first timed rep.

The three entrants are the two models the app already installs and picks between
(`ModelDownloader.fast` and `ModelDownloader.shared`) and MiniCPM5-1B, added for
this run only:

| role | model |
|---|---|
| Fast | Qwen3-0.6B-MLX-4bit |
| Accurate | Qwen3-1.7B-MLX-8bit |
| challenger | MiniCPM5-1B-MLX-4bit (`mlx-community/MiniCPM5-1B-4bit`, 602 MB) |

## Results

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-0.6B-MLX-4bit | 96% | 85% | 0.17s | 1.59s | 2.34s | 1/27 | 10/27 | 3/27 |
| Qwen3-1.7B-MLX-8bit | 97% | 88% | 0.66s | 4.59s | 4.80s | 9/27 | 1/27 | 1/27 |
| MiniCPM5-1B-MLX-4bit | 97% | 79% | 0.21s | 1.51s | 1.77s | 0/27 | 10/27 | 3/27 |

`median` is the median of the per-case medians, `p95` the 95th percentile over
every individual rep. `over deadline` counts cases whose median misses
`LLMCleaner.deadlineMs` for the Fast path (900ms + 6ms/word, capped at 2500ms).
A case over the deadline ships as `ruleClean` however well it scored.

## What the numbers say

MiniCPM5-1B is the fastest model that never misses the budget: 0/27 over
deadline, and its worst case is 1.77s against the 0.6b's 2.34s. It pays for that
with the lowest quality of the three, 79%. It loses the points in the same two
places the Qwen models lose them, spoken symbols (`.env`, `app.log`, `--force`,
`X_audio`) and self-corrections, and it loses more of them.

Qwen3-1.7B has the best quality, 88%, and cannot deliver it. Nine of 27 cases
miss the deadline, including every long one, so on those the user gets rule-based
output rather than the 88%. Its p95 is 4.59s. Quality that arrives after the
budget is not quality the user sees.

Qwen3-0.6B is still the best trade: 85% quality, 0.17s median, one case over
budget. Against MiniCPM it wins on quality by 6 points at the same order of
latency.

The lossy column is not a tiebreak here. Both 4-bit models sit at 10/27, meaning
the guards reject the model's answer and fall back to rules on a third of the
suite, and that fallback is what "quality is bad" feels like in use. The 1.7b is
1/27 lossy because it is careful, and 9/27 over deadline because being careful
takes time. So the app currently fails the same third of dictations two different
ways depending on which model is picked.

## Caveats

Time to first token is not measured. The harness times the whole completion and
the in-process path returns one string, so there is no first-token event to read.
Every number here is end to end.

MiniCPM5-1B needed two local fixes before it would run, both to the checkpoint on
disk and neither to any Swift source:

- `tokenizer_config.json` ships `eos_token: "</s>"` while the model stops on
  `<|im_end|>`. Without the fix every reply ran to the 16,000-character cap and
  repeated itself dozens of times. Set to `<|im_end|>`.
- Thinking is disabled through `chat_template.jinja`, whose `enable_thinking`
  branch was replaced with an unconditional `<think>\n\n</think>` after the
  generation prompt. `chat_template` in `tokenizer_config.json` is ignored by this
  stack; the `.jinja` file is what gets read, verified by swapping it for a
  sentinel template. The original file is kept beside it as
  `chat_template.jinja.orig`.

The `/no_think` switch the Qwen models take is not appended for MiniCPM, which is
correct: it is a Qwen training artifact and MiniCPM controls thinking through the
template.

## Per case

**Qwen3-0.6B-MLX-4bit / short_question** 0.10s 100% recall 100% ok

> Yeah, wait what's in this PR can you see the link again?

**Qwen3-0.6B-MLX-4bit / long_ramble** 0.80s 88% recall 100% LOSSY (lost content words): guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-MLX-4bit / terminal_flags** 0.17s 100% recall 100% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-MLX-4bit / jargon** 0.21s 67% recall 100% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**Qwen3-0.6B-MLX-4bit / self_correction** 0.11s 100% recall 100% ok

> Let's meet at 3 pm tomorrow at the office.

**Qwen3-0.6B-MLX-4bit / bug_report** 0.43s 100% recall 96% ok

> Okay so I tested the new build and the login flow is mostly working, but I found two issues: one is the spinner never goes away on slow connections, and two when you log out it doesn't actually clear the session. We should fix those before Friday.

**Qwen3-0.6B-MLX-4bit / question_not_instruction** 0.22s 100% recall 100% ok

> Hey, can you review my PR when you get a chance, it's the one that fixes the webhook retry logic?

**Qwen3-0.6B-MLX-4bit / discourse_like** 0.26s 71% recall 100% kept 'like closer'; LOSSY (lost content words): guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-MLX-4bit / stacked_fillers** 0.09s 100% recall 94% ok

> We should just ship it today and see what breaks.

**Qwen3-0.6B-MLX-4bit / meaningful_like** 0.10s 67% recall 78% missing 'something like that'; retained 58% < 80%

> I like the new design and it looks like a bug in the retry logic.

**Qwen3-0.6B-MLX-4bit / false_start** 0.24s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-MLX-4bit / restart_wrong_word** 0.13s 58% recall 95% kept 'sorry'

> Can you move the button to the right side of the toolbar, sorry?

**Qwen3-0.6B-MLX-4bit / restated_clause** 0.08s 100% recall 80% ok

> We should ship it on Thursday, before the demo.

**Qwen3-0.6B-MLX-4bit / abandoned_phrase** 0.12s 100% recall 83% ok

> The retry logic needs to check whether the webhook even fired before we retry anything.

**Qwen3-0.6B-MLX-4bit / snap_regions** 0.51s 65% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'dragon'; kept "shouldn't even be showing"; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / snap_regions_joined** 0.57s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / long_doc** 1.59s 92% recall 95% LOSSY (lost content words): guard rejected it, rules ran instead

> Okay so for the design doc i want to start with the problem which is that our dictation is accurate enough when you speak clearly but it falls apart the moment you mumble or trail off and the cleanup stage can't fix that because by then the words are already wrong. second section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds and the cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. third i want to lay out the three options we discussed which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remembering it. and then the last section is the recommendation which is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-MLX-4bit / long_meeting_notes** 0.06s 92% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. third thing, we still owe a decision on whether insert then upgrade ships on by default and i think the answer is no because replacing text in someone else's app can go wrong. and then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-MLX-4bit / draft_context** 0.16s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in Sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-MLX-4bit / agent_prompt_streaming** 0.06s 91% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-MLX-4bit / agent_prompt_ui_options** 0.51s 75% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-MLX-4bit / agent_prompt_council** 0.12s 86% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-0.6B-MLX-4bit / enumerated_options** 0.30s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> For the storage layer we could use postgres with a jsonb column or actually maybe duckdb since it's all analytical or we could just keep it in sqlite and deal with it later i'm leaning postgres but tell me if i'm wrong

**Qwen3-0.6B-MLX-4bit / identifier_symbols** 0.25s 50% recall 98% missing '--force'; missing '.env'; missing 'app.log'

> Check whether flag retry v2 is set in the dot env file and if it is, run npm run build dash dash force and then tail the logs in var log slash app dot log.

**Qwen3-0.6B-MLX-4bit / design_doc_polish_long** 2.34s 90% recall 100% **over 2034ms budget** LOSSY (lost content words): guard rejected it, rules ran instead

> Okay so for the reliability section i want to start with what actually happens today which is that when the webhook sender fails we just log it and move on so the customer never finds out and neither do we until they email us and then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the org owner listing anything that failed in the last twenty four hours and then third i want to talk about the tradeoff which is that a digest is not real time so if something breaks at nine in the morning they hear about it the next day and i think that's that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building

**Qwen3-0.6B-MLX-4bit / deliberate_repetition** 0.06s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

**Qwen3-0.6B-MLX-4bit / spoken_underscore** 0.09s 100% recall 67% ok

> Should our paper mention X_audio if we never use it?

**Qwen3-1.7B-MLX-8bit / short_question** 0.29s 100% recall 100% ok

> Yeah wait what's in this PR can you see the link again

**Qwen3-1.7B-MLX-8bit / long_ramble** 2.12s 88% recall 100% **over 1560ms budget** REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-1.7B-MLX-8bit / terminal_flags** 0.39s 100% recall 100% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-1.7B-MLX-8bit / jargon** 0.48s 100% recall 100% ok

> The work tree is dirty so I had to stash before rebasing onto main and the .env file was missing.

**Qwen3-1.7B-MLX-8bit / self_correction** 0.33s 50% recall 100% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**Qwen3-1.7B-MLX-8bit / bug_report** 1.20s 86% recall 100% kept 'the the'

> Okay so I tested the new build and the login flow it's it's mostly working but I found like two issues one is the the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so so yeah we should probably fix those before before friday

**Qwen3-1.7B-MLX-8bit / question_not_instruction** 0.48s 100% recall 100% ok

> Hey can you review my PR when you get a chance it's the one that fixes the webhook retry logic

**Qwen3-1.7B-MLX-8bit / discourse_like** 1.07s 100% recall 83% ok

> Our pill still sits a bit too high, could be closer to the system tray on a desktop or the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-1.7B-MLX-8bit / stacked_fillers** 0.28s 100% recall 100% ok

> I think we should just ship it today and see what breaks.

**Qwen3-1.7B-MLX-8bit / meaningful_like** 0.54s 100% recall 100% ok

> I like the new design and it looks like a bug in the retry logic so can you do something like that for the webhook one

**Qwen3-1.7B-MLX-8bit / false_start** 0.78s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-1.7B-MLX-8bit / restart_wrong_word** 0.40s 50% recall 100% kept 'to the left'; kept 'sorry'

> Can you move the button to the left, sorry, to the right side of the toolbar.

**Qwen3-1.7B-MLX-8bit / restated_clause** 0.39s 60% recall 100% kept 'friday'; kept 'actually'

> We should ship it on Friday, we should ship it on Thursday actually, before the demo.

**Qwen3-1.7B-MLX-8bit / abandoned_phrase** 0.37s 100% recall 92% ok

> The retry logic needs to first check whether the webhook even fired before we retry anything.

**Qwen3-1.7B-MLX-8bit / snap_regions** 1.93s 71% recall 100% **over 1362ms budget** kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-1.7B-MLX-8bit / snap_regions_joined** 1.96s 71% recall 100% **over 1362ms budget** kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-1.7B-MLX-8bit / long_doc** 3.72s 100% recall 100% **over 1992ms budget** ok

> Okay so for the design doc I want to start with the problem which is that our dictation is accurate enough when you speak clearly but it falls apart the moment you mumble or trail off and the cleanup stage can't fix that because by then the words are already wrong. Second section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds and the cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. Third I want to lay out the three options we discussed which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remembering it. And then the last section is the recommendation which is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-1.7B-MLX-8bit / long_meeting_notes** 3.10s 100% recall 100% **over 1794ms budget** ok

> So notes from the standup, Kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where SwiftUI declined the hit. Third thing, we still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-1.7B-MLX-8bit / draft_context** 0.54s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-1.7B-MLX-8bit / agent_prompt_streaming** 4.80s 100% recall 96% **over 2340ms budget** ok

> Okay so I need you to look at the streaming endpoint because right now we're buffering the whole response before we send it and that defeats the point of streaming. So what I want is to pipe the chunks straight through as they come in. And then there's a second thing which is rate limiting. We don't have any on that route so someone could just hammer it and take the whole service down. So I want a token bucket per API key like sixty requests a minute burst of ten and when they blow through it return a 429 with a retry after header not a 500 because a 500 makes it look like our fault. And then the third thing and this is the one I keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to. So check for the disconnect in the loop and bail out. And for testing I want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two.

**Qwen3-1.7B-MLX-8bit / agent_prompt_ui_options** 1.76s 86% recall 92% **over 1380ms budget** kept 'you know'

> Note latency is a huge factor. We want sub 500 to 600 milliseconds in the UI. I'm thinking there's model options like fastest, medium, and slow or something like that to show if someone wants to make the choice between three different choices. Maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best UI.

**Qwen3-1.7B-MLX-8bit / agent_prompt_council** 2.37s 100% recall 96% **over 1626ms budget** ok

> So we have two other agents working on bluejay whisper but I want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where I say a lot of text and it doesn't take into account that I'm trying to prompt maybe I'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent. Council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-1.7B-MLX-8bit / enumerated_options** 0.97s 100% recall 100% ok

> For the storage layer we could use postgres with a jsonb column, or actually maybe DuckDB since it's all analytical, or we could just keep it in sqlite and deal with it later. I'm leaning postgres but tell me if I'm wrong.

**Qwen3-1.7B-MLX-8bit / identifier_symbols** 0.66s 94% recall 88% missing 'app.log'

> Check whether flag retry v2 is set in the .env file and if it is run npm run build --force and then tail the logs in var/log/app.log

**Qwen3-1.7B-MLX-8bit / design_doc_polish_long** 3.45s 89% recall 100% **over 2034ms budget** kept 'we we'

> Okay so for the reliability section I want to start with what actually happens today which is that when the webhook sender fails we we just log it and move on so the customer never finds out and and neither do we until they email us and then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the the org owner listing anything that failed in the last twenty four hours and then third I want to talk about the the tradeoff which is that a digest is is not real time so if something breaks at nine in the morning they hear about it the next day and I think that's that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building

**Qwen3-1.7B-MLX-8bit / deliberate_repetition** 0.18s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

**Qwen3-1.7B-MLX-8bit / spoken_underscore** 0.29s 100% recall 83% ok

> Should our paper even mention X_audio if we never use it?

**MiniCPM5-1B-MLX-4bit / short_question** 0.07s 75% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> Yeah wait what's in this PR can you see the link again

**MiniCPM5-1B-MLX-4bit / long_ramble** 0.68s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**MiniCPM5-1B-MLX-4bit / terminal_flags** 0.15s 100% recall 100% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**MiniCPM5-1B-MLX-4bit / jargon** 0.19s 61% recall 87% missing '.env'

> The worktree is dirty, so I had to stash before rebasing onto main, and the dot env file was missing.

**MiniCPM5-1B-MLX-4bit / self_correction** 0.20s 50% recall 100% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**MiniCPM5-1B-MLX-4bit / bug_report** 0.07s 88% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> Okay so i tested the new build and the login flow it's it's mostly working but i found like two issues one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so yeah we should probably fix those before friday

**MiniCPM5-1B-MLX-4bit / question_not_instruction** 0.10s 83% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> Hey can you review my PR when you get a chance it's the one that fixes the webhook retry logic

**MiniCPM5-1B-MLX-4bit / discourse_like** 0.28s 71% recall 100% kept 'like closer'; LOSSY (lost content words): guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**MiniCPM5-1B-MLX-4bit / stacked_fillers** 0.11s 100% recall 100% ok

> I think we should just ship it today and see what breaks.

**MiniCPM5-1B-MLX-4bit / meaningful_like** 0.22s 100% recall 89% ok

> I like the new design, and it looks like a bug in the retry logic, so can you do something like that for the webhook.

**MiniCPM5-1B-MLX-4bit / false_start** 0.26s 83% recall 100% kept 'like center'

> And by its dragging to left or right, I mean, it's going to anchor to the center, vertically centered, left side, or vertically centered right side of the screen.

**MiniCPM5-1B-MLX-4bit / restart_wrong_word** 0.16s 50% recall 100% kept 'to the left'; kept 'sorry'

> Can you move the button to the left, sorry, to the right side of the toolbar.

**MiniCPM5-1B-MLX-4bit / restated_clause** 0.16s 73% recall 100% kept 'friday'

> We should ship it on Friday, we should ship it on Thursday, and before the demo.

**MiniCPM5-1B-MLX-4bit / abandoned_phrase** 0.16s 100% recall 92% ok

> The retry logic needs to first check whether the webhook even fired before we retry anything.

**MiniCPM5-1B-MLX-4bit / snap_regions** 0.65s 68% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**MiniCPM5-1B-MLX-4bit / snap_regions_joined** 0.64s 68% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**MiniCPM5-1B-MLX-4bit / long_doc** 1.10s 92% recall 92% missing 'remembering it'

> I tested the Kubernetes deployment work. I want to start with the problem: our dictation is accurate enough when you speak clearly, but it falls apart the moment you mumble or trail off. The transcription tail is about a hundred and forty milliseconds, and the cleanup call is around three hundred. Neither of those is the bottleneck, the bottleneck is recognition quality. I want to lay out the three options we discussed, which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remember it. The last section is the recommendation: we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**MiniCPM5-1B-MLX-4bit / long_meeting_notes** 0.08s 92% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. third thing, we still owe a decision on whether insert then upgrade ships on by default and i think the answer is no because replacing text in someone else's app can go wrong. and then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**MiniCPM5-1B-MLX-4bit / draft_context** 0.21s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 is on for about 10 percent of orgs.

**MiniCPM5-1B-MLX-4bit / agent_prompt_streaming** 1.77s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**MiniCPM5-1B-MLX-4bit / agent_prompt_ui_options** 0.61s 74% recall 99% kept 'you know'; LOSSY (dropped content): guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**MiniCPM5-1B-MLX-4bit / agent_prompt_council** 0.37s 86% recall 100% LOSSY (lost content words): guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**MiniCPM5-1B-MLX-4bit / enumerated_options** 0.36s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> For the storage layer we could use postgres with a jsonb column or actually maybe duckdb since it's all analytical or we could just keep it in sqlite and deal with it later i'm leaning postgres but tell me if i'm wrong

**MiniCPM5-1B-MLX-4bit / identifier_symbols** 0.28s 48% recall 79% missing '--force'; missing '.env'; missing 'app.log'

> Check whether flag retry v2 is set in the dotenv file and if it is, run `npm run build` and then tail the logs in `var log slash app dot log`.

**MiniCPM5-1B-MLX-4bit / design_doc_polish_long** 1.30s 85% recall 90% missing 'twenty four hours'

> I want to start with what actually happens today, which is that when the webhook sender fails, we just log it and move on. The customer will never know, and neither do we until they email us, and then the second part should be what we're proposing, which is a dead letter table plus a daily digest that goes to the owner listing anything that failed in the last 24 hours, and then third, i want to talk about the tradeoff, which is that a digest is not real time, so if something breaks at 9 AM, they hear about it the next day, and i think that's acceptable for now, because the alternative is to build a whole alerting system, and we don't have anyone to build that this quarter, and then last, the rollout plan is to ship the table first, behind a flag measure how often it actually fills up on real traffic, and only then decide whether the digest is even worth building.

**MiniCPM5-1B-MLX-4bit / deliberate_repetition** 0.14s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

**MiniCPM5-1B-MLX-4bit / spoken_underscore** 0.12s 56% recall 94% missing 'X_audio'; kept 'X underscore'

> Should our paper even mention X underscore audio if we never use it?
