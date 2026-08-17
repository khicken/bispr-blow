# Cleanup benchmark (nothink=auto, reps=3, deadline=900ms+6ms/word)

| model | recall | quality | median | p95 | worst | over deadline | lossy | reworded |
|---|---|---|---|---|---|---|---|---|
| Qwen3-0.6B-MLX-4bit | 96% | 85% | 0.19s | 1.30s | 1.32s | 0/26 | 5/26 | 3/26 |

## Per case

**Qwen3-0.6B-MLX-4bit / short_question** 0.10s 100% recall 100% ok

> Yeah, wait what's in this PR? Let me see the link again.

**Qwen3-0.6B-MLX-4bit / long_ramble** 0.73s 88% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> We should also update the system prompt to not just strictly remove filler words but also tailor that is towards like developers so when we set up like accounts and stuff we can tailor it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because i'm noticing that when i say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod

**Qwen3-0.6B-MLX-4bit / terminal_flags** 0.12s 100% recall 88% ok

> Run the tests with --verbose, and then commit and push to dev, not prod.

**Qwen3-0.6B-MLX-4bit / jargon** 0.15s 67% recall 100% missing '.env'

> the work tree is dirty, so I had to stash before rebasing onto main, and the dot env file was missing.

**Qwen3-0.6B-MLX-4bit / self_correction** 0.11s 67% recall 100% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**Qwen3-0.6B-MLX-4bit / bug_report** 0.29s 100% recall 94% ok

> Okay so I tested the new build and the login flow is mostly working, but I found two issues: one is the spinner never goes away on slow connections, and two when you log out it doesn't actually clear the session. We should fix those before before Friday.

**Qwen3-0.6B-MLX-4bit / question_not_instruction** 0.14s 100% recall 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**Qwen3-0.6B-MLX-4bit / discourse_like** 0.17s 71% recall 100% kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**Qwen3-0.6B-MLX-4bit / stacked_fillers** 0.08s 95% recall 100% LOSSY: guard rejected it, rules ran instead

> I think we should just ship it today and see what breaks.

**Qwen3-0.6B-MLX-4bit / meaningful_like** 0.16s 100% recall 100% ok

> I like the new design and it looks like a bug in the retry logic. So can you do something like that for the webhook one?

**Qwen3-0.6B-MLX-4bit / false_start** 0.22s 75% recall 94% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**Qwen3-0.6B-MLX-4bit / restart_wrong_word** 0.08s 100% recall 71% ok

> Can you move the button to the right side of the toolbar?

**Qwen3-0.6B-MLX-4bit / restated_clause** 0.08s 80% recall 80% kept 'actually'

> We should ship it on Thursday actually, before the demo.

**Qwen3-0.6B-MLX-4bit / abandoned_phrase** 0.15s 92% recall 89% kept 'needs to, we'

> the retry logic needs to, we need to first check whether the webhook even fired before we retry anything,

**Qwen3-0.6B-MLX-4bit / snap_regions** 0.56s 68% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing. It shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / snap_regions_joined** 0.54s 71% recall 100% kept 'dragon'; kept "shouldn't even be showing"

> When we do the dragon, it's supposed to show the 3 regions that will automatically snap the dragon too. We shouldn't it shouldn't move. We shouldn't even have the pill picked up until it's snapped into the other 2 possible positions if that makes sense. Like currently we can pick it up and then it'll snap, but we shouldn't even be showing, it shouldn't even be shown the pill is being picked up.

**Qwen3-0.6B-MLX-4bit / long_doc** 1.06s 86% recall 91% missing 'remembering it'

> Okay so for the design doc, we want to start with the problem. The problem is that our dictation is accurate when you speak clearly, but it falls apart when you mumble or trail off. The cleanup stage can't fix that because by then the words are already wrong. The second section should cover what we actually measured. The transcription tail is about a hundred and forty milliseconds, and the cleanup call is around three hundred. Neither of those is the bottleneck, the bottleneck is recognition quality. The third option is to lay out the three options we discussed. The three options are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remember it. And then the recommendation is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**Qwen3-0.6B-MLX-4bit / long_meeting_notes** 0.87s 94% recall 90% missing 'shortcut'; missing 'borderless panel'

> Notes from the standup, the event tap part is done, and the recorder UI is going to take another day. The second thing is that the pill was eating clicks along the bottom of the screen and it was fixed now. The third thing is that we still owe a decision on whether insert then upgrade ships on by default and the answer is no because replacing text in someone else's app can go wrong. And then last, nobody has actually dictated into the instrumented build yet, so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**Qwen3-0.6B-MLX-4bit / draft_context** 0.15s 67% recall 100% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**Qwen3-0.6B-MLX-4bit / agent_prompt_streaming** 1.32s 91% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; LOSSY: guard rejected it, rules ran instead

> Okay so i need you to look at the streaming endpoint because right now we're we're buffering the whole response before we send it and that defeats the point of streaming so what i want is to pipe the chunks straight through as they come in and then there's a second thing which is rate limiting we don't have any on that route so someone could just hammer it and take the whole service down so i want a token bucket per api key like sixty requests a minute burst of ten and when they blow through it return a four twenty nine with a retry after header not a five hundred because a five hundred makes it look like our fault and then the third thing and this is the one i keep forgetting is we need to actually close the connection when the client disconnects because right now the generator keeps running and we keep paying for tokens on a request nobody is listening to so check for the disconnect in the loop and bail out and then for testing i want one test that asserts the first chunk arrives in under a hundred milliseconds and one that asserts we stop generating after a disconnect and maybe one for the rate limiter but that one's less important than the other two

**Qwen3-0.6B-MLX-4bit / agent_prompt_ui_options** 0.51s 79% recall 100% REWORDED: subsequence guard rejected it, rules ran instead; kept 'you know'; LOSSY: guard rejected it, rules ran instead

> Note latency is a huge factor we want sub five hundred to six hundred milliseconds in the ui i'm thinking that there's model options like fastest medium and slow or something like that to show if someone wants to make the choice between three different choices between or maybe it could just be two choices between like you know fast but less accurate but this is or it's like slower and more accurate whatever you think is the best ui

**Qwen3-0.6B-MLX-4bit / agent_prompt_council** 0.73s 90% recall 99% missing 'one to one'

> So we have two other agents working on Blue Jay Whisper. I want you to mainly be concerned about the quality of how our transcription works because there's a lot of times where I say a lot of text and it doesn't take into account that I'm trying to prompt maybe I'm trying to prompt code and it just changes my text too much and it doesn't fully understand my intent. So council our quality issues. You get a council of agents by using the debate skill and our prompt. Our system prompt and how our design works to give the best transcription quality. Imagine you're Whisper Flow and we're trying to replicate Whisper Flow one-to-one.

**Qwen3-0.6B-MLX-4bit / enumerated_options** 0.30s 86% recall 100% missing 'actually'

> for the storage layer, we could use postgres with a jsonb column, or maybe duckdb since it's all analytical. or we could just keep it in sqlite and deal with it later. I'm leaning postgres, but tell me if I'm wrong.

**Qwen3-0.6B-MLX-4bit / identifier_symbols** 0.24s 50% recall 100% missing '--force'; missing '.env'; missing 'app.log'

> Check whether flag retry v2 is set in the dot env file and if it is, run npm run build dash dash force and then tail the logs in var log slash app dot log.

**Qwen3-0.6B-MLX-4bit / design_doc_polish_long** 0.88s 93% recall 89% missing 'twenty four hours'

> Okay, so for the reliability section, I want to start with the issue when the webhook sender fails. We just log it and move on. The customer never finds out and neither do we until they email us. Then the second part is what we're proposing: a dead letter table plus a daily digest that goes to the org owner. Then the third part is about the tradeoff: a digest is not real time. If something breaks at nine in the morning, they hear about it the next day. I think that's acceptable for now because the alternative is a whole alerting system and we don't have anyone to build that this quarter. Then last the rollout plan: we ship the table first behind a flag measure how often it actually fills up on real traffic and only then decide whether the digest is even worth building.

**Qwen3-0.6B-MLX-4bit / deliberate_repetition** 0.06s 100% recall 100% ok

> Blue Jays, Blue Jays, Blue Jays

