#!/usr/bin/env bash
#
# Exercises hooks/scripts/detect.sh against scratch repositories built under /tmp.
#
# This suite is the reason detect.sh exists as a script rather than as instructions in the
# calibrate skill's prose. The phase asks for a sane profile on several dissimilar repos and
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

# One field of one record: $2 = label, $3 = field number (1-based).
field() { printf '%s\n' "$1" | grep "^$2|" | head -1 | cut -d'|' -f"$3"; }

run_suite() {
  local out r

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
  # The one case ADR-005 exists for: pnpm has its own content-addressable store, so the tree
  # must be INSTALLED, never hardlinked.
  r=$(mkrepo pnpmws package.json pnpm-lock.yaml pnpm-workspace.yaml)
  out=$(det "$r")
  eq 'pnpm: install, never hardlink (ADR-005)' 'install' "$(field "$out" dep 5)"
  eq 'pnpm: --frozen-lockfile'  'pnpm install --frozen-lockfile' "$(field "$out" dep 6)"
  has 'pnpm: the reason names the content-addressable store' 'content-addresses' "$out"

  # --- a Python uv project -----------------------------------------------------
  r=$(mkrepo uvproj pyproject.toml uv.lock)
  out=$(det "$r")
  eq 'uv: .venv is the target directory' '.venv' "$(field "$out" dep 3)"
  eq 'uv: install, because uv has its own cache' 'install' "$(field "$out" dep 5)"
  eq 'uv: uv sync --frozen' 'uv sync --frozen' "$(field "$out" dep 6)"

  # --- poetry, whose in-project venv is opt-in ---------------------------------
  # hardlink is only meaningful if the directory is really there; poetry only creates it
  # in-project when configured to, so the strategy must degrade rather than name a directory
  # that does not exist.
  r=$(mkrepo poetrynovenv pyproject.toml poetry.lock)
  out=$(det "$r")
  eq 'poetry: no .venv present -> downgraded to install' 'install' "$(field "$out" dep 5)"
  has 'poetry: and the downgrade is announced with a reason' 'depDowngrade|0|hardlink|install' "$out"
  r=$(mkrepo poetryvenv pyproject.toml poetry.lock .venv/pyvenv.cfg)
  out=$(det "$r")
  eq 'poetry: an existing in-project .venv keeps hardlink' 'hardlink' "$(field "$out" dep 5)"
  hasnt 'poetry: and nothing is downgraded' 'depDowngrade' "$out"

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
  eq 'shell: which is the catch-all rule, not a fallthrough' '' "$(field "$out" shellMarker 2)"
  has 'shell: and it still states a reason' 'shellReason|no toolchain marker found' "$out"

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
  r=$(mkrepo cfg uv.lock .env .env.local)
  printf 'tracked-not-ignored\n' >"$r/.env.tracked"
  printf '.env\n.env.local\n' >"$r/.gitignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm cfg >/dev/null 2>&1
  out=$(det "$r")
  has 'config: a gitignored .env is proposed'       'config|.env' "$out"
  hasnt 'config: a TRACKED file is not proposed'    'config|.env.tracked' "$out"
  # Credentials and machine state are never proposed, even when gitignored.
  r=$(mkrepo creds uv.lock .env id_rsa auth.json app.sqlite)
  printf '.env\nid_rsa\nauth.json\napp.sqlite\n' >"$r/.gitignore"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm creds >/dev/null 2>&1
  out=$(det "$r")
  has   'config: an ordinary .env is still proposed' 'config|.env' "$out"
  hasnt 'config: an SSH private key is never proposed' 'config|id_rsa' "$out"
  hasnt 'config: registry credentials are never proposed' 'config|auth.json' "$out"
  hasnt 'config: a database file is never proposed' 'config|app.sqlite' "$out"

  # --- layer 3 is hints only ---------------------------------------------------
  # Nothing here may conclude anything (ADR-006). A wrong guess does not break a worktree; it
  # corrupts a colleague's data.
  r=$(mkrepo hints uv.lock docker-compose.yml .env)
  printf 'services:\n  db:\n    image: mysql\n  cache:\n    image: redis\n' >"$r/docker-compose.yml"
  printf 'APP_PORT=8080\nDATABASE_URL=mysql://localhost/app\n' >"$r/.env"
  commit_all "$r"
  out=$(det "$r")
  has 'hints: a port variable is offered as a hint' 'hint|port|APP_PORT' "$out"
  has 'hints: a database variable is offered as a hint' 'hint|db|DATABASE_URL' "$out"
  has 'hints: compose service names are offered as hints' 'hint|service|db' "$out"
  hasnt 'hints: NOTHING is emitted as a runtime decision' 'runtime|' "$out"

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

  # --- IDEMPOTENCE -------------------------------------------------------------
  # The acceptance criterion "a second run changes nothing" — an assertion rather than a
  # promise. This is the property that a model-driven detector could not have.
  r=$(mkrepo idem composer.lock composer.json package.json pnpm-lock.yaml flake.nix .env)
  printf '{"scripts":{"post-install-cmd":["@db"],"db":"doctrine:migrations:migrate"}}' >"$r/composer.json"
  printf '{"scripts":{"postinstall":"vite build"}}' >"$r/package.json"
  commit_all "$r"
  eq 'idempotent: two consecutive runs are byte-identical' "$(det "$r")" "$(det "$r")"
  eq 'idempotent: and a third agrees with the first' "$(det "$r")" "$(det "$r")"
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
