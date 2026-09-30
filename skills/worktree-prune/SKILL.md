---
name: worktree-prune
description: Find what this plugin's worktrees left behind — orphaned worktree directories, stale git registrations, runtime allocations (databases, containers) nothing uses any more, broken ledger entries — report it with the disk each item frees, and remove only the items the developer confirms. Use when disk is filling up with old worktrees, after worktrees were deleted by hand, or when a teardown did not finish.
argument-hint: "[--dry-run]"
---

# Worktree — prune what worktrees left behind

`hooks/scripts/prune.sh` does all the finding, judging and deleting. It is deterministic shell and
never asks anything ([ADR-002](../../docs/01-decisions.md#adr-002)). Your job is the part a script
cannot do: show its report to the developer in plain words, ask which items to remove, and pass
exactly those back to it.

**You never decide on your own that something is safe to delete.** The script re-checks every item
at the moment it acts and refuses anything it cannot prove safe. A refusal is the answer, not an
obstacle.

## The hard rule

You do not delete anything yourself, by any means. Specifically, you never run:

- `rm`, `rmdir`, `find -delete`, or anything else that removes a file or directory;
- `git worktree remove`, `git worktree prune`, `git branch -D`, or any other git command that
  changes a repository;
- `teardown.sh`, the profile's `runtime.teardown` script, or any seed/teardown script;
- a database, `docker`, or container command.

The only command that changes anything is `prune.sh --apply` with ids the developer selected. If it
refuses an item, explain the reason and stop. Do not retry it, work around it, or offer to remove the
item "manually" — every refusal exists because removing it could lose work or break a live session.

## 1 — Run the report

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/prune.sh" --repo "$REPO"
```

`$REPO` is the repository root you are working in — a **value to quote**, not text to paste. Any
directory of the repository works; the script finds the main checkout itself. Report mode changes
nothing on disk.

Exit status:

- `0` — the report printed. Continue.
- `2` — not a git repository, the main checkout cannot be found, or the worktrees cannot be
  surveyed. Say so in one or two sentences, quoting the script's stderr line, and stop.
- anything else — show stderr and stop.

## 2 — Read the output

Each item is one line of six TAB-separated fields:

```
id  kind  path  bytes  action  reason
```

Lines starting `# ` are the summary: the item count, the total bytes, and a `# to apply:` line with
the exact apply command for every applicable item. Anything on stderr is diagnostics.

| action | Meaning | Offer it? |
|---|---|---|
| `delete` | Remove the path. | Yes |
| `teardown` | Run the repo's own teardown script with the recorded environment (it may drop a database or stop a container), then forget the ledger entry. | Yes — say what the script will release |
| `forget` | Forget the ledger entry; nothing runs. The entry may be the only record of a database or containers that still exist — forgotten, nothing will ever tear them down. For a `runtime-leftover` whose reason says it is recorded only in a state file, it deletes that state file. | Yes — say both in the option's description |
| `refuse` | Not safe now; the reason says why. | No |
| `none` | Kept on purpose, listed so the developer sees why (a live worktree holding work). | No |

Kinds you will see: `orphan-dir` (a worktree directory git no longer knows), `stale-admin` (git's
registration of a worktree that is gone), `runtime-leftover` (a runtime allocation nothing uses),
`ledger-junk` (a broken or abandoned ledger entry), `abandoned` (a subagent worktree — `agent-<hex>` — that is
unlocked, holds no work and has gone untouched for an hour; Claude Code leaves these when a
`WorktreeCreate` hook made them, and applying one runs the teardown hook on it), `held` (a live
worktree with work in it).
**A kind you do not recognise — `store` is reserved for a later phase — is shown as reported, under
its own name.** What decides whether an item can be offered is its `action`, never its kind.

`bytes` is `du -sk` x 1024, or `-` where there is nothing to measure (a runtime allocation lives in
a database or container only the teardown script can see). Hardlinked files are counted in full;
when that applies, the reason says so — pass it on.

## 3 — Present it

Group items by kind. For each item show its path, its bytes, its action, and its reason. Every
`refuse` and `none` item **must** show its reason — that is the whole point of listing it.

Show bytes as the raw number followed by a human unit, so the number stays checkable against `du`:
`315392 bytes (308 KiB)`. Use 1024-based units (KiB, MiB, GiB), one decimal place above KiB. Show
`-` as "not measured" and say why.

Then the totals from the summary lines, and the `# to apply:` command exactly as printed, in a code
block.

If the summary says `# nothing to apply`, say that nothing can be removed now, list any `refuse` or
`none` items with their reasons, and stop.

**If the developer asked for a dry run (`--dry-run`, "just show me", "what would it free"), stop
here.** Do not ask the question in step 4.

## 4 — Ask which items to remove

Ask with `AskUserQuestion`. Offer only items whose action is `delete`, `teardown` or `forget`.

`AskUserQuestion` takes 2–4 options per question; a question with one option is invalid. Label an
item's option with the kind and the last path component; put the bytes and, for `teardown`, what
the script releases in the description. A `forget` option's description must say that the entry may
be the only record of a database or containers that still exist, which nothing will then tear down,
and — for a `runtime-leftover` recorded only in a state file — that the state file is deleted.

- **One applicable item:** one single-select question with two options, *Remove <label>* and
  *Keep it*.
- **Two to four:** one `multiSelect` question, one option per item.
- **More than four:** first ask *All applicable items / None / Let me pick*. On *Let me pick*, ask
  `multiSelect` questions of up to four items each until every applicable item has been offered.
  Split so that no question is left with one item (five items: three and two, not four and one);
  if one item must be asked alone, ask it as *Remove <label>* / *Keep it*.

Nothing selected, *None*, *Keep it*, or a cancelled question means **nothing is done** for those
items. Say so and stop.
Never treat silence, an ambiguous reply, or an earlier general "clean it up" as a selection.

## 5 — Apply exactly the selection

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/prune.sh" --repo "$REPO" --apply <id> <id> ...
```

Pass the selected ids exactly as the report printed them, and no others. Run it once.

Each outcome is one TAB-separated line:

```
applied  id  kind  path  freed-bytes  detail
refused  id  kind  path  -            reason
```

and a closing `# <n> applied, <n> refused, <n> bytes freed by du` line.

Report every line faithfully: for `applied`, the freed bytes as printed (plus the human unit) and
the detail; for `refused`, the reason. Then the closing summary as printed. Do not round, re-add or
re-measure the numbers yourself.

Exit status:

- `0` — every selected item was applied.
- `1` — at least one was refused; the others still ran. Explain each refusal from its reason and
  stop. A refusal of "no such item now" means the item changed since the report; offer to re-run the
  report, not to retry the id. A refusal because another prune holds the lock means someone else is
  sweeping this repository; say so and stop.
- `2` — usage error or the repository could not be surveyed; nothing was applied. Say so briefly
  and stop.

Some `refuse` items wait on another item — a runtime leftover whose directory still exists becomes
applicable once that directory is gone. If the report had such items and the apply succeeded, you
may offer to re-run the report once. That starts again at step 1, with a fresh question.
