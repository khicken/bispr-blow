# Cleanup benchmark (nothink=auto, reps=3, deadline=900ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-0.6B-MLX-4bit | 94% | 84% | 0.23s | 1.58s | 1.58s | 0/26 | 5/26 | 3/26 |

## Per case

**Qwen3-0.6B-MLX-4bit / short_question** 0.07s 56% recall 60% missing 'link'; retained 50% < 60%

> Yeah, wait what's in this PR?

**Qwen3-0.6B-MLX-4bit / long_ramble** 0.74s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-MLX-4bit / terminal_flags** 0.12s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-MLX-4bit / jargon** 0.15s 67% recall 100% missing '.env'

> the work tree is dirty, so i had to stash before rebasing onto main and the dot env file was missing.

**Qwen3-0.6B-MLX-4bit / self_correction** 0.10s 75% recall 100% kept 'at 2'

> Let's meet at 2:30 PM tomorrow at the office.

**Qwen3-0.6B-MLX-4bit / bug_report** 0.28s 100% recall 92% ok

> Okay so the new build and the login flow is mostly working but I found two issues: one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session. We should fix those before before Friday.

**Qwen3-0.6B-MLX-4bit / question_not_instruction** 0.14s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-MLX-4bit / discourse_like** 0.18s 71% recall 100% kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-MLX-4bit / stacked_fillers** 0.06s 90% recall 100% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**Qwen3-0.6B-MLX-4bit / meaningful_like** 0.16s 100% recall 100% ok

> I like the new design and it looks like a bug in the retry logic. So can you do something like that for the webhook one?

**Qwen3-0.6B-MLX-4bit / false_start** 0.23s 75% recall 91% kept 'like center'

> And by it's dragging to left or right, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-MLX-4bit / restart_wrong_word** 0.09s 100% recall 71% ok

> Can you move the button to the right side of the toolbar?

**Qwen3-0.6B-MLX-4bit / restated_clause** 0.09s 80% recall 80% kept 'actually'

> We should ship it on Thursday actually, before the demo.

**Qwen3-0.6B-MLX-4bit / abandoned_phrase** 0.13s 100% recall 83% ok

> the retry logic needs to check whether the webhook even fired before we retry anything

**Qwen3-0.6B-MLX-4bit / snap_regions** 0.57s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / snap_regions_joined** 0.61s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / long_doc** 1.58s 86% recall 85% missing 'hundred and forty'; missing 'three hundred'; missing 'remembering it'

> Okay, so the transcript is about Notion. Let me go through it step by step. First, the speaker mentions that their dictation is accurate when speaking clearly but fails when they mumble or trail off. The cleanup stage can't fix this because the words are already wrong. Then they talk about two issues: one about the spinner not going away on slow connections, and another about logging out not clearing the session. They mention that these issues are not the bottleneck, and the bottleneck is recognition quality. Next, they talk about laying out three options: biasing the recognizer with a vocabulary list, feeding focused field text in as context, and letting the user correct a word once and remember it. Finally, they mention the recommendation being the third option because it gets better with use and should be shipped behind a flag to measure it on real dictations before turning it on for everyone. So putting it all together, the cleaned transcript would be: Okay, so for the design doc, we start with the problem: our dictation is accurate when speaking clearly but falls apart when we mumble or trail off. The cleanup stage can't fix this because the words are already wrong. Then we talk about two issues: one about the spinner not going away on slow connections, and another about logging out not clearing the session. We should fix those before Friday. The recommendation is the third option, which is the only one that gets better with use and should be shipped behind a flag to measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-MLX-4bit / long_meeting_notes** 1.35s 100% recall 99% ok

> So notes from the standup, kaleb is still on the shortcut, he said the event tap part is done, but the recorder UI is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. Third thing, we still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And then last, nobody has actually dictated into the instrumented build yet, so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-MLX-4bit / draft_context** 0.24s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-MLX-4bit / agent_prompt_streaming** 1.42s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-MLX-4bit / agent_prompt_ui_options** 0.60s 79% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY: guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-MLX-4bit / agent_prompt_council** 0.90s 100% recall 100% ok

> So we have two other agents working on Blue Jay Whisper. I want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where I say a lot of text and it doesn't take into account that I'm trying to prompt maybe I'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent. So council our quality issues. You get a council of agents by using the debate skill and our prompt. Our system prompt and how our design works to give the best transcription quality. Imagine you're whisper flow and we're trying to replicate whisper flow one to one.

**Qwen3-0.6B-MLX-4bit / enumerated_options** 0.35s 86% recall 100% missing 'actually'

> for the storage layer, we could use postgres with a jsonb column, or maybe duckdb since it's all analytical. or we could just keep it in sqlite and deal with it later. I'm leaning postgres, but tell me if I'm wrong.

**Qwen3-0.6B-MLX-4bit / identifier_symbols** 0.28s 50% recall 100% missing '--force'; missing '.env'; missing 'app.log'

> check whether flag retry v2 is set in the dot env file and if it is, run npm run build dash dash force and then tail the logs in var log slash app dot log

**Qwen3-0.6B-MLX-4bit / design_doc_polish_long** 1.22s 89% recall 83% missing 'twenty four hours'

> Okay, so for the reliability section, I want to start with the issue where the webhook sender fails, and we just log it and move on. The customer never finds out, and neither do we until they email us. Then the second part is about the proposed solution: a dead letter table plus a daily digest that goes to the org owner. The third part is about the tradeoff: a digest is not real time. If something breaks at nine in the morning, they hear about it the next day, and that's acceptable for now. Then the rollout plan is to ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building.

**Qwen3-0.6B-MLX-4bit / deliberate_repetition** 0.10s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

