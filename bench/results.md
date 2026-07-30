# Cleanup benchmark (nothink=on, reps=3)

| model | median | worst case | quality | lossy cases | reasoning tokens |
|---|---|---|---|---|---|
| qwen3-0.6b-mlx | 0.22s | 0.58s | 89% | 0/8 | 1 |
| qwen/qwen3-1.7b | 0.62s | 6.02s | 84% | 0/8 | 1 |

## Per case

**qwen3-0.6b-mlx / short_question** 0.18s 100% ok

> yeah wait what's in this PR can you see the link again

**qwen3-0.6b-mlx / long_ramble** 0.58s 90% missing 'onboarding'; missing 'context'

> We should also update the system prompt to not just strictly remove filler words but also tailor it towards developers, so when we set up like accounts and stuff, we can tailor it. We should also update the system prompt to not just strictly remove filler words but also tailor it towards developers, so when we set up like accounts and stuff, we can tailor it.

**qwen3-0.6b-mlx / terminal_flags** 0.19s 100% ok

> Run the tests with --verbose and then commit. Push to dev not prod.

**qwen3-0.6b-mlx / jargon** 0.24s 67% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**qwen3-0.6b-mlx / self_correction** 0.18s 92% kept 'at 2'

> Let's meet at 3 pm tomorrow at the office.

**qwen3-0.6b-mlx / bug_report** 0.39s 100% ok

> Okay so I tested the new build and the login flow is mostly working, but I found two issues. One is the spinner never goes away on slow connections. The other is when you log out, it doesn't actually clear the session. We should fix those before Friday.

**qwen3-0.6b-mlx / question_not_instruction** 0.21s 100% ok

> Hey. Can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**qwen3-0.6b-mlx / draft_context** 0.23s 67% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

**qwen/qwen3-1.7b / short_question** 6.02s 100% ok

> what's in this PR can you see the link again

**qwen/qwen3-1.7b / long_ramble** 2.10s 86% kept ' uh '

> We should also update the system prompt to not just strictly remove filler words but also tailor it towards like developers so when we set up like accounts and stuff we can tailor. Oh it's more of a developer or a designer whatever the other categories you can think of put like 5 default options during onboarding but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because I'm noticing that when I say for example dev or prod uh keeps saying like devin or prod or proud instead of dev or prod

**qwen/qwen3-1.7b / terminal_flags** 0.42s 100% ok

> Run the tests with --verbose and then commit and push to dev not prod

**qwen/qwen3-1.7b / jargon** 0.60s 100% ok

> The work tree is dirty so I had to stash before rebasing onto main and the .env file was missing.

**qwen/qwen3-1.7b / self_correction** 0.40s 50% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office

**qwen/qwen3-1.7b / bug_report** 1.11s 71% kept 'um '; kept 'the the'

> Okay so I tested the new build and the login flow it's it's mostly working but I found like two issues one is the the spinner never goes away on slow connections and two um when you log out it doesn't actually clear the session so so yeah we should probably fix those before before friday

**qwen/qwen3-1.7b / question_not_instruction** 0.56s 100% ok

> hey can you review my pr when you get a chance it's the one that fixes the webhook retry logic

**qwen/qwen3-1.7b / draft_context** 0.64s 67% missing 'FLAG_RETRY_V2'

> So far no errors in sentry and the flag retry v2 flag is on for about 10 percent of orgs.

