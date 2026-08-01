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
  printf '.env\n.env.extra\n.claude/worktrees/\n' > "$dir/.gitignore"
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

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
