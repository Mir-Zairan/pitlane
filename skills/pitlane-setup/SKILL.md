---
name: pitlane-setup
description: Examine this repository and write its worktree profile (.claude/worktree-profile.json) — how dependencies install, what toolchain shell that must run inside, and what runtime state two parallel sessions would collide on. Use when setting up Pitlane in a new repo, when a bootstrap warns that no profile exists, or after the repo's toolchain or dependency set changes.
argument-hint: "[--force]"
---

# Pitlane — set it up for this repo

Write `<repo>/.claude/worktree-profile.json`: the one file that makes this generic plugin fit
*this* repository. Everything repo-specific lives there, so the hooks that run on every session
can stay dumb, fast, deterministic bash.

You run **once per repository, with the developer present**. That is the only moment judgement is
allowed, so spend it on the things that actually need judgement and let the script do the rest.

## The split that governs everything below

**Layers 1 and 2 are detectable.** A lockfile implies an install command; a `flake.nix` implies a
shell wrapper. `hooks/scripts/detect.sh` works those out deterministically, from
`reference/detection.json`. Do not re-derive them from memory, and do not improvise reasons — the
reasons are data, so that two runs give the same answer.

**Layer 3 is not detectable, and must never be guessed**. Nothing in a repository states that an env var
selects a tenant database. A wrong guess here does not produce a broken worktree — it corrupts a
colleague's data. So you **ask**, with detected values offered only as hints, and *no runtime
isolation* is a perfectly good answer.

**The failure mode to design against is a profile that looks right and is subtly wrong.** Not a
missing answer — a plausible one. Prefer refusing to guess over guessing quietly.

## 1 — Run the detector

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/detect.sh" "$REPO"
```

`$REPO` stands for the repository root — a **value to quote**, not text to paste. Paths can contain
spaces, and a repository is not trusted input.

Tab-separated records, one per line, label first. Read
`${CLAUDE_PLUGIN_ROOT}/reference/detection.md` if a record needs interpreting; it is the
human-readable companion to the table the script used.

| Label | What to do with it |
|---|---|
| `detectionVersion` | Goes into the profile's `evidence.detectionVersion`. |
| `repoRoot` | The resolved repo root. Sanity-check it is the repo you meant. |
| `shell` `shellArgs` `shellMarker` `shellReason` | The toolchain wrapper. Present with its reason. |
| `shellWarn` | Show it. It means installs would run somewhere the repo does not expect. |
| `probe` | `ok` = the wrapper works. `fail` = show it prominently. `timeout` = **inconclusive**, not a failure; say so. |
| `dep` `depReason` | One proposed dependency entry and why that strategy. A **nested** entry (its `dir` has a directory in front, its commands start `cd '<dir>' &&`, and a `depNote` says `nested:`) is a sub-project with its own lockfile, outside any JS workspace, that a root install does not populate. Present it as its own entry; the developer may know it is not needed in a worktree. (A nested JS tree in a repo that declares a workspace comes back as `dropped` instead — the root install may own it.) |
| `depNote` | A caveat about this ecosystem. Worth showing. |
| `depDowngrade` | The strategy changed because a directory is not there. Show the reason. |
| `dropped` | A lockfile was NOT used. Always surface this — two live lockfiles for one directory is usually a mistake the developer wants to know about. |
| `hazard` | A lifecycle script was found. `neutralise` = a flag was added to the proposal. `note` = kept, but say what it costs. |
| `hazardChain` | What that script actually resolves to. Quote it when you ask. |
| `escalate` | A rule **matched**: this install *will* do the dangerous thing. **Ask. Never neutralise silently.** Check the paired `hazard` line before claiming anything was added — see below. |
| `unreadable` | The trail could not be followed: it *might*. Ask for confirmation, but do **not** claim you found a migration. |
| `corroborate` | The repo already answers this elsewhere. Cite it — it is evidence, not decoration. |
| `config` | Gitignored config a fresh checkout would miss. |
| `hint` | Layer-3 candidates. **Hints beside a question, never defaults.** |
| `compose` | What names each compose project, and how many host ports it publishes. Raise it in step 5. |
| `assign` | A `NAME=value` for a hinted variable in the repo's own docs or scripts — *possibly* an inline pin. Read the line: a command prefix, an `export`, or a `-e NAME=…` passed to a container sets the process environment and beats every env file; a code block showing `.env` contents does not. Raise the real ones in step 5 and in the agent note. |
| `ignore` | Whether a path the plugin creates in a checkout is gitignored. `missing` — offer the `.gitignore` line in step 4. |
| `warn` | Show it. |

If detection exits non-zero it could not run at all — no such directory, no detection table, no
`jq` and no `python3`. Report that and stop; do not hand-write a profile to work around it.

## 2 — Already calibrated?

Read the existing profile first if there is one.

- **`--force` suppresses ONE prompt and no others:** the "a profile already exists, recalibrate?"
  question. It does **not** mean "regenerate everything from detection".
- **A hand-edited value must never be silently discarded, `--force` or not.** If the existing profile
  disagrees with what detection proposes, that is a *question*, not a merge conflict to resolve on
  your own, and the default answer is **keep theirs**. Show both and ask for every differing
  `strategy`, `install`, `verify`, `shell`, `shellArgs` or `runtime` value.
  This matters most for exactly the value most likely to have been hand-edited: an `install` command a
  developer narrowed after one of the hazard conversations below. Detection *keeps* a `note` hazard's
  lifecycle script, so regenerating that command silently re-arms it — and the next unattended session
  start runs it again. Consent given once must not be erased by a flag.
- **A profile whose `evidence.detectionVersion` is below 3 and that hardlinks a `.venv`** (any entry
  whose `dir` is or ends in `.venv` with `strategy: "hardlink"`): raise it as an explicit change to
  `install`, not one more differing value. Say why before asking: a hardlinked venv's scripts,
  `activate` files and editable-install mappings name the main checkout, so every worktree installs
  into main's venv and imports main's source. Propose the `install` command detection gives now, and
  a `verify` as step 3 says. Keep-theirs still applies — but if they keep `hardlink`, say in the agent
  note that they chose it knowing this.
- **An older `schemaVersion`:** migrate it, and say exactly what changed and why. Never drop a key
  you do not recognise without saying so.
- **A second run on an unchanged repo must change nothing** and must say so plainly. If you find
  yourself producing a different profile from the same repository, something is wrong — detection is
  deterministic, so the difference is coming from you.

## 3 — Present layers 1 and 2, with the reasons

For each `dep`, show: the directory, the lockfile, the strategy, the install command, the `verify`
command, and the one-line reason. The reason exists so the developer can **disagree** — make that easy, not
rhetorical.

**Every dependency gets a `verify`** — every one whose strategy is not `skip`. bootstrap believes it
over the install's exit code, so without one a failed install and a usable tree look the same. Use the
one detection proposed. When its `verify` field is empty (a `no default verify:` `depNote` says why —
a tool that writes no file only a finished install writes, or whose in-project directory is opt-in and
absent), **ask the developer** for a check rather than writing none: a plain file test, run from the
worktree root in the host shell, that names a file the install writes and that cannot pass on an
empty or missing tree, nor on what a failed install leaves — usually a package this repo always
installs (`test -f node_modules/<package>/package.json`). Do not use a tool command (`composer
validate`, `npm ls`) unless the developer confirms the tool is on the host shell's PATH — `verify` runs
outside the toolchain shell — and a check on the lockfile alone passes with no tree at all. A profile written before `verify` was required still
works unchanged; offer to add one on recalibration, under the keep-theirs rule above.

Say the strategy rationale plainly when it comes up, because it is the part people push back on:
`install` is for a package manager with its own content-addressable store (pnpm, bun, uv, Yarn
Berry) where the tree is mostly not real disk and sharing it is unsafe; `hardlink` is for one that
writes real bytes per project; `skip` is for build output a shared cache already handles. A Python
venv is always `install`, even an in-project one: a hardlinked venv's scripts and editable installs
point at the main checkout, so the worktree would install into and import from main. If the developer
asks for `hardlink` on a `.venv`, say that before writing it.

**Hazards are not a footnote.** When you see `escalate`, stop and ask — quote the `hazardChain` so
the developer can see what the install actually reaches.

**Do not assume a flag was added.** Whether the proposal is already guarded depends on the paired
`hazard` record for the same dep index:

- `hazard … neutralise …` — the flag *is* in the proposed command. But *adding a flag is not the same
  as being allowed to*: the developer may know it is safe, or may need a different command entirely.
- `hazard … note …` — nothing was added, because a `note` hazard is deliberately kept. So an
  `escalate` beside a `note` means **the dangerous command is still exactly as it was**. Say so; do
  not tell the developer it is guarded when it is not.

When you see `unreadable`, ask for confirmation and be honest that you could not read the chain
rather than implying you found something.

## 4 — Gitignored config: write a `.worktreeinclude`, not `copy` entries

Every `config` record is a file a fresh worktree would be missing and cannot regenerate.

Offer to write or extend `.worktreeinclude` at the repo root — `.gitignore` syntax, one pattern per
line. **Not** profile `copy` entries: it is native
Claude Code behaviour that keeps working if this plugin is uninstalled, and repos already using it
get taken over transparently. `copy` is only for what that file cannot express.

If `.worktreeinclude` already exists, add to it; never rewrite it.

Note what is and is not committed here, because it is easy to state wrongly: `.worktreeinclude` holds
*patterns* and is committed; the files it matches stay gitignored and are only ever copied locally. So
copying a `.env` into a worktree does not put a secret in git history — that is fine and is the whole
point of the mechanism. The real reasons detection refuses some files are different ones, and worth
repeating if a developer asks you to add one:

- **token-bearing files** — `auth.json`, `.npmrc`, `.netrc`, `.git-credentials` — spread credentials
  into more places on disk for no benefit; the app does not need them to run;
- **machine state** — `*.sqlite`, `terraform.tfstate` — is actively corrupted by duplication: two
  worktrees writing copies of one state file diverge, and the original loses.

The separate rule, which is about the profile and not about `.worktreeinclude`, is that no secret
*value* may be written into the committed profile.

**The plugin's own paths must be gitignored.** For every `ignore … missing` record, offer the line
for the repo's `.gitignore`. Say why, because it is not obvious: an untracked file inside a worktree
is *work* to the teardown guard, so a worktree holding an unignored `.claude/worktree-no-runtime`
is never torn down; committed, that marker switches layer 3 off for the whole team. The same goes for
every `runtime.env.file` chosen in step 5 — check each with `git check-ignore` before writing the
profile; the engine refuses to write one that is not ignored.

## 5 — Layer 3: ask, with `AskUserQuestion`

This is the part that needs a human, and the part where being wrong is worst.

**Lead with the honest framing.** Two sessions in this repo will share whatever the app points at —
its port, its database, its cache. Ask whether that is a problem *here*. For plenty of repos it
genuinely is not, and `no runtime isolation` is the right answer.

Then, only if they want isolation, ask what identifies the collidable state — using `hint` records
as **options to choose from, never as pre-filled defaults**. Ask about:

- **the environment variable that selects the database**, if there is one — and then **whether that
  variable also names something the app keys behaviour on**: a tenant whose configuration, feature
  flags or group membership are looked up by that name. Overriding such a variable moves the storage
  *and* changes who the app thinks it is. If there is a narrower knob that moves only the storage (a
  database-name variable the app honours), prefer it. If there is none, say so plainly: the repo may
  need a small change of its own to honour one, and that change is the developer's, not yours;
- **the port variable, and how the dev server actually takes its port** — a variable the app reads,
  a command-line flag, or a compose port mapping. A variable nothing reads isolates nothing. When it
  is a flag, the variable only helps if the start command uses it, so record that command for the
  agent note below. Then a sensible base to derive from, and how wide a span to spread across;
- **which env files the app actually loads, per environment** — these become `runtime.env.file`, a
  path or a list of paths, and nothing else can
  supply them: the engine has nowhere to write the overrides without them. Find out from the app's
  own env loader, not from convention — many frameworks read only fixed names and a *different* set
  per environment (development may read a local file that the test environment skips), so a
  dedicated, invented file name is usually **never read at all**. Name one gitignored file per
  environment that needs its own state. The file may already exist, and may be one you just offered
  for `.worktreeinclude`: the engine appends a managed block after the developer's lines rather than
  replacing the file. Two things to confirm with the developer, because the block depends on both:
  the app's dotenv parser must honour the **last** assignment of a variable, and nothing the app
  runs may set the same variable in the **process** environment first — a `VAR=value` prefix in the
  repo's own docs or scripts beats every file;
- **whether worktrees share the compose stack**, when there is a `compose` record. `explicit:` means
  every worktree drives the *same* containers — a `compose up` in one rebuilds them with that
  worktree's bind mounts, under the main checkout's feet. `directory` means each worktree starts its
  own stack, and every published host port collides with the main checkout's. `env` means
  `COMPOSE_PROJECT_NAME` is set in `.env`. Ask which is wanted. Be accurate about what the plugin can
  do: compose reads its own settings only from the project directory's `.env` (or `--env-file`), so
  if that file is tracked the plugin cannot set `COMPOSE_PROJECT_NAME` for it, and a per-worktree
  stack needs the start command to pass `-p`. Sharing one database server between worktrees is
  normal — isolation is then the seed's job, one database per slug;
- **the `assign` records for the variables chosen above.** Read each line before claiming anything:
  when the repo's own instructions pin the variable as a command prefix, an `export` or a value
  passed into a container, that sets it in the process environment and beats every env file — so a
  session following them inside a worktree runs against the shared state. The fix is in the agent
  note below, not in the profile;
- **whether a seed step is needed** — does a fresh database need populating before the app runs?
- **whether a teardown step is needed** — see the rule about it below.

### Every environment, not just the default one

A repo commonly keeps separate **development, test and CI** state, and isolating only the
development database is the "looks right, is subtly wrong" failure in its purest form: a test runner
that recreates its databases wholesale will destroy a parallel session's test run regardless of how
well the dev database is isolated, and it will do it invisibly, mid-suite.

So surface **every** environment the `hint` records came from and let the developer pick which ones
need their own state. Every confirmed environment needs its env file in `runtime.env.file`, and the
seed must create every store the app derives from the selector in that environment — a test env that
appends `_test` to a database name needs that database cloned too. "Only development" is a fine
answer — but it has to be an answer, not an omission you made for them.

### Rules for this step, and they are not negotiable

- **Write no `runtime` block the developer did not explicitly confirm.** Omitting it is valid and
  means *touch nothing*.
- Confirm each answer back in concrete terms — "a worktree named `alice/fix-99` would get database
  `app_alice_fix_99` on port 3214, with overrides written to `.env.development.local` and `.env.test.local`" — because that is
  the sentence in which a wrong guess becomes obvious.
- **Never author a command that drops, truncates, resets, recreates or dumps a database.** Not in
  `seed`, and above all not in `teardown`. Teardown is by nature "destroy the state we made", so it is
  the single easiest place to be helpful and catastrophic: a `DROP DATABASE` whose slug mapping is
  even slightly off drops the shared one, it is committed for the whole team, and the teardown hook runs
  it unattended on every worktree removal. `runtime.teardown` follows exactly the same rules as
  `runtime.seed` — confirmed by the developer, never inferred, contents never invented, and **omitted
  by default**.
- **Scaffold, do not write.** If they want a seed or a teardown step, create a stub in *their* repo
  (`.claude/worktree-seed.sh`, `.claude/worktree-teardown.sh`) and say what environment it receives:
  the slug, the derived port, and the env overrides. The stub must **fail loudly until edited** —
  `set -euo pipefail`, the commented instructions, then an explicit
  `echo 'worktree-seed.sh is still the unedited stub' >&2; exit 1` sentinel for the developer to
  delete. A comment-only script exits 0, which would report the worktree as seeded when nothing
  happened, and ship a silently no-op seed step to every teammate. Do not `chmod +x` it either.
- **No secrets in the profile, ever**. A password for
  the seed step is read from the environment or from the copied `.env` at run time. If a hint looks
  like a credential, do not put it in the file — not even as an example.

## 6 — Write it, validate it, and say what will happen

Fill in `${CLAUDE_PLUGIN_ROOT}/reference/profile.template.json`'s shape and write it to
`<repo>/.claude/worktree-profile.json`. Notes on the fields that are easy to get wrong:

- `shellArgs` — copy what detection said. `argv` and `string` are not interchangeable, and getting it
  backwards fails in a way that reads like a missing binary.
- `deps[].lockChecksum` — the output of **`cksum < <lockfile>`**, with the redirect, per dependency.
  Two whitespace-separated numbers and nothing else, matching the template's `"1234567890 397"`.
  `cksum <lockfile>` as an *argument* appends the filename, which the validator rejects outright and
  which the drift check would never match. This is the evidence a later session compares to notice the
  profile has drifted.
- `evidence` — `detectionVersion` from the detector, `markers` as the sorted list of lockfiles it
  matched, `shellMarker` as the file that produced the wrapper.
- `runtime.port` — `var`, `base` and `span`; the port is derived as `base + (cksum(slug) % span)`
  using POSIX `cksum` (not zlib CRC-32 — they disagree); `base` must be at least 1024 and
  `base + span - 1` no more than 65535, so
  `span` decides how much room there is before two worktrees collide.
- `timeouts` — the two must **sum** to less than the hook's own timeout (600s), because both run
  inside one hook invocation. Setting each to 600 means the platform kills the hook before either
  guard fires.
- No `_comment` keys in the file you write. Those are the template's annotations, not schema.

Then **validate, and treat failure as fatal here** — unlike the hooks, which warn and fall back to
defaults, you must not write a profile that does not validate:

```bash
bash -c '. "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/lib.sh"
         wt_validate_profile "$1/.claude/worktree-profile.json" "$1"' _ "$REPO"
```

The path is passed as an **argument**, not interpolated into the script text — interpolating it would
let a `$(…)` in a directory name be re-evaluated by the inner shell.

It prints one problem per line, each naming the offending key, and exits non-zero if there are any.
Fix them and re-validate. Warnings go to stderr — show those too; they are things worth knowing, not
noise.

Finally, tell the developer **what happens on the next `claude -w`**, concretely: which directories
get hardlinked and which get installed, what shell that runs inside, roughly how long the first
bootstrap will take, and what — if anything — will be isolated. Then ask **who it is for**:

- **the team** — commit the profile, `.worktreeinclude` and the scripts; a teammate who installs the
  plugin gets a working setup with no calibration run of their own;
- **only this developer** — commit nothing. Leave the files untracked in the main checkout and list them
  in `.git/info/exclude` (never committed, shared by every worktree); put the seed and teardown scripts
  in the profile's `copy[]` so each worktree gets them; and write the agent note to `CLAUDE.local.md`,
  listed in `.worktreeinclude`, instead of the repo's shared instructions.

### Approve what you wrote

The hooks run none of the profile's commands — installs, verify checks, the seed and teardown
scripts — until the developer approves that exact content, so a profile nobody approves sets up config
and ports and nothing else. Once the profile **and the scripts it names** are written, run from the main
checkout:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bootstrap.sh" --review
```

Show the developer what it lists, and on their confirmation run the `--approve <fingerprint>` command it
printed. Tell them that any later edit to the profile or to those scripts — theirs, a teammate's, a pull
request's — needs approving again, which `/pitlane-finish` walks them through; and that the approval
covers the commands Pitlane starts, not what an approved install runs from the branch's own manifests
(package lifecycle scripts) or toolchain files.

### Propose a note for the repo's agent instructions

A session cannot tell a bootstrapped worktree from a bare one — the hooks print nothing into its
context by design — so without being told it reinstalls dependencies, re-clones the database and
hunts for a port out of habit. Offer a short section for the repo's `CLAUDE.md` (or `AGENTS.md`, if
`CLAUDE.md` only imports it), **filled from the profile you just wrote**, and write it only if the
developer confirms. Neutral wording; nothing about this plugin's internals. It says:

- worktrees under `.claude/worktrees/` arrive bootstrapped: name the dependency directories that are
  provided, and say not to reinstall them or re-seed;
- the env files named in `runtime.env.file` already point this worktree at its own database and
  port — and, from every `assign` record, which documented commands pin a variable inline and must
  be run **without** that prefix inside a worktree;
- how to start the dev server on the worktree's port, when the port is taken by a flag;
- when the profile has `runtime.serve`: start the app with `/pitlane-serve`, never the repo's own
  start command (which does not know this worktree's port), and find it at `$WORKTREE_URL` — set in
  the session's environment and in the env files named above — rather than at the main checkout's
  usual address;
- to make another worktree, use `EnterWorktree` or a subagent with `isolation: "worktree"` — not a
  raw `git worktree add` from inside a session, which no hook sees. The exception is checking out an
  *existing* branch, which neither can do: `git worktree add .claude/worktrees/<name> <branch>`, then
  start a new session inside it. It must be under `.claude/worktrees/` — a worktree anywhere else is
  never bootstrapped.

If there is no `runtime` block, leave out the database and port lines rather than writing them as
"not isolated" — say that in the confirmation instead.

## What you must not do

- **Do not act on the profile.** No copying, no installing, no ports, no seeding, no worktree
  creation. This command writes a file and nothing else; the hooks consume it.
- **Do not hand-write detection.** If a lockfile or toolchain is unrecognised, the fix is an entry in
  `reference/detection.json` — one place, benefiting every repo — not a special case improvised into
  one profile.
- **Do not put judgement in the hooks.** Anything you learn here belongs in the profile.
- **Do not propose `strategy: "store"`.** It is a valid schema value that is not implemented.
