# Detection

What `/worktree-calibrate` can work out for itself, what it must ask about, and what it must refuse to
do quietly.

> **`reference/detection.json` is ground truth.** The tables below are a readable rendering of it, for
> humans deciding whether a rule is right. `hooks/scripts/detect.sh` reads the JSON; nothing reads this
> file at runtime. **To add an ecosystem, edit `detection.json`** — then update the table here in the
> same commit. If the two ever disagree, the JSON is correct and this file is stale.
>
> `docs/02-architecture.md` used to carry a third copy of these tables. It now points here. One table
> restated in three places is a doc-rot generator, and this repo's rule is that documents which lie are
> worse than no documents.

## The split this file exists to enforce

Layers 1 and 2 are **genuinely detectable**: a lockfile implies an install command, a `flake.nix`
implies a shell wrapper. Layer 3 is **not**, and must never be guessed
([ADR-006](../docs/01-decisions.md#adr-006)) — nothing in a repository says that an env var selects a
tenant database.

So calibration *detects and proposes* the first two, and *hints and asks* for the third. The failure
mode to design against is not "no answer"; it is **a profile that looks right and is subtly wrong**.
Detection should refuse to guess rather than guess quietly.

## Dependency directories

First column is the marker file at the repo root. Strategy rationale is
[ADR-004](../docs/01-decisions.md#adr-004) / [ADR-005](../docs/01-decisions.md#adr-005): `install`
where the tool has its own content-addressable store, `hardlink` where it materialises real bytes per
project, `skip` where the artefacts are build output that a shared cache already handles.

| Marker | `dir` | Strategy | Install command |
|---|---|---|---|
| `composer.lock` | `vendor` | hardlink | `composer install --no-interaction --no-progress` |
| `pnpm-lock.yaml` | `node_modules` | install | `pnpm install --frozen-lockfile` |
| `package-lock.json` | `node_modules` | hardlink | `npm ci` |
| `yarn.lock` + `.yarnrc.yml` | `.yarn/cache` | install | `yarn install --immutable` |
| `yarn.lock` (no `.yarnrc.yml`) | `node_modules` | hardlink | `yarn install --frozen-lockfile` |
| `bun.lock` / `bun.lockb` | `node_modules` | install | `bun install --frozen-lockfile` |
| `uv.lock` | `.venv` | install | `uv sync --frozen` |
| `poetry.lock` | `.venv` | hardlink¹ | `poetry install` |
| `Pipfile.lock` | `.venv` | hardlink¹ | `pipenv sync` |
| `Gemfile.lock` | `vendor/bundle` | hardlink¹ | `bundle install` |
| `mix.lock` | `deps` | hardlink | `mix deps.get` |
| `Cargo.lock` | — | skip | `cargo fetch` |
| `go.sum` | — | skip | `go mod download` |

¹ `requiresDir: true` — these three only get `hardlink` if the directory actually exists in the main
checkout, because for all three it is **opt-in, not the default**. Otherwise they fall back to
`install`. See the caveats.

A repo can match several of these at once and each is independent — **except that at most one entry
may claim a given `dir`**. A repo mid-migration with both `pnpm-lock.yaml` and `package-lock.json`
would otherwise get two `node_modules` entries with contradicting strategies, so bootstrap would
hardlink a tree and then reinstall over it. Array order breaks the tie, and calibration must **say
which marker it dropped** — two live lockfiles for one directory is usually a mistake the developer
wants told about.

Matching is **first-match-wins per marker**. A rule may carry a `when` guard, and the guarded rule sits
*before* the rule it refines: the Yarn Berry rule is guarded on `.yarnrc.yml`, so a Berry repo takes it
and a classic repo falls through to the next rule naming `yarn.lock`. The table is flat for a reason —
an earlier revision nested guarded rules inside a `variants` array on their parent, which reads well but
cannot be consumed, because the plugin's JSON layer addresses values by dotted path and cannot index
into an array. Ordering plus a guard expresses the same thing with no nesting.

### Caveats worth stating out loud

- **Yarn Berry is a different package manager wearing the same lockfile name.** `yarn.lock` plus
  `.yarnrc.yml` means Yarn 2+, which keeps a zip cache and — under Plug'n'Play — has no
  `node_modules` to share at all. `--frozen-lockfile` is the deprecated spelling of `--immutable`.
  Detecting only on `yarn.lock` would propose hardlinking a directory that does not exist.
- **`Pipfile.lock`'s `.venv` is the exception, not the rule.** pipenv's *default* is a venv **outside**
  the project, under `~/.local/share/virtualenvs/<project>-<hash>`. `.venv` is used only when
  `PIPENV_VENV_IN_PROJECT` is set or a `.venv` already exists — so proposing `hardlink` unconditionally
  would name a directory that isn't there.
- **`poetry.lock` assumes an in-project venv too.** `poetry install` only creates `.venv` in the
  project when `virtualenvs.in-project` is set. Also note `poetry install --sync` is deprecated in
  Poetry 2.0 in favour of `poetry sync`; plain `poetry install` is correct on both, which is why the
  table uses it.
- **`Gemfile.lock` assumes a vendored bundle.** `vendor/bundle` only exists if bundler is configured
  with `path` — check `.bundle/config`. Otherwise gems live in the system/rbenv gem home.
- **A venv is not fully relocatable.** Scripts in `.venv/bin` hard-code an absolute interpreter path
  in their shebang, so a hardlinked venv still points at the main checkout's path. It usually works
  because the interpreter is outside the repo, but it is the reason `uv` is `install` rather than
  `hardlink` even beyond ADR-005.
- **`Cargo.lock` gets `dir: null`, not `dir: target`.** `install` is documented as the command that
  populates `dir`, and `cargo fetch` populates `CARGO_HOME`, not `target/`. Naming a directory the
  entry then skips would be a claim it doesn't honour. Nothing per-project is managed for Rust.
- **A workspace is one entry; a nested project with its own lockfile is its own entry.** A pnpm (or
  npm, yarn, bun) workspace has one root lockfile, and its members' `node_modules` are the root
  install's business — recording each would make the profile a mirror of the workspace layout. A
  nested directory that keeps its **own** lockfile is different: no root install touches it (a
  tool-per-directory composer layout is the common case). Since detection version 2 such directories
  are found through `git ls-files` — so ignored trees are never walked and untracked scratch is never
  proposed — and each is judged by the same rules as the root: strategy, hazards from its own
  manifest, escalations. It is proposed only when its dependency directory **exists and is
  gitignored** in the checkout, which is the evidence that somebody installs it there; a tracked
  lockfile without an installed tree is usually a test fixture and is reported as `dropped`. Its
  commands begin `cd '<dir>' &&`, because every entry's commands run from the worktree root. At most
  32 directories are considered, and one whose name has characters outside a conservative set is
  warned about rather than put in a command.

## The toolchain shell

Hooks launch from the **host** shell, where the project's PHP/Node/Python is usually not on `PATH`.
This table is **ordered by precedence** and matching is first-match-wins.

| Marker | `shell` | `shellArgs` |
|---|---|---|
| `flake.nix` | `nix develop --command` | `argv` |
| `shell.nix` (no flake) | `nix-shell --run` | **`string`** |
| `.envrc` (no nix) | `direnv exec .` | `argv` |
| `.devcontainer/` only | `""` + warn that installs run on the host | `argv` |
| none (`marker: null` catch-all) | `""` | `argv` |

The last row is a real entry in `detection.json`, not just prose — a catch-all with `marker: null` at
the end of the precedence list. Encoding it means first-match-wins always terminates, so `detect.sh`
never has a no-match branch to get wrong.

`shellArgs` is not cosmetic, and it is why the profile records it rather than letting a consumer infer
it from the string. `nix develop --command` takes the wrapped command as **argv**; `nix-shell --run`
takes it as **one string**. Get it backwards and the failures are not graceful:

```
nix-shell --run composer install          # `install` is read as a nix file to load
nix develop --command "composer install"  # looks for a binary literally named "composer install"
```

### Smoke-test the wrapper, not the install

After proposing a shell, run **one bounded version check per detected tool** — `<shell> <tool>
<versionArgs>`. Seconds, no side effects, no database, nothing installed. This catches the largest real
class of "the profile looks right and is wrong" — a wrong wrapper, or a toolchain simply absent from
the host.

`versionArgs` is per tool in `detection.json`, not a hard-coded `--version`, because there is no
universal spelling: **`go --version` does not exist** — it exits non-zero with a usage error, and the
subcommand is `go version`. Hard-coding `--version` would report "toolchain absent from the host" for
every healthy Go repo, which is exactly the false positive the probe exists to rule out.

Full prove-by-installing is deliberately **not** done at calibrate time. It costs minutes (on the
real repository, a 400 MB `vendor/` plus a pnpm workspace), and it proves the wrong property: an install
that migrates the shared database **exits 0**, so the dangerous variant is exactly the one that passes.
Phase 6 owns the real run.

## Post-install hazards

This is where a plausible profile does real damage. The hazard is not that an install fails — it is
that it **succeeds** and has side effects on state shared with every other worktree and with the main
checkout.

| Hazard | Probes | Action |
|---|---|---|
| composer lifecycle scripts | `pre-install-cmd`, `post-install-cmd`, `post-autoload-dump`, `post-package-install`, `post-package-update` in `composer.json` | **Neutralise** — append `--no-scripts` |
| npm/pnpm/yarn lifecycle scripts | `preinstall`, `install`, `postinstall`, `prepare` in `package.json` | **Note** — keep it, but tell the developer this is where bootstrap time goes |
| Rails setup-task wrapper | `Rakefile` present | **Note** — bundler has no post-install hook, but a `setup` task often loads the schema; check what the install command actually wraps |
| A rule matched over the resolved chain | the escalation pattern | **`escalate` / refuse and ask** — it *will* migrate |
| The chain could not be followed | an unfollowable leaf, or the hop budget ran out | **`unreadable` / confirm** — it *might* |

**Probing one key is not enough.** `composer install` fires more than `post-install-cmd`, and a
framework repo conventionally hangs its migration off `post-autoload-dump` — so a single-key probe
reported such a repo as clean and proposed a plain `composer install`. Every key above is probed and
each resolved chain is judged separately.

### The escalation rule, and why one level of matching is not enough

Any hazard whose script text matches the migration pattern in `detection.json` — `migrat`,
`doctrine:`, `db:migrate`, `db:reset`, `db:fresh`, `schema:load`, `artisan migrate`, `rake db:`,
`alembic`, `prisma migrate`, `drizzle-kit push`, `atlas schema apply`, `flyway`, `liquibase`, a raw
`mysql … < dump.sql` — **escalates**. Calibration must not quietly append a flag. It must state which
script it found and what that script calls, then **ask**.

Three properties of that matching are load-bearing:

- **Matching is case-insensitive.** Real script targets are camelCase (`dbMigrate`), and a lowercase
  pattern misses them.
- **Match the whole resolved chain, not the first link.** A probe returns a script's *immediate* value,
  and in real repos that value is almost always a reference somewhere else — `@name`, `npm run x`,
  `make x`, `bin/console x`, a `Class::method` callback, a path to a script. Follow each form (up to
  `chainMaxDepth`) and match at every level. **Running out of hops counts as unfollowable**, or a repo
  need only nest its migration one level deeper than the budget to be reported as a fully-followed,
  migration-free chain.
- **A script name containing a dot cannot be followed at all.** The plugin addresses JSON values by
  dotted path, so `scripts.some.name` is unreachable and a reference to it is treated as an
  unfollowable trail. This fails *safe* — it reports `unreadable` and asks — but it is a false alarm
  rather than a real finding, so a repo that names its scripts `db.migrate` rather than `db:migrate`
  will be asked about every install. Colons and dashes are followed normally; only dots are affected.
- **An unfollowable chain is reported, but not as a match.** A trail that runs into code this cannot
  read is not evidence of safety — and it is not evidence of danger either. It gets its own
  `unreadable` label with action `confirm`, because nearly every real composer chain ends in a code
  callback: reporting all of them as "a migration was found" would fire on almost every repository,
  and an alarm that always fires is one developers learn to click through. Both reach the developer;
  only `escalate` claims to have found something.

A real match is the one failure mode with no recovery, because it runs against the *shared*
development database.

### The worked example that proves it

The repository this design was drawn from chains into a migration like this:

```
post-install-cmd  ->  @install-lib, @cache:clear, @db, @warm-up, @assets:install
@db               ->  @db:prepare-config, @db:update-functions, @db:migrate, @db:update-views
@db:migrate       ->  Vendor\Pkg\Scripts::dbMigrate
```

A plain `composer install` in a fresh worktree therefore migrates the shared database and rewrites
its views and functions, while another session is using it. This is bug 4 of the source
conversation's scripts ([00-context](../docs/00-context.md#the-source-conversation)) — confirmed
against a real repository rather than assumed.

Now read that chain against a one-level, case-sensitive matcher, because this is the *reason* for
every rule above: the probe returns `["@install-lib","@cache:clear","@db",…]`. Nothing there matches
`db:migrate` — the string is just `@db`. Follow it one hop and `@db:migrate` matches. Follow it one
more and the target is `dbMigrate`, which a lowercase `migrat` misses. **A naive matcher reports the
very repository the hazard rule was written from as clean.** Hence: every lifecycle key, the whole
chain, case-insensitively, with an unfollowable trail reported rather than assumed safe.

## Corroboration: cite it, never import it

Where the repo has **already** answered the same question in an artifact that gets exercised — a CI
workflow, a `Makefile` target, a compose file, a devcontainer — read it and **cite the file** when
proposing. "Your own CI already passes `--no-scripts`" is independent confirmation and far more
convincing than a rule from a table.

**Never import the flags verbatim,** and the difference is not academic. A real workflow line looks
like this:

```
composer install --no-progress --prefer-dist --optimize-autoloader --no-dev --classmap-authoritative --no-scripts
pnpm install --frozen-lockfile --filter <one-package>
```

Imported as-is, a development worktree would get **no dev dependencies** — so no test runner and no
static analyser — and **one package of a multi-package workspace**. CI optimises for a throwaway
machine running one job; a worktree is a development environment. So:

- Strip production/CI-only flags: `--no-dev`, `--production`, `--omit=dev`, `--only=production`,
  `--no-optional`, `--classmap-authoritative`, `--optimize-autoloader`, `--prefer-dist`.
- Strip scoping flags **and their values**: `--filter`, `--workspace` (and their `--flag=value` form).
- **Never take `shell` from CI.** CI has no nix and no direnv — it installs the toolchain itself. A
  wrapper taken from CI is wrong on a developer machine, and wrong in a way that surfaces only as
  "command not found" inside a hook.

Take the corroboration. Drop the flags.

### Two flags that must NOT be stripped

**`--ignore-scripts` and `--no-scripts` are safety flags, not CI optimisations.** They suppress
arbitrary dependency- or repo-authored lifecycle code. Finding one in CI is corroboration to **keep**
it in the proposed install command — stripping it would turn "this repo's own CI deliberately disabled
lifecycle scripts" into "a hook now runs them unattended at session start, before any UI renders".
`--frozen-lockfile`, `--immutable` and `--locked` are in the same keep list: they stop an install from
rewriting the lockfile in a worktree. `detection.json`'s `keepFlags` holds all of them.

**`-w` is stripped, but not as a valued flag.** For npm, `-w` is short for `--workspace` and takes a
value; for pnpm it is `--workspace-root` and is a **boolean**. Treating it as valued would swallow the
following token, so `pnpm install -w --frozen-lockfile` becomes `pnpm install` — a non-frozen install
that can rewrite the lockfile. It therefore sits in `stripFlags` (drop the flag only), which is correct
for both tools.

## Gitignored config a fresh checkout misses

A new worktree is a clean checkout: everything gitignored is absent, and some of it cannot be
regenerated. Candidates are in `detection.json` (`.env*`, `.envrc`, `*.local.yaml`, `config/local.php`,
compose overrides, …).

Two rules:

1. **Propose a `.worktreeinclude`, not profile `copy` entries.** `.worktreeinclude` stays authoritative
   ([ADR-007](../docs/01-decisions.md#adr-007)): it is native behaviour that keeps working if this
   plugin is uninstalled, and repos already using it get taken over transparently. `copy` is a
   supplement for what that file cannot express.
2. **A candidate only counts if it is actually gitignored.** Native copying applies the
   gitignored-only rule, so listing a tracked file achieves nothing and listing a non-existent file is
   noise. Confirm with `git check-ignore` before proposing.

And never propose credentials or machine state. `detection.json`'s `neverPropose` list covers them as
classes rather than one-offs:

- **Keys and certificates** — `*.pem`, `*.key`, `*.crt`, `*.p12`, `*.pfx`, `*.keystore`, and every SSH
  private-key name (`id_rsa*`, `id_ed25519*`, `id_ecdsa*`, `id_dsa*`).
- **Registry and database credentials** — `auth.json` (composer tokens), `.npmrc` (npm tokens),
  `.netrc`, `.pgpass`, `.my.cnf`, `.git-credentials`. These belong together: `auth.json` was on the
  *propose* list in an earlier draft while its direct npm equivalent `.npmrc` was banned, which is
  incoherent — both are registry tokens.
- **Cloud credentials** — `*service-account*.json`, `*credentials*.json`.
- **Machine state that a second writer corrupts** — `*.sqlite`, `*.sqlite3`, `*.db`,
  `terraform.tfstate`. Duplicating these is not just leaky, it is actively destructive: two worktrees
  writing copies of one state file diverge and the original loses.

Secrets belong in a copied `.env`, never in the committed profile
([ADR-008](../docs/01-decisions.md#adr-008)).

## Layer 3: hints, never conclusions

`detection.json`'s `runtimeHints` block lists **where to look** and **what shape to look for** — port
variables in compose files and `.env`, database-ish and tenancy-ish variable names, service names. It
deliberately contains no rule that concludes anything.

The tenancy family (`INSTALLATION*`, `TENANT*`, `SITE*`, `CLIENT*`, `ORG*`, `ACCOUNT*`, `WORKSPACE*`,
`SCHEMA*`) is a naming **convention**, not a list of variables seen in some particular repository —
that distinction is the difference between a general engine and one carrying another project's
identity. A repo whose selector is spelled something the family misses is exactly why the developer is
asked rather than told: the pattern saves typing, it does not reach a conclusion.

Everything found there is offered as a **hint beside a question**, never as a pre-filled default. A
`runtime` block the developer did not explicitly confirm must not be written, and **"no runtime
isolation" is always an offered outcome** — a profile with no `runtime` block is valid and means touch
nothing.

The reason is [ADR-006](../docs/01-decisions.md#adr-006), and it is worth restating in full because it
is the rule most tempting to shave: nothing in a repository states which variable
selects a tenant database, or that a test database gets dropped wholesale by an env var. A wrong guess here
does not produce a broken worktree. It corrupts a colleague's data.

### Three more things detection reports for layer 3 — still facts, not conclusions

- **`compose`** — for each compose file, what names its project: an explicit top-level `name:`
  (every worktree then drives the *same* containers, rebuilt with whichever checkout's bind mounts ran
  last), `COMPOSE_PROJECT_NAME` set in `.env` (asked whether it is set, never for its value), or the
  directory (each worktree starts its own stack, and every published host port collides with the main
  checkout's). The count of published host ports goes with it. Which of those is wanted is a question.
- **`assign`** — an inline `NAME=value` for a variable already offered as a port or database hint,
  found in the repo's own commands: agent guides, README, task runners, manifest scripts. That sets the
  variable in the **process** environment, which beats every env file the plugin writes into, so a
  session following those instructions inside a worktree runs against the shared state. The agent
  note calibration proposes must say not to copy the prefix.
- **`ignore`** — whether each path the plugin itself creates inside a checkout
  (`.claude/worktrees/`, `.claude/worktree-no-runtime`) is gitignored. An untracked one is work to the
  teardown guard, so the worktree it sits in is never torn down.

## Drift, and what the profile records about itself

The profile carries an `evidence` block: the `detectionVersion` it was written against, the sorted list
of dependency markers found, the marker that produced `shell`, and — per dependency — a `cksum` of the
lockfile. Nothing acts on it. It exists so that later, cheap, deterministic shell can compare and
**say** that the profile was calibrated against a different tree than the one in front of it, instead
of applying stale advice in silence.

The comparison is a checksum and a string compare — no re-detection, no judgement, no model. That is
what keeps it legal inside a hook ([ADR-002](../docs/01-decisions.md#adr-002)), and it warns without
ever blocking ([ADR-003](../docs/01-decisions.md#adr-003)).

Its limits, stated honestly:

- A lockfile can churn without changing anything that matters, producing a warning nobody needed.
- A hazard can appear in `composer.json`'s `scripts` section **without touching the lockfile at all**,
  producing no warning exactly where one would matter most. The marker list catches a new *ecosystem*,
  not a new *script*.

So drift detection is a net for the common case (someone added a dependency and didn't re-calibrate),
not a guarantee. It is cheap enough to be worth having and must not be described as more than it is.
