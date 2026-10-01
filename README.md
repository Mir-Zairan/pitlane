# worktree

A Claude Code plugin that makes parallel sessions in one repository actually usable.

Claude Code creates git worktrees natively (`claude -w <name>`, `EnterWorktree`, subagents with
`isolation: "worktree"`). What it does not do is make the new worktree *runnable*: a fresh checkout has
no `.env`, no `vendor/`, no `node_modules/`, and it still points at the same database and the same port
as every other session — so session A's migration changes the schema under session B's test run. This
plugin closes both gaps, and it fits itself to the repo instead of assuming a stack.

Three questions have to be answered for any repo: *how are dependencies installed*, *what shell must
that run inside*, and *what runtime state would two sessions collide on*. The first two are detectable;
the third is not — nothing in a repo says which variable picks the database. So `/worktree-calibrate`
inspects the repo once, asks, and writes `.claude/worktree-profile.json`. From then on the hooks are
deterministic bash that read that file. Model at calibrate time; plain bash at hook time.

## What a worktree gets

| | How |
|---|---|
| Gitignored config (`.env.local`, …) | `.worktreeinclude`, applied natively by Claude Code, and by the plugin where native does not run |
| Dependencies | **hardlinked** from the main checkout when the tool writes real bytes per project (`composer`, `npm`), **installed** when it has its own content-addressable store (`pnpm`, `uv`, `bun`), inside the repo's toolchain shell (`nix develop`, `direnv`, …) |
| Its own port | `base + cksum(slug) % span`, stable per worktree name |
| Its own database(s) | env overrides written as a managed block into every env file the app loads, plus a repo-owned **seed** script that clones what those overrides name |
| Clean removal | a teardown hook that releases the allocation and removes the worktree — only when it holds no work |

Measured on a 424 MB-`vendor/` monolith: hardlinking `vendor/` takes 0.8 s and ~26 MB of real disk
(a copy: 6.4 s, 424 MB); a first bootstrap with four database clones takes about three minutes; every
later session start costs about half a second.

## Install

```bash
claude plugin marketplace add Mir-Zairan/worktree
claude plugin install worktree@worktree --scope project   # or --scope user
```

Project scope writes the repo's committed `.claude/settings.json`, which makes Claude Code offer the
plugin to every teammate — but **each developer still runs the install command once**: a plugin that is
only enabled by the project's settings is cached, not installed, and its hooks never run (measured; its
slash commands may appear anyway, which hides the problem). Once installed it loads inside every
worktree of the repo without a per-worktree install.

### Just for yourself

Nothing has to be committed to the repo ([ADR-016](docs/01-decisions.md#adr-016)). Install at user
scope (`--scope user`), keep the profile, `.worktreeinclude` and the seed/teardown scripts untracked in
the main checkout, list them in `.git/info/exclude`, put the scripts in the profile's `copy[]`, and keep
the agent note in `CLAUDE.local.md`. Worktrees cut from any branch still bootstrap, because the plugin
falls back to the main checkout's files. `/worktree-calibrate` offers this as an option.

## Calibrate once per repository

```
/worktree-calibrate
```

It runs deterministic detection (`hooks/scripts/detect.sh`), then asks — with the findings as options,
never as defaults — about everything it cannot know: whether sessions should be isolated at all, which
variable selects the database and whether it also names the tenant, which env files the app actually
loads per environment, how the dev server takes its port, whether worktrees share the compose stack, and
whether a seed and a teardown step are needed. It writes and validates the profile, offers
`.worktreeinclude` and `.gitignore` lines, and offers a short section for the repo's agent instructions
so a session knows its worktree is already set up. Commit all of it: a teammate who installs the plugin
then needs no calibration of their own.

## The profile

`.claude/worktree-profile.json` — the authoritative, annotated schema is
[`reference/profile.template.json`](reference/profile.template.json). In brief:

```jsonc
{
  "schemaVersion": 1,
  "shell": "nix develop --command", "shellArgs": "argv",
  "deps": [
    { "dir": "vendor", "lock": "composer.lock", "strategy": "hardlink",
      "install": "composer install --no-interaction --no-progress --no-scripts",
      "verify": "test -r vendor/autoload.php" },
    { "dir": "node_modules", "lock": "pnpm-lock.yaml", "strategy": "install",
      "install": "pnpm install --frozen-lockfile" }
  ],
  "runtime": {
    "slug": "{slug}",
    "port": { "var": "WORKTREE_PORT", "base": 3800, "span": 200 },
    "env": {
      "file": [".env.development.local", ".env.test.local"],
      "vars": {
        "DATABASE_URL": "mysql://root@127.0.0.1/app_{slug}",
        ".env.test.local:REPORTS_DATABASE_URL": "mysql://root@127.0.0.1/reports_{slug}_test"
      }
    },
    "seed": ".claude/worktree-seed.sh",
    "teardown": ".claude/worktree-teardown.sh"
  },
  "timeouts": { "bootstrapSeconds": 330, "seedSeconds": 240 }
}
```

- `env.file` is every gitignored file the app loads, one per environment that needs its own state. The
  plugin appends a marked block after the developer's own lines and rewrites it in place each session;
  a key written `<file>:<VAR>` applies to that one file. Delete the block to take a file over.
- A profile with no `runtime` block is valid and means "touch nothing at runtime".
- The two timeouts run inside one hook invocation, so their **sum** must stay under 600 s.

## The seed contract

`runtime.seed` is a script in *your* repo — [`reference/seed-example.sh`](reference/seed-example.sh) is a
template that refuses to run unedited. It runs once per worktree, inside the profile's shell, with the
worktree as its working directory and `WT_NAME`, `WT_SLUG`, `WT_PORT`, `WT_PATH`, `WT_ROOT`,
`WT_ENV_FILE` and `WT_ENV_FILES` in the environment. Its rules: it only ever creates; it checks before it
writes; it holds no credentials; it creates **every** store the app derives, in every environment (a test
env that appends `_test` to a database name needs that database too); and it marks what it made, so
`runtime.teardown` — which runs only for a worktree whose seed actually ran — can prove a database is its
own before dropping it.

## Cleaning up

A worktree the plugin created (`EnterWorktree`, subagents) is torn down when Claude Code removes it —
**only if it holds no work** (uncommitted or
unpushed changes, an operation in progress, a lock). One that does is kept, and Claude Code is told it was
kept. A `claude -w` worktree is removed by Claude Code itself, which tells no hook, so its runtime
allocation (its databases) is deliberately left for you to release — re-entering the same name reuses
it. For that, and anything else left over:

```
/worktree-prune
```

reports orphaned directories, stale git registrations, runtime allocations nothing uses, and abandoned
subagent worktrees, and removes only what you confirm. It never touches a live worktree that holds work,
and never a database the plugin did not allocate.

## Troubleshooting

- **The worktree is bootstrapped but the app still uses the shared database.** Run the app's own "which
  database is this" query in the worktree. Common causes: the override file is not one the app loads in
  that environment (frameworks read fixed names, and a different set per environment — the test
  environment often skips `.env.local`); something sets the variable in the **process** environment,
  which beats every env file (a `VAR=value` prefix in a documented command, a task runner passing
  `-e VAR=…` into a container); or the app's dotenv parser keeps the first assignment rather than the
  last.
- **The first bootstrap is slow.** A toolchain wrapper can cost tens of seconds per call — `nix develop`
  measured 14 s warm and 25–38 s in a fresh worktree — and each install runs inside it. Database clones
  are bound by the server's DDL, not by bytes: run them in parallel in the seed.
- **A worktree made with `git worktree add` is not set up.** It must be under `.claude/worktrees/`; the
  plugin ignores a session anywhere else. Its first session then applies `.worktreeinclude` too.
- **Migrating a cloned database is refused over "previously executed migrations that are not
  registered".** The source database already carries migrations from other branches — the
  cross-contamination this plugin prevents from here on, inherited by the clone. Answer the migration
  tool's confirmation, or re-seed from a clean source.
- **A hand-configured worktree was left alone.** Deliberate: an env file that differs from the main
  checkout's and was never written by the plugin is treated as yours. Add the block's first line back to
  hand it over.
- **A worktree was not bootstrapped at all, though the plugin's commands work.** It is enabled by the
  project but not installed for you: run `claude plugin install worktree@worktree --scope project`.
- **Databases from removed `claude -w` worktrees stay around.** Deliberate (re-entry reuses them);
  `/worktree-prune` releases them when you are done.
- **Subagent worktrees pile up.** Claude Code does not remove subagent worktrees a `WorktreeCreate` hook
  made; `/worktree-prune` offers the abandoned ones.

## Documentation

| Document | What it holds |
|---|---|
| [docs/00-context.md](docs/00-context.md) | The problem, verified platform facts, prior art |
| [docs/01-decisions.md](docs/01-decisions.md) | Design decisions and their evidence (ADRs) |
| [docs/02-architecture.md](docs/02-architecture.md) | Layers, profile schema, hook contracts, file layout |
| [docs/03-roadmap.md](docs/03-roadmap.md) | Phase index and status |
| [docs/phases/](docs/phases/) | One document per phase, each with its handoff |

Tests: `tests/test_*.sh`, against scratch repositories; run with `nix shell nixpkgs#jq -c <suite>` so
both JSON backends are exercised.

## License

MIT
