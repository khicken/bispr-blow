# Cleanup benchmark (nothink=on, reps=3)

| model | median | worst case | quality | lossy cases | reasoning tokens |
|---|---|---|---|---|---|
| qwen3-0.6b-mlx | 0.23s | 0.56s | 92% | 0/7 | 1 |
| qwen/qwen3-1.7b | 0.56s | 2.03s | 87% | 0/7 | 1 |

## Per case

**qwen3-0.6b-mlx / short_question** 0.17s 100% ok

> Yeah wait what's in this PR can you see the link again?

**qwen3-0.6b-mlx / long_ramble** 0.56s 100% ok

> We should also update the system prompt to not just strictly remove filler words but also tailor it toward developers. When we set up like accounts and stuff, we can tailor it to include 5 default options during onboarding. We also need to inject more context of the app and at the beginning or end of the system prompt, because I'm noticing that when I say "dev" or "prod", it keeps saying "devin" or "prod" instead of "dev" or "prod".

**qwen3-0.6b-mlx / terminal_flags** 0.19s 100% ok

> Run the tests with --verbose and then commit. Push to dev not prod.

**qwen3-0.6b-mlx / jargon** 0.23s 67% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**qwen3-0.6b-mlx / self_correction** 0.17s 75% kept 'at 2'

> Let's meet at 2 and 3 pm tomorrow at the office.

**qwen3-0.6b-mlx / bug_report** 0.40s 100% ok

> Okay so I tested the new build and the login flow is mostly working, but I found two issues. One is the spinner never goes away on slow connections. The other is when you log out, it doesn't actually clear the session. We should fix those before Friday.

**qwen3-0.6b-mlx / question_not_instruction** 0.25s 100% ok

> Hey can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

**qwen/qwen3-1.7b / short_question** 0.45s 100% ok

> Yeah wait what's in this PR can you see the link again

**qwen/qwen3-1.7b / long_ramble** 2.03s 86% kept ' uh '

> We should also update the system prompt to not just strictly remove filler words but also tailor it towards like developers. When we set up like accounts and stuff we can tailor it, so when we say dev or prod it should say dev or prod. We can think of 5 default options during onboarding, but we also have to inject more context of the app and at the beginning of the system prompt or the end of it because I'm noticing that when I say for example dev or prod uh keeps saying like devin or prod or proud instead of dev or prod.

**qwen/qwen3-1.7b / terminal_flags** 0.44s 100% ok

> Run the tests with --verbose and then commit and push to dev not prod

**qwen/qwen3-1.7b / jargon** 0.61s 100% ok

> The work tree is dirty so I had to stash before rebasing onto main and the .env file was missing.

**qwen/qwen3-1.7b / self_correction** 0.44s 50% kept 'at 2'; kept 'actually'

> Let's meet at 2 actually 3 pm tomorrow at the office.

**qwen/qwen3-1.7b / bug_report** 1.16s 71% kept 'um '; kept 'the the'

> Okay so I tested the new build and the login flow it's it's mostly working but I found like two issues one is the the spinner never goes away on slow connections and two um when you log out it doesn't actually clear the session so so yeah we should probably fix those before before friday

**qwen/qwen3-1.7b / question_not_instruction** 0.56s 100% ok

> hey can you review my pr when you get a chance it's the one that fixes the webhook retry logic

