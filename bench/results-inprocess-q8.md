# Cleanup benchmark (nothink=auto, reps=3, deadline=900ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-0.6B-Q8_0 | 94% | 81% | 0.38s | 1.76s | 1.91s | 0/25 | 13/25 | 9/25 |

## Per case

**Qwen3-0.6B-Q8_0 / short_question** 0.13s 33% recall 80% missing 'PR'; retained 58% < 60%

> Wait, can you see the link again?

**Qwen3-0.6B-Q8_0 / long_ramble** 0.66s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-Q8_0 / terminal_flags** 0.20s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-Q8_0 / jargon** 0.26s 100% recall 91% ok

> The work tree is dirty, so I had to stash before rebasing onto main, and the .env file was missing.

**Qwen3-0.6B-Q8_0 / self_correction** 0.15s 100% recall 100% ok

> Let's meet at 3 pm tomorrow at the office.

**Qwen3-0.6B-Q8_0 / bug_report** 0.47s 96% recall 95% LOSSY: guard rejected it, rules ran instead

> I tested the new build and the login flow is mostly working, but I found two issues. First, the spinner never goes away on slow connections. Second, when you log out it doesn't actually clear the session. We should fix those before Friday.

**Qwen3-0.6B-Q8_0 / question_not_instruction** 0.25s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-Q8_0 / discourse_like** 0.38s 71% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-Q8_0 / stacked_fillers** 0.10s 86% recall 100% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**Qwen3-0.6B-Q8_0 / meaningful_like** 0.16s 87% recall 100% LOSSY: guard rejected it, rules ran instead

> I like the new design and it looks like a bug in the retry logic so can you do something like that for the webhook one

**Qwen3-0.6B-Q8_0 / false_start** 0.37s 83% recall 100% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-Q8_0 / restart_wrong_word** 0.14s 100% recall 71% ok

> Move the button to the right side of the toolbar.

**Qwen3-0.6B-Q8_0 / restated_clause** 0.16s 80% recall 87% kept 'actually'

> We should ship it on Thursday, and actually before the demo.

**Qwen3-0.6B-Q8_0 / abandoned_phrase** 0.19s 73% recall 94% REWORDED: subsequence guard rejected it, rules ran instead; kept 'needs to, we'; LOSSY: guard rejected it, rules ran instead

> the retry logic needs to check whether the webhook even fired before we retry anything.

**Qwen3-0.6B-Q8_0 / snap_regions** 0.57s 59% recall 89% missing "and then it'll snap"; kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. We shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-Q8_0 / snap_regions_joined** 0.64s 59% recall 88% REWORDED: subsequence guard rejected it, rules ran instead; kept 'dragon'; kept "shouldn't even be showing"; LOSSY: guard rejected it, rules ran instead

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-Q8_0 / long_doc** 1.54s 81% recall 87% missing 'remembering it'

> Okay so for the design doc, I want to start with the problem that our dictation is accurate when speaking clearly, but falls apart when mumbled or trails off. The cleanup stage can't fix that because by then the words are already wrong. The second section should cover what we actually measured: the transcription tail is about a hundred and forty milliseconds, and the cleanup call is around three hundred. Neither of those is the bottleneck, the bottleneck is recognition quality. I want to lay out the three options we discussed: biasing the recognizer with a vocabulary list, feeding the focused field's text as context, and allowing the user to correct a word once and remember it. The last section is the recommendation: we do the third one because it gets better with use, and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-Q8_0 / long_meeting_notes** 0.86s 94% recall 100% LOSSY: guard rejected it, rules ran instead

> So notes from the standup, Kaleb is still on the shortcut work and he said the event tap part is done, but the recorder UI is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where SwiftUI declined the hit. Third thing, we still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And then last, nobody has actually dictated into the instrumented build yet, so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-Q8_0 / draft_context** 0.26s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in Sentry and the flag retry V2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-Q8_0 / agent_prompt_streaming** 1.91s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-Q8_0 / agent_prompt_ui_options** 0.71s 75% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY: guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-Q8_0 / agent_prompt_council** 1.10s 86% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> So we have two other agents working on blue jay whisper but i want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where i say a lot of text and it doesn't take into account that i'm trying to prompt maybe i'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent so council our quality issues can you get a council of agents by using the debate skill and our prompt our system prompt and how our design works to give the best transcription quality just imagine you're whisper flow and we're trying to replicate whisper flow one to one

**Qwen3-0.6B-Q8_0 / enumerated_options** 0.59s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> For the storage layer we could use postgres with a jsonb column or actually maybe duckdb since it's all analytical or we could just keep it in sqlite and deal with it later i'm leaning postgres but tell me if i'm wrong

**Qwen3-0.6B-Q8_0 / identifier_symbols** 0.46s 43% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; missing '--force'; missing '.env'; missing 'app.log'; LOSSY: guard rejected it, rules ran instead

> Check whether flag retry v2 is set in the dot env file and if it is run npm run build dash force and then tail the logs in var log slash app dot log

**Qwen3-0.6B-Q8_0 / design_doc_polish_long** 1.49s 89% recall 91% missing 'twenty four hours'

> Okay so for the reliability section, I want to start with what actually happens today, when the webhook sender fails, we just log it and move on. The customer never finds out and neither do we until they email us. The second part should be a dead letter table plus a daily digest that goes to the org owner. The third part is about the tradeoff, a digest is not real-time, so if something breaks at 9 AM, they hear it the next day. I think that's acceptable for now because the alternative is a whole alerting system and we don't have anyone to build that this quarter. Last, the rollout plan is we ship the table first, behind a flag measure how often it actually fills up on real traffic, and only then decide whether the digest is even worth building.

