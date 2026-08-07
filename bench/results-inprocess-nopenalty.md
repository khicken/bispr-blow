# Cleanup benchmark (nothink=auto, reps=3, deadline=900ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-0.6B-Q4_K_M | 94% | 77% | 0.26s | 0.85s | 0.85s | 0/25 | 13/25 | 7/25 |
| Qwen3-0.6B-Q8_0 | 92% | 78% | 0.36s | 1.74s | 1.87s | 0/25 | 12/25 | 8/25 |

## Per case

**Qwen3-0.6B-Q8_0 / short_question** 0.12s 33% recall 80% missing 'PR'; retained 58% < 60%

> Wait, can you see the link again?

**Qwen3-0.6B-Q8_0 / long_ramble** 0.90s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-Q8_0 / terminal_flags** 0.20s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-Q8_0 / jargon** 0.26s 100% recall 91% ok

> The work tree is dirty, so I had to stash before rebasing onto main, and the .env file was missing.

**Qwen3-0.6B-Q8_0 / self_correction** 0.15s 100% recall 100% ok

> Let's meet at 3 pm tomorrow at the office.

**Qwen3-0.6B-Q8_0 / bug_report** 0.45s 96% recall 95% LOSSY: guard rejected it, rules ran instead

> Okay so i tested the new build and the login flow it's it's mostly working but i found like two issues one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so yeah we should probably fix those before friday

**Qwen3-0.6B-Q8_0 / question_not_instruction** 0.24s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-Q8_0 / discourse_like** 0.36s 71% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-Q8_0 / stacked_fillers** 0.10s 86% recall 100% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**Qwen3-0.6B-Q8_0 / meaningful_like** 0.14s 80% recall 100% LOSSY: guard rejected it, rules ran instead

> I like the new design and it looks like a bug in the retry logic so can you do something like that for the webhook one

**Qwen3-0.6B-Q8_0 / false_start** 0.36s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-Q8_0 / restart_wrong_word** 0.14s 100% recall 71% ok

> Move the button to the right side of the toolbar.

**Qwen3-0.6B-Q8_0 / restated_clause** 0.15s 80% recall 80% kept 'actually'

> We should ship it on Thursday, and actually before the demo.

**Qwen3-0.6B-Q8_0 / abandoned_phrase** 0.18s 60% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'needs to, we'; LOSSY: guard rejected it, rules ran instead

> The retry logic needs to, we need to first check whether the webhook even fired before we retry anything

**Qwen3-0.6B-Q8_0 / snap_regions** 0.58s 59% recall 89% missing "and then it'll snap"; kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. We shouldn't even be showing the pill is being picked up.

**Qwen3-0.6B-Q8_0 / snap_regions_joined** 0.50s 29% recall 58% missing 'snapped into the other 2 possible positions'; missing "and then it'll snap"; kept 'dragon'; kept "shouldn't even be showing"; retained 52% < 60%

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-Q8_0 / long_doc** 1.34s 86% recall 81% missing 'remembering it'

> Okay so for the design doc, I want to start with the problem: our dictation is accurate when we speak clearly, but it falls apart when we mumble or trail off. The cleanup stage can't fix that because the words are already wrong. The second section should cover what we actually measured: the transcription tail is about a hundred and forty milliseconds, and the cleanup call is around three hundred. The bottleneck is recognition quality. The third option is to bias the recognizer with a vocabulary list, feed focused field's text as context, and let the user correct a word once and remember it. The recommendation is to go with that option because it gets better with use, and we should ship it behind a flag so we can measure it on real dictations before turning it on.

**Qwen3-0.6B-Q8_0 / long_meeting_notes** 0.77s 82% recall 86% LOSSY: guard rejected it, rules ran instead

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. third thing, we still owe a decision on whether insert then upgrade ships on by default and i think the answer is no because replacing text in someone else's app can go wrong. and then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-Q8_0 / draft_context** 0.25s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in Sentry and the flag retry V2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-Q8_0 / agent_prompt_streaming** 1.87s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-Q8_0 / agent_prompt_ui_options** 0.57s 75% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY: guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-Q8_0 / agent_prompt_council** 1.03s 86% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-0.6B-Q8_0 / enumerated_options** 0.49s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> For the storage layer we could use postgres with a jsonb column or actually maybe duckdb since it's all analytical or we could just keep it in sqlite and deal with it later i'm leaning postgres but tell me if i'm wrong

**Qwen3-0.6B-Q8_0 / identifier_symbols** 0.40s 43% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; missing '--force'; missing '.env'; missing 'app.log'; LOSSY: guard rejected it, rules ran instead

> Check whether flag retry v2 is set in the dot env file and if it is run npm run build dash force and then tail the logs in var log slash app dot log

**Qwen3-0.6B-Q8_0 / design_doc_polish_long** 1.41s 85% recall 80% missing 'twenty four hours'

> Okay so for the reliability section, I want to start with what actually happens today, when the webhook sender fails, we just log it and move on. The customer never finds out and we don't know until they email us. The second part is what we're proposing, a dead letter table plus a daily digest that goes to the org owner. The third part is the tradeoff, a digest is not real-time. If something breaks at nine in the morning, they hear about it the next day, and I think that's acceptable for now because the alternative is a whole alerting system and we don't have anyone to build that this quarter. Last, the rollout plan is we ship the table first, and we flag how often it actually fills up on real traffic, and only then decide whether the digest is even worth building.

**Qwen3-0.6B-Q4_K_M / short_question** 0.09s 33% recall 80% missing 'PR'; retained 58% < 60%

> Wait, can you see the link again?

**Qwen3-0.6B-Q4_K_M / long_ramble** 0.62s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-Q4_K_M / terminal_flags** 0.15s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-Q4_K_M / jargon** 0.20s 67% recall 100% missing '.env'

> the work tree is dirty, so i had to stash before rebasing onto main, and the dot env file was missing.

**Qwen3-0.6B-Q4_K_M / self_correction** 0.11s 100% recall 100% ok

> Let's meet at 3 pm tomorrow at the office.

**Qwen3-0.6B-Q4_K_M / bug_report** 0.14s 88% recall 100% LOSSY: guard rejected it, rules ran instead

> Okay so i tested the new build and the login flow it's it's mostly working but i found like two issues one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so yeah we should probably fix those before friday

**Qwen3-0.6B-Q4_K_M / question_not_instruction** 0.18s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-Q4_K_M / discourse_like** 0.28s 71% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-Q4_K_M / stacked_fillers** 0.05s 86% recall 100% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**Qwen3-0.6B-Q4_K_M / meaningful_like** 0.13s 27% recall 70% missing 'like the new design'; missing 'looks like a bug'; missing 'something like that'; retained 54% < 80%

> Do you want the webhook one to have a bug in the retry logic?

**Qwen3-0.6B-Q4_K_M / false_start** 0.28s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-Q4_K_M / restart_wrong_word** 0.10s 50% recall 71% missing 'right side'; kept 'to the left'

> Move the button to the left side of the toolbar.

**Qwen3-0.6B-Q4_K_M / restated_clause** 0.13s 100% recall 80% ok

> We should ship it on Thursday, and let's do it before the demo.

**Qwen3-0.6B-Q4_K_M / abandoned_phrase** 0.14s 100% recall 83% ok

> the retry logic needs to check whether the webhook even fired before we retry anything.

**Qwen3-0.6B-Q4_K_M / snap_regions** 0.30s 61% recall 94% REWORDED: subsequence guard rejected it, rules ran instead; kept 'dragon'; kept "shouldn't even be showing"; LOSSY: guard rejected it, rules ran instead

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-Q4_K_M / snap_regions_joined** 0.26s 51% recall 86% REWORDED: subsequence guard rejected it, rules ran instead; kept 'dragon'; kept "shouldn't even be showing"; LOSSY: guard rejected it, rules ran instead

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-Q4_K_M / long_doc** 0.59s 92% recall 100% LOSSY: guard rejected it, rules ran instead

> Okay so for the design doc i want to start with the problem which is that our dictation is accurate enough when you speak clearly but it falls apart the moment you mumble or trail off and the cleanup stage can't fix that because by then the words are already wrong. second section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds and the cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. third i want to lay out the three options we discussed which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remembering it. and then the last section is the recommendation which is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-Q4_K_M / long_meeting_notes** 0.51s 92% recall 100% LOSSY: guard rejected it, rules ran instead

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. third thing, we still owe a decision on whether insert then upgrade ships on by default and i think the answer is no because replacing text in someone else's app can go wrong. and then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-Q4_K_M / draft_context** 0.20s 67% recall 100% missing 'FLAG_RETRY_V2'

> so far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-Q4_K_M / agent_prompt_streaming** 0.62s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-Q4_K_M / agent_prompt_ui_options** 0.62s 75% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY: guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-Q4_K_M / agent_prompt_council** 0.85s 86% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-0.6B-Q4_K_M / enumerated_options** 0.37s 86% recall 100% missing 'actually'

> for the storage layer, we could use postgres with a jsonb column, or maybe duckdb since it's all analytical, or we could just keep it in sqlite and deal with it later. I'm leaning postgres, but tell me if I'm wrong.

**Qwen3-0.6B-Q4_K_M / identifier_symbols** 0.30s 48% recall 100% missing '--force'; missing '.env'; missing 'app.log'; LOSSY: guard rejected it, rules ran instead

> Check whether flag retry v2 is set in the dot env file and if it is run npm run build dash force and then tail the logs in var log slash app dot log

**Qwen3-0.6B-Q4_K_M / design_doc_polish_long** 0.38s 90% recall 100% LOSSY: guard rejected it, rules ran instead

> Okay so for the reliability section i want to start with what actually happens today which is that when the webhook sender fails we just log it and move on so the customer never finds out and neither do we until they email us and then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the org owner listing anything that failed in the last twenty four hours and then third i want to talk about the tradeoff which is that a digest is not real time so if something breaks at nine in the morning they hear about it the next day and i think that's that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building

