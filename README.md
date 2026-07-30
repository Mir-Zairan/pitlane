# worktree

A Claude Code plugin that makes parallel sessions in one repository actually usable.

Claude Code already creates git worktrees natively (`claude --worktree <name>`). What it does not do is
make the new worktree *runnable*: a fresh checkout has no `.env`, no `vendor/`, no `node_modules/`, and
it still points at the same database and the same port as every other session. This plugin closes that
gap — and it fits itself to the repo instead of assuming a stack.

**Status: in development. Nothing is implemented yet — see [docs/03-roadmap.md](docs/03-roadmap.md).**

## The idea in one paragraph

Three questions have to be answered for any repo: *how do I install dependencies here*, *what shell must
that run inside*, and *what runtime state would two sessions collide on*. The first two are detectable
from the repo (lockfiles, `flake.nix`, `.envrc`, devcontainer). The third is not — nothing in a repo tells
you that `INSTALLATION_NAME` picks the tenant database. So a `/worktree-calibrate` command inspects the
repo once, proposes answers, and writes `.claude/worktree-profile.json`. From then on the hooks are
deterministic shell that read that file. Model at calibrate time; plain bash at hook time.

## Documentation

Read in this order:

| Document | What it holds |
|---|---|
| [docs/00-context.md](docs/00-context.md) | The problem, verified platform facts, prior art |
| [docs/01-decisions.md](docs/01-decisions.md) | Design decisions and their rationale (ADRs) |
| [docs/02-architecture.md](docs/02-architecture.md) | Layers, profile schema, hook contracts, file layout |
| [docs/03-roadmap.md](docs/03-roadmap.md) | Phase index and status |
| [docs/phases/](docs/phases/) | One document per phase: intent, context, tasks, acceptance |

## Installation

Not yet installable. Once Phase 1 lands:

```bash
claude plugin marketplace add Mir-Zairan/worktree
claude plugin install worktree@worktree
```

## License

MIT
