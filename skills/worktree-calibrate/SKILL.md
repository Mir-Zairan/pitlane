---
name: worktree-calibrate
description: Examine this repository and write its worktree profile (.claude/worktree-profile.json) — how dependencies install, what toolchain shell that must run inside, and what runtime state two parallel sessions would collide on. Use when setting up the worktree plugin in a new repo, when a bootstrap warns that no profile exists, or after the repo's toolchain or dependency set changes.
argument-hint: "[--force]"
---

# Worktree — calibrate to this repo

Write `<repo>/.claude/worktree-profile.json`: the one file that makes this generic plugin fit
*this* repository. Everything repo-specific lives there, so the hooks that run on every session
can stay dumb, fast, deterministic bash
([ADR-001](../../docs/01-decisions.md#adr-001), [ADR-002](../../docs/01-decisions.md#adr-002)).

You run **once per repository, with the developer present**. That is the only moment judgement is
allowed, so spend it on the things that actually need judgement and let the script do the rest.

## The split that governs everything below

**Layers 1 and 2 are detectable.** A lockfile implies an install command; a `flake.nix` implies a
shell wrapper. `hooks/scripts/detect.sh` works those out deterministically, from
`reference/detection.json`. Do not re-derive them from memory, and do not improvise reasons — the
reasons are data, so that two runs give the same answer.

**Layer 3 is not detectable, and must never be guessed**
([ADR-006](../../docs/01-decisions.md#adr-006)). Nothing in a repository states that an env var
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
| `dep` `depReason` | One proposed dependency entry and why that strategy. |
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
  `install`, `verify`, `shell`, `shellArgs` or `runtime` value.
  This matters most for exactly the value most likely to have been hand-edited: an `install` command a
  developer narrowed after one of the hazard conversations below. Detection *keeps* a `note` hazard's
  lifecycle script, so regenerating that command silently re-arms it — and the next unattended session
  start runs it again. Consent given once must not be erased by a flag.
- **An older `schemaVersion`:** migrate it, and say exactly what changed and why. Never drop a key
  you do not recognise without saying so.
- **A second run on an unchanged repo must change nothing** and must say so plainly. If you find
  yourself producing a different profile from the same repository, something is wrong — detection is
  deterministic, so the difference is coming from you.

## 3 — Present layers 1 and 2, with the reasons

For each `dep`, show: the directory, the lockfile, the strategy, the install command, the `verify`
command if there is one, and the one-line reason. The reason exists so the developer can **disagree** — make that easy, not
rhetorical.

Say the strategy rationale plainly when it comes up, because it is the part people push back on:
`install` is for a package manager with its own content-addressable store (pnpm, bun, uv, Yarn
Berry) where the tree is mostly not real disk and sharing it is unsafe; `hardlink` is for one that
writes real bytes per project; `skip` is for build output a shared cache already handles
([ADR-004](../../docs/01-decisions.md#adr-004), [ADR-005](../../docs/01-decisions.md#adr-005)).

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
line. **Not** profile `copy` entries ([ADR-007](../../docs/01-decisions.md#adr-007)): it is native
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

## 5 — Layer 3: ask, with `AskUserQuestion`

This is the part that needs a human, and the part where being wrong is worst.

**Lead with the honest framing.** Two sessions in this repo will share whatever the app points at —
its port, its database, its cache. Ask whether that is a problem *here*. For plenty of repos it
genuinely is not, and `no runtime isolation` is the right answer.

Then, only if they want isolation, ask what identifies the collidable state — using `hint` records
as **options to choose from, never as pre-filled defaults**. Ask about:

- **the environment variable that selects the database**, if there is one;
- **the port variable**, a sensible base to derive from, and how wide a span to spread across;
- **which override file the app actually loads** — this becomes `runtime.env.file`, and nothing else
  can supply it: the engine has nowhere to write the overrides without it. It must be a file the app
  loads **last**, and it must **not** be a file the checkout already has. Never name `.env` or
  anything you just offered for `.worktreeinclude` — the engine would overwrite the copied file. A
  dedicated, gitignored `.env.worktree.local`-style name is what you want;
- **whether a seed step is needed** — does a fresh database need populating before the app runs?
- **whether a teardown step is needed** — see the rule about it below.

### Every environment, not just the default one

A repo commonly keeps separate **development, test and CI** state, and isolating only the
development database is the "looks right, is subtly wrong" failure in its purest form: a test runner
that recreates its databases wholesale will destroy a parallel session's test run regardless of how
well the dev database is isolated, and it will do it invisibly, mid-suite.

So surface **every** environment the `hint` records came from and let the developer pick which ones
need their own state. Write one `runtime.env.vars` entry per confirmed environment. "Only development"
is a fine answer — but it has to be an answer, not an omission you made for them.

### Rules for this step, and they are not negotiable

- **Write no `runtime` block the developer did not explicitly confirm.** Omitting it is valid and
  means *touch nothing*.
- Confirm each answer back in concrete terms — "a worktree named `alice/fix-99` would get database
  `app_alice_fix_99` on port 3214, with overrides written to `.env.worktree.local`" — because that is
  the sentence in which a wrong guess becomes obvious.
- **Never author a command that drops, truncates, resets, recreates or dumps a database.** Not in
  `seed`, and above all not in `teardown`. Teardown is by nature "destroy the state we made", so it is
  the single easiest place to be helpful and catastrophic: a `DROP DATABASE` whose slug mapping is
  even slightly off drops the shared one, it is committed for the whole team, and a later phase runs
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
- **No secrets in the profile, ever** ([ADR-008](../../docs/01-decisions.md#adr-008)). A password for
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
- `runtime.port` — `var`, `base` and `span`; the port is derived as `base + (crc32(slug) % span)`, so
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
bootstrap will take, and what — if anything — will be isolated. Recommend committing the profile: it
is meant to be shared, so a teammate who installs the plugin gets a working setup with no
calibration run of their own ([ADR-008](../../docs/01-decisions.md#adr-008)).

## What you must not do

- **Do not act on the profile.** No copying, no installing, no ports, no seeding, no worktree
  creation. This command writes a file and nothing else; later phases consume it.
- **Do not hand-write detection.** If a lockfile or toolchain is unrecognised, the fix is an entry in
  `reference/detection.json` — one place, benefiting every repo — not a special case improvised into
  one profile.
- **Do not put judgement in the hooks.** Anything you learn here belongs in the profile.
  ([ADR-002](../../docs/01-decisions.md#adr-002)).
- **Do not propose `strategy: "store"`.** It is a valid schema value that no phase implements yet.
