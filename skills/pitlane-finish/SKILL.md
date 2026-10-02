---
name: pitlane-finish
description: Wait for, or finish, this worktree's setup — Pitlane installs dependencies and seeds the databases in the background after the session starts, and this waits for that, completes anything left over, and reports what is ready. Use before running tests, builds, the app or database queries when a session was told its worktree "is still being set up in the background" or "is not fully set up yet", when dependencies or the worktree's databases are missing, or when the user asks to finish or repair a worktree's setup.
---

# Pitlane — finish this worktree's setup

When a session starts in a worktree, Pitlane does the quick steps before the first prompt and hands the
slow ones — installs and the database seed — to a run in the background. A step can also be held back
(not enough memory, a toolchain that failed to start). This command waits for a background run that is
still going, then does whatever is left, with no time limit.

## Run it

From the worktree's root:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bootstrap.sh" --finish
```

Run it **in the background** (`run_in_background: true`) and wait for it to finish: it may wait for the
background setup, download a toolchain or clone databases, which can take many minutes, longer than a
foreground command may run. Work that needs none of the missing pieces can go on meanwhile.

It prints progress on stderr and one status line on stdout as its last word:

- `Pitlane: this worktree is fully set up.` — done. Say so in one line.
- `Pitlane: still not complete — missing: …` — show the user that line and the stderr lines that
  explain each missing item (they say why: a toolchain that failed to start, a seed that refused, a
  command that failed). Do not retry in a loop; one more run only if the reason was time.
  If the reason was **memory** ("memory is free", "memory cap"), Pitlane held the step back so it could
  not freeze the desktop: tell the user to close something heavy and run it again, or to set
  `PITLANE_MEMORY_MAX` (e.g. `PITLANE_MEMORY_MAX=12G`) if the step genuinely needs more.
- `Pitlane: run /pitlane-finish from inside a worktree …` — the session is not in a worktree; say so.

## The rule

**Never do the setup by hand instead.** Do not run the project's install commands, create or clone
databases, or copy env files yourself. Pitlane's setup knows which commands are safe here — for
example, an install that would migrate the shared database is run with that step switched off — and it
records what it did, so it does not redo it or tear down the wrong thing later. A hand-run install can
undo exactly those protections.
