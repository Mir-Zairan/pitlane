# AI Agent

This repository is built one phase per session. This file tells a fresh session how to pick up.

## Start here

1. Read `docs/03-roadmap.md` and find the first phase whose status is not `done`.
2. Read that phase's document in `docs/phases/` **in full**.
3. Read `docs/01-decisions.md` before writing code — several decisions exist specifically to stop a
   later session re-litigating an earlier one.
4. Read `docs/02-architecture.md` for the profile schema and hook contracts.
5. `docs/00-context.md` is background: the problem, the verified platform facts, and prior art. Read it
   when a phase asks you to, or when something in a phase document doesn't make sense.

Do not start a phase whose dependencies are unfinished. Do not silently widen a phase's scope — every
phase document has an **Out of scope** section naming the phase that owns the work instead.

## When you finish a phase

1. Fill in the **Handoff** section at the bottom of the phase document: what you built, what you learned
   that contradicts the docs, and anything the next phase should know.
2. If you discovered something that invalidates a decision, update `docs/01-decisions.md` — supersede the
   entry, don't delete it. Same for `docs/00-context.md` when a platform fact turns out to be wrong.
3. Flip the phase's status in `docs/03-roadmap.md`.
4. Commit.

Documents that lie are worse than no documents. If reality disagrees with a doc, the doc changes.

## Conventions

- **The engine is general; no repo's identity belongs in it.** Phases 1–5 and 7 build a plugin for any
  repository. Naming *ecosystems* is fine and necessary — `composer`, `pnpm`, `uv`, `flake.nix` are what
  the detection tables are made of. Naming a particular *repository* is not: no local paths, no
  project-specific env vars, database names, ports or ticket prefixes in requirements, tasks or
  acceptance criteria. When a concrete example genuinely helps, invent a neutral one (`alice/fix-99`) or
  point at the worked example in `docs/00-context.md` and say it is an example.
  Two deliberate exceptions: **Phase 6** is the named-repo validation phase, and `00-context.md`'s
  "reference repo" section plus the evidence cited in ADRs — those record what was actually measured,
  and measurements name their subject.
- **Hooks are deterministic shell.** No model calls, no network, no interactive prompts inside a hook.
  Anything that needs judgement happens in `/worktree-calibrate` and is written to the profile.
- **A hook must never cost the user their session.** On any internal failure, warn on stderr, still emit
  the worktree path, exit 0. A worktree missing its `vendor/` is recoverable; a session that won't start
  is not.
- **stdout is a protocol.** For `WorktreeCreate`, stdout is the worktree path and nothing else. Every
  informational message goes to stderr.
- Shell scripts: `bash`, `set -euo pipefail`, shellcheck-clean, POSIX tools only (no `jq` dependency —
  fall back to `python3` as the source conversation's scripts do).
- Plugin scripts are referenced as `"${CLAUDE_PLUGIN_ROOT}"/hooks/scripts/<name>.sh`.
- Conventional commits, present tense: `feat(bootstrap): copies gitignored config into new worktrees`.
- No `Co-Authored-By` lines and no generated-with attribution in commits or PR bodies.

## Testing

There is no target repo inside this one. Test against a scratch git repository created under
`/tmp`, and — from Phase 6 — against `/home/alice/acme-app`, which is the hard case the design was
drawn from (nix + docker + composer + a pnpm workspace + a per-tenant MySQL database).

Never test destructive paths against `acme-trade` directly until they have passed against a scratch repo.
