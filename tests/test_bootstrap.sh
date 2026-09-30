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
unset XDG_CONFIG_HOME
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

# The two copy mechanisms are split by event, and BOTH halves matter. On this path native already
# honoured .worktreeinclude, so the hook must NOT redo it; the profile's copy[] is the only list
# it owes, because native knows nothing about that one.
eq 'SessionStart applies the profile copy[] list' 'EXTRA=1' "$(cat "$W1/.env.extra" 2>/dev/null)"
eq 'SessionStart does NOT re-run .worktreeinclude, which native already did' '' \
  "$([ -e "$W1/.env" ] && echo copied)"

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
  eq "$1: and still writes nothing to stdout" '' "$out"
}

R2=$TMP/r2
make_repo "$R2" '{"dir":"vendor","lock":"composer.lock","strategy":"install","install":"exit 1"}'
W2=$R2/.claude/worktrees/f2
git -C "$R2" worktree add -q "$W2" -b worktree-f2 2>/dev/null
inject 'an install that fails' "$R2" "$W2"
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
contains 'no profile: it says what to do about it' 'worktree-calibrate' "$(cat "$TMP/err")"

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
# The phase's acceptance asks for a scratch pnpm repo and a scratch composer repo to come up with
# config and dependencies present and no manual steps.
#
# pnpm is exercised FOR REAL when it is on PATH — a dependency-free package still produces a
# lockfile and a node_modules, which is enough to prove the whole path (profile -> shell wrapper ->
# install -> verify -> state) against a genuine package manager rather than a stand-in.
#
# composer is NOT installed on every machine this runs on, so its repo is composer-SHAPED: the
# same vendor/ + composer.lock + hardlink strategy, driven by a stand-in command. That proves the
# engine's behaviour, not composer's. A real composer run against a 397 MB vendor/ is Phase 6's
# job, and the handoff says so rather than implying this covered it.

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
    # ADR-005: pnpm has its own content-addressable store, so it must be installed, never shared.
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
# the case ADR-004 exists for and the one a real composer repo hits.
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
# Layer 3 — the phase's acceptance criteria, end to end through the hook
# ---------------------------------------------------------------------------
#
# The unit suite drives the engine's functions directly. This drives the ENTRYPOINT, which is the
# only thing that proves the profile's runtime block is read, the values reach the right places,
# and the whole sequence survives a real hook invocation.

# A repo whose profile isolates a port and THREE environments — development, test and CI. Isolating
# only the development database is the "looks right, is subtly wrong" failure the phase names: a
# test runner that recreates its databases wholesale destroys a parallel session's test run
# regardless of how well the dev database is separated.
# A NESTED PROJECT WITH ITS OWN LOCKFILE — what detect.sh now proposes (Phase 6 pre-flight): its
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
    "port": { "var": "SERVER_PORT", "base": 3786, "span": 200 },
    "env": {
      "file": ".env.worktree.local",
      "vars": {
        "INSTALLATION_NAME": "demo_{slug}",
        "TEST_INSTALLATION_NAME": "demo_{slug}_test",
        "CI_INSTALLATION_NAME": "demo_{slug}_ci"
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
# block sits (ADR-012). $3 names another override file.
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
  "$(envval "$WA" INSTALLATION_NAME)" "$(envval "$WB" INSTALLATION_NAME)"
ne 'two worktrees get different TEST databases too' \
  "$(envval "$WA" TEST_INSTALLATION_NAME)" "$(envval "$WB" TEST_INSTALLATION_NAME)"
ne 'and different CI databases' \
  "$(envval "$WA" CI_INSTALLATION_NAME)" "$(envval "$WB" CI_INSTALLATION_NAME)"
eq "alice's development database is named after her slug" 'demo_alice' \
  "$(envval "$WA" INSTALLATION_NAME)"
eq "and her test database is a distinct name again" 'demo_alice_test' \
  "$(envval "$WA" TEST_INSTALLATION_NAME)"
contains 'and the hook says what it settled on' 'runtime: slug=alice' "$errA"

# ACCEPTANCE: reopening lands on the same port and the same database. A developer bookmarks the URL.
start_hook "$WA" >/dev/null
eq 'reopening a worktree keeps its port' "$pA" "$(envval "$WA" SERVER_PORT)"
eq 'and its database' 'demo_alice' "$(envval "$WA" INSTALLATION_NAME)"

# The override file must not show up as an untracked change — that is how one gets committed and
# every teammate's worktree ends up pointing at one database.
eq "the override file is invisible to git status" '' \
  "$(git -C "$WA" status --porcelain 2>/dev/null)"

# ACCEPTANCE: a developer can redirect a worktree without touching the profile, and the plugin
# respects it on EVERY later session — warning once, not every time.
printf 'INSTALLATION_NAME=the_shared_one\n' > "$WA/.env.worktree.local"
start_hook "$WA" >/dev/null; first=$(cat "$TMP/err")
start_hook "$WA" >/dev/null; second=$(cat "$TMP/err")
eq 'a hand-edited override file survives a re-bootstrap byte for byte' \
  'INSTALLATION_NAME=the_shared_one' "$(cat "$WA/.env.worktree.local")"
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
  "$(envval "$WN1" INSTALLATION_NAME)" "$(envval "$WN2" INSTALLATION_NAME)"
ne 'and different ports' "$(envval "$WN1" SERVER_PORT)" "$(envval "$WN2" SERVER_PORT)"
eq 'a nested name slugs to a legal database name' 'demo_alice_fix_99' \
  "$(envval "$WN1" INSTALLATION_NAME)"

# A long, punctuation-heavy, non-ASCII name still produces something legal.
WLONG="$RT/.claude/worktrees/Ünïcode--Feature/Very-Long-Branch-Name-That-Goes-On-And-On-For-A-While"
mkdir -p "${WLONG%/*}"
git -C "$RT" worktree add -q "$WLONG" -b worktree-long 2>/dev/null
start_hook "$WLONG" >/dev/null
longdb=$(envval "$WLONG" INSTALLATION_NAME)
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
  "$(envval "$WC1" INSTALLATION_NAME)" "$(envval "$WC2" INSTALLATION_NAME)"
ne 'and different ports' "$(envval "$WC1" SERVER_PORT)" "$(envval "$WC2" SERVER_PORT)"
eq 'and the database is named after the worktree, as the validator promised' 'demo_one' \
  "$(envval "$WC1" INSTALLATION_NAME)"
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
  "$(envval "$WD1" INSTALLATION_NAME)"

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

# AN OVERRIDE FILE LISTED FOR COPYING IS COPIED, AND THEN GETS THE BLOCK (ADR-012). The file an app
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
printf 'SECRET=from-main\nINSTALLATION_NAME=the_main_checkout_one\n' > "$RO/.env.worktree.local"
git -C "$RO" add -A; git -C "$RO" commit -qm overlap
WO=$RO/.claude/worktrees/o1
git -C "$RO" worktree add -q "$WO" -b worktree-o1 2>/dev/null
start_hook "$WO" >/dev/null
eq 'the developer configuration IS copied in' 'from-main' "$(envval "$WO" SECRET)"
eq 'and the block after it isolates the worktree' 'demo_o1' "$(envval "$WO" INSTALLATION_NAME)"
eq 'which a second session leaves the same' 'demo_o1' \
  "$(start_hook "$WO" >/dev/null; envval "$WO" INSTALLATION_NAME)"
eq 'with the copied lines still there exactly once' 1 \
  "$(grep -c '^SECRET=' "$WO/.env.worktree.local" | tr -d ' ')"

# THE NATIVE PATH, simulated: Claude Code copies .worktreeinclude BEFORE SessionStart runs, so the
# hook finds the developer's file already there. That is the case the old skip never covered.
WN=$RO/.claude/worktrees/n1
git -C "$RO" worktree add -q "$WN" -b worktree-n1 2>/dev/null
cp "$RO/.env.worktree.local" "$WN/.env.worktree.local"
start_hook "$WN" >/dev/null; errN=$(cat "$TMP/err")
eq 'a file native creation copied in gets the block too' 'demo_n1' "$(envval "$WN" INSTALLATION_NAME)"
lacks 'and is not announced as the developer file' 'is yours' "$errN"

# ...and the same for .worktreeinclude on the WorktreeCreate path, where the plugin copies it.
printf '.env.worktree.local\n' > "$RO/.worktreeinclude"
git -C "$RO" add -A; git -C "$RO" commit -qm wtinclude
outWC=$(run_hook "{\"hook_event_name\":\"WorktreeCreate\",\"name\":\"o2\",\"cwd\":\"$RO\"}" "$RO")
eq 'WorktreeCreate still prints the worktree path' "$RO/.claude/worktrees/o2" "$outWC"
eq 'and .worktreeinclude copied the developer configuration in' 'from-main' \
  "$(envval "$RO/.claude/worktrees/o2" SECRET)"
eq 'while the worktree got its own isolated value' 'demo_o2' \
  "$(envval "$RO/.claude/worktrees/o2" INSTALLATION_NAME)"

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
# native creation would have put there. A copy gets the block; a hand-made file would not (ADR-013).
printf 'ALSO_MINE=1\n' > "$RV/.env.other.local"
cp "$RV/.env.other.local" "$WV/.env.other.local"
start_hook "$WV" >/dev/null; errV=$(cat "$TMP/err")
eq 'a newly listed existing file keeps its lines' 'ALSO_MINE=1' "$(head -1 "$WV/.env.other.local")"
eq 'and gets the block' 'demo_v1' "$(envval "$WV" INSTALLATION_NAME .env.other.local)"
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

# ADOPTION (ADR-013): a worktree set up by hand before the plugin arrived. Its env file differs from
# the main checkout's and nothing records it, so the plugin must not re-point it — and must not seed.
RA=$TMP/rtadopt
make_rt_repo "$RA" ',
    "seed": ".claude/worktree-seed.sh"'
printf 'INSTALLATION_NAME=shared_db\n' > "$RA/.env.worktree.local"
mkdir -p "$RA/.claude"
# shellcheck disable=SC2016  # $WT_PATH must reach the seed script, not be expanded here.
printf '#!/usr/bin/env bash\nprintf ran > "$WT_PATH/seeded.txt"\n' > "$RA/.claude/worktree-seed.sh"
chmod +x "$RA/.claude/worktree-seed.sh"
git -C "$RA" add -A; git -C "$RA" commit -qm adopt
WA1=$RA/.claude/worktrees/handmade
git -C "$RA" worktree add -q "$WA1" -b worktree-handmade 2>/dev/null
printf 'INSTALLATION_NAME=handmade_clone\n' > "$WA1/.env.worktree.local"   # pointed at a hand clone
start_hook "$WA1" >/dev/null; errA=$(cat "$TMP/err")
eq 'adoption: a hand-configured env file is left byte for byte alone' 'INSTALLATION_NAME=handmade_clone' \
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
printf 'INSTALLATION_NAME=only_here\n' > "$WA2/.env.worktree.local"
start_hook "$WA2" >/dev/null
eq 'adoption: a file only the worktree has is left alone too' 'INSTALLATION_NAME=only_here' \
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
eq 'the first file gets the block' 'demo_m1' "$(envval "$WM" INSTALLATION_NAME)"
eq 'and so does the second' 'demo_m1' "$(envval "$WM" INSTALLATION_NAME .env.test.local)"
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
eq 'a failing seed still leaves a usable session (nothing on stdout)' '' "$outS"
contains 'and it says the seed failed' 'the seed failed' "$errS"
eq 'and the worktree still got its dependencies' 'ok' "$(cat "$WS/vendor/marker" 2>/dev/null)"
eq 'and its port and database' 'demo_s1' "$(envval "$WS" INSTALLATION_NAME)"
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
  eq 'a HANGING seed still leaves a usable session' '' "$outS"
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

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
