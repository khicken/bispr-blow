# Cleanup benchmark (nothink=auto, reps=3)

| model | median | worst case | quality | lossy cases | reasoning tokens |
|---|---|---|---|---|---|
| qwen3-0.6b-mlx | 0.25s | 1.05s | 90% | 2/17 | 1 |
| qwen/qwen3-1.7b | 0.67s | 5.42s | 83% | 0/17 | 1 |

## Per case

**qwen3-0.6b-mlx / short_question** 0.19s 100% ok

> Yeah wait what's in this PR can you see the link again?

**qwen3-0.6b-mlx / long_ramble** 0.65s 100% ok

> We should also update the system prompt to not just strictly remove filler words but also tailor it toward developers, so when we set up like accounts and stuff, we can tailor it to include 5 default options during onboarding. We also need to inject more context of the app and at the beginning or end of the system prompt because we're noticing that when I say "dev" or "prod", it keeps saying like "devin" or "prod" instead of "dev" or "prod".

**qwen3-0.6b-mlx / terminal_flags** 0.21s 100% ok

> Run the tests with --verbose and then commit. Push to dev not prod.

**qwen3-0.6b-mlx / jargon** 0.25s 67% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**qwen3-0.6b-mlx / self_correction** 0.18s 100% ok

> Let's meet at 3 pm tomorrow at the office.

**qwen3-0.6b-mlx / bug_report** 0.38s 100% ok

> Okay so I tested the new build and the login flow is mostly working but I found two issues: one is the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session. We should fix those before Friday.

**qwen3-0.6b-mlx / question_not_instruction** 0.24s 100% ok

> Hey can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**qwen3-0.6b-mlx / discourse_like** 0.25s 71% kept 'like closer'; LOSSY: guard rejected it, rules ran instead

> Our pill also still sits a bit too high when it could be like closer to, let's say, the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**qwen3-0.6b-mlx / stacked_fillers** 0.15s 86% LOSSY: guard rejected it, rules ran instead

> So i think we should just ship it today and see what breaks

**qwen3-0.6b-mlx / meaningful_like** 0.26s 92% missing 'something like that'

> I like the new design and it looks like a bug in the retry logic. So can you do something like that for the webhook one?

**qwen3-0.6b-mlx / false_start** 0.31s 75% kept 'like center'

> And by it's dragging to the left or right, I mean, it's going to anchor to the like center, vertically centered, left side or vertically centered right side of the screen.

**qwen3-0.6b-mlx / restart_wrong_word** 0.18s 100% ok

> Can you move the button to the right side of the toolbar?

**qwen3-0.6b-mlx / restated_clause** 0.18s 80% kept 'actually'

> We should ship it on Thursday actually, before the demo.

**qwen3-0.6b-mlx / abandoned_phrase** 0.20s 100% ok

> The retry logic needs to check whether the webhook even fired before we retry anything.

**qwen3-0.6b-mlx / long_doc** 1.05s 89% missing 'remembering it'

> Okay so we want to start with the problem. The design doc is about the issue when dictation is accurate when you speak clearly but falls apart when you mumble or trail off. The cleanup stage can't fix that because by then the words are already wrong. Next section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds. The cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. Next section: we discussed three options. The first is biasing the recognizer with a vocabulary list, feeding focused field's text in as context, and letting the user correct a word once and remember it. Then the recommendation is we do the third one because it's the only one that gets better as you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**qwen3-0.6b-mlx / long_meeting_notes** 0.91s 97% missing 'borderless panel'

> Kaleb is still on the shortcut work. The event tap part is done, and the recorder UI will take another day because there's no existing pattern in the app to copy. The pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. We still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. And then last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**qwen3-0.6b-mlx / draft_context** 0.26s 67% missing 'FLAG_RETRY_V2'

> So, far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**qwen/qwen3-1.7b / short_question** 5.42s 78% missing 'PR'; retained 50% < 60%

> Can you see the link again?

**qwen/qwen3-1.7b / long_ramble** 2.08s 100% ok

> We should also update the system prompt to not just strictly remove filler words but also tailor it towards like developers. When we set up like accounts and stuff, we can tailor it to be dev or designer whatever the other categories you can think of. Put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because I'm noticing that when I say for example dev or prod keeps saying like devin or prod or proud instead of dev or prod.

**qwen/qwen3-1.7b / terminal_flags** 0.40s 100% ok

> Run the tests with --verbose and then commit and push to dev not prod

**qwen/qwen3-1.7b / jargon** 0.59s 100% ok

> The work tree is dirty, so I had to stash before rebasing onto main and the.env file was missing.

**qwen/qwen3-1.7b / self_correction** 0.41s 50% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**qwen/qwen3-1.7b / bug_report** 1.16s 86% kept 'the the'

> Okay so I tested the new build and the login flow it's it's mostly working but I found like two issues one is the the spinner never goes away on slow connections and two when you log out it doesn't actually clear the session so so yeah we should probably fix those before before friday

**qwen/qwen3-1.7b / question_not_instruction** 5.07s 88% retained 55% < 70%

> Can you review my PR that fixes the webhook retry logic?

**qwen/qwen3-1.7b / discourse_like** 1.27s 83% kept 'like closer'

> Our pill still sits a bit too high when it could be like closer to the system tray on a desktop or like the task bar on a desktop or lower down in the ID or close to the bottom of the screen. It's just too far up and in the middle of everything.

**qwen/qwen3-1.7b / stacked_fillers** 0.44s 100% ok

> I think we should just ship it today and see what breaks.

**qwen/qwen3-1.7b / meaningful_like** 0.65s 100% ok

> I like the new design and it looks like a bug in the retry logic. Can you do something like that for the webhook one?

**qwen/qwen3-1.7b / false_start** 0.86s 75% kept 'like center'

> And by it's dragging to left or right, I mean, it's going to anchor to the like center, vertically centered, left side, or vertically centered right side of the screen.

**qwen/qwen3-1.7b / restart_wrong_word** 0.55s 50% kept 'to the left'; kept 'sorry'

> Can you move the button to the left, sorry, to the right side of the toolbar.

**qwen/qwen3-1.7b / restated_clause** 0.47s 40% missing 'demo'; kept 'friday'; kept 'actually'

> We should ship it on Friday, we should ship it on Thursday actually.

**qwen/qwen3-1.7b / abandoned_phrase** 0.48s 100% ok

> The retry logic needs to check whether the webhook even fired before we retry anything.

**qwen/qwen3-1.7b / long_doc** 3.75s 100% ok

> Okay so for the design doc I want to start with the problem which is that our dictation is accurate enough when you speak clearly but it falls apart the moment you mumble or trail off and the cleanup stage can't fix that because by then the words are already wrong. Second section should cover what we actually measured, so the transcription tail is about a hundred and forty milliseconds and the cleanup call is around three hundred so neither of those is the bottleneck, the bottleneck is recognition quality. Third I want to lay out the three options we discussed which are biasing the recognizer with a vocabulary list, feeding the focused field's text in as context, and letting the user correct a word once and remembering it. And then the last section is the recommendation which is we do the third one because it's the only one that gets better the more you use it and we should ship it behind a flag so we can measure it on real dictations before turning it on for everyone.

**qwen/qwen3-1.7b / long_meeting_notes** 3.06s 100% ok

> So notes from the standup, kaleb is still on the shortcut work and he said the event tap part is done but the recorder ui is going to take another day because there's no existing pattern in the app to copy. The second thing is that the pill was eating clicks along the bottom of the screen and that's fixed now, it was a borderless panel claiming every point in its frame even where swiftui declined the hit. Third thing, we still owe a decision on whether insert then upgrade ships on by default and I think the answer is no because replacing text in someone else's app can go wrong. Last, nobody has actually dictated into the instrumented build yet so the latency numbers we're quoting are from the benchmark not from real use, which we should fix before we optimize anything else.

**qwen/qwen3-1.7b / draft_context** 0.67s 67% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

