#!/usr/bin/env bash
#
# End-to-end tests for hooks/scripts/bootstrap.sh — the entrypoint, driven the way Claude Code
# drives it: a JSON payload on stdin, in a real scratch git repository with a real worktree.
#
# tests/test_bootstrap_lib.sh covers the engine's pieces in isolation. This covers the things only
# the entrypoint can get wrong: the stdout protocol, the order of the symlink refusal, which event
# does what, and that a broken profile or a failing install still leaves a usable session.
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

HOOK=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)/bootstrap.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The fixture repo must decide its own ignore rules, not the developer's.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
# These suites assert what a start-up run DID, so it does all of it in the hook; the background
# hand-off has its own tests, which turn it back on.
PITLANE_BACKGROUND=off
export PITLANE_BACKGROUND
# The approval gate has its own section in test_bootstrap.sh; everywhere else the fixture profiles
# are the suite's own, so they are trusted the way a developer who opens only their own branches would.
PITLANE_TRUST_PROFILES=1
export PITLANE_TRUST_PROFILES
unset XDG_CONFIG_HOME
# A corepack-managed pnpm keeps ITSELF in $HOME/.cache/node/corepack. Moving HOME makes corepack
# think pnpm is not installed and try to download it, which fails offline and read as "pnpm cannot
# produce a lockfile" — the long-standing failure of this suite. Only the tool's own cache is kept;
# git and pnpm's store still see the scratch HOME.
if [ -z "${COREPACK_HOME:-}" ] && [ -d "$HOME/.cache/node/corepack" ]; then
  COREPACK_HOME=$HOME/.cache/node/corepack
  export COREPACK_HOME
fi
HOME=$TMP/home
mkdir -p "$HOME"
export HOME

pass=0 fail=0

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      expected: %q\n      actual:   %q\n' "$1" "$2" "$3" >&2
  fi
}

ne() {  # $1 = label, $2, $3 = values that must differ
  if [ "$2" != "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      both were: %q\n' "$1" "$2" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL %s\n      expected to contain: %q\n      actual: %q\n' "$1" "$2" "$3" >&2 ;;
  esac
}

lacks() {  # $1 = label, $2 = needle that must NOT appear, $3 = haystack
  case $3 in
    *"$2"*) fail=$((fail + 1))
            printf 'FAIL %s\n      must not contain: %q\n      actual: %q\n' "$1" "$2" "$3" >&2 ;;
    *) pass=$((pass + 1)) ;;
  esac
}

# Build a scratch repo with a committed profile, a lockfile and a gitignored config file.
# $1 = directory, $2 = the deps[] fragment (may be empty)
make_repo() {
  local dir=$1 deps=${2-} copy=${3-} evidence=${4-}
  mkdir -p "$dir/.claude"
  git init -q "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  printf '.env\n.env.extra\n.claude/worktrees/\nvendor/\n' > "$dir/.gitignore"
  printf '.env\n' > "$dir/.worktreeinclude"
  printf 'SECRET=1\n' > "$dir/.env"
  printf 'LOCK\n' > "$dir/composer.lock"
  cat > "$dir/.claude/worktree-profile.json" <<JSON
{
  "schemaVersion": 1,
  "shell": "",
  "shellArgs": "argv",
  "copy": [$copy],
  $evidence
  "deps": [$deps],
  "timeouts": { "bootstrapSeconds": 60, "seedSeconds": 30 }
}
JSON
  git -C "$dir" add .gitignore .worktreeinclude composer.lock .claude/worktree-profile.json
  git -C "$dir" commit -qm init
}

# Run the hook exactly as Claude Code does: JSON on stdin, nothing on argv.
run_hook() {  # $1 = payload JSON, $2 = cwd to run from; prints stdout, stderr goes to $TMP/err
  local payload=$1 cwd=$2
  ( cd "$cwd" && printf '%s' "$payload" | bash "$HOOK" 2>"$TMP/err" )
}

# ---------------------------------------------------------------------------
# SessionStart — the launch-time `claude -w` path
# ---------------------------------------------------------------------------

R1=$TMP/r1
make_repo "$R1" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}' \
  '".env.extra"' '"evidence": { "detectionVersion": 0, "markers": ["composer.lock"], "shellMarker": "" },'
printf 'EXTRA=1\n' > "$R1/.env.extra"
W1=$R1/.claude/worktrees/feat
git -C "$R1" worktree add -q "$W1" -b worktree-feat 2>/dev/null

out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$W1\"}" "$W1")
err=$(cat "$TMP/err")

# THE PROTOCOL. On SessionStart stdout is injected into the model's context, so a single stray
# byte there is a bug — including anything an install command prints.
eq 'SessionStart writes NOTHING to stdout' '' "$out"
eq 'the dependency was installed' 'ok' "$(cat "$W1/vendor/marker" 2>/dev/null)"
contains 'and progress went to stderr' 'installing' "$err"
contains 'with a total time at the end' 'bootstrap finished in' "$err"

# The profile's copy[] is applied every session, because native knows nothing about it. And on a
# worktree's FIRST bootstrap .worktreeinclude is applied too, copy-if-missing: this fixture was made
# with plain `git worktree add`, which no native copying ever touched.
eq 'SessionStart applies the profile copy[] list' 'EXTRA=1' "$(cat "$W1/.env.extra" 2>/dev/null)"
eq 'the first SessionStart fills in .worktreeinclude where nothing did' 'SECRET=1' "$(cat "$W1/.env" 2>/dev/null)"

# Drift, end to end: the entrypoint must feed wt_report_drift the right evidence fields. The unit
# tests pass those directly, so only this proves the entrypoint reads them out correctly.
contains 'the entrypoint reports a stale detection table from the profile evidence' \
  'detection table is now version' "$err"

# Re-entry: fast, silent about work, and does nothing.
printf 'TOUCHED' > "$W1/vendor/marker"
start=$(date +%s)
out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$W1\"}" "$W1")
took=$(( $(date +%s) - start ))
err=$(cat "$TMP/err")
eq 're-entry still writes nothing to stdout' '' "$out"
eq 're-entry does not redo the install' 'TOUCHED' "$(cat "$W1/vendor/marker")"
contains 're-entry says it is already up to date' 'already up to date' "$err"
# Second-resolution timing straddles boundaries, so this is a generous ceiling: it exists to
# catch a re-entry that re-runs the whole install, not to measure milliseconds.
eq 're-entering an already-bootstrapped worktree is fast, not a full reinstall' yes \
  "$([ "$took" -le 3 ] && echo yes)"

# A session in the MAIN checkout is not a worktree session and must stay completely silent.
out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$R1\"}" "$R1")
err=$(cat "$TMP/err")
eq 'a session in the main checkout writes nothing to stdout' '' "$out"
eq '...and nothing to stderr either — a plugin that talks on every session gets uninstalled' '' "$err"

# `compact` fires mid-session, where re-running the bootstrap is pure cost.
out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"compact\",\"cwd\":\"$W1\"}" "$W1")
eq 'a compact SessionStart does nothing at all' '' "$out$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# Failure injection — every one must still leave a usable session
# ---------------------------------------------------------------------------

inject() {  # $1 = label, $2 = repo, $3 = worktree
  local rc out
  out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$3\"}" "$3")
  rc=$?
  eq "$1: the hook still exits 0" 0 "$rc"
  # stdout is model context: nothing, or the one-line "not fully set up" notice — never a stray byte.
  case $out in
    '' | 'Pitlane: this worktree is not fully set up'*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL %s: stdout is neither empty nor the notice\n      actual: %q\n' "$1" "$out" >&2 ;;
  esac
  eq "$1: and stdout is at most one line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
  INJECT_OUT=$out
}

R2=$TMP/r2
make_repo "$R2" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"exit 1"}'
W2=$R2/.claude/worktrees/f2
git -C "$R2" worktree add -q "$W2" -b worktree-f2 2>/dev/null
inject 'an install that fails' "$R2" "$W2"
contains 'a failed install is named in the SessionStart notice, with its reason' 'vendor missing (install failed: exit 1)' "$INJECT_OUT"
contains '...which says /pitlane-finish can retry it only on the user'"'"'s word' 'retry it on their word' "$INJECT_OUT"
contains 'an install that fails: says so' 'install command failed' "$(cat "$TMP/err")"

R3=$TMP/r3
make_repo "$R3" '{"dir":"vendor","lock":"nosuch.lock","strategy":"hardlink","install":"mkdir -p vendor"}'
W3=$R3/.claude/worktrees/f3
git -C "$R3" worktree add -q "$W3" -b worktree-f3 2>/dev/null
inject 'a lockfile that does not exist' "$R3" "$W3"

R4=$TMP/r4
make_repo "$R4" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor && printf i > vendor/m"}'
W4=$R4/.claude/worktrees/f4
git -C "$R4" worktree add -q "$W4" -b worktree-f4 2>/dev/null
inject 'no source directory to hardlink from' "$R4" "$W4"
eq 'no source directory: it installed instead' 'i' "$(cat "$W4/vendor/m" 2>/dev/null)"

# A profile that is absent entirely.
R5=$TMP/r5
make_repo "$R5" ''
rm -f "$R5/.claude/worktree-profile.json"
git -C "$R5" rm -q --cached .claude/worktree-profile.json 2>/dev/null
git -C "$R5" commit -qm drop 2>/dev/null
W5=$R5/.claude/worktrees/f5
git -C "$R5" worktree add -q "$W5" -b worktree-f5 2>/dev/null
inject 'no profile at all' "$R5" "$W5"
contains 'no profile: it says what to do about it' 'pitlane-setup' "$(cat "$TMP/err")"

# A profile that is present and invalid.
R6=$TMP/r6
make_repo "$R6" ''
printf '{"schemaVersion":1,"deps":[{"dir":"../escape","strategy":"nonsense"}]}' \
  > "$R6/.claude/worktree-profile.json"
git -C "$R6" add .claude/worktree-profile.json
git -C "$R6" commit -qm 'break the profile'
W6=$R6/.claude/worktrees/f6
git -C "$R6" worktree add -q "$W6" -b worktree-f6 2>/dev/null
inject 'an invalid profile' "$R6" "$W6"
contains 'an invalid profile: names the offending key' 'deps[0]' "$(cat "$TMP/err")"
eq 'an invalid profile: nothing escaped the worktree' '' \
  "$([ -e "$R6/.claude/worktrees/escape" ] && echo escaped)"

# A profile that is not JSON at all.
R7=$TMP/r7
make_repo "$R7" ''
printf 'this is not json' > "$R7/.claude/worktree-profile.json"
git -C "$R7" add .claude/worktree-profile.json
git -C "$R7" commit -qm 'break the profile'
W7=$R7/.claude/worktrees/f7
git -C "$R7" worktree add -q "$W7" -b worktree-f7 2>/dev/null
inject 'a profile that is not JSON' "$R7" "$W7"

# An unreadable payload must never be mistaken for a SessionStart.
out=$(printf '' | bash "$HOOK" 2>"$TMP/err")
eq 'an empty payload writes nothing to stdout' '' "$out"
contains 'an empty payload says why it did nothing' 'could not read hook_event_name' "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# WorktreeCreate — the EnterWorktree / subagent path
# ---------------------------------------------------------------------------

R8=$TMP/r8
make_repo "$R8" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf wc > vendor/m"}'

out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"entered\",\"cwd\":\"$R8\"}" "$R8")
err=$(cat "$TMP/err")

# THE PROTOCOL, the other way round: here stdout IS the worktree path and must be that alone.
eq 'WorktreeCreate prints exactly the worktree path on stdout' "$R8/.claude/worktrees/entered" "$out"
eq '...and exactly one line of it' 1 "$(printf '%s\n' "$out" | grep -c .)"
eq 'the worktree really was created' yes "$([ -d "$R8/.claude/worktrees/entered" ] && echo yes)"
eq 'the dependency was installed there too' 'wc' \
  "$(cat "$R8/.claude/worktrees/entered/vendor/m" 2>/dev/null)"
# Native does not run on this path, so the plugin owes .worktreeinclude here.
eq 'and .worktreeinclude was honoured, which native no longer does on this path' 'SECRET=1' \
  "$(cat "$R8/.claude/worktrees/entered/.env" 2>/dev/null)"

# Reopening the same name must be idempotent: the hook is re-invoked for an existing worktree.
out2=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"entered\",\"cwd\":\"$R8\"}" "$R8")
eq 'reopening the same name prints the same path' "$out" "$out2"
contains 'and says it is reopening rather than failing' 'reopening existing worktree' "$(cat "$TMP/err")"

# THE SYMLINK REFUSAL, and that it happens BEFORE anything is created. On this path Claude Code's
# own refusal arrives after the hook has run, so everything the hook did would already be done.
R9=$TMP/r9
make_repo "$R9" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf X > '"$TMP"'/SIDE_EFFECT"}'
mkdir -p "$TMP/outside"
rm -rf "$R9/.claude/worktrees"
ln -s "$TMP/outside" "$R9/.claude/worktrees"
rm -f "$TMP/SIDE_EFFECT"
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"evil\",\"cwd\":\"$R9\"}" "$R9")
err=$(cat "$TMP/err")
eq 'a symlinked .claude/worktrees prints NO path, so Claude Code reports the failure' '' "$out"
contains '...and says why' 'is a symlink' "$err"
eq '...and NOTHING was installed first — the whole point of checking before creating' '' \
  "$(cat "$TMP/SIDE_EFFECT" 2>/dev/null)"
eq '...and no worktree was registered outside the repository' 0 \
  "$(git -C "$R9" worktree list --porcelain 2>/dev/null | grep -c "$TMP/outside")"
rm -f "$R9/.claude/worktrees"

# The worktree path ITSELF being a symlink — the most reachable variant, since it needs only one
# entry inside worktrees/ rather than replacing the whole directory.
R9b=$TMP/r9b
make_repo "$R9b" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"printf X > '"$TMP"'/SIDE_EFFECT2"}'
mkdir -p "$R9b/.claude/worktrees" "$TMP/outside2"
ln -s "$TMP/outside2" "$R9b/.claude/worktrees/target"
rm -f "$TMP/SIDE_EFFECT2"
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"target\",\"cwd\":\"$R9b\"}" "$R9b")
eq 'a symlinked worktree path prints no path' '' "$out"
contains '...and says which one' 'is a symlink' "$(cat "$TMP/err")"
eq '...and installed nothing first' '' "$(cat "$TMP/SIDE_EFFECT2" 2>/dev/null)"

# A symlinked .claude itself.
R10=$TMP/r10
make_repo "$R10" ''
mv "$R10/.claude" "$R10/.claude-real"
ln -s "$R10/.claude-real" "$R10/.claude"
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"x\",\"cwd\":\"$R10\"}" "$R10")
eq 'a symlinked .claude prints no path either' '' "$out"
contains '...and says which path was refused' '.claude is a symlink' "$(cat "$TMP/err")"

# A name that would break the protocol or escape the directory.
R11=$TMP/r11
make_repo "$R11" ''
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"..\",\"cwd\":\"$R11\"}" "$R11")
eq 'a worktree name of .. prints no path' '' "$out"
contains '...and is refused as unsafe' 'refusing the unsafe worktree name' "$(cat "$TMP/err")"

# A name carrying a newline. MEASURED BEHAVIOUR, which is not what the code reads like: the JSON
# layer's desep folds every CR and LF into a space before any value leaves it, so the name arrives
# as "a b" and bootstrap.sh's own newline refusal is never reached. That refusal is therefore
# defence in depth rather than dead code — it still guards a caller that sets the payload some
# other way — and what actually matters is pinned here: whatever the name contains, stdout stays a
# single line, because a second line on that channel breaks worktree creation outright.
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"a\\nb\",\"cwd\":\"$R11\"}" "$R11")
eq 'a worktree name containing a newline never puts a second line on stdout' yes \
  "$([ "$(printf '%s\n' "$out" | grep -c .)" -le 1 ] && echo yes)"
out=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"cwd\":\"$R11\"}" "$R11")
eq 'a WorktreeCreate with no name at all prints no path' '' "$out"
contains '...and says the name was missing' 'no name' "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# Concurrency: two worktrees bootstrapping at once from cold
# ---------------------------------------------------------------------------

R12=$TMP/r12
make_repo "$R12" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && echo $$ >> vendor/who && sleep 1"}'
WA=$R12/.claude/worktrees/a
WB=$R12/.claude/worktrees/b
git -C "$R12" worktree add -q "$WA" -b worktree-a 2>/dev/null
git -C "$R12" worktree add -q "$WB" -b worktree-b 2>/dev/null

( cd "$WA" && printf '%s' "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WA\"}" \
    | bash "$HOOK" >/dev/null 2>"$TMP/err.a" ) &
pa=$!
( cd "$WB" && printf '%s' "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WB\"}" \
    | bash "$HOOK" >/dev/null 2>"$TMP/err.b" ) &
pb=$!
wait "$pa" "$pb"

eq 'two simultaneous cold creations both produce a populated worktree: the first' yes \
  "$([ -s "$WA/vendor/who" ] && echo yes)"
eq 'two simultaneous cold creations both produce a populated worktree: the second' yes \
  "$([ -s "$WB/vendor/who" ] && echo yes)"
# Each worktree's own tree must be its own: exactly one installer wrote each.
eq 'the first worktree was installed by exactly one process, not two racing' 1 \
  "$(grep -c . "$WA/vendor/who" | tr -d ' ')"
eq 'the second worktree was installed by exactly one process, not two racing' 1 \
  "$(grep -c . "$WB/vendor/who" | tr -d ' ')"
eq 'and the two worktrees were installed by DIFFERENT processes, so both really ran' 2 \
  "$(cat "$WA/vendor/who" "$WB/vendor/who" | sort -u | grep -c .)"
lacks 'and neither reported a corrupt or interleaved install' 'interrupted' \
  "$(cat "$TMP/err.a" "$TMP/err.b" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Acceptance: a real ecosystem, end to end
# ---------------------------------------------------------------------------
# Bootstrap's acceptance asks for a scratch pnpm repo and a scratch composer repo to come up with
# config and dependencies present and no manual steps.
#
# pnpm is exercised FOR REAL when it is on PATH — a dependency-free package still produces a
# lockfile and a node_modules, which is enough to prove the whole path (profile -> shell wrapper ->
# install -> verify -> state) against a genuine package manager rather than a stand-in.
#
# composer is NOT installed on every machine this runs on, so its repo is composer-SHAPED: the
# same vendor/ + composer.lock + hardlink strategy, driven by a stand-in command. That proves the
# engine's behaviour, not composer's. A real composer run against a 400 MB vendor/ is a
# real repository's job, and this says so rather than implying it covered it.

if command -v pnpm >/dev/null 2>&1; then
  RP=$TMP/pnpmrepo
  mkdir -p "$RP/.claude"
  git init -q "$RP"
  git -C "$RP" config user.email t@example.com
  git -C "$RP" config user.name t
  printf '{"name":"scratch","version":"1.0.0","private":true}\n' > "$RP/package.json"
  printf 'node_modules/\n.env\n.claude/worktrees/\n' > "$RP/.gitignore"
  printf '.env\n' > "$RP/.worktreeinclude"
  printf 'APP_ENV=local\n' > "$RP/.env"
  ( cd "$RP" && pnpm install --lockfile-only >/dev/null 2>&1 )
  if [ -f "$RP/pnpm-lock.yaml" ]; then
    cat > "$RP/.claude/worktree-profile.json" <<'JSON'
{
  "schemaVersion": 1,
  "shell": "",
  "shellArgs": "argv",
  "copy": [],
  "deps": [
    { "dir": "node_modules", "lock": "pnpm-lock.yaml", "strategy": "install",
      "install": "pnpm install --frozen-lockfile", "verify": "test -d node_modules" }
  ],
  "timeouts": { "bootstrapSeconds": 120, "seedSeconds": 30 }
}
JSON
    git -C "$RP" add -A
    git -C "$RP" commit -qm init
    WP=$RP/.claude/worktrees/pn
    git -C "$RP" worktree add -q "$WP" -b worktree-pn 2>/dev/null

    out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WP\"}" "$WP")
    err=$(cat "$TMP/err")
    eq 'pnpm: the session start writes nothing to stdout' '' "$out"
    eq 'pnpm: node_modules really is installed by a real pnpm' yes \
      "$([ -d "$WP/node_modules" ] && echo yes)"
    # pnpm has its own content-addressable store, so it must be installed, never shared.
    lacks 'pnpm: and it was installed, not hardlinked from the main checkout' 'hardlinked' "$err"
    eq 'pnpm: the worktree is usable with no manual steps' yes \
      "$([ -d "$WP/node_modules" ] && [ -f "$WP/package.json" ] && echo yes)"

    # Idempotence against a real package manager, asserted by OBSERVATION rather than by a clock:
    # a wall-clock budget both flakes on a loaded machine and is weak here, since a wrongly
    # re-run `pnpm install` on a dependency-free project finishes in well under a second anyway.
    # An untouched node_modules is the thing that actually proves pnpm was not run.
    before=$(find "$WP/node_modules" -maxdepth 1 -newer "$WP/package.json" 2>/dev/null | wc -l)
    marker=$WP/node_modules/.wt-untouched
    : > "$marker"
    run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WP\"}" "$WP" >/dev/null
    contains 'pnpm: re-entry is a no-op' 'already up to date' "$(cat "$TMP/err")"
    eq 'pnpm: and node_modules was not rewritten' yes "$([ -e "$marker" ] && echo yes)"
    eq 'pnpm: nor was the tree otherwise disturbed' "$before" \
      "$(find "$WP/node_modules" -maxdepth 1 -newer "$WP/package.json" 2>/dev/null | grep -vc '.wt-untouched$')"
  else
    printf 'WARNING: pnpm could not produce a lockfile offline — real-pnpm path NOT verified\n' >&2
    fail=$((fail + 1))
  fi
else
  # A skipped acceptance criterion is not a pass. Same rule as the cross-backend guard in
  # tests/test_lib.sh: a suite whose whole point is proving something must not report success
  # having quietly not proved it.
  if [ -n "${WT_TEST_ALLOW_MISSING_PNPM:-}" ]; then
    printf 'WARNING: pnpm absent — the real-ecosystem acceptance was NOT verified\n' >&2
  else
    printf 'FAIL: pnpm is not on PATH, so the real-ecosystem acceptance is untested.\n' >&2
    printf '      Run: nix shell nixpkgs#pnpm -c tests/test_bootstrap.sh\n' >&2
    printf '      Or set WT_TEST_ALLOW_MISSING_PNPM=1 to accept a run without it.\n' >&2
    fail=$((fail + 1))
  fi
fi

# composer-SHAPED: vendor/ hardlinked from the main checkout when the lockfiles agree, which is
# the case hardlinking exists for and the one a real composer repo hits.
# NOTE ON THE HARNESS, because it changes what can be asserted: this creates worktrees with plain
# `git worktree add`, which does NOT do Claude Code's native `.worktreeinclude` copying. So on the
# SessionStart path a .worktreeinclude file legitimately never arrives here, and asserting it
# would be asserting the harness rather than the hook. The profile's copy[] is what the hook
# genuinely owes on that path, so that is what is checked. The WorktreeCreate case above, where
# the hook DOES own .worktreeinclude, asserts the other half.
RC=$TMP/composerish
make_repo "$RC" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor && printf installed > vendor/autoload.php","verify":"test -r vendor/autoload.php"}' '".env"'
mkdir -p "$RC/vendor/pkg"
printf 'REALBYTES\n' > "$RC/vendor/autoload.php"
printf 'x\n' > "$RC/vendor/pkg/big.php"
WC=$RC/.claude/worktrees/cm
git -C "$RC" worktree add -q "$WC" -b worktree-cm 2>/dev/null

out=$(run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WC\"}" "$WC")
err=$(cat "$TMP/err")
eq 'composer-shaped: vendor/ is present in the worktree' 'REALBYTES' \
  "$(cat "$WC/vendor/autoload.php" 2>/dev/null)"
contains 'composer-shaped: and it was hardlinked rather than installed' 'hardlinked' "$err"
eq 'composer-shaped: the session start writes nothing to stdout' '' "$out"
src_ino=$(stat -c '%i' "$RC/vendor/pkg/big.php" 2>/dev/null || stat -f '%i' "$RC/vendor/pkg/big.php" 2>/dev/null)
# Guard against the comparison passing because BOTH sides are empty on a host with neither stat.
eq 'composer-shaped: the source inode is readable, so the next assertion means something' yes \
  "$([ -n "$src_ino" ] && echo yes)"
eq 'composer-shaped: the tree really shares inodes, so a big vendor costs no disk' "$src_ino" \
  "$(stat -c '%i' "$WC/vendor/pkg/big.php" 2>/dev/null || stat -f '%i' "$WC/vendor/pkg/big.php" 2>/dev/null)"
eq 'composer-shaped: the profile copy[] config came across, so the worktree is runnable' 'SECRET=1' \
  "$(cat "$WC/.env" 2>/dev/null)"

# --- an unsupported or cross-filesystem hardlink --------------------------------------------
# A second filesystem cannot be arranged inside one repository, so the failure is injected where
# the engine actually observes it: `cp -al` returning non-zero. That is exactly what a
# cross-device link or a filesystem without hardlinks produces.
RX=$TMP/nohardlink
make_repo "$RX" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor && printf fellback > vendor/m"}'
mkdir -p "$RX/vendor/pkg"; printf 'src\n' > "$RX/vendor/pkg/f"
WX=$RX/.claude/worktrees/nx
git -C "$RX" worktree add -q "$WX" -b worktree-nx 2>/dev/null

mkdir -p "$TMP/stub"
REAL_CP=$(command -v cp)
cat > "$TMP/stub/cp" <<STUB
#!/bin/sh
# Fail a hardlink copy the way a cross-device link really does: PARTWAY, having already created
# the destination and some of its contents. Exiting before touching anything would make the
# debris-cleanup assertion below unfalsifiable — and that branch is load-bearing, because a
# leftover destination makes the NEXT run report "already present" and freeze a partial tree.
case " \$* " in
  *" -al "*)
    for d; do :; done
    mkdir -p "\$d/pkg" 2>/dev/null
    : > "\$d/pkg/partial" 2>/dev/null
    echo "cp: cannot create hard link: Invalid cross-device link" >&2
    exit 1
    ;;
esac
exec "$REAL_CP" "\$@"
STUB
chmod +x "$TMP/stub/cp"
out=$( cd "$WX" && printf '%s' "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WX\"}" \
       | PATH="$TMP/stub:$PATH" bash "$HOOK" 2>"$TMP/err" )
err=$(cat "$TMP/err")
eq 'a hardlink that cannot be made does not fail the session' '' "$out"
contains '...it says the link was not possible' 'could not hardlink' "$err"
eq '...and installs instead, so the worktree still works' 'fellback' "$(cat "$WX/vendor/m" 2>/dev/null)"
eq '...having first cleared the debris the failed copy left' '' \
  "$([ -e "$WX/vendor/pkg/partial" ] && echo debris)"
# And the state that debris would otherwise poison: a second run must not decide the leftover
# directory is a finished dependency.
out=$( cd "$WX" && printf '%s' "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WX\"}" \
       | bash "$HOOK" 2>"$TMP/err" )
contains '...and the next run sees a finished dependency, not a frozen partial one' \
  'already up to date' "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# Layer 3 — runtime isolation's acceptance criteria, end to end through the hook
# ---------------------------------------------------------------------------
#
# The unit suite drives the engine's functions directly. This drives the ENTRYPOINT, which is the
# only thing that proves the profile's runtime block is read, the values reach the right places,
# and the whole sequence survives a real hook invocation.

# A repo whose profile isolates a port and THREE environments — development, test and CI. Isolating
# only the development database is the "looks right, is subtly wrong" failure to design against: a
# test runner that recreates its databases wholesale destroys a parallel session's test run
# regardless of how well the dev database is separated.
# VERIFY RUNS ON THE HOST, INSTALL INSIDE THE TOOLCHAIN. The wrapper can cost tens of seconds a
# call (measured: nix develop, 14–38s), and a verify is a cheap file test by contract.
RWV=$TMP/verifyhost
mkdir -p "$RWV"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/wrapper.log"\nexec "$@"\n' "$TMP" > "$TMP/wrap.sh"
chmod +x "$TMP/wrap.sh"
make_repo "$RWV" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker","verify":"test -r vendor/marker"}'
python3 - "$RWV/.claude/worktree-profile.json" "$TMP/wrap.sh" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["shell"] = sys.argv[2]
json.dump(d, open(f, "w"))
PYJ
git -C "$RWV" add -A; git -C "$RWV" commit -qm wrapper
WWV=$RWV/.claude/worktrees/v1
git -C "$RWV" worktree add -q "$WWV" -b worktree-v1 2>/dev/null
: > "$TMP/wrapper.log"
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WWV\"}" "$WWV" >/dev/null
contains 'verify on host: the install ran through the toolchain wrapper' 'printf ok > vendor/marker' "$(cat "$TMP/wrapper.log")"
lacks 'verify on host: the verify did not' 'test -r vendor/marker' "$(cat "$TMP/wrapper.log")"
eq 'verify on host: and the entry is still recorded done' 'ok' "$(cat "$WWV/vendor/marker" 2>/dev/null)"
lacks 'verify on host: with no verify failure reported' 'verify command failed' "$(cat "$TMP/err")"

# A WORKTREE MADE WITH PLAIN `git worktree add` never had .worktreeinclude applied — native only does
# it for `claude -w`. Its first SessionStart applies it (copy-if-missing); later ones do not re-walk.
RGA=$TMP/gitadd
make_repo "$RGA" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}'
WGA=$RGA/.claude/worktrees/existing-branch
git -C "$RGA" worktree add -q "$WGA" -b some-branch 2>/dev/null
eq 'git worktree add: fixture — the gitignored .env is not there' no "$([ -e "$WGA/.env" ] && echo yes || echo no)"
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WGA\"}" "$WGA" >/dev/null
eq 'git worktree add: the first session copies .worktreeinclude in' 'SECRET=1' "$(cat "$WGA/.env" 2>/dev/null)"
rm -f "$WGA/.env"
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WGA\"}" "$WGA" >/dev/null
eq 'git worktree add: a later session does not re-copy what the developer deleted' no \
  "$([ -e "$WGA/.env" ] && echo yes || echo no)"

# Where native creation already placed a file, the first session leaves it exactly as it is.
WNA=$RGA/.claude/worktrees/native-copied
git -C "$RGA" worktree add -q "$WNA" -b other-branch 2>/dev/null
printf 'SECRET=native-put-this\n' > "$WNA/.env"
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WNA\"}" "$WNA" >/dev/null
eq 'first session: a file native already copied is not overwritten' 'SECRET=native-put-this' "$(cat "$WNA/.env")"

# THE WORKTREE'S OWN .worktreeinclude wins over the main checkout's (the profile's own rule):
# a branch that adds one must not wait for the main checkout to have it too.
RWI=$TMP/wtinclude-own
make_repo "$RWI" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}'
printf 'EXTRA=from-main\n' > "$RWI/.env.extra"
git -C "$RWI" rm -q --cached .worktreeinclude; rm -f "$RWI/.worktreeinclude"; git -C "$RWI" commit -qm 'no include on main'
git -C "$RWI" checkout -q -b adds-include
printf '.env.extra\n' > "$RWI/.worktreeinclude"; git -C "$RWI" add .worktreeinclude; git -C "$RWI" commit -qm 'adds include'
git -C "$RWI" checkout -q -
WWI=$RWI/.claude/worktrees/wi
git -C "$RWI" worktree add -q "$WWI" adds-include 2>/dev/null
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WWI\"}" "$WWI" >/dev/null
eq 'own .worktreeinclude: the worktree branch patterns are used' 'EXTRA=from-main' "$(cat "$WWI/.env.extra" 2>/dev/null)"

# A NAME THAT IS A LEGAL DIRECTORY BUT NOT A LEGAL BRANCH. `worktree-my fix` used to fail
# `git worktree add -b`, so the hook printed no path and creation failed.
RSP=$TMP/spaced
make_repo "$RSP" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}'
outSP=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"my fix\",\"cwd\":\"$RSP\"}" "$RSP")
eq 'spaced name: WorktreeCreate prints the worktree path' "$RSP/.claude/worktrees/my fix" "$outSP"
eq 'spaced name: on a legal branch' 'worktree-my-fix' \
  "$(git -C "$RSP/.claude/worktrees/my fix" rev-parse --abbrev-ref HEAD 2>/dev/null)"
contains 'spaced name: and it says which branch it used' 'using worktree-my-fix' "$(cat "$TMP/err")"
eq 'spaced name: reopening it prints the same path' "$RSP/.claude/worktrees/my fix" \
  "$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"my fix\",\"cwd\":\"$RSP\"}" "$RSP")"

# A NESTED PROJECT WITH ITS OWN LOCKFILE — what detect.sh now proposes: its
# dir and lock carry the directory, and its commands `cd` into it from the worktree root. The
# engine has to be able to hardlink it and, when the lockfile differs, install it there.
RN=$TMP/nested
make_repo "$RN" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"},
  {"dir":"tools/lint/vendor","lock":"tools/lint/composer.lock","strategy":"hardlink",
   "install":"cd '"'"'tools/lint'"'"' && mkdir -p vendor && printf installed > vendor/autoload.php",
   "verify":"cd '"'"'tools/lint'"'"' && test -r vendor/autoload.php"}'
mkdir -p "$RN/tools/lint/vendor"
printf 'NESTEDLOCK\n' > "$RN/tools/lint/composer.lock"
printf '{}\n' > "$RN/tools/lint/composer.json"
printf 'from-main\n' > "$RN/tools/lint/vendor/autoload.php"
git -C "$RN" add tools/lint/composer.lock tools/lint/composer.json; git -C "$RN" commit -qm nested
WN1=$RN/.claude/worktrees/n1
git -C "$RN" worktree add -q "$WN1" -b worktree-n1 2>/dev/null
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WN1\"}" "$WN1" >/dev/null
eq 'nested: the nested tree is hardlinked from the main checkout' 'from-main' \
  "$(cat "$WN1/tools/lint/vendor/autoload.php" 2>/dev/null)"
# shellcheck disable=SC2012  # ls -ld for the link count, portable where stat -c is not
eq 'nested: a hardlink, not a copy' 2 \
  "$(ls -ld "$RN/tools/lint/vendor/autoload.php" | awk '{print $2}')"
# A branch that changes the nested lockfile installs it instead, from its own directory.
WN2=$RN/.claude/worktrees/n2
git -C "$RN" worktree add -q "$WN2" -b worktree-n2 2>/dev/null
printf 'CHANGED\n' > "$WN2/tools/lint/composer.lock"
run_hook "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$WN2\"}" "$WN2" >/dev/null
eq 'nested: a changed nested lockfile installs in its own directory' 'installed' \
  "$(cat "$WN2/tools/lint/vendor/autoload.php" 2>/dev/null)"
eq 'nested: and nothing was installed at the root by mistake' 0 \
  "$([ -e "$WN2/vendor/autoload.php" ] && echo 1 || echo 0)"

make_rt_repo() {  # $1 = dir, $2 = extra runtime JSON keys
  local dir=$1 extra=${2-}
  mkdir -p "$dir/.claude"
  git init -q "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  printf '.env.worktree.local\n.claude/worktrees/\n.claude/worktree-no-runtime\nvendor/\n' > "$dir/.gitignore"
  printf 'LOCK\n' > "$dir/composer.lock"
  cat > "$dir/.claude/worktree-profile.json" <<JSON
{
  "schemaVersion": 1,
  "shell": "",
  "shellArgs": "argv",
  "deps": [{"dir":"vendor","lock":"composer.lock","strategy":"install",
            "install":"mkdir -p vendor && printf ok > vendor/marker"}],
  "runtime": {
    "slug": "{slug}",
    "port": { "var": "SERVER_PORT", "base": 4100, "span": 200 },
    "env": {
      "file": ".env.worktree.local",
      "vars": {
        "DATABASE_NAME": "demo_{slug}",
        "TEST_DATABASE_NAME": "demo_{slug}_test",
        "CI_DATABASE_NAME": "demo_{slug}_ci"
      }
    }$extra
  },
  "timeouts": { "bootstrapSeconds": 60, "seedSeconds": 20 }
}
JSON
  git -C "$dir" add .gitignore composer.lock .claude/worktree-profile.json
  git -C "$dir" commit -qm init
}
start_hook() {  # $1 = worktree
  ( cd "$1" && printf '%s' "{\"hook_event_name\":\"SessionStart\",\"source\":\"startup\",\"cwd\":\"$1\"}" \
    | bash "$HOOK" 2>"$TMP/err" )
}
# The EFFECTIVE value: the last assignment, which is what dotenv honours and where the plugin's
# block sits. $3 names another override file.
envval() { grep "^$2=" "$1/${3:-.env.worktree.local}" 2>/dev/null | tail -1 | cut -d= -f2-; }

RT=$TMP/rt
make_rt_repo "$RT"
WA=$RT/.claude/worktrees/alice
WB=$RT/.claude/worktrees/bob
git -C "$RT" worktree add -q "$WA" -b worktree-alice 2>/dev/null
git -C "$RT" worktree add -q "$WB" -b worktree-bob 2>/dev/null

outA=$(start_hook "$WA"); errA=$(cat "$TMP/err")
outB=$(start_hook "$WB"); errB=$(cat "$TMP/err")

eq 'runtime work still writes NOTHING to stdout on SessionStart' '' "$outA$outB"
eq 'both worktrees still get their dependencies' 'okok' \
  "$(cat "$WA/vendor/marker" 2>/dev/null)$(cat "$WB/vendor/marker" 2>/dev/null)"

# ACCEPTANCE: two worktrees, different ports and different databases — for EVERY environment.
pA=$(envval "$WA" SERVER_PORT); pB=$(envval "$WB" SERVER_PORT)
ne 'two worktrees get different ports' "$pA" "$pB"
ne 'two worktrees get different development databases' \
  "$(envval "$WA" DATABASE_NAME)" "$(envval "$WB" DATABASE_NAME)"
ne 'two worktrees get different TEST databases too' \
  "$(envval "$WA" TEST_DATABASE_NAME)" "$(envval "$WB" TEST_DATABASE_NAME)"
ne 'and different CI databases' \
  "$(envval "$WA" CI_DATABASE_NAME)" "$(envval "$WB" CI_DATABASE_NAME)"
eq "alice's development database is named after her slug" 'demo_alice' \
  "$(envval "$WA" DATABASE_NAME)"
eq "and her test database is a distinct name again" 'demo_alice_test' \
  "$(envval "$WA" TEST_DATABASE_NAME)"
contains 'and the hook says what it settled on' 'runtime: slug=alice' "$errA"

# ACCEPTANCE: reopening lands on the same port and the same database. A developer bookmarks the URL.
start_hook "$WA" >/dev/null
eq 'reopening a worktree keeps its port' "$pA" "$(envval "$WA" SERVER_PORT)"
eq 'and its database' 'demo_alice' "$(envval "$WA" DATABASE_NAME)"

# The override file must not show up as an untracked change — that is how one gets committed and
# every teammate's worktree ends up pointing at one database.
eq "the override file is invisible to git status" '' \
  "$(git -C "$WA" status --porcelain 2>/dev/null)"

# ACCEPTANCE: a developer can redirect a worktree without touching the profile, and the plugin
# respects it on EVERY later session — warning once, not every time.
printf 'DATABASE_NAME=the_shared_one\n' > "$WA/.env.worktree.local"
start_hook "$WA" >/dev/null; first=$(cat "$TMP/err")
start_hook "$WA" >/dev/null; second=$(cat "$TMP/err")
eq 'a hand-edited override file survives a re-bootstrap byte for byte' \
  'DATABASE_NAME=the_shared_one' "$(cat "$WA/.env.worktree.local")"
contains 'and the developer is told once that it is now theirs' 'it will be left alone' "$first"
lacks 'and NOT told again on the next session' 'it will be left alone' "$second"
rm -f "$WA/.env.worktree.local"
start_hook "$WA" >/dev/null
eq 'deleting it hands ownership back' "$pA" "$(envval "$WA" SERVER_PORT)"

# ACCEPTANCE: the opt-out marker skips layer 3 entirely and leaves dependencies working.
rm -f "$WB/.env.worktree.local"
mkdir -p "$WB/.claude"
: > "$WB/.claude/worktree-no-runtime"
start_hook "$WB" >/dev/null; errB=$(cat "$TMP/err")
eq 'the opt-out marker writes no override file' 0 \
  "$([ -e "$WB/.env.worktree.local" ] && echo 1 || echo 0)"
contains 'and says so once' 'leaving this worktree' "$errB"
eq 'while the dependencies it already had are untouched' 'ok' \
  "$(cat "$WB/vendor/marker" 2>/dev/null)"
rm -f "$WB/.claude/worktree-no-runtime"

# ACCEPTANCE: nested and awkward names produce legal, DISTINCT slugs — through the entrypoint,
# which is where the basename bug lived: `alice/fix-99` and `bob/fix-99` both used to reduce to
# `fix-99`, giving two worktrees one port and one database while each believed it was isolated.
mkdir -p "$RT/.claude/worktrees/alice" "$RT/.claude/worktrees/bob"
WN1=$RT/.claude/worktrees/alice/fix-99
WN2=$RT/.claude/worktrees/bob/fix-99
git -C "$RT" worktree add -q "$WN1" -b worktree-alice-fix-99 2>/dev/null
git -C "$RT" worktree add -q "$WN2" -b worktree-bob-fix-99 2>/dev/null
start_hook "$WN1" >/dev/null
start_hook "$WN2" >/dev/null
ne 'two NESTED worktrees sharing a leaf name get different databases' \
  "$(envval "$WN1" DATABASE_NAME)" "$(envval "$WN2" DATABASE_NAME)"
ne 'and different ports' "$(envval "$WN1" SERVER_PORT)" "$(envval "$WN2" SERVER_PORT)"
eq 'a nested name slugs to a legal database name' 'demo_alice_fix_99' \
  "$(envval "$WN1" DATABASE_NAME)"

# A long, punctuation-heavy, non-ASCII name still produces something legal.
WLONG="$RT/.claude/worktrees/Ünïcode--Feature/Very-Long-Branch-Name-That-Goes-On-And-On-For-A-While"
mkdir -p "${WLONG%/*}"
git -C "$RT" worktree add -q "$WLONG" -b worktree-long 2>/dev/null
start_hook "$WLONG" >/dev/null
longdb=$(envval "$WLONG" DATABASE_NAME)
ne 'an awkward name still yields a database name' '' "$longdb"
eq 'and it contains only characters an identifier may have' '' \
  "$(printf '%s' "$longdb" | tr -d 'a-z0-9_')"

# A CONSTANT runtime.slug MUST NOT COLLAPSE EVERY WORKTREE ONTO ONE DATABASE. Validation only
# WARNS about such a template, on the explicit promise that the worktree's own name is used
# instead — so if the engine honoured it literally, two parallel sessions would run migrations
# against one database while the developer had been told otherwise. The same-slug rule in the port
# claim would then treat them as one worktree rather than as a collision, so nothing downstream
# would notice either.
RC=$TMP/rtconst
make_rt_repo "$RC"
python3 - "$RC/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["slug"] = "shared"
json.dump(d, open(f, "w"))
PYJ
git -C "$RC" add -A; git -C "$RC" commit -qm const
WC1=$RC/.claude/worktrees/one
WC2=$RC/.claude/worktrees/two
git -C "$RC" worktree add -q "$WC1" -b worktree-one 2>/dev/null
git -C "$RC" worktree add -q "$WC2" -b worktree-two 2>/dev/null
start_hook "$WC1" >/dev/null; constwarn=$(cat "$TMP/err")
start_hook "$WC2" >/dev/null
ne 'a constant runtime.slug still gives two worktrees different databases' \
  "$(envval "$WC1" DATABASE_NAME)" "$(envval "$WC2" DATABASE_NAME)"
ne 'and different ports' "$(envval "$WC1" SERVER_PORT)" "$(envval "$WC2" SERVER_PORT)"
eq 'and the database is named after the worktree, as the validator promised' 'demo_one' \
  "$(envval "$WC1" DATABASE_NAME)"
contains 'and the engine says it ignored the template' 'same for every worktree' "$constwarn"

# A profile that OMITS runtime.slug behaves the same way — the ordinary case, and the one whose
# default has to expand correctly rather than leaving a literal brace in a database name.
RD=$TMP/rtdefault
make_rt_repo "$RD"
python3 - "$RD/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
del d["runtime"]["slug"]
json.dump(d, open(f, "w"))
PYJ
git -C "$RD" add -A; git -C "$RD" commit -qm nodefault
WD1=$RD/.claude/worktrees/dee
git -C "$RD" worktree add -q "$WD1" -b worktree-dee 2>/dev/null
start_hook "$WD1" >/dev/null
eq 'a profile with no runtime.slug names the database after the worktree' 'demo_dee' \
  "$(envval "$WD1" DATABASE_NAME)"

# CHANGING runtime.slug re-points a live worktree, and its seed must run again for the NEW
# database — even with no runtime.port, where the port claim (which also resets these) never runs.
RE=$TMP/rtreslug
make_rt_repo "$RE" ',
    "seed": ".claude/worktree-seed.sh"'
python3 - "$RE/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
del d["runtime"]["port"]                      # no port claim to reset the seed marker for us
json.dump(d, open(f, "w"))
PYJ
mkdir -p "$RE/.claude"
# SC2016: single-quoted ON PURPOSE — $WT_SLUG and $WT_PATH must reach the SEED SCRIPT and be
# expanded when it runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$WT_SLUG" >> "$WT_PATH/seeded.txt"\n' \
  > "$RE/.claude/worktree-seed.sh"
chmod +x "$RE/.claude/worktree-seed.sh"
git -C "$RE" add -A; git -C "$RE" commit -qm seed
WRS=$RE/.claude/worktrees/rs
git -C "$RE" worktree add -q "$WRS" -b worktree-rs 2>/dev/null
start_hook "$WRS" >/dev/null
eq 'the seed ran for the original slug' 'rs' "$(cat "$WRS/seeded.txt" 2>/dev/null)"
start_hook "$WRS" >/dev/null
eq 'and is skipped while nothing has changed' 'rs' "$(cat "$WRS/seeded.txt" 2>/dev/null)"
python3 - "$WRS/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["slug"] = "t_{slug}"
json.dump(d, open(f, "w"))
PYJ
start_hook "$WRS" >/dev/null
eq 'but a CHANGED slug seeds the new database, rather than trusting the old marker' 'rs
t_rs' "$(cat "$WRS/seeded.txt" 2>/dev/null)"

# THE SUMMARY MUST NOT CLAIM AN ENV FILE IT REFUSED TO WRITE. It is the one line a developer reads
# before the TUI renders, and the sentence in which a wrong mapping is supposed to become obvious —
# so naming a file that does not exist reports isolation that did not happen.
RF=$TMP/rtrefused
make_rt_repo "$RF"
python3 - "$RF/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["env"]["file"] = "tracked.env"     # deliberately NOT gitignored
json.dump(d, open(f, "w"))
PYJ
git -C "$RF" add -A; git -C "$RF" commit -qm refused
WRF=$RF/.claude/worktrees/rf
git -C "$RF" worktree add -q "$WRF" -b worktree-rf 2>/dev/null
start_hook "$WRF" >/dev/null; errRF=$(cat "$TMP/err")
contains 'a non-gitignored override path is refused' 'not gitignored' "$errRF"
lacks 'and the summary does not claim it wrote one' 'env=tracked.env' "$errRF"
contains 'while still reporting the slug it settled on' 'runtime: slug=rf' "$errRF"
eq 'and no such file was created' 0 "$([ -e "$WRF/tracked.env" ] && echo 1 || echo 0)"

# AN UNWRITABLE OVERRIDE FILE MUST ALSO STOP THE SEED. The seed's first refusal is "the app is not
# pointed where WT_SLUG describes" — and a write that was REFUSED leaves exactly that state, with
# the app still reading the shared database. Seeding then creates a database nothing points at,
# which is the failure the refusal exists for arrived at by a different route.
RU=$TMP/rtunwritable
make_rt_repo "$RU" ',
    "seed": ".claude/worktree-seed.sh"'
python3 - "$RU/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["env"]["file"] = "tracked.env"     # deliberately NOT gitignored, so the write refuses
json.dump(d, open(f, "w"))
PYJ
mkdir -p "$RU/.claude"
# shellcheck disable=SC2016  # $WT_PATH must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nprintf ran > "$WT_PATH/seeded.txt"\n' > "$RU/.claude/worktree-seed.sh"
chmod +x "$RU/.claude/worktree-seed.sh"
git -C "$RU" add -A; git -C "$RU" commit -qm unwritable
WU=$RU/.claude/worktrees/u1
git -C "$RU" worktree add -q "$WU" -b worktree-u1 2>/dev/null
start_hook "$WU" >/dev/null; errU=$(cat "$TMP/err")
eq 'a refused env write stops the seed' 0 "$([ -e "$WU/seeded.txt" ] && echo 1 || echo 0)"
contains 'and says the worktree is not pointed anywhere yet' 'not pointed at anything named' "$errU"
eq 'and the session still survives' 'ok' "$(cat "$WU/vendor/marker" 2>/dev/null)"

# AN OVERRIDE FILE LISTED FOR COPYING IS COPIED, AND THEN GETS THE BLOCK. The file an app
# loads by name is usually the one holding the developer's real configuration, so it must arrive —
# and the plugin's block, appended after it, is what isolates the worktree. This used to be the
# opposite: the copier skipped the file, because a copied file without the marker read as
# developer-owned forever, and that skip never covered the native `claude -w` path at all.
RO=$TMP/rtoverlap
make_rt_repo "$RO"
python3 - "$RO/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["copy"] = [".env.worktree.local"]             # the same path runtime.env.file names
json.dump(d, open(f, "w"))
PYJ
printf 'SECRET=from-main\nDATABASE_NAME=the_main_checkout_one\n' > "$RO/.env.worktree.local"
git -C "$RO" add -A; git -C "$RO" commit -qm overlap
WO=$RO/.claude/worktrees/o1
git -C "$RO" worktree add -q "$WO" -b worktree-o1 2>/dev/null
start_hook "$WO" >/dev/null
eq 'the developer configuration IS copied in' 'from-main' "$(envval "$WO" SECRET)"
eq 'and the block after it isolates the worktree' 'demo_o1' "$(envval "$WO" DATABASE_NAME)"
eq 'which a second session leaves the same' 'demo_o1' \
  "$(start_hook "$WO" >/dev/null; envval "$WO" DATABASE_NAME)"
eq 'with the copied lines still there exactly once' 1 \
  "$(grep -c '^SECRET=' "$WO/.env.worktree.local" | tr -d ' ')"

# THE NATIVE PATH, simulated: Claude Code copies .worktreeinclude BEFORE SessionStart runs, so the
# hook finds the developer's file already there. That is the case the old skip never covered.
WN=$RO/.claude/worktrees/n1
git -C "$RO" worktree add -q "$WN" -b worktree-n1 2>/dev/null
cp "$RO/.env.worktree.local" "$WN/.env.worktree.local"
start_hook "$WN" >/dev/null; errN=$(cat "$TMP/err")
eq 'a file native creation copied in gets the block too' 'demo_n1' "$(envval "$WN" DATABASE_NAME)"
lacks 'and is not announced as the developer file' 'is yours' "$errN"

# ...and the same for .worktreeinclude on the WorktreeCreate path, where the plugin copies it.
printf '.env.worktree.local\n' > "$RO/.worktreeinclude"
git -C "$RO" add -A; git -C "$RO" commit -qm wtinclude
outWC=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"o2\",\"cwd\":\"$RO\"}" "$RO")
eq 'WorktreeCreate still prints the worktree path' "$RO/.claude/worktrees/o2" "$outWC"
eq 'and .worktreeinclude copied the developer configuration in' 'from-main' \
  "$(envval "$RO/.claude/worktrees/o2" SECRET)"
eq 'while the worktree got its own isolated value' 'demo_o2' \
  "$(envval "$RO/.claude/worktrees/o2" DATABASE_NAME)"

# OWNERSHIP IS PER FILE, looked up by name. Taking over one file must not stop the plugin writing a
# file it has never seen — a newly listed file that already exists is the developer's configuration
# and gets the block — and the file taken over stays taken over.
RV=$TMP/rtchangedenv
make_rt_repo "$RV"
git -C "$RV" worktree add -q "$RV/.claude/worktrees/v1" -b worktree-v1 2>/dev/null
WV=$RV/.claude/worktrees/v1
start_hook "$WV" >/dev/null
printf 'MINE=1\n' > "$WV/.env.worktree.local"          # take the first file over: its block is gone
start_hook "$WV" >/dev/null; errV1=$(cat "$TMP/err")
contains 'taking a file over is announced' '.env.worktree.local is yours' "$errV1"
eq 'and it is left alone' 'MINE=1' "$(cat "$WV/.env.worktree.local")"
start_hook "$WV" >/dev/null; errV2=$(cat "$TMP/err")
lacks 'but only once' 'is yours' "$errV2"
printf '.env.other.local\n' >> "$WV/.gitignore"
python3 - "$WV/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["env"]["file"] = [".env.worktree.local", ".env.other.local"]
json.dump(d, open(f, "w"))
PYJ
# The main checkout has the file too, and the worktree's is a copy of it — what .worktreeinclude or
# native creation would have put there. A copy gets the block; a hand-made file would not.
printf 'ALSO_MINE=1\n' > "$RV/.env.other.local"
cp "$RV/.env.other.local" "$WV/.env.other.local"
start_hook "$WV" >/dev/null; errV=$(cat "$TMP/err")
eq 'a newly listed existing file keeps its lines' 'ALSO_MINE=1' "$(head -1 "$WV/.env.other.local")"
eq 'and gets the block' 'demo_v1' "$(envval "$WV" DATABASE_NAME .env.other.local)"
eq 'while the file taken over is still left alone' 'MINE=1' "$(cat "$WV/.env.worktree.local")"
lacks 'and is not re-announced' '.env.worktree.local is yours' "$errV"
# shellcheck disable=SC1091  # sourced from the plugin at run time
eq 'the record keeps one disposition per file, aligned' 'theirs:ours' \
  "$(. "${HOOK%/*}/lib.sh"; . "${HOOK%/*}/bootstrap-lib.sh"; wt_runtime_state_get "$WV" envstate)"

# A SESSION THAT CANNOT WRITE A FILE KEEPS WHAT WAS RECORDED FOR IT. Forgetting `ours` there would
# let a later take-over (block deleted) read as "never written" and get the block appended again.
rm -f "$WV/.env.other.local"; mkdir "$WV/.env.other.local"
start_hook "$WV" >/dev/null
# shellcheck disable=SC1091  # sourced from the plugin at run time
eq 'an unwritable file keeps its recorded disposition' 'theirs:ours' \
  "$(. "${HOOK%/*}/lib.sh"; . "${HOOK%/*}/bootstrap-lib.sh"; wt_runtime_state_get "$WV" envstate)"
rmdir "$WV/.env.other.local"
printf 'TOOK_IT=1\n' > "$WV/.env.other.local"
start_hook "$WV" >/dev/null
eq 'so taking it over afterwards is still honoured' 'TOOK_IT=1' "$(cat "$WV/.env.other.local")"

# ADOPTION: a worktree set up by hand before the plugin arrived. Its env file differs from
# the main checkout's and nothing records it, so the plugin must not re-point it — and must not seed.
RA=$TMP/rtadopt
make_rt_repo "$RA" ',
    "seed": ".claude/worktree-seed.sh"'
printf 'DATABASE_NAME=shared_db\n' > "$RA/.env.worktree.local"
mkdir -p "$RA/.claude"
# shellcheck disable=SC2016  # $WT_PATH must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nprintf ran > "$WT_PATH/seeded.txt"\n' > "$RA/.claude/worktree-seed.sh"
chmod +x "$RA/.claude/worktree-seed.sh"
git -C "$RA" add -A; git -C "$RA" commit -qm adopt
WA1=$RA/.claude/worktrees/handmade
git -C "$RA" worktree add -q "$WA1" -b worktree-handmade 2>/dev/null
printf 'DATABASE_NAME=handmade_clone\n' > "$WA1/.env.worktree.local"   # pointed at a hand clone
start_hook "$WA1" >/dev/null; errA=$(cat "$TMP/err")
eq 'adoption: a hand-configured env file is left byte for byte alone' 'DATABASE_NAME=handmade_clone' \
  "$(cat "$WA1/.env.worktree.local")"
contains 'adoption: and it says why, once' 'set up in this worktree by hand' "$errA"
eq 'adoption: nothing is seeded against a name the worktree does not use' 0 \
  "$([ -e "$WA1/seeded.txt" ] && echo 1 || echo 0)"
start_hook "$WA1" >/dev/null; errA2=$(cat "$TMP/err")
lacks 'adoption: the notice is not repeated' 'set up in this worktree by hand' "$errA2"
# A file that exists only in the worktree was made there too.
WA2=$RA/.claude/worktrees/handmade2
git -C "$RA" worktree add -q "$WA2" -b worktree-handmade2 2>/dev/null
rm -f "$RA/.env.worktree.local"
printf 'DATABASE_NAME=only_here\n' > "$WA2/.env.worktree.local"
start_hook "$WA2" >/dev/null
eq 'adoption: a file only the worktree has is left alone too' 'DATABASE_NAME=only_here' \
  "$(cat "$WA2/.env.worktree.local")"

# EVERY ENVIRONMENT'S FILE gets the same block, and the seed sees them all.
RM=$TMP/rtmulti
make_rt_repo "$RM" ',
    "seed": ".claude/worktree-seed.sh"'
printf '.env.test.local\n' >> "$RM/.gitignore"
python3 - "$RM/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["runtime"]["env"]["file"] = [".env.worktree.local", ".env.test.local"]
json.dump(d, open(f, "w"))
PYJ
mkdir -p "$RM/.claude"
# shellcheck disable=SC2016  # the $WT_* references must reach the seed script.
printf '#!/usr/bin/env bash\nprintf "%%s|%%s" "$WT_ENV_FILE" "$WT_ENV_FILES" > "$WT_PATH/seed-env.txt"\n' \
  > "$RM/.claude/worktree-seed.sh"
chmod +x "$RM/.claude/worktree-seed.sh"
git -C "$RM" add -A; git -C "$RM" commit -qm multi
WM=$RM/.claude/worktrees/m1
git -C "$RM" worktree add -q "$WM" -b worktree-m1 2>/dev/null
start_hook "$WM" >/dev/null; errM=$(cat "$TMP/err")
eq 'the first file gets the block' 'demo_m1' "$(envval "$WM" DATABASE_NAME)"
eq 'and so does the second' 'demo_m1' "$(envval "$WM" DATABASE_NAME .env.test.local)"
contains 'and the summary names both' 'env=.env.worktree.local, .env.test.local' "$errM"
eq 'the seed receives the first as WT_ENV_FILE and all of them as WT_ENV_FILES' \
  ".env.worktree.local|.env.worktree.local
.env.test.local" "$(cat "$WM/seed-env.txt" 2>/dev/null)"
# One file taken over is enough to stop a reseed: that environment points somewhere the slug does
# not describe.
printf 'MINE=1\n' > "$WM/.env.test.local"
# shellcheck disable=SC2016  # $WT_PATH must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nprintf again > "$WT_PATH/seed-again.txt"\n' > "$WM/.claude/worktree-seed.sh"
start_hook "$WM" >/dev/null; errM2=$(cat "$TMP/err")
eq 'a seed with one file taken over is refused' 0 "$([ -e "$WM/seed-again.txt" ] && echo 1 || echo 0)"
contains 'and the refusal names the files' '.env.worktree.local or .env.test.local is managed by you' "$errM2"

# ACCEPTANCE: every runtime failure path still yields a session. A seed that fails, and one that
# hangs past its budget.
RS=$TMP/rtseed
make_rt_repo "$RS" ',
    "seed": ".claude/worktree-seed.sh"'
mkdir -p "$RS/.claude"
printf '#!/usr/bin/env bash\nexit 3\n' > "$RS/.claude/worktree-seed.sh"
chmod +x "$RS/.claude/worktree-seed.sh"
git -C "$RS" add .claude/worktree-seed.sh; git -C "$RS" commit -qm seed
WS=$RS/.claude/worktrees/s1
git -C "$RS" worktree add -q "$WS" -b worktree-s1 2>/dev/null
outS=$(start_hook "$WS"); errS=$(cat "$TMP/err")
contains 'a failing seed still leaves a usable session (only the notice on stdout)' \
  'databases missing (seed: failed)' "$outS"
contains 'and it says the seed failed' 'the seed failed' "$errS"
eq 'and the worktree still got its dependencies' 'ok' "$(cat "$WS/vendor/marker" 2>/dev/null)"
eq 'and its port and database' 'demo_s1' "$(envval "$WS" DATABASE_NAME)"
contains 'and the bootstrap still reports finishing' 'bootstrap finished in' "$errS"

if command -v timeout >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nsleep 60\n' > "$WS/.claude/worktree-seed.sh"
  chmod +x "$WS/.claude/worktree-seed.sh"
  # A one-second seed budget, so the hang is stopped by the guard rather than by the platform.
  python3 - "$WS/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["timeouts"]["seedSeconds"] = 1
json.dump(d, open(f, "w"))
PYJ
  outS=$(start_hook "$WS"); errS=$(cat "$TMP/err")
  contains 'a HANGING seed still leaves a usable session (only the notice on stdout)' \
    'databases missing (seed: timeout)' "$outS"
  contains 'and the hang is stopped and reported' 'was stopped' "$errS"
  contains 'and the bootstrap still finishes' 'bootstrap finished in' "$errS"
fi

# ACCEPTANCE: a profile with NO runtime block changes nothing on disk, silently.
NR=$TMP/nort
make_repo "$NR" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}'
WNR=$NR/.claude/worktrees/plain
git -C "$NR" worktree add -q "$WNR" -b worktree-plain 2>/dev/null
start_hook "$WNR" >/dev/null
before=$(cd "$WNR" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
errNR=$(cat "$TMP/err")
start_hook "$WNR" >/dev/null
after=$(cd "$WNR" && find . -path ./.git -prune -o -print | LC_ALL=C sort)
eq 'a profile with no runtime block leaves the worktree unchanged' "$before" "$after"
lacks 'and says nothing at all about runtime' 'runtime:' "$errNR"
eq 'and nothing shows up in git status' '' "$(git -C "$WNR" status --porcelain 2>/dev/null)"

# ---------------------------------------------------------------------------
# A slow toolchain — the hook's time runs out, and the session is told so
# ---------------------------------------------------------------------------
# Not nix-specific: any wrapper (a container, a dev-env manager) can spend a first start downloading.
# The fake one logs every start and, while $TMP/shell.slow exists, never becomes ready.

if command -v timeout >/dev/null 2>&1; then
  cat > "$TMP/fakeshell" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/shell.log"
[ -e "$TMP/shell.slow" ] && exec sleep 30
exec "\$@"
SH
  chmod +x "$TMP/fakeshell"

  FT=$TMP/slowtool
  # The INSTALL entry is listed first on purpose: the hardlink after it must still be done first.
  make_repo "$FT" '{"dir":"node_modules","lock":"composer.lock","strategy":"install","install":"mkdir -p node_modules && printf ok > node_modules/m"},
    {"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor"}'
  python3 - "$FT/.claude/worktree-profile.json" "$TMP/fakeshell" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["shell"] = sys.argv[2]
d["timeouts"]["bootstrapSeconds"] = 3
json.dump(d, open(f, "w"))
PYJ
  printf 'node_modules/\n' >> "$FT/.gitignore"
  git -C "$FT" add -A; git -C "$FT" commit -qm slow
  mkdir -p "$FT/vendor"; printf 'MAIN\n' > "$FT/vendor/autoload.php"
  WF=$FT/.claude/worktrees/slow
  git -C "$FT" worktree add -q "$WF" -b worktree-slow 2>/dev/null

  touch "$TMP/shell.slow"
  outF=$(start_hook "$WF"); errF=$(cat "$TMP/err")
  eq 'slow toolchain: the cheap hardlink is done although the install came first in deps[]' 'MAIN' \
    "$(cat "$WF/vendor/autoload.php" 2>/dev/null)"
  contains 'slow toolchain: the warm-up is timed and reported' 'toolchain: still not ready' "$errF"
  eq 'slow toolchain: the install that needs it was left alone' no \
    "$([ -e "$WF/node_modules/m" ] && echo yes || echo no)"
  contains 'slow toolchain: the session is told what is missing on stdout' \
    'node_modules missing (not installed yet).' "$outF"
  lacks '...and only what is missing — the hardlinked vendor is not named' 'vendor' "$outF"
  contains '...and how to finish it' 'Run /pitlane-finish' "$outF"
  eq '...in a single line of model context' 1 "$(printf '%s\n' "$outF" | wc -l | tr -d ' ')"

  # /pitlane-finish: no hook time limit, so the same toolchain now gets as long as it needs.
  rm -f "$TMP/shell.slow"
  outF=$( (cd "$WF" && bash "$HOOK" --finish </dev/null 2>"$TMP/err") ); rcF=$?; errF=$(cat "$TMP/err")
  eq '--finish exits 0' 0 "$rcF"
  eq '--finish reports the worktree complete as its only stdout' \
    'Pitlane: this worktree is fully set up.' "$outF"
  eq '--finish ran the install the hook had to skip' ok "$(cat "$WF/node_modules/m" 2>/dev/null)"
  contains '--finish warmed the toolchain first' 'toolchain: ready' "$errF"

  # A complete worktree: silent, and the toolchain is not even started.
  : > "$TMP/shell.log"
  outF=$(start_hook "$WF")
  eq 'a complete worktree gets no notice on stdout' '' "$outF"
  eq 'and a complete re-entry never starts the toolchain' '' "$(cat "$TMP/shell.log")"

  outF=$( (cd "$FT" && bash "$HOOK" --finish </dev/null 2>/dev/null) )
  contains '--finish outside a worktree says so instead of doing nothing silently' \
    'from inside a worktree' "$outF"

  # THE SEED HAS ITS OWN BUDGET. An install that eats all of bootstrapSeconds used to leave the
  # seed nothing; now it gets its seedSeconds on top, so the worktree still gets its databases.
  SB=$TMP/seedbudget
  make_rt_repo "$SB" ',
    "seed": ".claude/worktree-seed.sh"'
  python3 - "$SB/.claude/worktree-profile.json" <<'PYJ'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d["deps"][0]["install"] = "exec sleep 30"
d.setdefault("timeouts", {})["bootstrapSeconds"] = 2
d["timeouts"]["seedSeconds"] = 20
json.dump(d, open(f, "w"))
PYJ
  # shellcheck disable=SC2016  # $WT_PATH belongs to the seed script, not this suite
  printf '#!/usr/bin/env bash\nprintf seeded > "$WT_PATH/seeded.txt"\n' > "$SB/.claude/worktree-seed.sh"
  chmod +x "$SB/.claude/worktree-seed.sh"
  git -C "$SB" add -A; git -C "$SB" commit -qm seed
  WSB=$SB/.claude/worktrees/sb
  git -C "$SB" worktree add -q "$WSB" -b worktree-sb 2>/dev/null
  outSB=$(start_hook "$WSB")
  eq 'the seed still runs when installs use up the whole bootstrap budget' seeded \
    "$(cat "$WSB/seeded.txt" 2>/dev/null)"
  contains '...and the notice names only the install' '— vendor missing (not installed yet).' "$outSB"
  lacks '...not the databases, which are done' 'databases (seed' "$outSB"
fi

# ---------------------------------------------------------------------------
# Low memory — the setup steps back instead of crowding out the desktop
# ---------------------------------------------------------------------------
# A fake /proc/meminfo with 1.5 GiB free of 16: below what a heavy step is started with.
printf 'MemTotal: 16777216 kB\nMemAvailable: 1572864 kB\n' > "$TMP/meminfo.low"
printf 'MemTotal: 16777216 kB\nMemAvailable: 8388608 kB\n' > "$TMP/meminfo.ok"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$TMP/passshell"; chmod +x "$TMP/passshell"
LM=$TMP/lowmem
make_repo "$LM" '{"dir":"node_modules","lock":"composer.lock","strategy":"install","install":"mkdir -p node_modules && printf ok > node_modules/m"},
    {"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor"}'
python3 - "$LM/.claude/worktree-profile.json" "$TMP/passshell" <<'PYJ'
import json, sys
f = sys.argv[1]; d = json.load(open(f)); d["shell"] = sys.argv[2]; json.dump(d, open(f, "w"))
PYJ
printf 'node_modules/\n' >> "$LM/.gitignore"
git -C "$LM" add -A; git -C "$LM" commit -qm lowmem
mkdir -p "$LM/vendor"; printf 'MAIN\n' > "$LM/vendor/autoload.php"
WLM=$LM/.claude/worktrees/lm
git -C "$LM" worktree add -q "$WLM" -b worktree-lm 2>/dev/null

outL=$(WT_MEMINFO=$TMP/meminfo.low start_hook "$WLM"); rcL=$?; errL=$(cat "$TMP/err")
eq 'low memory: the session still starts' 0 "$rcL"
eq 'low memory: the hardlink, which needs no memory to speak of, is still done' MAIN \
  "$(cat "$WLM/vendor/autoload.php" 2>/dev/null)"
eq 'low memory: the toolchain and the install are not started' no \
  "$([ -e "$WLM/node_modules/m" ] && echo yes || echo no)"
contains 'low memory: stderr says why' 'MiB of memory is free' "$errL"
lacks '...and does not call the toolchain broken' 'failed to start' "$errL"
contains 'low memory: the session is told what is missing' '— node_modules missing (not installed yet).' "$outL"

outL=$(WT_MEMINFO=$TMP/meminfo.ok start_hook "$WLM")
eq 'with memory back, the next session completes it' ok "$(cat "$WLM/node_modules/m" 2>/dev/null)"
eq '...and is silent again' '' "$outL"

# ---------------------------------------------------------------------------
# The background hand-off: the session starts after the cheap steps, the rest finishes behind it
# ---------------------------------------------------------------------------
#
# Claude Code holds the first prompt until SessionStart returns, so the start-up run does config,
# hardlinks and the env overrides, and a detached `--finish --background` does the installs and the
# seed. These tests turn the hand-off back on; everything above runs with it off.

BG=$TMP/bg
make_rt_repo "$BG" ',
    "seed": ".claude/worktree-seed.sh"'
python3 - "$BG/.claude/worktree-profile.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["deps"] = [
  {"dir": "vendor", "lock": "composer.lock", "strategy": "hardlink",
   "install": "mkdir -p vendor && rm -f vendor/autoload.php && printf installed > vendor/autoload.php"},
  {"dir": "node_modules", "lock": "composer.lock", "strategy": "install",
   "install": "sleep 3 && mkdir -p node_modules && printf ok > node_modules/m"},
]
json.dump(d, open(p, "w"), indent=2)
EOF
printf 'node_modules/\nseeded.txt\n' >> "$BG/.gitignore"
# shellcheck disable=SC2016  # $WT_PATH and $DATABASE_NAME must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nsleep 1\nprintf "%%s\\n" "$WT_SLUG" > "$WT_PATH/seeded.txt"\n' > "$BG/.claude/worktree-seed.sh"
chmod +x "$BG/.claude/worktree-seed.sh"
git -C "$BG" add -A; git -C "$BG" commit -qm bg
mkdir -p "$BG/vendor"; printf 'MAIN\n' > "$BG/vendor/autoload.php"
WBG=$BG/.claude/worktrees/bg
git -C "$BG" worktree add -q "$WBG" -b worktree-bg 2>/dev/null
GDBG=$(git -C "$WBG" rev-parse --absolute-git-dir)

t0=$(date +%s)
outB=$(PITLANE_BACKGROUND=on start_hook "$WBG"); rcB=$?; errB=$(cat "$TMP/err")
t1=$(date +%s)
eq 'background: the session starts' 0 "$rcB"
eq 'background: the hook returns before the slow install could have finished' yes \
  "$([ $((t1 - t0)) -lt 3 ] && echo yes || echo no)"
eq 'background: the hardlink is done before the session starts' MAIN "$(cat "$WBG/vendor/autoload.php" 2>/dev/null)"
ne 'background: so is the port' '' "$(envval "$WBG" SERVER_PORT)"
eq 'background: the install is not done in the hook' no "$([ -e "$WBG/node_modules/m" ] && echo yes || echo no)"
eq 'background: nor is the seed' no "$([ -e "$WBG/seeded.txt" ] && echo yes || echo no)"
contains 'background: the session is told it is in progress' 'still being set up in the background — node_modules missing (still installing), databases missing (seeding).' "$outB"
contains '...and what to run before work that needs it' '/pitlane-finish' "$outB"
lacks '...and is not told it is broken' 'not fully set up yet' "$outB"
contains 'background: stderr names the log' 'worktree-bootstrap.log' "$errB"
pidB=$(tr -cd '0-9' < "$GDBG/worktree-bootstrap.pid" 2>/dev/null)
eq 'background: its pid is recorded and alive' yes "$([ -n "$pidB" ] && kill -0 "$pidB" 2>/dev/null && echo yes || echo no)"

# A second session while it runs starts no second run.
PITLANE_BACKGROUND=on start_hook "$WBG" >/dev/null
eq 'background: a second session does not start a second run' "$pidB" \
  "$(tr -cd '0-9' < "$GDBG/worktree-bootstrap.pid" 2>/dev/null)"

# Teardown keeps out while it works: it holds the worktree's bootstrap lock.
eq 'background: it holds the worktree lock, which teardown honours' held \
  "$(flock -n "$GDBG/worktree-bootstrap-state.lock" true 2>/dev/null && echo free || echo held)"

# /pitlane-finish waits for it rather than racing it, and reports the finished worktree.
outF=$( cd "$WBG" && bash "$HOOK" --finish 2>"$TMP/err" ); errF=$(cat "$TMP/err")
contains 'finish: waits for the background run' 'still running — waiting for it' "$errF"
eq 'finish: then reports a complete worktree' 'Pitlane: this worktree is fully set up.' "$outF"
eq 'background: the install ran' ok "$(cat "$WBG/node_modules/m" 2>/dev/null)"
eq 'background: the seed ran' bg "$(cat "$WBG/seeded.txt" 2>/dev/null)"
eq 'background: the pid record is cleared when it ends' no "$([ -e "$GDBG/worktree-bootstrap.pid" ] && echo yes || echo no)"
contains 'background: its log has the progress' 'node_modules: installed' "$(cat "$GDBG/worktree-bootstrap.log" 2>/dev/null)"
lacks 'background: nothing lands in the checkout' 'worktree-bootstrap' "$(git -C "$WBG" status --porcelain)"

outB=$(PITLANE_BACKGROUND=on start_hook "$WBG")
eq 'background: a complete worktree starts silent' '' "$outB"
eq '...and starts no run' no "$([ -e "$GDBG/worktree-bootstrap.pid" ] && echo yes || echo no)"

# A session starting mid-run asks the running one to go round again: it may need work the run has
# already walked past. And a recycled pid that is some other bootstrap does not count as the run.
rm -rf "$WBG/node_modules"
PITLANE_BACKGROUND=on start_hook "$WBG" >/dev/null
PITLANE_BACKGROUND=on start_hook "$WBG" >/dev/null
( cd "$WBG" && bash "$HOOK" --finish >/dev/null 2>&1 )
contains 'background: a session mid-run makes it go round again' 'going round once more' \
  "$(cat "$GDBG/worktree-bootstrap.log" 2>/dev/null)"
eq '...and the request is consumed' no "$([ -e "$GDBG/worktree-bootstrap.again" ] && echo yes || echo no)"
bash -c 'exec -a "bash bootstrap.sh" sleep 5' & decoy=$!
printf '%s\n' "$decoy" > "$GDBG/worktree-bootstrap.pid"
( cd "$WBG" && bash "$HOOK" --finish >/dev/null 2>"$TMP/err" ); errD=$(cat "$TMP/err")
lacks 'background: a pid that is not a background run is not waited on' 'waiting for it' "$errD"
kill "$decoy" 2>/dev/null; wait "$decoy" 2>/dev/null; rm -f "$GDBG/worktree-bootstrap.pid"

# The --finish payload must not need python3: a jq-only host would otherwise get an empty payload,
# and the background run would do nothing at all.
if command -v jq >/dev/null 2>&1; then
  mkdir -p "$TMP/nopy"; printf '#!/bin/sh\nexit 127\n' > "$TMP/nopy/python3"; chmod +x "$TMP/nopy/python3"
  outJ=$( cd "$WBG" && PATH=$TMP/nopy:$PATH bash "$HOOK" --finish 2>"$TMP/err" )
  eq 'finish: works with jq and no python3' 'Pitlane: this worktree is fully set up.' "$outJ"
fi

# A hardlink that must fall back to an install is just as slow, so it is deferred too.
printf 'CHANGED\n' > "$WBG/composer.lock"
outB=$(PITLANE_BACKGROUND=on start_hook "$WBG"); errB=$(cat "$TMP/err")
contains 'background: a hardlink falling back to an install is deferred' 'vendor: to be installed in the background' "$errB"
contains '...and named in the notice' 'vendor missing (still installing)' "$outB"
( cd "$WBG" && bash "$HOOK" --finish >/dev/null 2>&1 )
eq '...and installed by the background run' installed "$(cat "$WBG/vendor/autoload.php" 2>/dev/null)"
eq "...leaving the main checkout's copy alone" MAIN "$(cat "$BG/vendor/autoload.php" 2>/dev/null)"
git -C "$WBG" checkout -q composer.lock

# ---------------------------------------------------------------------------
# Verify decides, not the install's exit code; a failure that would repeat is not retried
# ---------------------------------------------------------------------------

# A package manager that installs everything, then exits 1 on a policy check.
WRN=$TMP/wrn
make_repo "$WRN" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"printf x >> $TMP/wrn-count; mkdir -p vendor && printf ok > vendor/autoload.php; echo ERR_FAKE_IGNORED_BUILDS >&2; exit 1\",\"verify\":\"test -r vendor/autoload.php\"}"
WWR=$WRN/.claude/worktrees/wrn
git -C "$WRN" worktree add -q "$WWR" -b worktree-wrn 2>/dev/null
outW=$(start_hook "$WWR"); errW=$(cat "$TMP/err")
eq 'warn: an install that exits 1 with a passing verify is named as ready with warnings, with its reason' \
  'Pitlane: this worktree is set up, with warnings — vendor ready with warnings (ERR_FAKE_IGNORED_BUILDS). It is usable; tell the user if it matters for the task.' "$outW"
contains '...and stderr says it installed with warnings' 'installed with warnings' "$errW"
outF=$( cd "$WWR" && bash "$HOOK" --finish 2>"$TMP/err" )
eq 'warn: /pitlane-finish reports it set up, but not as a bare "fully set up"' \
  'Pitlane: this worktree is set up, with warnings — vendor ready with warnings (ERR_FAKE_IGNORED_BUILDS).' "$outF"
eq '...without re-running the install' x "$(cat "$TMP/wrn-count")"

# One that exits 1 having installed nothing: failed, and /pitlane-finish does not pay for it again.
FLD=$TMP/fld
make_repo "$FLD" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"printf x >> $TMP/fld-count; echo 'error: registry unreachable' >&2; exit 1\",\"verify\":\"test -r vendor/autoload.php\"}"
WFL=$FLD/.claude/worktrees/fld
git -C "$FLD" worktree add -q "$WFL" -b worktree-fld 2>/dev/null
outW=$(start_hook "$WFL")
contains 'failed: the session is told the dependency is missing, and why' \
  'not fully set up — vendor missing (install failed: error: registry unreachable).' "$outW"
# Only a standing failure is left, which /pitlane-finish would not retry: the session must not be
# sent there as if it would fix it.
lacks '...and is not told /pitlane-finish will complete it' 'Run /pitlane-finish to complete it' "$outW"
contains '...but that it can retry it on the user'"'"'s word' '/pitlane-finish can retry it on their word' "$outW"
eq '...in one line' 1 "$(printf '%s\n' "$outW" | wc -l | tr -d ' ')"
outF=$( cd "$WFL" && bash "$HOOK" --finish 2>"$TMP/err" ); errF=$(cat "$TMP/err")
contains 'failed: /pitlane-finish still reports it missing, with the recorded reason' \
  'Pitlane: still not complete — vendor missing (install failed: error: registry unreachable).' "$outF"
contains '...and names the retry as the user'"'"'s call' '--finish --retry-failed` only on the user'"'"'s word' "$outF"
eq '...without re-running an install that would fail the same way' x "$(cat "$TMP/fld-count")"
contains '...saying why, and what would make a retry worth it' 'error: registry unreachable) — not retrying' "$errF"
# With the hand-off on, a standing failure starts no background run that would only repeat that.
outB=$(PITLANE_BACKGROUND=on start_hook "$WFL")
GDFL=$(git -C "$WFL" rev-parse --absolute-git-dir)
eq 'failed: a standing failure starts no background run' no "$([ -e "$GDFL/worktree-bootstrap.pid" ] && echo yes || echo no)"
lacks '...and the session is not told one is in progress' 'in the background' "$outB"
# A changed lockfile is worth a retry.
printf 'LOCK2\n' > "$WFL/composer.lock"
( cd "$WFL" && bash "$HOOK" --finish >/dev/null 2>&1 )
eq 'failed: a changed lockfile retries the install' xx "$(cat "$TMP/fld-count")"
# Nothing automatic can tell a network outage from a broken lockfile, so a failure that stands is
# retried only when asked: a plain --finish leaves it, and names the way to ask.
outF=$( cd "$WFL" && bash "$HOOK" --finish 2>"$TMP/err" ); errF=$(cat "$TMP/err")
eq 'failed: a plain --finish does not retry a standing failure' xx "$(cat "$TMP/fld-count")"
contains '...and names the retry' '--finish --retry-failed' "$errF"
mkdir -p "$TMP/fld-tmp"
outR=$( cd "$WFL" && TMPDIR=$TMP/fld-tmp bash "$HOOK" --finish --retry-failed 2>"$TMP/err" ); errR=$(cat "$TMP/err")
eq 'failed: --finish --retry-failed re-runs it' xxx "$(cat "$TMP/fld-count")"
contains '...reporting it still missing' 'Pitlane: still not complete — vendor missing (install failed: error: registry unreachable)' "$outR"
contains "...with the install's own output in the log" 'error: registry unreachable' "$errR"
contains '...the output captured in the git dir' 'error: registry unreachable' \
  "$(cat "$GDFL/worktree-bootstrap.install.vendor.log" 2>/dev/null)"
eq '...and nothing left in TMPDIR' '' "$(ls -A "$TMP/fld-tmp")"

# ---------------------------------------------------------------------------
# An install that changes a tracked file is named, and never restored
# ---------------------------------------------------------------------------

TRK=$TMP/trk
make_repo "$TRK" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"mkdir -p vendor && touch vendor/autoload.php && echo '# placeholder' >> .gitignore\",\"verify\":\"test -r vendor/autoload.php\"},{\"dir\":\"node_modules\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"exit 1\"}"
WTK=$TRK/.claude/worktrees/trk
git -C "$TRK" worktree add -q "$WTK" -b worktree-trk 2>/dev/null
start_hook "$WTK" >/dev/null
contains 'tracked: the start-up run names the tracked file the install changed' \
  'the install changed tracked files: .gitignore' "$(cat "$TMP/err")"
contains '...and leaves it changed' '# placeholder' "$(cat "$WTK/.gitignore")"
outF=$( cd "$WTK" && bash "$HOOK" --finish 2>/dev/null )
contains 'tracked: the --finish summary counts it beside what is missing' \
  'Pitlane: still not complete — node_modules missing (install failed: exit 1); an install changed 1 tracked file (bash "' "$outF"
contains '...and says how to see them' '--changed lists them)' "$outF"
lacks '...without the name, which is branch content' '.gitignore' "$outF"
eq 'tracked: --changed prints it, one path per line' '.gitignore' "$( cd "$WTK" && bash "$HOOK" --changed 2>/dev/null )"
eq '...from a subdirectory too' '.gitignore' "$( cd "$WTK/vendor" && bash "$HOOK" --changed 2>/dev/null )"
git -C "$WTK" checkout -q -- .gitignore
eq '...and nothing once the user restored it' '' "$( cd "$WTK" && bash "$HOOK" --changed 2>/dev/null )"
outF=$( cd "$WTK" && bash "$HOOK" --finish 2>/dev/null )
contains '...nor in the summary' 'Pitlane: still not complete — node_modules missing (install failed: exit 1).' "$outF"
lacks '...which no longer mentions changed files' 'tracked file' "$outF"
eq 'tracked: --changed outside a repository prints no path' '' "$( cd "$TMP" && bash "$HOOK" --changed 2>"$TMP/err" )"
contains '...and says why on stderr' 'not inside a git repository' "$(cat "$TMP/err")"

# A worktree that is complete but whose install changed a tracked file is not "clean": the start-up
# notice and the --finish line both say so, with the count, until the file is restored.
TRC=$TMP/trc
make_repo "$TRC" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"mkdir -p vendor && touch vendor/autoload.php && echo '# placeholder' >> .gitignore && echo '# x' >> .worktreeinclude\",\"verify\":\"test -r vendor/autoload.php\"}"
WTC=$TRC/.claude/worktrees/trc
git -C "$TRC" worktree add -q "$WTC" -b worktree-trc 2>/dev/null
outS=$(start_hook "$WTC")
eq 'changed, complete: the session is told how many tracked files an install changed' \
  "Pitlane: this worktree is set up, with warnings — an install changed 2 tracked files (/pitlane-finish lists them, and restores one only on the user's word). It is usable; tell the user if it matters for the task." "$outS"
outF=$( cd "$WTC" && bash "$HOOK" --finish 2>/dev/null )
eq 'changed, complete: --finish does not call it fully set up' \
  "Pitlane: this worktree is set up, with warnings — an install changed 2 tracked files (bash \"$HOOK\" --changed lists them)." "$outF"
git -C "$WTC" checkout -q -- .gitignore
contains '...and counts only what is still changed' 'an install changed 1 tracked file (' "$(start_hook "$WTC")"
git -C "$WTC" checkout -q -- .worktreeinclude
eq '...and once restored, a clean complete worktree starts silent' '' "$(start_hook "$WTC")"
eq '...and --finish says fully set up' 'Pitlane: this worktree is fully set up.' \
  "$( cd "$WTC" && bash "$HOOK" --finish 2>/dev/null )"

# Lockfile drift is the MAIN checkout's lockfile moving on from what calibration read; a branch's own
# lockfile differing is not drift. And a hardlinked virtualenv is called out, once.
DRF=$TMP/drf
LCK=$(printf 'LOCK\n' | cksum)
make_repo "$DRF" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"mkdir -p vendor\",\"lockChecksum\":\"$LCK\"},
  {\"dir\":\".venv\",\"lock\":\"composer.lock\",\"strategy\":\"hardlink\",\"install\":\"mkdir -p .venv\"}"
printf '.venv/\n' >> "$DRF/.gitignore"; git -C "$DRF" commit -qam venv
WDR=$DRF/.claude/worktrees/drf
git -C "$DRF" worktree add -q "$WDR" -b worktree-drf 2>/dev/null
printf 'BRANCH\n' > "$WDR/composer.lock"
start_hook "$WDR" >/dev/null; errD=$(cat "$TMP/err")
lacks "drift: a branch whose lockfile differs from main's is not told to re-run setup" 'changed since calibration' "$errD"
eq 'venv: a hardlinked .venv is warned about, once' 1 "$(printf '%s\n' "$errD" | grep -c 'Python virtualenv')"
printf 'MAIN2\n' > "$DRF/composer.lock"
start_hook "$WDR" >/dev/null
contains "drift: the main checkout's lockfile moving on is reported" \
  'composer.lock in the main checkout has changed since calibration' "$(cat "$TMP/err")"

# The list is capped, so the line stays short however many dependencies are missing.
CAP=$TMP/cap
make_repo "$CAP" '{"dir":"d1","lock":"composer.lock","strategy":"install","install":"exit 1"},
  {"dir":"d2","lock":"composer.lock","strategy":"install","install":"exit 2"},
  {"dir":"d3","lock":"composer.lock","strategy":"install","install":"exit 3"},
  {"dir":"d4","lock":"composer.lock","strategy":"install","install":"exit 4"},
  {"dir":"d5","lock":"composer.lock","strategy":"install","install":"exit 5"}'
WCP=$CAP/.claude/worktrees/cap
git -C "$CAP" worktree add -q "$WCP" -b worktree-cap 2>/dev/null
outC=$(start_hook "$WCP")
contains 'cap: the first three are named, then a count' \
  '— d1 missing (install failed: exit 1), d2 missing (install failed: exit 2), d3 missing (install failed: exit 3) and 2 more.' "$outC"
lacks '...and the fourth is not' 'd4' "$outC"
eq '...in one line' 1 "$(printf '%s\n' "$outC" | wc -l | tr -d ' ')"

# A tracked file named `*` or `:(glob)*` is one file to restore, not a pattern matching every file.
STAR=$TMP/star
NL_=$'\n'
make_repo "$STAR" "{\"dir\":\"vendor\",\"lock\":\"composer.lock\",\"strategy\":\"install\",\"install\":\"mkdir -p vendor && touch vendor/autoload.php && echo x >> '*' && echo x >> ':(glob)*' && echo x >> other.txt\",\"verify\":\"test -r vendor/autoload.php\"}"
printf 'star\n' > "$STAR/*"; printf 'glob\n' > "$STAR/:(glob)*"; printf 'other\n' > "$STAR/other.txt"
git -C "$STAR" --literal-pathspecs add -- '*' ':(glob)*' other.txt; git -C "$STAR" commit -qm files
WTS=$STAR/.claude/worktrees/star
git -C "$STAR" worktree add -q "$WTS" -b worktree-star 2>/dev/null
start_hook "$WTS" >/dev/null
eq 'restore: every file the install changed is listed' "*${NL_}:(glob)*${NL_}other.txt" \
  "$( cd "$WTS" && bash "$HOOK" --changed 2>/dev/null | LC_ALL=C sort )"
outR=$( cd "$WTS" && bash "$HOOK" --restore '*' 2>/dev/null ); rc=$?
eq 'restore: --restore of the file named * succeeds' 0 "$rc"
contains '...and says what it restored' 'restored *' "$outR"
eq '...that one file is back to its committed content' 'star' "$(cat "$WTS/*")"
eq '...and the other file is untouched' "other${NL_}x" "$(cat "$WTS/other.txt")"
eq '...and still listed' ":(glob)*${NL_}other.txt" "$( cd "$WTS" && bash "$HOOK" --changed 2>/dev/null | LC_ALL=C sort )"
# Pathspec magic is not obeyed either: without --literal-pathspecs this one restores every file.
( cd "$WTS" && bash "$HOOK" --restore ':(glob)*' >/dev/null 2>&1 )
eq 'restore: the file named :(glob)* is restored' 'glob' "$(cat "$WTS/:(glob)*")"
eq '...and the other file is still untouched' "other${NL_}x" "$(cat "$WTS/other.txt")"
( cd "$WTS" && bash "$HOOK" --restore .gitignore >/dev/null 2>&1 ); rc=$?
eq 'restore: a path no install changed is refused with exit 1' 1 "$rc"

# ---------------------------------------------------------------------------
# The approval gate: nothing a profile names runs until that content is approved
# ---------------------------------------------------------------------------
#
# The threat is `claude -w "#N"`: the worktree is a stranger's pull request, and its profile and the
# scripts that profile names are the stranger's files. Everything above trusts its fixtures with
# PITLANE_TRUST_PROFILES; here it is unset, as it is for a real developer.

gated_hook() ( unset PITLANE_TRUST_PROFILES; start_hook "$1" )
gated_cli() ( unset PITLANE_TRUST_PROFILES; cd "$1" && shift && bash "$HOOK" "$@" 2>"$TMP/err" )
fp_of() { sed -n 's/^NOT approved (fingerprint \([0-9a-f]*\)).*/\1/p'; }

AP=$TMP/ap
make_rt_repo "$AP" ',
    "seed": ".claude/worktree-seed.sh",
    "teardown": ".claude/worktree-teardown.sh"'
printf 'seeded.txt\n' >> "$AP/.gitignore"
# shellcheck disable=SC2016  # $WT_PATH must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$WT_SLUG" > "$WT_PATH/seeded.txt"\n' > "$AP/.claude/worktree-seed.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$AP/.claude/worktree-teardown.sh"
chmod +x "$AP/.claude/worktree-seed.sh" "$AP/.claude/worktree-teardown.sh"
git -C "$AP" add -A; git -C "$AP" commit -qm scripts
APBASE=$(git -C "$AP" rev-parse HEAD)

# A worktree of the developer's own, nothing approved yet: nothing runs, and the session is told
# why in words that do not invite it to work around the gate.
WAP=$AP/.claude/worktrees/own
git -C "$AP" worktree add -q "$WAP" -b worktree-own 2>/dev/null
outA=$(gated_hook "$WAP"); errA=$(cat "$TMP/err")
eq 'approval: an unapproved install does not run' no "$([ -e "$WAP/vendor/marker" ] && echo yes || echo no)"
eq 'approval: nor does an unapproved seed' no "$([ -e "$WAP/seeded.txt" ] && echo yes || echo no)"
ne 'approval: the steps that run nothing still happen (the port)' '' "$(envval "$WAP" SERVER_PORT)"
contains 'approval: stderr says the commands are not approved' 'not approved in this form' "$errA"
contains 'approval: the session is told nothing was run' 'setup commands were NOT run — vendor missing (held back), databases missing (held back).' "$outA"
contains '...and not to do it by hand or approve on its own' 'Do not approve it, run those commands' "$outA"
contains '...and where approval happens' '/pitlane-finish' "$outA"

# --finish holds back too, and says so.
outF=$(gated_cli "$WAP" --finish)
contains 'approval: /pitlane-finish does not run unapproved commands' 'not run — the profile' "$outF"
eq '...the install is still not done' no "$([ -e "$WAP/vendor/marker" ] && echo yes || echo no)"

# Review shows what would run, and an approval must name exactly what was reviewed.
outR=$(gated_cli "$WAP" --review)
contains 'review: shows the install command' 'vendor (install): install: mkdir -p vendor' "$outR"
contains 'review: shows the seed script' "seed script: $WAP/.claude/worktree-seed.sh" "$outR"
contains 'review: shows the teardown script' "teardown script: $WAP/.claude/worktree-teardown.sh" "$outR"
FP=$(printf '%s\n' "$outR" | fp_of)
eq 'review: prints a sha256 fingerprint' 64 "${#FP}"
outW=$(gated_cli "$WAP" --approve 0000000000000000000000000000000000000000000000000000000000000000)
contains 'approve: a fingerprint that is not the current one is refused' 'is not the current fingerprint' "$outW"
outW=$(gated_cli "$WAP" --approve)
contains 'approve: no fingerprint at all is refused' 'is not the current fingerprint' "$outW"
APSTORE=$(git -C "$AP" rev-parse --git-common-dir)/pitlane-approved
case $APSTORE in /*) ;; *) APSTORE=$AP/$APSTORE ;; esac
eq '...and records nothing' no "$([ -s "$APSTORE" ] && echo yes || echo no)"
outW=$(gated_cli "$WAP" --approve "$FP")
contains 'approve: the reviewed fingerprint is approved' 'Pitlane: approved' "$outW"
contains 'approve: recorded in the shared git directory' "$FP" "$(cat "$APSTORE" 2>/dev/null)"
eq '...and nothing lands in the checkout' '' "$(git -C "$WAP" status --porcelain)"
contains 'review: now reports it approved' 'Approved: this exact content is approved' "$(gated_cli "$WAP" --review)"

outF=$(gated_cli "$WAP" --finish)
eq 'approval: once approved, /pitlane-finish completes the worktree' 'Pitlane: this worktree is fully set up.' "$outF"
eq '...the install ran' ok "$(cat "$WAP/vendor/marker" 2>/dev/null)"
eq '...and the seed' own "$(cat "$WAP/seeded.txt" 2>/dev/null)"

# Approval is by content: a second worktree with the same bytes needs nothing more.
WAP2=$AP/.claude/worktrees/own2
git -C "$AP" worktree add -q "$WAP2" -b worktree-own2 2>/dev/null
outA=$(gated_hook "$WAP2")
eq 'approval: another worktree with the same content runs at once, silently' '' "$outA"
eq '...its install ran' ok "$(cat "$WAP2/vendor/marker" 2>/dev/null)"

# The developer's own edit to the profile needs approving again, like any other change.
python3 - "$WAP2/.claude/worktree-profile.json" <<'EOF'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["deps"][0]["install"] = "mkdir -p vendor && printf edited > vendor/marker"
json.dump(d, open(p, "w"), indent=2)
EOF
outA=$(gated_hook "$WAP2")
eq 'approval: an edited install command does not run until re-approved' ok "$(cat "$WAP2/vendor/marker" 2>/dev/null)"
contains '...and the session is told' 'setup commands were NOT run' "$outA"
git -C "$WAP2" checkout -q .claude/worktree-profile.json

# THE PULL REQUEST, the way `claude -w "#1"` checks it out: detached at the PR's head. Three PRs,
# each changing one executable thing and leaving everything else as approved.
pr_worktree() {  # $1 = PR number; the fixture's edits are made by the caller in $AP on a branch
  git -C "$AP" commit -qam "pr $1"
  git -C "$AP" update-ref "refs/pull/$1/head" HEAD
  git -C "$AP" checkout -q --detach "$APBASE"
  git -C "$AP" worktree add -q --detach "$AP/.claude/worktrees/pr-$1" "refs/pull/$1/head" 2>/dev/null
}
git -C "$AP" checkout -q -b pr-src-1 "$APBASE"
python3 - "$AP/.claude/worktree-profile.json" <<EOF
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["deps"][0]["install"] = "touch $TMP/pwned-install; mkdir -p vendor"
json.dump(d, open(p, "w"), indent=2)
EOF
pr_worktree 1
git -C "$AP" checkout -q -b pr-src-2 "$APBASE"
printf '#!/usr/bin/env bash\ntouch %s/pwned-seed\n' "$TMP" > "$AP/.claude/worktree-seed.sh"
pr_worktree 2
git -C "$AP" checkout -q -b pr-src-3 "$APBASE"
printf '#!/usr/bin/env bash\ntouch %s/pwned-teardown\n' "$TMP" > "$AP/.claude/worktree-teardown.sh"
pr_worktree 3

outP=$(gated_hook "$AP/.claude/worktrees/pr-1")
eq "approval: a PR's rewritten install command does not run" no "$([ -e "$TMP/pwned-install" ] && echo yes || echo no)"
contains '...and the reviewer is told' 'setup commands were NOT run' "$outP"
outP=$(gated_hook "$AP/.claude/worktrees/pr-2")
eq "approval: a PR that rewrites only the seed script does not get it run" no "$([ -e "$TMP/pwned-seed" ] && echo yes || echo no)"
eq '...nor, since the gate is all-or-nothing, the approved install' no \
  "$([ -e "$AP/.claude/worktrees/pr-2/vendor/marker" ] && echo yes || echo no)"
contains '...and the reviewer is told' 'setup commands were NOT run' "$outP"

# The teardown script is gated where it runs: a PR worktree that was seeded under an approved
# script and then changed only its teardown script does not get the new one run on removal.
TEARDOWN_HOOK=$(dirname "$HOOK")/teardown.sh
WP3=$AP/.claude/worktrees/pr-3
git -C "$WP3" checkout -q "$APBASE" -- .claude/worktree-teardown.sh
gated_cli "$WP3" --approve "$(gated_cli "$WP3" --review | fp_of)" >/dev/null
gated_hook "$WP3" >/dev/null
eq '...(setup: the reviewer approved this PR commit with the original scripts, and it was seeded)' pr_3 "$(cat "$WP3/seeded.txt" 2>/dev/null)"
git -C "$WP3" checkout -q HEAD -- .claude/worktree-teardown.sh
( unset PITLANE_TRUST_PROFILES; cd "$AP" \
  && printf '%s' "{\"hook_event_name\":\"WorktreeRemove\",\"worktree_path\":\"$WP3\",\"cwd\":\"$AP\"}" \
  | bash "$TEARDOWN_HOOK" >/dev/null 2>"$TMP/err" ); errT=$(cat "$TMP/err")
eq "approval: a PR's rewritten teardown script does not run on removal" no "$([ -e "$TMP/pwned-teardown" ] && echo yes || echo no)"
contains '...and teardown says why' 'is not approved in' "$errT"

# WorktreeCreate holds back the same way, and its stdout stays the path alone.
git -C "$AP" checkout -q --detach "$APBASE"
git -C "$AP" branch -q worktree-pr-4 refs/pull/1/head
outC=$( ( unset PITLANE_TRUST_PROFILES; cd "$AP" \
  && printf '%s' "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"pr-4\",\"cwd\":\"$AP\"}" \
  | bash "$HOOK" 2>"$TMP/err" ) )
eq 'approval: WorktreeCreate prints the path and nothing else' "$AP/.claude/worktrees/pr-4" "$outC"
eq "...and does not run the branch's install" no "$([ -e "$TMP/pwned-install" ] && echo yes || echo no)"

# No background run is started for work that is waiting on an approval: it could do nothing.
outP=$( ( unset PITLANE_TRUST_PROFILES; PITLANE_BACKGROUND=on start_hook "$AP/.claude/worktrees/pr-1" ) )
GDP1=$(git -C "$AP/.claude/worktrees/pr-1" rev-parse --absolute-git-dir)
eq 'approval: no background run is started while approval is pending' no \
  "$([ -e "$GDP1/worktree-bootstrap.pid" ] && echo yes || echo no)"
contains '...and the session is told why, not that setup is under way' 'setup commands were NOT run' "$outP"

# A PR that changes NOTHING Pitlane fingerprints still does not inherit the developer's approval: an
# approved install would run its package scripts and toolchain files. A PR worktree's approval is
# bound to its commit, and each push needs its own.
git -C "$AP" checkout -q -b pr-src-5 "$APBASE"
printf 'pr five\n' > "$AP/README"; git -C "$AP" add README
pr_worktree 5
WP5=$AP/.claude/worktrees/pr-5
outP=$(gated_hook "$WP5")
eq "approval: a PR with the developer's approved content is still held back" no "$([ -e "$WP5/vendor/marker" ] && echo yes || echo no)"
contains '...and the reviewer is told' 'setup commands were NOT run' "$outP"
outR=$(gated_cli "$WP5" --review)
contains 'review: a PR worktree is flagged, with what an install would run' 'pull-request worktree: approving covers this commit only' "$outR"
gated_cli "$WP5" --approve "$(printf '%s\n' "$outR" | fp_of)" >/dev/null
gated_hook "$WP5" >/dev/null
eq 'approval: once this PR commit is approved, it is set up' ok "$(cat "$WP5/vendor/marker" 2>/dev/null)"
printf 'push two\n' >> "$WP5/README"; git -C "$WP5" commit -qam 'push two'
rm -rf "$WP5/vendor"
outP=$(gated_hook "$WP5")
eq "approval: the PR's next push needs approving again" no "$([ -e "$WP5/vendor/marker" ] && echo yes || echo no)"

# A fork's PR checked out with `gh pr checkout` into an ordinarily named worktree is a PR too: gh
# records its upstream as the pull ref, in the shared config.
WGH=$AP/.claude/worktrees/review
# At the PR's second push, which nobody approved (its first commit was approved above, and that
# approval rightly covers any worktree at that commit with that content).
git -C "$AP" worktree add -q "$WGH" -b gh-pr-5 "$(git -C "$WP5" rev-parse HEAD)" 2>/dev/null
git -C "$AP" config branch.gh-pr-5.merge refs/pull/5/head
git -C "$AP" config branch.gh-pr-5.remote origin
outP=$(gated_hook "$WGH")
eq "approval: a gh-checked-out fork PR does not inherit the developer's approval" no "$([ -e "$WGH/vendor/marker" ] && echo yes || echo no)"
contains 'review: it is flagged as a pull request' 'pull-request worktree' "$(gated_cli "$WGH" --review)"

# The developer's re-approved edit does run.
python3 - "$WAP2/.claude/worktree-profile.json" <<'EOF2'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["deps"][0]["install"] = "mkdir -p vendor && printf edited > vendor/marker"
json.dump(d, open(p, "w"), indent=2)
EOF2
gated_cli "$WAP2" --approve "$(gated_cli "$WAP2" --review | fp_of)" >/dev/null
gated_hook "$WAP2" >/dev/null
eq 'approval: a re-approved edit runs' edited "$(cat "$WAP2/vendor/marker" 2>/dev/null)"
git -C "$WAP2" checkout -q .claude/worktree-profile.json

# A script changed AFTER the check, before it runs (a pull in the live session while a background
# run installs), is not run on the stale answer.
LIB=$(dirname "$HOOK")/bootstrap-lib.sh
# shellcheck disable=SC1090  # the library under test, found relative to the hook.
still=$( ( unset PITLANE_TRUST_PROFILES; . "$LIB"
  wt_load_profile_for "$WAP" "$AP"; wt_approval_check "$WAP" 2>/dev/null
  printf '%s ' "$WT_APPROVAL"
  wt_approval_still "$WAP" && printf 'still ' || printf 'changed '
  printf '\n# appended\n' >> "$WAP/.claude/worktree-seed.sh"
  wt_approval_still "$WAP" && printf 'still' || printf 'changed' ) )
git -C "$WAP" checkout -q .claude/worktree-seed.sh
eq 'approval: a script edited between the check and its run is caught' 'yes still changed' "$still"

# The review screen shows branch text with control characters made visible, so a carriage return or
# an escape sequence cannot make it show one command while another runs.
CC=$TMP/cc
make_repo "$CC" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"touch pwned\r\u001b[2Kmkdir -p vendor"}'
outR=$(gated_cli "$CC" --review)
contains 'review: control characters are shown as ?' '?[2Kmkdir -p vendor' "$outR"
lacks '...no carriage return reaches the screen' $'\r' "$outR"
lacks '...nor an escape' $'\033' "$outR"
vis=$(bash -c '. "$1"; wt_visible "$2"' _ "$LIB" $'a\xe2\x80\xaeb\xc2\x9bc\xe2\x80\x8bd')
eq 'review: bidi overrides, C1 controls and zero-width characters are shown as ?' 'a???b??c???d' "$vis"

# A hardlink entry's verify is a command too: held back, reported pending, done once approved.
HV=$TMP/hv
make_repo "$HV" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"mkdir -p vendor","verify":"test -f vendor/autoload.php"}'
mkdir -p "$HV/vendor"; printf 'MAIN\n' > "$HV/vendor/autoload.php"
WHV=$HV/.claude/worktrees/hv
git -C "$HV" worktree add -q "$WHV" -b worktree-hv 2>/dev/null
outH=$(gated_hook "$WHV"); errH=$(cat "$TMP/err")
eq 'approval: the hardlink itself still happens' MAIN "$(cat "$WHV/vendor/autoload.php" 2>/dev/null)"
contains '...its verify is held back' 'verify command is not approved' "$errH"
contains '...and it is reported pending' 'vendor missing (held back)' "$outH"
gated_cli "$WHV" --approve "$(gated_cli "$WHV" --review | fp_of)" >/dev/null
eq '...and it is done once approved' 'Pitlane: this worktree is fully set up.' "$(gated_cli "$WHV" --finish)"

# Every SHA-256 backend gives the same digest, and a broken one falls through to the next.
printf 'pitlane\n' > "$TMP/sha-in"
want=$(bash -c '. "$1"; wt_sha256 "$2"' _ "$LIB" "$TMP/sha-in")
eq 'sha256: a well-formed digest' 64 "${#want}"
hide=''
for tool in sha256sum shasum openssl; do
  hide="$hide $tool"
  mkdir -p "$TMP/shim-$tool"
  for h in $hide; do printf '#!/bin/sh\necho broken\nexit 1\n' > "$TMP/shim-$tool/$h"; chmod +x "$TMP/shim-$tool/$h"; done
  got=$(PATH=$TMP/shim-$tool:$PATH bash -c '. "$1"; wt_sha256 "$2"' _ "$LIB" "$TMP/sha-in")
  eq "sha256: with$hide broken, the next tool gives the same digest" "$want" "$got"
done
eq 'sha256: stdin and a file agree' "$want" "$(bash -c '. "$1"; wt_sha256' _ "$LIB" < "$TMP/sha-in")"

# A profile that runs nothing needs no approval at all.
NC=$TMP/nc
make_repo "$NC" '{"dir":"vendor","lock":"composer.lock","strategy":"skip"}' '".env.extra"'
printf 'EXTRA=1\n' > "$NC/.env.extra"
WNC=$NC/.claude/worktrees/nc
git -C "$NC" worktree add -q "$WNC" -b worktree-nc 2>/dev/null
outN=$(gated_hook "$WNC")
eq 'approval: a profile that runs no commands is set up without one' '' "$outN"
eq '...and its config copied' 'EXTRA=1' "$(cat "$WNC/.env.extra" 2>/dev/null)"
contains 'review: says such a profile needs no approval' 'runs no commands, so it needs no approval' "$(gated_cli "$WNC" --review)"

# Approving from the main checkout covers a worktree carrying the same content.
MC=$TMP/mc
make_repo "$MC" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"mkdir -p vendor && printf ok > vendor/marker"}'
FPM=$(gated_cli "$MC" --review | fp_of)
gated_cli "$MC" --approve "$FPM" >/dev/null
WMC=$MC/.claude/worktrees/mc
git -C "$MC" worktree add -q "$WMC" -b worktree-mc 2>/dev/null
eq 'approval: approved from the main checkout, a worktree starts silent' '' "$(gated_hook "$WMC")"
eq '...and its install ran' ok "$(cat "$WMC/vendor/marker" 2>/dev/null)"

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
