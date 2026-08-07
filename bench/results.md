# Cleanup benchmark (nothink=auto, reps=2, deadline=400ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| qwen3-0.6b-mlx | 96% | 84% | 0.37s | 1.35s | 1.57s | 0/25 | 5/25 | 3/25 |

## Per case

**qwen3-0.6b-mlx / short_question** 0.26s 100% recall 100% ok

> Yeah, wait, what's in this PR? Can you see the link again?

**qwen3-0.6b-mlx / long_ramble** 0.74s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**qwen3-0.6b-mlx / terminal_flags** 0.25s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**qwen3-0.6b-mlx / jargon** 0.29s 67% recall 100% missing '.env'

> the work tree is dirty, so i had to stash before rebasing onto main and the dot env file was missing.

**qwen3-0.6b-mlx / self_correction** 0.21s 100% recall 100% ok

> Let's meet at 3 pm tomorrow at the office.

**qwen3-0.6b-mlx / bug_report** 0.46s 100% recall 96% ok

> Okay so I tested the new build and the login flow is mostly working, but I found two issues. One is the spinner never goes away on slow connections. Two when you log out it doesn't actually clear the session. We should fix those before Friday.

**qwen3-0.6b-mlx / question_not_instruction** 0.26s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**qwen3-0.6b-mlx / discourse_like** 0.30s 71% recall 100% kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**qwen3-0.6b-mlx / stacked_fillers** 0.17s 86% recall 100% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**qwen3-0.6b-mlx / meaningful_like** 0.29s 88% recall 100% missing 'something like that'

> I like the new design and it looks like a bug in the retry logic. So can you do something for the webhook one?

**qwen3-0.6b-mlx / false_start** 0.37s 75% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side or vertically centered right side of the screen.

**qwen3-0.6b-mlx / restart_wrong_word** 0.23s 100% recall 71% ok

> Can you move the button to the right side of the toolbar?

**qwen3-0.6b-mlx / restated_clause** 0.20s 80% recall 80% kept 'actually'

> We should ship it on Thursday actually, before the demo.

**qwen3-0.6b-mlx / abandoned_phrase** 0.27s 75% recall 100% kept 'needs to, we'

> the retry logic needs to, we need to first check whether the webhook even fired before we retry anything.

**qwen3-0.6b-mlx / snap_regions** 0.65s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**qwen3-0.6b-mlx / snap_regions_joined** 0.64s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**qwen3-0.6b-mlx / long_doc** 1.13s 88% recall 88% missing 'remembering it'

> Okay so we want to start with the problem. The design doc is about the problem. Our dictation is accurate when you speak clearly, but it falls apart when you mumble or trail off. The cleanup stage can't fix that because by then the words are already wrong. Next section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds. The cleanup call is around three hundred. Neither of those is the bottleneck, the bottleneck is recognition quality. Next section: we discussed three options: biasing the recognizer with a vocabulary list, feeding focused field's text in as context, and letting the user correct a word once and remember it. Then the recommendation: we do the third one because it's the only one that gets better as you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**qwen3-0.6b-mlx / long_meeting_notes** 0.89s 91% recall 81% missing 'recorder'; missing 'borderless panel'

> Kaleb is still on the shortcut. The event tap part is done. The recorder UI will take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and it's fixed now. It was a borderless panel claiming every point in its frame even where swiftui declined the hit. We still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**qwen3-0.6b-mlx / draft_context** 0.27s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**qwen3-0.6b-mlx / agent_prompt_streaming** 1.57s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**qwen3-0.6b-mlx / agent_prompt_ui_options** 0.64s 80% recall 100% kept 'you know'

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the UI. I'm thinking that there's model options like fastest, medium, and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best UI.

**qwen3-0.6b-mlx / agent_prompt_council** 0.82s 86% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**qwen3-0.6b-mlx / enumerated_options** 0.44s 86% recall 100% missing 'actually'

> for the storage layer, we could use postgres with a jsonb column or duckdb since it's all analytical. We could keep it in sqlite and deal with it later. I'm leaning postgres, but tell me if I'm wrong.

**qwen3-0.6b-mlx / identifier_symbols** 0.44s 50% recall 100% missing '--force'; missing '.env'; missing 'app.log'

> check whether flag retry v2 is set in the dot env file and if it is, run npm run build dash dash force and then tail the logs in var log slash app dot log

**qwen3-0.6b-mlx / design_doc_polish_long** 1.32s 100% recall 100% ok

> Okay so for the reliability section, I want to start with what actually happens today which is that when the webhook sender fails we just log it and move on. The customer never finds out and neither do we until they email us. Then the second part should be what we're proposing which is a dead letter table plus a daily digest that goes to the the org owner listing anything that failed in the last twenty four hours and then third part i want to talk about the tradeoff which is that a digest is not real time so if something breaks at nine in the morning they hear about it the next day and i think that's acceptable for now because the alternative is a whole alerting system and we don't we don't have anyone to build that this quarter and then last the rollout plan is we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building.

