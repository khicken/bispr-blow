# Cleanup benchmark (nothink=auto, reps=3, deadline=900ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-1.7B-MLX-8bit | 97% | 88% | 0.63s | 4.06s | 4.09s | 9/27 | 1/27 | 1/27 |
| Qwen3-0.6B-MLX-4bit | 93% | 83% | 0.15s | 1.06s | 2.44s | 1/27 | 9/27 | 3/27 |

## Per case

**Qwen3-0.6B-MLX-4bit / short_question** 0.07s 33% recall 40% missing 'link'; retained 50% < 60%

> Yes, wait what's in this PR?

**Qwen3-0.6B-MLX-4bit / long_ramble** 0.74s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-MLX-4bit / terminal_flags** 0.12s 100% recall 100% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-MLX-4bit / jargon** 0.15s 67% recall 93% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**Qwen3-0.6B-MLX-4bit / self_correction** 0.10s 67% recall 100% kept 'at 2'; kept 'actually'

> Let's meet at 3 pm tomorrow at the office.

**Qwen3-0.6B-MLX-4bit / bug_report** 0.28s 96% recall 95% LOSSY (lost content words): guard rejected it, rules ran instead

> Okay so i tested the new build and the login flow it's it's mostly working but i found like two issues one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so yeah we should probably fix those before friday

**Qwen3-0.6B-MLX-4bit / question_not_instruction** 0.14s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-MLX-4bit / discourse_like** 0.26s 71% recall 100% kept 'like closer'; LOSSY (lost content words): guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-MLX-4bit / stacked_fillers** 0.05s 86% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**Qwen3-0.6B-MLX-4bit / meaningful_like** 0.17s 100% recall 100% ok

> I like the new design and it looks like a bug in the retry logic. So can you do something like that for the webhook one?

**Qwen3-0.6B-MLX-4bit / false_start** 0.23s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-MLX-4bit / restart_wrong_word** 0.09s 100% recall 71% ok

> Can you move the button to the right side of the toolbar?

**Qwen3-0.6B-MLX-4bit / restated_clause** 0.07s 100% recall 80% ok

> We should ship it on Thursday, before the demo.

**Qwen3-0.6B-MLX-4bit / abandoned_phrase** 0.11s 100% recall 83% ok

> The retry logic needs to check whether the webhook even fired before we retry anything.

**Qwen3-0.6B-MLX-4bit / snap_regions** 0.58s 68% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / snap_regions_joined** 0.57s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / long_doc** 1.05s 92% recall 93% missing 'remembering it'

> Okay so for the design doc, I want to start with the problem: our dictation is accurate when you speak clearly, but falls apart when you mumble or trail off. The cleanup stage can't fix that because by then the words are already wrong. Second section should cover what we actually measured: the transcription tail is about a hundred and forty milliseconds, and the cleanup call is around three hundred. Neither of those is the bottleneck, the bottleneck is recognition quality. Third, I want to lay out the three options: biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remember it. And then the recommendation: we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-MLX-4bit / long_meeting_notes** 0.05s 92% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. third thing, we still owe a decision on whether insert then upgrade ships on by default and i think the answer is no because replacing text in someone else's app can go wrong. and then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-MLX-4bit / draft_context** 0.15s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-MLX-4bit / agent_prompt_streaming** 0.06s 91% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-MLX-4bit / agent_prompt_ui_options** 0.51s 75% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-MLX-4bit / agent_prompt_council** 0.06s 86% recall 100% LOSSY (dropped content): guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-0.6B-MLX-4bit / enumerated_options** 0.29s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> For the storage layer we could use postgres with a jsonb column or actually maybe duckdb since it's all analytical or we could just keep it in sqlite and deal with it later i'm leaning postgres but tell me if i'm wrong

**Qwen3-0.6B-MLX-4bit / identifier_symbols** 0.23s 48% recall 100% missing '--force'; missing '.env'; missing 'app.log'

> Check whether flag retry v2 is set in the dot env file and if it is, run npm run build dash dash force and then tail the logs in var log slash app dot log.

**Qwen3-0.6B-MLX-4bit / design_doc_polish_long** 2.44s 93% recall 100% **over 2034ms budget** kept 'we we'

> Okay, so for the Notion writing app transcript, I need to clean up the transcript. Let's go step by step. First, remove any filler words like "um" and "uh". The transcript is: "okay so for the reliability section i want to start with what actually happens today which is that when the webhook sender fails we we just log it and move on so the customer never finds out and and neither do we until they email us and then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the the org owner listing anything that failed in the last twenty four hours and then third i want to talk about the the tradeoff which is that a digest is is not real time so if something breaks at nine in the morning they hear about it the next day and i think that's that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building. Now, applying the rules: 1. Remove any filler words: "um" and "uh" in the transcript.
2. Replace any words that are repeated or false starts with their correct final form.
3. Ensure the transcript is in proper capitalization and punctuation.
4. Preserve the speaker's meaning and tone.
5. Keep the transcript clean and free of any markdown or formatting. After applying these rules, the cleaned transcript would look like this: Okay, so for the reliability section, I want to start with what actually happens today. That is, when the webhook sender fails, we just log it and move on. So the customer never finds out, and neither do we until they email us. Then the second part should be what we're proposing. That is, a dead letter table plus a daily digest that goes to the the org owner. Listing anything that failed in the last twenty four hours. Then, the third part is about the the tradeoff. Which is that a digest is not real time. So if something breaks at nine in the morning, they hear about it the next day. And I think that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building.

**Qwen3-0.6B-MLX-4bit / deliberate_repetition** 0.06s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

**Qwen3-0.6B-MLX-4bit / spoken_underscore** 0.09s 100% recall 67% ok

> Should our paper mention X_audio if we never use it.

**Qwen3-1.7B-MLX-8bit / short_question** 0.26s 100% recall 100% ok

> Yeah wait what's in this PR can you see the link again

**Qwen3-1.7B-MLX-8bit / long_ramble** 1.99s 88% recall 100% **over 1560ms budget** REWORDED: subsequence guard rejected it, rules ran instead; LOSSY (reworded content on the coding path): guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-1.7B-MLX-8bit / terminal_flags** 0.35s 100% recall 100% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-1.7B-MLX-8bit / jargon** 0.46s 100% recall 100% ok

> The work tree is dirty, so I had to stash before rebasing onto main and the .env file was missing.

**Qwen3-1.7B-MLX-8bit / self_correction** 0.30s 50% recall 100% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**Qwen3-1.7B-MLX-8bit / bug_report** 1.08s 86% recall 100% kept 'the the'

> Okay so I tested the new build and the login flow it's it's mostly working but I found like two issues one is the the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so so yeah we should probably fix those before before friday

**Qwen3-1.7B-MLX-8bit / question_not_instruction** 0.39s 100% recall 100% ok

> Hey can you review my PR when you get a chance it's the one that fixes the webhook retry logic

**Qwen3-1.7B-MLX-8bit / discourse_like** 1.07s 94% recall 84% kept 'like closer'

> Our pill still sits a bit too high, could be closer to the system tray on a desktop or the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-1.7B-MLX-8bit / stacked_fillers** 0.21s 100% recall 83% ok

> We should ship it today and see what breaks.

**Qwen3-1.7B-MLX-8bit / meaningful_like** 0.47s 100% recall 100% ok

> I like the new design and it looks like a bug in the retry logic so can you do something like that for the webhook one

**Qwen3-1.7B-MLX-8bit / false_start** 0.69s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-1.7B-MLX-8bit / restart_wrong_word** 0.35s 50% recall 100% kept 'to the left'; kept 'sorry'

> Can you move the button to the left, sorry, to the right side of the toolbar

**Qwen3-1.7B-MLX-8bit / restated_clause** 0.37s 60% recall 100% kept 'friday'; kept 'actually'

> We should ship it on Friday, we should ship it on Thursday actually, before the demo.

**Qwen3-1.7B-MLX-8bit / abandoned_phrase** 0.34s 100% recall 92% ok

> The retry logic needs to first check whether the webhook even fired before we retry anything.

**Qwen3-1.7B-MLX-8bit / snap_regions** 1.76s 71% recall 100% **over 1362ms budget** kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-1.7B-MLX-8bit / snap_regions_joined** 1.77s 71% recall 100% **over 1362ms budget** kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-1.7B-MLX-8bit / long_doc** 3.26s 100% recall 100% **over 1992ms budget** ok

> Okay so for the design doc I want to start with the problem which is that our dictation is accurate enough when you speak clearly but it falls apart the moment you mumble or trail off and the cleanup stage can't fix that because by then the words are already wrong. Second section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds and the cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. Third I want to lay out the three options we discussed which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remembering it. And then the last section is the recommendation which is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-1.7B-MLX-8bit / long_meeting_notes** 2.69s 100% recall 100% **over 1794ms budget** ok

> So notes from the standup, Kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where SwiftUI declined the hit. Third thing, we still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-1.7B-MLX-8bit / draft_context** 0.48s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-1.7B-MLX-8bit / agent_prompt_streaming** 4.09s 100% recall 96% **over 2340ms budget** ok

> Okay so I need you to look at the streaming endpoint because right now we're buffering the whole response before we send it and that defeats the point of streaming. So what I want is to pipe the chunks straight through as they come in. And then there's a second thing which is rate limiting. We don't have any on that route so someone could just hammer it and take the whole service down. So I want a token bucket per API key like sixty requests a minute burst of ten and when they blow through it return a 429 with a retry after header not a 500 because a 500 makes it look like our fault. And then the third thing and this is the one I keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to. So check for the disconnect in the loop and bail out. And for testing I want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two.

**Qwen3-1.7B-MLX-8bit / agent_prompt_ui_options** 1.57s 86% recall 92% **over 1380ms budget** kept 'you know'

> Note latency is a huge factor. We want sub 500 to 600 milliseconds in the UI. I'm thinking there's model options like fastest, medium, and slow or something like that to show if someone wants to make the choice between three different choices. Maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best UI.

**Qwen3-1.7B-MLX-8bit / agent_prompt_council** 2.18s 100% recall 96% **over 1626ms budget** ok

> So we have two other agents working on bluejay whisper but I want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where I say a lot of text and it doesn't take into account that I'm trying to prompt maybe I'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent. Council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-1.7B-MLX-8bit / enumerated_options** 0.90s 100% recall 100% ok

> For the storage layer we could use postgres with a jsonb column or actually maybe DuckDB since it's all analytical, or we could just keep it in sqlite and deal with it later. I'm leaning postgres but tell me if I'm wrong.

**Qwen3-1.7B-MLX-8bit / identifier_symbols** 0.63s 100% recall 81% ok

> Check whether flag retry v2 is set in the .env file and if it is, run npm run build --force and then tail the logs in var/log/app.log

**Qwen3-1.7B-MLX-8bit / design_doc_polish_long** 3.38s 89% recall 100% **over 2034ms budget** kept 'we we'

> Okay so for the reliability section I want to start with what actually happens today which is that when the webhook sender fails we we just log it and move on so the customer never finds out and and neither do we until they email us and then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the the org owner listing anything that failed in the last twenty four hours and then third I want to talk about the the tradeoff which is that a digest is is not real time so if something breaks at nine in the morning they hear about it the next day and I think that's that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building

**Qwen3-1.7B-MLX-8bit / deliberate_repetition** 0.19s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

**Qwen3-1.7B-MLX-8bit / spoken_underscore** 0.27s 100% recall 83% ok

> Should our paper even mention X_audio if we never use it?

