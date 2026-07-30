# Cleanup benchmark (nothink=off, reps=3)

| model | median | worst case | quality | lossy cases | reasoning tokens |
|---|---|---|---|---|---|
| qwen3-0.6b-mlx | 2.28s | 8.69s | 75% | 2/7 | 364 |

## Per case

**qwen3-0.6b-mlx / short_question** 8.69s 100% ok

> Yeah wait – what's in this PR? Can you see the link again?

**qwen3-0.6b-mlx / long_ramble** 2.31s 38% missing 'developer'; missing 'onboarding'; missing 'context'; retained 5% < 50%; LOSSY: guard would reject

> We should update the system prompt.

**qwen3-0.6b-mlx / terminal_flags** 2.28s 43% missing 'dev'; missing 'prod'; retained 42% < 50%; LOSSY: guard would reject

> Run the tests with --verbose and then commit.

**qwen3-0.6b-mlx / jargon** 2.20s 67% missing '.env'

> The work tree is dirty. I had to stash before rebasing onto main and the dot env file was missing.

**qwen3-0.6b-mlx / self_correction** 1.79s 75% kept 'at 2'

> Meeting at 2 and 3 pm tomorrow at the office.

**qwen3-0.6b-mlx / bug_report** 2.29s 100% ok

> Okay so i tested the new build and the login flow is mostly working, but I found two issues. One is the spinner never goes away on slow connections. Two when you log out it doesn't actually clear the session. We should fix those before before Friday.

**qwen3-0.6b-mlx / question_not_instruction** 1.49s 100% ok

> Hey, can you review my PR when you get a chance? It's the one that fixes the webhook retry logic.

