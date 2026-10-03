#!/usr/bin/env bash
#
# Exercises hooks/scripts/detect.sh against scratch repositories built under /tmp.
#
# This suite is the reason detect.sh exists as a script rather than as instructions in the
# calibrate skill's prose. Calibration owes a sane profile on several dissimilar repos and
# for "a second run changes nothing", and neither is checkable when detection is a model
# reading a table — it would be a different judgement every session. Here they are assertions.
#
#   tests/test_detect.sh                          # every backend on this machine
#   nix shell nixpkgs#jq -c tests/test_detect.sh  # ...including jq
#
# Both JSON backends are exercised, for the same reason test_lib.sh does it: detect.sh reads
# everything through the dual-backend layer, and the two implementations have genuinely
# diverged twice in this library's history.
#
# Probes are skipped (WT_SKIP_PROBES). They are the one part of detection whose answer depends
# on the HOST rather than on the repository, so they are the one part that cannot be asserted
# deterministically — a machine with composer installed and a machine without would disagree.
#
# Deliberately not `set -e`: one failed assertion must not hide the rest.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DETECT="$HERE/../hooks/scripts/detect.sh"
TABLE="$HERE/../reference/detection.json"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 backends_run=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export WT_SKIP_PROBES=1 WT_DETECTION_JSON="$TABLE"

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s] %s\n      expected: %q\n      actual:   %q\n' "$BACKEND" "$1" "$2" "$3" >&2
  fi
}

has() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL [%s] %s\n      expected to contain: %q\n' "$BACKEND" "$1" "$2" >&2 ;;
  esac
}

hasnt() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) fail=$((fail + 1))
            printf 'FAIL [%s] %s\n      must NOT contain: %q\n' "$BACKEND" "$1" "$2" >&2 ;;
    *) pass=$((pass + 1)) ;;
  esac
}

# A scratch git repository. $1 = name, rest = files to create empty.
#
# Namespaced by backend so the second pass builds a CLEAN repo rather than re-initialising the
# first pass's. Sharing them would make the two passes non-independent — one backend's leftover
# state could mask a divergence in the other, which is the one thing this suite exists to catch.
mkrepo() {
  local name=$1 d f
  shift
  d="$TMP/$BACKEND/$name"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  for f in "$@"; do
    mkdir -p "$(dirname "$d/$f")"
    : >"$d/$f"
  done
  printf '.env\n.env.local\n.venv/\nnode_modules/\nvendor/\n' >"$d/.gitignore"
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" commit -qm init >/dev/null 2>&1
  printf '%s' "$d"
}

commit_all() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm more >/dev/null 2>&1 || true; }

# All output, tabs turned into a separator that is easy to assert on.
det() { bash "$DETECT" "$1" 2>/dev/null | tr '\t' '|'; }

# One field of one record: $2 = label, $3 = field number (1-based), $4 = which record (default 1).
# The index is explicit because several fixtures emit more than one record per label, and a
# helper that silently took the first would let an assertion read dep 0 while appearing to
# assert about dep 1.
field() { printf '%s\n' "$1" | grep "^$2|" | sed -n "${4:-1}p" | cut -d'|' -f"$3"; }

run_suite() {
  local out r first

  # --- a plain npm application -------------------------------------------------
  r=$(mkrepo npmapp package.json package-lock.json .env)
  printf '{"name":"x","scripts":{"build":"vite build"}}' >"$r/package.json"
  commit_all "$r"
  out=$(det "$r")
  eq 'npm: node_modules is the target directory' 'node_modules' "$(field "$out" dep 3)"
  eq 'npm: keyed on package-lock.json'           'package-lock.json' "$(field "$out" dep 4)"
  eq 'npm: hardlink, because npm writes real bytes per project' 'hardlink' "$(field "$out" dep 5)"
  eq 'npm: the install command is npm ci'        'npm ci' "$(field "$out" dep 6)"
  eq 'npm: no toolchain wrapper is detected'     '' "$(field "$out" shell 2)"
  has 'npm: a gitignored .env is offered for .worktreeinclude' 'config|.env' "$out"
  hasnt 'npm: a build script is not a lifecycle hazard' 'hazard|' "$out"

  # --- a pnpm workspace --------------------------------------------------------
  # The one case install-not-hardlink exists for: pnpm has its own content-addressable store, so the tree
  # must be INSTALLED, never hardlinked.
  r=$(mkrepo pnpmws package.json pnpm-lock.yaml pnpm-workspace.yaml)
  out=$(det "$r")
  eq 'pnpm: install, never hardlink' 'install' "$(field "$out" dep 5)"
  eq 'pnpm: --frozen-lockfile'  'pnpm install --frozen-lockfile' "$(field "$out" dep 6)"
  has 'pnpm: the reason names the content-addressable store' 'content-addresses' "$out"

  # --- a Python uv project -----------------------------------------------------
  r=$(mkrepo uvproj pyproject.toml uv.lock)
  out=$(det "$r")
  eq 'uv: .venv is the target directory' '.venv' "$(field "$out" dep 3)"
  eq 'uv: install, because uv has its own cache' 'install' "$(field "$out" dep 5)"
  eq 'uv: uv sync --frozen' 'uv sync --frozen' "$(field "$out" dep 6)"

  # --- a virtualenv is never hardlinked -----------------------------------------
  # Measured: a hardlinked venv's shebangs, activate scripts and editable-install mappings name the
  # MAIN checkout, so pip installs into main's venv and imports load main's source. Even an
  # in-project .venv that exists must be installed.
  r=$(mkrepo poetryvenv pyproject.toml poetry.lock .venv/pyvenv.cfg)
  out=$(det "$r")
  eq 'poetry: an existing in-project .venv is installed, not hardlinked' 'install' "$(field "$out" dep 5)"
  # poetry seeds the venv (interpreter, pip and pip's .dist-info) before resolving, so no generic file
  # test fails on what a failed install leaves; the rule says so instead of proposing one.
  eq 'poetry: no default verify, even with an in-project .venv' '' "$(field "$out" dep 7)"
  has 'poetry: and the developer is told why' 'depNote|0|no default verify: poetry creates the venv' "$out"
  hasnt 'poetry: and nothing is downgraded' 'depDowngrade' "$out"
  r=$(mkrepo pipenvvenv Pipfile Pipfile.lock .venv/pyvenv.cfg)
  out=$(det "$r")
  eq 'pipenv: an existing in-project .venv is installed, not hardlinked' 'install' "$(field "$out" dep 5)"
  eq 'pipenv: no default verify, for the same reason' '' "$(field "$out" dep 7)"
  has 'pipenv: and the developer is told why' 'depNote|0|no default verify: pipenv creates the venv' "$out"
  # No in-project venv: poetry puts it under its own cache, so a .venv check would fail in every
  # worktree. The default is withheld and the developer is told why, rather than handed a check
  # that cannot pass.
  r=$(mkrepo poetrynovenv pyproject.toml poetry.lock)
  out=$(det "$r")
  eq 'poetry: no .venv present -> still install' 'install' "$(field "$out" dep 5)"
  hasnt 'poetry: and install is not announced as a downgrade' 'depDowngrade' "$out"
  eq 'poetry: no .venv present -> no default verify' '' "$(field "$out" dep 7)"
  has 'poetry: and says the verify must come from the developer' 'depNote|0|no default verify' "$out"
  # A nested poetry project with an installed, gitignored .venv is proposed — still with no verify.
  r=$(mkrepo nestedpoetry composer.lock tools/py/pyproject.toml tools/py/poetry.lock)
  mkdir -p "$r/tools/py/.venv/bin"
  out=$(det "$r")
  has 'nested poetry: proposed as its own entry' 'dep|1|tools/py/.venv|tools/py/poetry.lock|install|' "$out"
  eq 'nested poetry: with an empty verify field' '' "$(field "$out" dep 7 2)"
  has 'nested poetry: and the reason there is none' 'depNote|1|no default verify: poetry creates the venv' "$out"
  has 'nested poetry: and the nested note beside it' 'depNote|1|nested: tools/py' "$out"

  # The whole table, one row per rule as dir|strategy|verify|noVerify. The row count is asserted
  # first: an empty read would pass every "no row matches" check below.
  local rules
  rules=$(
    # shellcheck disable=SC1091
    . "$HERE/../hooks/scripts/lib.sh"
    wt_json_records deps dir strategy verify noVerify <"$TABLE" | tr "$WT_RS" '\n' | tr "$WT_US" '|'
  )
  eq 'table: every rule is read' "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["deps"]))' "$TABLE")" \
    "$(printf '%s\n' "$rules" | grep -c '|')"
  # A rule added later that proposes hardlink for a venv fails here.
  eq 'table: no rule proposes hardlink for a .venv' '' \
    "$(printf '%s\n' "$rules" | grep -E '^([^|]*/)?\.?venv\|hardlink\|' || true)"

  # --- a default verify for every dependency directory -------------------------
  # Exact values, run from the worktree root in the host shell. Each names a file the tool's own
  # install writes (checked against real installs): a check that passes on an empty directory, or
  # with no directory at all, cannot tell bootstrap anything.
  vfy() {  # $1 = repo name, $2 = expected dir, $3 = expected verify, rest = files
    local name=$1 dir=$2 want=$3 d o
    shift 3
    d=$(mkrepo "$name" "$@")
    o=$(det "$d")
    eq "verify: $name targets $dir" "$dir" "$(field "$o" dep 3)"
    eq "verify: $name" "$want" "$(field "$o" dep 7)"
  }
  vfy v_composer vendor        'test -r vendor/autoload.php'            composer.lock
  vfy v_pnpm     node_modules  'test -f node_modules/.modules.yaml'     package.json pnpm-lock.yaml
  vfy v_npm      node_modules  'test -f node_modules/.package-lock.json' package.json package-lock.json
  vfy v_berry    .yarn/cache   'test -f .yarn/install-state.gz'         package.json yarn.lock .yarnrc.yml
  vfy v_yarn1    node_modules  'test -f node_modules/.yarn-integrity'   package.json yarn.lock
  vfy v_bun      node_modules  ''                                       package.json bun.lock
  vfy v_bunb     node_modules  ''                                       package.json bun.lockb
  # shellcheck disable=SC2016  # the $1 belongs to the verify command under test
  vfy v_uv       .venv         'set -- .venv/lib/python*/site-packages/*.dist-info; test -d "$1"' \
                                                                        pyproject.toml uv.lock
  vfy v_bundle   vendor/bundle 'test -d vendor/bundle/ruby'             Gemfile Gemfile.lock vendor/bundle/ruby/3.4.0/x
  vfy v_mix      deps          ''                                       mix.exs mix.lock
  # Where the table has no verify, the developer is told why rather than handed a check that passes
  # on the tree a failed install leaves.
  has 'verify: bun says why it has none' 'depNote|0|no default verify: bun' "$(det "$TMP/$BACKEND/v_bun")"
  has 'verify: mix says why it has none' 'depNote|0|no default verify: mix deps.get' "$(det "$TMP/$BACKEND/v_mix")"
  hasnt 'verify: a rule with a default does not say it has none' 'no default verify' "$(det "$TMP/$BACKEND/v_uv")"
  # cargo and go keep their dependencies in a machine-wide cache; there is no directory to check.
  vfy v_cargo    ''            ''                                       Cargo.toml Cargo.lock
  vfy v_go       ''            ''                                       go.mod go.sum
  # Bundler's vendor/bundle is opt-in like poetry's .venv: absent, the check is withheld, and the
  # hardlink still degrades to install as before.
  r=$(mkrepo v_nobundle Gemfile Gemfile.lock)
  out=$(det "$r")
  eq 'verify: bundler without vendor/bundle gets no default verify' '' "$(field "$out" dep 7)"
  has 'verify: and the hardlink still degrades' 'depDowngrade|0|hardlink|install' "$out"
  # With vendor/bundle present nothing is withheld: hardlink stays, and the verify is proposed.
  r=$(mkrepo v_bundlekept Gemfile Gemfile.lock vendor/bundle/ruby/3.4.0/x)
  out=$(det "$r")
  eq 'verify: bundler with vendor/bundle keeps hardlink' 'hardlink' "$(field "$out" dep 5)"
  hasnt 'verify: and nothing is downgraded' 'depDowngrade' "$out"
  hasnt 'verify: nor its verify withheld' 'no default verify' "$out"
  eq 'table: every rule that manages a directory carries a verify or says why it has none' '' \
    "$(printf '%s\n' "$rules" | grep -E '^[^|]+\|[^|]+\|\|$' || true)"
  eq 'table: and never both' '' "$(printf '%s\n' "$rules" | grep -E '^[^|]*\|[^|]*\|[^|]+\|[^|]+$' || true)"

  # --- Yarn Berry is a different package manager wearing the same lockfile name --
  r=$(mkrepo berry package.json yarn.lock .yarnrc.yml)
  out=$(det "$r")
  eq 'yarn berry: the guarded rule wins on .yarnrc.yml' '.yarn/cache' "$(field "$out" dep 3)"
  eq 'yarn berry: --immutable, not the deprecated --frozen-lockfile' \
    'yarn install --immutable' "$(field "$out" dep 6)"
  r=$(mkrepo yarnclassic package.json yarn.lock)
  out=$(det "$r")
  eq 'yarn classic: falls through to the unguarded rule' 'node_modules' "$(field "$out" dep 3)"
  eq 'yarn classic: hardlink' 'hardlink' "$(field "$out" dep 5)"
  eq 'yarn classic: a verify that reads the installed tree' \
    'test -f node_modules/.yarn-integrity' "$(field "$out" dep 7)"

  # --- two live lockfiles for one directory ------------------------------------
  # Two entries for one directory would make bootstrap hardlink a tree and then reinstall
  # over it, so exactly one is kept and the other is announced rather than dropped silently.
  r=$(mkrepo twolocks package.json package-lock.json pnpm-lock.yaml)
  out=$(det "$r")
  eq 'two lockfiles: exactly one dep entry survives' 1 "$(printf '%s\n' "$out" | grep -c '^dep|')"
  eq 'two lockfiles: the earlier table rule wins' 'pnpm-lock.yaml' "$(field "$out" dep 4)"
  has 'two lockfiles: the loser is announced, not dropped silently' \
    'dropped|package-lock.json|node_modules' "$out"

  # --- the toolchain shell, in precedence order --------------------------------
  r=$(mkrepo nixflake uv.lock flake.nix shell.nix .envrc)
  out=$(det "$r")
  eq 'shell: a flake wins over shell.nix and .envrc' 'nix develop --command' "$(field "$out" shell 2)"
  eq 'shell: and takes its command as argv' 'argv' "$(field "$out" shellArgs 2)"
  r=$(mkrepo nixshell uv.lock shell.nix .envrc)
  out=$(det "$r")
  eq 'shell: shell.nix wins over .envrc' 'nix-shell --run' "$(field "$out" shell 2)"
  eq 'shell: and takes ONE string, which is not interchangeable with argv' \
    'string' "$(field "$out" shellArgs 2)"
  r=$(mkrepo direnvonly uv.lock .envrc)
  out=$(det "$r")
  eq 'shell: .envrc alone gives direnv' 'direnv exec .' "$(field "$out" shell 2)"
  r=$(mkrepo devconly uv.lock .devcontainer/devcontainer.json)
  out=$(det "$r")
  eq 'shell: a devcontainer yields no wrapper' '' "$(field "$out" shell 2)"
  has 'shell: and warns that installs would run on the host' 'shellWarn|' "$out"
  r=$(mkrepo bareshell uv.lock)
  out=$(det "$r")
  eq 'shell: nothing matched -> the host shell' '' "$(field "$out" shell 2)"
  # The empty marker alone proves nothing — it is also the initial value, so it would match if
  # the rules loop had yielded no records at all. The catch-all's REASON is the discriminator.
  has 'shell: reached via the catch-all rule, not a silent fallthrough' \
    'shellReason|no toolchain marker found' "$out"
  eq 'shell: and shellArgs still defaults to argv' 'argv' "$(field "$out" shellArgs 2)"

  # --- post-install hazards ----------------------------------------------------
  # The failure mode with no recovery: an install that succeeds and migrates the SHARED
  # development database.
  hz() {  # $1 = repo name, $2 = composer.json body
    local d
    d=$(mkrepo "$1" composer.lock composer.json)
    printf '%s' "$2" >"$d/composer.json"
    commit_all "$d"
    det "$d"
  }

  out=$(hz hz_postinstall '{"scripts":{"post-install-cmd":["doctrine:migrations:migrate"]}}')
  has 'hazard: a migration is escalated to refuse-and-ask' 'escalate|0|migration|refuse-and-ask' "$out"
  has 'hazard: and --no-scripts is added to the proposal'  '--no-scripts' "$(field "$out" dep 6)"

  # Probing only the best-known key is not enough: composer install fires several, and a
  # framework repo conventionally hangs its migration off post-autoload-dump.
  out=$(hz hz_autoload '{"scripts":{"post-autoload-dump":["@php artisan migrate --force"]}}')
  has 'hazard: post-autoload-dump is probed too' 'escalate|0|migration' "$out"
  out=$(hz hz_preinstall '{"scripts":{"pre-install-cmd":["rake db:migrate"]}}')
  has 'hazard: pre-install-cmd is probed too' 'escalate|0|migration' "$out"

  # Indirection: the probe returns a REFERENCE, and the migration is two hops away behind a
  # camelCase target that a case-sensitive pattern would miss.
  out=$(hz hz_chain '{"scripts":{"post-install-cmd":["@db"],"db":["@db:migrate"],"db:migrate":"Vendor\\Pkg\\Scripts::dbMigrate"}}')
  has 'hazard: the chain is followed through @references' 'hazardChain|0|' "$out"
  has 'hazard: and a camelCase target still matches (case-insensitive)' \
    'escalate|0|migration|refuse-and-ask' "$out"

  # "Found a migration" and "could not tell" are different findings. Almost every real
  # composer chain ends in a code callback, so conflating them would fire on nearly every
  # repository and the alarm would stop meaning anything.
  out=$(hz hz_unknown '{"scripts":{"post-install-cmd":["@cache"],"cache":"Vendor\\Pkg\\Scripts::cacheClear"}}')
  has 'hazard: an unfollowable trail is reported as unreadable' 'unreadable|0|migration|confirm' "$out"
  hasnt 'hazard: and NOT as a migration that was found' 'escalate|0|migration' "$out"

  # Running out of hop budget must count as unfollowable, or a repo need only nest one level
  # deeper than the limit to look clean.
  out=$(hz hz_deep '{"scripts":{"post-install-cmd":["@a"],"a":["@b"],"b":["@c"],"c":["@d"],"d":["@e"],"e":["@f"],"f":"rake db:migrate"}}')
  has 'hazard: exhausting the hop budget is unfollowable, not clean' 'unreadable|0|' "$out"
  has 'hazard: and the chain says where it stopped' 'unfollowed after' "$out"

  # An ordinary .json filename must not read as an unfollowable script path.
  out=$(hz hz_jsonfile '{"scripts":{"post-install-cmd":["cp config.json.dist config.json"]}}')
  hasnt 'hazard: a .json file is not an unfollowable trail' 'unreadable|' "$out"
  hasnt 'hazard: and nothing is escalated' 'escalate|' "$out"

  # No lifecycle scripts at all: nothing to neutralise, nothing to ask.
  out=$(hz hz_none '{"require":{"php":"^8.3"}}')
  hasnt 'hazard: a repo with no lifecycle scripts raises nothing' 'hazard|' "$out"
  eq 'hazard: and the install command is left alone' \
    'composer install --no-interaction --no-progress' "$(field "$out" dep 6)"

  # An npm lifecycle script is kept (a worktree needs the assets) but the cost is stated.
  r=$(mkrepo hz_npm package.json package-lock.json)
  printf '{"scripts":{"postinstall":"vite build"}}' >"$r/package.json"
  commit_all "$r"
  out=$(det "$r")
  has 'hazard: an asset-building postinstall is a note, not a neutralisation' \
    'hazard|0|npm-postinstall|note' "$out"
  eq 'hazard: and the install command keeps it' 'npm ci' "$(field "$out" dep 6)"

  # --- gitignored config -------------------------------------------------------
  # Only ACTUALLY gitignored files count: native .worktreeinclude copying applies the
  # gitignored-only rule, so a tracked file listed there does nothing.
  # `.env.local` is a candidate glob AND is committed here, so it exercises the check-ignore
  # gate in its negative direction — the direction .worktreeinclude depends on, since a tracked file
  # listed in .worktreeinclude is a silent no-op. An earlier fixture used a name no glob
  # matched, so the gate was never reached at all.
  r=$(mkrepo cfg uv.lock .env .env.local)
  printf '.env\n' >"$r/.gitignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm cfg >/dev/null 2>&1
  out=$(det "$r")
  has 'config: a gitignored candidate is proposed' 'config|.env' "$out"
  hasnt 'config: a TRACKED candidate is not proposed, even though a glob matches it' \
    'config|.env.local' "$out"
  # Credentials are never proposed, even when gitignored AND matching a candidate glob.
  #
  # Two things make this fixture fiddly, and both are the reason the earlier version of it was
  # vacuous. First, the name must match a configCandidates GLOB or the neverPropose filter is
  # never reached — `id_rsa` alone matches nothing, so it passed for the wrong reason.
  # `*.local.yml` IS a candidate glob, so `id_rsa.local.yml` matches both lists and genuinely
  # exercises the filter. Second, the files must stay UNTRACKED: `git check-ignore` does not
  # report a tracked file as ignored, so committing them would make every candidate vanish for
  # an unrelated reason.
  r=$(mkrepo creds uv.lock)
  printf 'ok.local.yml\nid_rsa.local.yml\n' >"$r/.gitignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm ignore >/dev/null 2>&1
  : >"$r/ok.local.yml"
  : >"$r/id_rsa.local.yml"
  out=$(det "$r")
  has   'config: an ordinary gitignored local config file is proposed' 'config|ok.local.yml' "$out"
  hasnt 'config: an SSH-key-shaped name is refused by neverPropose' 'config|id_rsa.local.yml' "$out"

  # --- layer 3 is hints only ---------------------------------------------------
  # Nothing here may conclude anything. A wrong guess does not break a worktree; it
  # corrupts a colleague's data.
  r=$(mkrepo hints uv.lock docker-compose.yml .env)
  printf 'services:\n  db:\n    image: mysql\n  cache:\n    image: redis\n' >"$r/docker-compose.yml"
  printf 'APP_PORT=8080\nDATABASE_URL=mysql://localhost/app\n' >"$r/.env"
  commit_all "$r"
  out=$(det "$r")
  has 'hints: a port variable is offered as a hint' 'hint|port|APP_PORT' "$out"
  has 'hints: a database variable is offered as a hint' 'hint|db|DATABASE_URL' "$out"
  has 'hints: compose service names are offered as hints' 'hint|service|db' "$out"
  eq 'hints: NOTHING is emitted as a runtime decision' 0 "$(printf '%s\n' "$out" | grep -c '^runtime|')"

  # --- an unrecognised repository ----------------------------------------------
  # No deps is a valid outcome, not a failure.
  r=$(mkrepo mystery README.md Makefile)
  out=$(det "$r")
  eq 'unknown repo: no dep records' 0 "$(printf '%s\n' "$out" | grep -c '^dep|')"
  has 'unknown repo: and it says so rather than failing' 'no dependency lockfile recognised' "$out"
  bash "$DETECT" "$r" >/dev/null 2>&1
  eq 'unknown repo: exit status is still success' 0 $?

  # --- failure modes -----------------------------------------------------------
  bash "$DETECT" "$TMP/does-not-exist" >/dev/null 2>&1
  eq 'a missing directory exits non-zero' 1 $?
  out=$(WT_DETECTION_JSON="$TMP/no-table.json" bash "$DETECT" "$TMP/$BACKEND/mystery" 2>&1 >/dev/null)
  has 'a missing detection table says so' 'cannot read the detection table' "$out"

  # --- a directory that is not a git repository --------------------------------
  # Dependencies and the shell are still proposed; only the gitignore-dependent part degrades.
  mkdir -p "$TMP/$BACKEND/notgit"
  : >"$TMP/$BACKEND/notgit/uv.lock"
  : >"$TMP/$BACKEND/notgit/.env"
  out=$(det "$TMP/$BACKEND/notgit")
  eq 'not a repo: dependencies are still detected' '.venv' "$(field "$out" dep 3)"
  has 'not a repo: and it says why config cannot be confirmed' 'not a git repository' "$out"
  hasnt 'not a repo: so no config is proposed' 'config|' "$out"

  # --- hostile filenames -------------------------------------------------------
  # A repository is not trusted input. None of these may split a record or expand a glob.
  r=$(mkrepo hostile uv.lock)
  : >"$r/a b.yml"
  : >"$r/-rf"
  : >"$r/star*name" 2>/dev/null || true
  commit_all "$r"
  out=$(det "$r")
  eq 'hostile filenames: detection still produces one dep' 1 "$(printf '%s\n' "$out" | grep -c '^dep|')"
  eq 'hostile filenames: and every record has its label in field 1' 0 \
    "$(printf '%s\n' "$out" | grep -cv '^[a-zA-Z]')"

  # --- NESTED PROJECTS WITH THEIR OWN LOCKFILE ---------------------------------
  # Root markers alone missed a nested project that keeps its own lockfile, which a root install
  # never populates (a tool-per-directory composer layout). Found through git, proposed only when
  # its tree is installed in this checkout and gitignored.
  r=$(mkrepo nested composer.lock composer.json tools/lint/composer.lock tools/lint/composer.json \
        tests/fixtures/app/composer.lock tests/fixtures/app/composer.json \
        packages/web/package.json package.json pnpm-lock.yaml pnpm-workspace.yaml)
  printf '{"scripts":{"post-install-cmd":["@db"],"db":"doctrine:migrations:migrate"}}' >"$r/tools/lint/composer.json"
  mkdir -p "$r/tools/lint/vendor" "$r/untracked/vendor" "$r/node_modules/dep"
  : >"$r/tools/lint/vendor/autoload.php"
  : >"$r/node_modules/dep/package-lock.json"           # inside an ignored tree
  commit_all "$r"
  : >"$r/untracked/composer.lock"                      # created AFTER the commit: never tracked
  out=$(det "$r")
  has 'nested: the nested project is proposed as its own entry' \
    'dep|2|tools/lint/vendor|tools/lint/composer.lock|hardlink|' "$out"
  has 'nested: its install runs from its own directory' \
    "|cd 'tools/lint' && composer install --no-interaction --no-progress" "$out"
  has 'nested: its verify does too' "|cd 'tools/lint' && test -r vendor/autoload.php" "$out"
  has 'nested: and says why the root install does not cover it' 'depNote|2|nested: tools/lint' "$out"
  has 'nested: its OWN manifest is probed for hazards, and neutralised' 'hazard|2|composer-post-install|neutralise|--no-scripts' "$out"
  has 'nested: and its migration is escalated like the root one would be' 'escalate|2|' "$out"
  has 'nested: a lockfile with no installed tree (a fixture) is dropped, saying so' \
    'dropped|tests/fixtures/app/composer.lock|tests/fixtures/app/vendor|a nested lockfile, but' "$out"
  hasnt 'nested: and is not proposed' 'dep|3|tests/fixtures' "$out"
  hasnt 'nested: an untracked lockfile is never considered' 'untracked/' "$out"
  hasnt 'nested: nor one inside an ignored tree' 'node_modules/dep' "$out"
  hasnt 'nested: a workspace member without its own lockfile is the root install'"'"'s business' \
    'packages/web' "$out"
  eq 'nested: exactly three entries — two roots and one nested project' 3 \
    "$(printf '%s\n' "$out" | grep -c '^dep|')"
  eq 'nested: detection is still idempotent' "$out" "$(det "$r")"

  # A nested tree that is COMMITTED needs nothing from the plugin.
  r=$(mkrepo nestedcommitted composer.lock sub/composer.lock sub/composer.json sub/vendor/autoload.php)
  printf '!sub/vendor/\n' >>"$r/.gitignore"
  commit_all "$r"
  out=$(det "$r")
  has 'nested: a committed nested vendor is dropped as not gitignored' \
    'dropped|sub/composer.lock|sub/vendor|a nested lockfile whose sub/vendor is not gitignored' "$out"

  # A directory name outside the conservative set is never put in a command.
  r=$(mkrepo nestedodd composer.lock "we ird/composer.lock")
  mkdir -p "$r/we ird/vendor"
  out=$(det "$r")
  has 'nested: an odd directory name is warned about, not proposed' 'warn|the nested lockfile directory "we ird"' "$out"

  # --- COMPOSE: which project a worktree's stack would be ------------------------
  r=$(mkrepo composedir composer.lock)
  # shellcheck disable=SC2016  # the ${...} is compose syntax under test, not shell
  printf 'services:\n  app:\n    ports:\n      - "127.0.0.1:${APP_PORT:-8080}:8080"\n      - "5173:5173"\n  db:\n    image: mysql\n' >"$r/docker-compose.yml"
  commit_all "$r"
  out=$(det "$r")
  has 'compose: no name anywhere means one stack per directory, with its published ports counted' \
    'compose|docker-compose.yml|directory|2' "$out"
  printf 'name: shared-stack\n' | cat - "$r/docker-compose.yml" >"$r/c.tmp" && mv "$r/c.tmp" "$r/docker-compose.yml"
  out=$(det "$r")
  has 'compose: a top-level name means every worktree drives the SAME stack' \
    'compose|docker-compose.yml|explicit:shared-stack|2' "$out"
  r=$(mkrepo composeenv composer.lock)
  printf 'services:\n  app:\n    image: x\n' >"$r/compose.yaml"
  printf 'COMPOSE_PROJECT_NAME=secretly-named\n' >"$r/.env"
  out=$(det "$r")
  has 'compose: COMPOSE_PROJECT_NAME in .env is reported as set' 'compose|compose.yaml|env|0' "$out"
  hasnt 'compose: without reading its value' 'secretly-named' "$out"

  # Only a `ports:` block publishes; an environment entry ending in `:<digits>` does not. Long
  # syntax counts `published:`; a bare container port gets a random host port and cannot collide.
  r=$(mkrepo composeports composer.lock)
  printf 'services:\n  app:\n    environment:\n      - REDIS_URL=redis://cache:6379\n    ports:\n      - "3000"\n      - target: 80\n        published: "8080"\n  db:\n    ports:\n      - 3306:3306\n' >"$r/compose.yml"
  out=$(det "$r")
  has 'compose: environment entries are not ports; long syntax and bare container ports are right' \
    'compose|compose.yml|directory|2' "$out"
  # A quoted name is the name; an interpolated one is controllable from the environment.
  printf 'name: "quoted"\nservices:\n  a:\n    image: x\n' >"$r/compose.yml"
  has 'compose: a quoted name loses its quotes' 'compose|compose.yml|explicit:quoted|0' "$(det "$r")"
  # shellcheck disable=SC2016  # compose interpolation under test
  printf 'name: ${STACK:-app}\nservices:\n  a:\n    image: x\n' >"$r/compose.yml"
  has 'compose: an interpolated name is env-controlled, not fixed' 'compose|compose.yml|env|0' "$(det "$r")"
  # Compose never reads .env.local, so a name set only there does not name the project.
  printf 'services:\n  a:\n    image: x\n' >"$r/compose.yml"
  printf 'COMPOSE_PROJECT_NAME=x\n' >"$r/.env.local"
  has 'compose: .env.local is not where compose looks' 'compose|compose.yml|directory|0' "$(det "$r")"

  # A nested JS tree in a repo that declares a workspace is the root install's to populate.
  r=$(mkrepo nestedws package.json pnpm-lock.yaml pnpm-workspace.yaml packages/a/package.json packages/a/package-lock.json)
  mkdir -p "$r/packages/a/node_modules"
  out=$(det "$r")
  has 'nested: a workspace member with a stray lockfile is dropped, saying why' \
    'dropped|packages/a/package-lock.json|packages/a/node_modules|the repository declares a JS workspace' "$out"
  eq 'nested: and only the root entry is proposed' 1 "$(printf '%s\n' "$out" | grep -c '^dep|')"

  # A directory starting with `-` would be read by `cd` as an option.
  r=$(mkrepo nesteddash composer.lock -legacy/composer.lock)
  mkdir -p "$r/-legacy/vendor"
  has 'nested: a leading-dash directory is warned about, not put in a command' \
    'warn|the nested lockfile directory "-legacy"' "$(det "$r")"

  # A tool whose ONLY lockfile is nested is still probed. A stub on PATH stands in for the tool.
  r=$(mkrepo nestedprobe tools/x/composer.lock tools/x/composer.json)
  mkdir -p "$r/tools/x/vendor" "$TMP/$BACKEND/stubbin"
  printf '#!/bin/sh\necho "Composer version 9.9.9"\n' >"$TMP/$BACKEND/stubbin/composer"
  chmod +x "$TMP/$BACKEND/stubbin/composer"
  out=$(PATH="$TMP/$BACKEND/stubbin:$PATH" WT_SKIP_PROBES='' bash "$DETECT" "$r" 2>/dev/null | tr '\t' '|')
  has 'nested: a nested-only tool is still probed' 'probe|composer|ok|Composer version 9.9.9' "$out"

  # --- INLINE ASSIGNMENTS that would beat every env file ------------------------
  r=$(mkrepo assigns package.json package-lock.json .env)
  printf 'TENANT_ID=local\n' >"$r/.env"
  # shellcheck disable=SC2016  # the backticks are markdown under test, not command substitution
  printf '# Dev\n\nRun `TENANT_ID=acme npm run migrate` first.\nAlso OTHER_THING=1 npm test\n' >"$r/README.md"
  commit_all "$r"
  out=$(det "$r")
  # shellcheck disable=SC2016  # same markdown backticks
  has 'assign: an inline NAME=value for a hinted variable is reported, with count and first line' \
    'assign|TENANT_ID|README.md|1|3:Run `TENANT_ID=acme npm run migrate` first.' "$out"
  hasnt 'assign: a variable that is not a hint is not' 'assign|OTHER_THING' "$out"
  hasnt 'assign: a dotenv file is not a source of inline assignments' 'assign|TENANT_ID|.env|' "$out"

  # --- HOW THE APP STARTS: start commands, with any port they pin -------------
  # A port nothing reads isolates nothing; these records show setup each start command and the
  # port literal or flag in it, so a hardcoded port is visible before runtime.port is written.
  r=$(mkrepo starts package.json package-lock.json composer.json composer.lock)
  printf '{"scripts":{"dev":"vite --port 5173","start":"node server.js","build":"vite build"}}' >"$r/package.json"
  printf '{"scripts":{"serve":["php -S localhost:8000 -t public"]}}' >"$r/composer.json"
  printf 'web: bundle exec rails s -p 3000\n# a comment: not a process\nworker: bin/jobs' >"$r/Procfile"
  # shellcheck disable=SC2016  # markdown backticks under test
  printf 'Run `symfony serve --port=8123 -d` first.\n\n    python manage.py runserver 0.0.0.0:8001\nnpm run dev\nvite build\n' >"$r/README.md"
  printf 'up:\n\tPORT=4000 uvicorn app:main --reload\n' >"$r/Makefile"
  commit_all "$r"
  out=$(det "$r")
  has 'start: a manifest dev script, with its port flag' 'start|package.json|scripts.dev|--port 5173|vite --port 5173' "$out"
  has 'start: a script with no port in it has an empty port field' 'start|package.json|scripts.start||node server.js' "$out"
  hasnt 'start: a script not named as a start script is not one' 'scripts.build' "$out"
  has 'start: a composer script array, with the host:port it binds' \
    'start|composer.json|scripts.serve|-S localhost:8000|["php -S localhost:8000 -t public"]' "$out"
  has 'start: every Procfile process' 'start|Procfile|web|-p 3000|bundle exec rails s -p 3000' "$out"
  has 'start: including the last line with no newline' 'start|Procfile|worker||bin/jobs' "$out"
  hasnt 'start: a Procfile comment is not a process' 'start|Procfile|# a comment' "$out"
  # shellcheck disable=SC2016  # markdown backticks under test
  has 'start: a documented server command, with its flag' \
    'start|README.md|line 1|--port=8123|Run `symfony serve --port=8123 -d` first.' "$out"
  has 'start: a runserver address is a port' 'start|README.md|line 3|runserver 0.0.0.0:8001|python manage.py runserver 0.0.0.0:8001' "$out"
  has 'start: a package-manager dev script named in docs' 'start|README.md|line 4||npm run dev' "$out"
  hasnt 'start: a build is not a server' 'vite build' "$out"
  has 'start: an inline PORT= is the port it pins' 'start|Makefile|line 2|PORT=4000|PORT=4000 uvicorn app:main --reload' "$out"
  # The per-file cap keeps a long README from burying the rest.
  r=$(mkrepo startcap composer.lock)
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do printf 'npm start\n' >>"$r/README.md"; done
  commit_all "$r"
  eq 'start: at most startLinesPerFile lines per file' 10 "$(det "$r" | grep -c '^start|README.md|')"

  # --- EVERY ENVIRONMENT the repo runs in --------------------------------------
  # Isolating development and leaving test or e2e shared is the profile that looks right; each
  # environment the repo names is reported so setup has to answer for it.
  r=$(mkrepo envs composer.lock .env .env.local .env.test .env.test.local .env.e2e.local .env.example .env.prod.dist)
  printf '.env*\n!.env.test\n!.env.example\n!.env.prod.dist\nnode_modules/\n' >"$r/.gitignore"
  mkdir -p "$r/e2e" "$r/node_modules/x"
  printf '<phpunit><php><server name="APP_ENV" value="test" force="true"/></php></phpunit>\n' >"$r/phpunit.xml.dist"
  printf 'export default { webServer: { command: "APP_ENV=e2e php -S localhost:9000" } }\n' >"$r/e2e/playwright.config.ts"
  printf '[pytest]\nDJANGO_SETTINGS_MODULE = proj.settings.ci\n' >"$r/pytest.ini"
  printf 'test:\n\tbin/console --env=test cache:clear\n\tdocker run --env=FOO=bar img\n\tRAILS_ENV="staging" rake\n' >"$r/Makefile"
  printf 'APP_ENV=vendored\n' >"$r/node_modules/x/phpunit.xml"
  commit_all "$r"
  git -C "$r" add -f node_modules/x/phpunit.xml >/dev/null 2>&1
  git -C "$r" commit -qm vendored >/dev/null 2>&1
  out=$(det "$r")
  has 'env: a .env.<name> file names an environment' 'env|test|.env.test|file' "$out"
  has 'env: so does a .env.<name>.local, under its own name' 'env|e2e|.env.e2e.local|file' "$out"
  hasnt 'env: .env.local is an overlay, not an environment' 'env|local|' "$out"
  hasnt 'env: an example file is not an environment' 'env|example|' "$out"
  hasnt 'env: nor a .dist one' 'env|prod|' "$out"
  has 'env: a phpunit server variable' 'env|test|phpunit.xml.dist|APP_ENV' "$out"
  has 'env: a selector set inside a nested test config' 'env|e2e|e2e/playwright.config.ts|APP_ENV' "$out"
  has 'env: an ini assignment with spaces round the =' 'env|proj.settings.ci|pytest.ini|DJANGO_SETTINGS_MODULE' "$out"
  has 'env: a --env= flag' 'env|test|Makefile|--env' "$out"
  has 'env: a quoted value loses its quote' 'env|staging|Makefile|RAILS_ENV' "$out"
  hasnt 'env: docker --env=NAME=value passes a variable, not an environment' 'env|FOO|' "$out"
  hasnt 'env: vendored files are not the repo speaking' 'vendored' "$out"
  has 'testConfig: a nested e2e config is found' 'testConfig|e2e/playwright.config.ts' "$out"
  has 'testConfig: and a root one' 'testConfig|phpunit.xml.dist' "$out"
  hasnt 'testConfig: but never under node_modules' 'testConfig|node_modules/' "$out"
  eq 'env: records come out sorted, so two runs agree' \
    "$(printf '%s\n' "$out" | grep '^env|' | LC_ALL=C sort -t'|' -k2,2 -k3,3 -k4,4)" "$(printf '%s\n' "$out" | grep '^env|')"

  # --- THE PLUGIN'S OWN PATHS must be gitignored --------------------------------
  r=$(mkrepo ignores composer.lock)
  out=$(det "$r")
  has 'ignore: an unignored worktrees directory is reported missing' 'ignore|.claude/worktrees/|missing' "$out"
  has 'ignore: and so is the opt-out marker' 'ignore|.claude/worktree-no-runtime|missing' "$out"
  printf '.claude/worktrees/\n.claude/worktree-no-runtime\n' >>"$r/.gitignore"
  out=$(det "$r")
  has 'ignore: once ignored, both are ok' 'ignore|.claude/worktrees/|ok' "$out"
  has 'ignore: including the marker' 'ignore|.claude/worktree-no-runtime|ok' "$out"

  # --- IDEMPOTENCE -------------------------------------------------------------
  # The acceptance criterion "a second run changes nothing" — an assertion rather than a
  # promise. This is the property that a model-driven detector could not have.
  r=$(mkrepo idem composer.lock composer.json package.json pnpm-lock.yaml flake.nix .env)
  printf '{"scripts":{"post-install-cmd":["@db"],"db":"doctrine:migrations:migrate"}}' >"$r/composer.json"
  printf '{"scripts":{"postinstall":"vite build"}}' >"$r/package.json"
  commit_all "$r"
  first=$(det "$r")
  eq 'idempotent: a second run is byte-identical to the first' "$first" "$(det "$r")"
  eq 'idempotent: and so is a third'                          "$first" "$(det "$r")"
  # And it is a real proposal, not an empty one that trivially matches itself.
  out=$(det "$r")
  eq 'idempotent: on a repo with two ecosystems' 2 "$(printf '%s\n' "$out" | grep -c '^dep|')"
  has 'idempotent: nix detected' 'shell|nix develop --command' "$out"
  has 'idempotent: composer neutralised' '--no-scripts' "$out"
  has 'idempotent: migration escalated' 'escalate|' "$out"
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_detect.sh\n' >&2
      fail=$((fail + 1))
      continue
    fi
    unset WT_JSON_BACKEND
  else
    if ! command -v python3 >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: python3 not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: python3 not on PATH, so backend parity is untested.\n' >&2
      fail=$((fail + 1))
      continue
    fi
    export WT_JSON_BACKEND=python3
  fi
  printf -- '--- backend: %s ---\n' "$BACKEND" >&2
  backends_run=$((backends_run + 1))
  run_suite
done

printf '%d passed, %d failed, %d backend(s) exercised\n' "$pass" "$fail" "$backends_run" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
