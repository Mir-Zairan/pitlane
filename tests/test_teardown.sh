#!/usr/bin/env bash
#
# End-to-end tests for hooks/scripts/teardown.sh — the WorktreeRemove entrypoint, driven the way
# Claude Code drives it: a JSON payload on stdin, against worktrees that bootstrap.sh itself created
# from a WorktreeCreate payload, so the state file and ledger entry are the real ones.
#
# tests/test_teardown_lib.sh covers the resolver and the holds-work guard in isolation. This covers
# what only the entrypoint can get wrong: the order of guard, script, second guard and removal; the
# seed's environment reaching the teardown script; what is kept on each failure; exit 0 and an empty
# stdout on every path.
#
# The seed and teardown scripts stand a marker file OUTSIDE the worktree in for a database, so
# "the teardown ran" and "the teardown did not run" are both observable after the directory is gone.
#
# Both hooks read their payload through the JSON layer, so the whole suite runs once per backend,
# with the same missing-backend rule as tests/test_lib.sh:
#
#   tests/test_teardown.sh                            # every backend present on this machine
#   nix shell nixpkgs#jq -c tests/test_teardown.sh    # ...including jq, if it isn't installed
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)
CREATE_HOOK=$SCRIPTS/bootstrap.sh
REMOVE_HOOK=$SCRIPTS/teardown.sh
SCRATCH=$(mktemp -d)
SCRATCH=$(cd -P "$SCRATCH" && pwd -P)
TMP=$SCRATCH
listener_pid=''
# A test that makes a directory undeletable restores it itself; the chmod here is for one that
# was interrupted before it could.
# Every server a test starts is killed on the way out, by its group, whatever happened.
SERVED=''
kill_served() {
  local g
  for g in $SERVED; do kill -s KILL -- "-$g" "$g" 2>/dev/null; done
}
trap '[ -n "$listener_pid" ] && kill "$listener_pid" 2>/dev/null; kill_served; chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

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
HOME=$SCRATCH/home
mkdir -p "$HOME"
export HOME

# shellcheck source=serve_helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/serve_helpers.sh"

pass=0 fail=0 backends_run=0
BACKEND=none

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s] %s\n      expected: %q\n      actual:   %q\n' "$BACKEND" "$1" "$2" "$3" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL [%s] %s\n      expected to contain: %q\n      actual: %q\n' "$BACKEND" "$1" "$2" "$3" >&2 ;;
  esac
}

lacks() {  # $1 = label, $2 = needle that must NOT appear, $3 = haystack
  case $3 in
    *"$2"*) fail=$((fail + 1))
            printf 'FAIL [%s] %s\n      must not contain: %q\n      actual: %q\n' "$BACKEND" "$1" "$2" "$3" >&2 ;;
    *) pass=$((pass + 1)) ;;
  esac
}

exists() { [ -e "$1" ] && echo yes || echo no; }

# The hardlink count of $1. `stat -c %h` is GNU-only and BSD stat spells it `-f %l`; the second
# column of `ls -l` is the same number everywhere. SC2012: one known path, so no name parsing.
# shellcheck disable=SC2012
link_count() { ls -ld -- "$1" 2>/dev/null | awk '{ print $2 }'; }

# A PATH with every command of this one except flock, for the stock-macOS case. Symlinks, so each
# tool still finds its own libraries; the first of a name wins, as it would on PATH.
NOFLOCK=$SCRATCH/noflock-bin
mkdir -p "$NOFLOCK"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b=${f##*/}
    [ "$b" != flock ] && [ -x "$f" ] && [ ! -e "$NOFLOCK/$b" ] && ln -s "$f" "$NOFLOCK/$b"
  done
done

# A repository whose profile hardlinks vendor/ from the main checkout and isolates a runtime: a port,
# an env override file, a seed that creates "$DB/<slug>" and a teardown that logs the environment it
# received and removes it. $2 is extra shell run by the teardown script after that, $3 the seed
# timeout — the only bound the teardown script has.
make_repo() {  # $1 = dir, $2 = extra teardown shell, $3 = seedSeconds
  local dir=$1 extra=${2-} seed_secs=${3:-20}
  mkdir -p "$dir/.claude" "$dir/vendor"
  git init -q "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  printf '.env\n.env.worktree.local\n.claude/worktrees/\nvendor/\n' >"$dir/.gitignore"
  printf '.env\n' >"$dir/.worktreeinclude"
  printf 'SECRET=1\n' >"$dir/.env"
  printf 'LOCK\n' >"$dir/composer.lock"
  printf 'shared\n' >"$dir/vendor/autoload.php"
  printf 'tracked\n' >"$dir/app.txt"
  cat >"$dir/.claude/worktree-profile.json" <<JSON
{
  "schemaVersion": 1,
  "shell": "",
  "shellArgs": "argv",
  "deps": [{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
            "install":"mkdir -p vendor && printf installed > vendor/autoload.php"}],
  "runtime": {
    "slug": "{slug}",
    "port": { "var": "SERVER_PORT", "base": 4100, "span": 200 },
    "env": { "file": ".env.worktree.local", "vars": { "DATABASE": "demo_{slug}" } },
    "seed": ".claude/worktree-seed.sh",
    "teardown": ".claude/worktree-teardown.sh"
  },
  "timeouts": { "bootstrapSeconds": 60, "seedSeconds": $seed_secs }
}
JSON
  # shellcheck disable=SC2016  # the $WT_* references belong to the scripts, not to this file.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$WT_SLUG" > "%s/$WT_SLUG"\n' "$DB"
    printf 'printf "%%s\\n" "$WT_NAME" > "%s/$WT_SLUG.seed-name"\n' "$LOGS"
  } >"$dir/.claude/worktree-seed.sh"
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ for v in WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT WT_ENV_FILE WT_ENV_FILES; do printf "%%s=%%s\\n" "$v" "${!v-<unset>}"; done\n'
    printf '  printf "PWD=%%s\\n" "$(pwd -P)"; } > "%s/$WT_SLUG.log"\n' "$LOGS"
    printf 'rm -f "%s/$WT_SLUG"\n' "$DB"
    printf '%s\n' "$extra"
  } >"$dir/.claude/worktree-teardown.sh"
  chmod +x "$dir/.claude/worktree-seed.sh" "$dir/.claude/worktree-teardown.sh"
  git -C "$dir" add .gitignore .worktreeinclude composer.lock app.txt .claude
  git -C "$dir" commit -qm init
}

# Create a worktree the way the EnterWorktree tool does, through bootstrap.sh; prints its path.
create() {  # $1 = repo, $2 = name
  ( cd "$1" && printf '{"hook_event_name":"WorktreeCreate","name":"%s","cwd":"%s"}' "$2" "$1" \
    | bash "$CREATE_HOOK" 2>"$TMP/create-err" )
}

# Run the removal hook exactly as Claude Code does. stdout is echoed (it must be empty), stderr goes
# to $TMP/err, and the exit status to $TMP/rc.
remove() {  # $1 = payload JSON (or any bytes), $2 = cwd to run from
  local rc=0
  ( cd "$2" && printf '%s' "$1" | bash "$REMOVE_HOOK" 2>"$TMP/err" ) || rc=$?
  printf '%s' "$rc" >"$TMP/rc"
}

remove_payload() {  # $1 = worktree path, $2 = cwd
  printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s","reason":"session_exit","cwd":"%s"}' "$1" "$2"
}

# Every file under the main checkout and its git dir, less what a create/remove cycle keeps ON
# PURPOSE: the branch (never deleted), the shared dependency locks, and the shared ledger directory
# itself. Ref logs and the index are git's own bookkeeping and change on any operation.
footprint() {  # $1 = repo
  ( cd "$1" && find . -type f 2>/dev/null ) | LC_ALL=C sort | grep -v \
    -e '^\./\.git/worktree-locks/' -e '^\./\.git/refs/heads/worktree-' -e '^\./\.git/logs/' \
    -e '^\./\.git/index$'
}

run_suite() {
TMP=$SCRATCH/$BACKEND
DB=$TMP/databases
LOGS=$TMP/teardown-logs
mkdir -p "$DB" "$LOGS"

# ---------------------------------------------------------------------------
# The full cycle: create -> bootstrap -> runtime -> remove
# ---------------------------------------------------------------------------

R=$TMP/repo
make_repo "$R"
before_files=$(footprint "$R")
before_vendor_du=$(du -sk "$R/vendor" | cut -f1)

W=$(create "$R" feat)
eq 'fixture: WorktreeCreate made the worktree' "$R/.claude/worktrees/feat" "$W"
eq 'fixture: the seed created its database' yes "$(exists "$DB/feat")"
eq 'fixture: the env override was written' yes "$(exists "$W/.env.worktree.local")"
eq 'fixture: vendor/ was hardlinked from the main checkout' 2 \
  "$(link_count "$R/vendor/autoload.php")"
eq 'fixture: the ledger records the worktree' yes "$(exists "$R/.git/worktree-ledger/feat")"
port=$(grep '^SERVER_PORT=' "$W/.env.worktree.local" | cut -d= -f2)

# A process on the recorded port. The state holds no PID, so nothing proves it is this worktree's,
# and teardown must leave it running whatever it is.
if command -v python3 >/dev/null 2>&1 && [ -n "$port" ]; then
  python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(1); time.sleep(60)' "$port" 2>/dev/null &
  listener_pid=$!
  sleep 0.5
fi

out=$(remove "$(remove_payload "$W" "$R")" "$R")
err=$(cat "$TMP/err")
eq 'removal exits 0' 0 "$(cat "$TMP/rc")"
eq 'removal writes NOTHING to stdout' '' "$out"
eq 'the worktree directory is gone' no "$(exists "$W")"
eq 'its git admin dir is gone' no "$(exists "$R/.git/worktrees/feat")"
eq 'git no longer lists it' '' "$(git -C "$R" worktree list --porcelain | grep "$W")"
eq 'the teardown script dropped the database' no "$(exists "$DB/feat")"
eq 'the ledger entry is forgotten' no "$(exists "$R/.git/worktree-ledger/feat")"
eq 'the branch is kept' yes \
  "$(git -C "$R" show-ref --verify --quiet refs/heads/worktree-feat && echo yes || echo no)"
contains 'and the log says the branch was kept' 'its branch is kept' "$err"

# THE SEED'S ENVIRONMENT, rebuilt from the record: same names, same values, cwd the worktree.
log=$(cat "$LOGS/feat.log" 2>/dev/null)
contains 'the teardown script got WT_NAME' 'WT_NAME=feat' "$log"
contains 'and WT_SLUG' 'WT_SLUG=feat' "$log"
contains 'and the recorded WT_PORT' "WT_PORT=$port" "$log"
contains 'and WT_PATH' "WT_PATH=$W" "$log"
contains 'and WT_ROOT' "WT_ROOT=$R" "$log"
contains 'and WT_ENV_FILE' 'WT_ENV_FILE=.env.worktree.local' "$log"
contains 'and WT_ENV_FILES, the whole list' 'WT_ENV_FILES=.env.worktree.local' "$log"
contains 'and ran inside the worktree' "PWD=$W" "$log"

# Disk-neutral apart from what is shared on purpose.
eq 'the main checkout and its git dir are back to their files' "$before_files" "$(footprint "$R")"
eq 'the hardlink source is untouched' 'shared' "$(cat "$R/vendor/autoload.php")"
eq 'and is no longer linked from anywhere' 1 "$(link_count "$R/vendor/autoload.php")"
eq 'and takes the same space as before' "$before_vendor_du" "$(du -sk "$R/vendor" | cut -f1)"
eq 'the ledger directory is empty' '' "$(ls -A "$R/.git/worktree-ledger" 2>/dev/null)"

if [ -n "$listener_pid" ]; then
  eq 'the process on the recorded port is still running' yes \
    "$(kill -0 "$listener_pid" 2>/dev/null && echo yes || echo no)"
  kill "$listener_pid" 2>/dev/null
  wait "$listener_pid" 2>/dev/null
  listener_pid=''
else
  printf 'SKIP no python3 to listen on the recorded port\n' >&2
fi

# ---------------------------------------------------------------------------
# A worktree that holds work is left exactly as it is
# ---------------------------------------------------------------------------

WD=$(create "$R" dirty)
printf 'edited\n' >"$WD/app.txt"
out=$(remove "$(remove_payload "$WD" "$R")" "$R")
err=$(cat "$TMP/err")
eq 'dirty: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
eq 'dirty: nothing on stdout' '' "$out"
eq 'dirty: the worktree is kept' yes "$(exists "$WD")"
eq 'dirty: the edit survives' 'edited' "$(cat "$WD/app.txt")"
eq 'dirty: the teardown script did NOT run' yes "$(exists "$DB/dirty")"
eq 'dirty: the env override is kept' yes "$(exists "$WD/.env.worktree.local")"
eq 'dirty: the ledger entry is kept' yes "$(exists "$R/.git/worktree-ledger/dirty")"
contains 'dirty: stderr names the reason' 'modified tracked files' "$err"
contains 'dirty: and says nothing was removed' 'nothing was removed' "$err"

git -C "$WD" checkout -q -- app.txt
printf 'new\n' >"$WD/notes.txt"
remove "$(remove_payload "$WD" "$R")" "$R" >/dev/null
err=$(cat "$TMP/err")
eq 'untracked: the worktree is kept' yes "$(exists "$WD/notes.txt")"
eq 'untracked: the teardown script did NOT run' yes "$(exists "$DB/dirty")"
contains 'untracked: stderr names the reason' 'untracked files' "$err"

rm -f "$WD/notes.txt"
remove "$(remove_payload "$WD" "$R")" "$R" >/dev/null
eq 'once clean, the same worktree is removed' no "$(exists "$WD")"

# ---------------------------------------------------------------------------
# A failing or hanging teardown script never stops the removal
# ---------------------------------------------------------------------------

RF=$TMP/repo-fails
make_repo "$RF" 'exit 3'
WF=$(create "$RF" boom)
out=$(remove "$(remove_payload "$WF" "$RF")" "$RF")
err=$(cat "$TMP/err")
eq 'failing teardown: exits 0' 0 "$(cat "$TMP/rc")"
eq 'failing teardown: nothing on stdout' '' "$out"
eq 'failing teardown: the worktree is still removed' no "$(exists "$WF")"
eq 'failing teardown: the ledger entry is KEPT for prune' yes \
  "$(exists "$RF/.git/worktree-ledger/boom")"
contains 'failing teardown: stderr says it failed' 'failed (exit 3)' "$err"
contains 'failing teardown: and that prune will list it' '/pitlane-tidy will list it' "$err"

if command -v timeout >/dev/null 2>&1; then
  RH=$TMP/repo-hangs
  make_repo "$RH" 'sleep 60' 2
  WH=$(create "$RH" stuck)
  started=$(date +%s)
  out=$(remove "$(remove_payload "$WH" "$RH")" "$RH")
  elapsed=$(( $(date +%s) - started ))
  err=$(cat "$TMP/err")
  eq 'hanging teardown: exits 0' 0 "$(cat "$TMP/rc")"
  eq 'hanging teardown: nothing on stdout' '' "$out"
  eq 'hanging teardown: stopped at the seedSeconds bound' yes "$([ "$elapsed" -lt 20 ] && echo yes || echo "no (${elapsed}s)")"
  eq 'hanging teardown: the worktree is still removed' no "$(exists "$WH")"
  eq 'hanging teardown: the ledger entry is KEPT' yes "$(exists "$RH/.git/worktree-ledger/stuck")"
  contains 'hanging teardown: stderr says it was stopped' 'was stopped' "$err"
else
  printf 'SKIP no coreutils timeout for the hanging-teardown test\n' >&2
fi

# The teardown script runs IN the worktree and can leave work there itself — a dump, a log. The
# second guard keeps the worktree then, and since its database is gone the state must stop saying
# the seed is done, or the next session would skip the seed and run against nothing.
RL=$TMP/repo-leaves
# shellcheck disable=SC2016  # $WT_PATH belongs to the teardown script.
make_repo "$RL" 'printf dump > "$WT_PATH/dump.sql"'
WL=$(create "$RL" leaves)
out=$(remove "$(remove_payload "$WL" "$RL")" "$RL")
err=$(cat "$TMP/err")
eq 'script leaves work: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
eq 'script leaves work: nothing on stdout' '' "$out"
eq 'script leaves work: the worktree is kept' yes "$(exists "$WL/dump.sql")"
eq 'script leaves work: with its env override' yes "$(exists "$WL/.env.worktree.local")"
eq 'script leaves work: the ledger entry is kept' yes "$(exists "$RL/.git/worktree-ledger/leaves")"
contains 'script leaves work: stderr names what it left' 'untracked files' "$err"
seed_recorded=$(
  # shellcheck source=../hooks/scripts/bootstrap-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPTS/bootstrap-lib.sh"
  wt_runtime_state_read "$RL/.git/worktrees/leaves/worktree-bootstrap-state" seedstatus
) 2>/dev/null
eq 'script leaves work: the seed is recorded as not run, so the next session seeds again' none \
  "$seed_recorded"

# ---------------------------------------------------------------------------
# git refuses the removal: rm -rf, then only THIS worktree's registration goes
# ---------------------------------------------------------------------------
#
# A shim on PATH fails `git worktree remove` and passes everything else to the real git. Beside the
# worktree being removed sits one whose checkout was deleted by hand: a repository-wide
# `git worktree prune` would erase its admin dir, and the state file in it that prune reads.

REAL_GIT=$(command -v git)
mkdir -p "$TMP/shim"
cat >"$TMP/shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = remove ] && [[ " \$* " == *" worktree remove "* ]]; then
    echo "fatal: refusing for the test" >&2
    exit 128
  fi
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$TMP/shim/git"

WR=$(create "$R" refused)
WO=$(create "$R" orphan)
rm -rf "$WO"
out=$(PATH=$TMP/shim:$PATH remove "$(remove_payload "$WR" "$R")" "$R")
err=$(cat "$TMP/err")
eq 'git refuses: exits 0' 0 "$(cat "$TMP/rc")"
eq 'git refuses: nothing on stdout' '' "$out"
contains 'git refuses: and says so' 'refusing for the test' "$err"
eq 'git refuses: the directory is deleted anyway' no "$(exists "$WR")"
eq 'git refuses: its admin dir is deleted' no "$(exists "$R/.git/worktrees/refused")"
eq 'git refuses: another missing worktree keeps its admin dir' yes \
  "$(exists "$R/.git/worktrees/orphan/worktree-bootstrap-state")"
eq 'git refuses: the teardown script ran' no "$(exists "$DB/refused")"
eq 'git refuses: the ledger entry is forgotten' no "$(exists "$R/.git/worktree-ledger/refused")"

# ---------------------------------------------------------------------------
# A main checkout moved since creation: nothing can be proven, so nothing is done
# ---------------------------------------------------------------------------

RM=$TMP/repo-moved
make_repo "$RM"
WM=$(create "$RM" moved)
mv "$RM" "$TMP/repo-moved-elsewhere"
WM2=$TMP/repo-moved-elsewhere/.claude/worktrees/moved
out=$(remove "$(remove_payload "$WM2" "$TMP/repo-moved-elsewhere")" "$TMP/repo-moved-elsewhere")
err=$(cat "$TMP/err")
eq 'moved main: exits 0' 0 "$(cat "$TMP/rc")"
eq 'moved main: nothing on stdout' '' "$out"
eq 'moved main: the worktree is kept' yes "$(exists "$WM2")"
eq 'moved main: the teardown script did NOT run' yes "$(exists "$DB/moved")"
contains 'moved main: stderr says why' 'moved or renamed' "$err"
eq 'fixture: the create path was the pre-move one' "$RM/.claude/worktrees/moved" "$WM"

# ---------------------------------------------------------------------------
# The directory is already gone (native removal ran first): the ledger is all that is left
# ---------------------------------------------------------------------------

RG=$TMP/repo-gone
make_repo "$RG"

# An allocation the prune sweep is releasing right now, held on its entry's lock as prune holds it:
# neither a gone worktree's nor a present one's teardown script runs, and both entries are kept.
if command -v flock >/dev/null 2>&1; then
  WH=$(create "$RG" held)
  WP=$(create "$RG" heldpresent)
  git -C "$RG" worktree remove --force "$WH"
  mkdir -p "$RG/.git/worktree-locks"
  exec 6>"$RG/.git/worktree-locks/rt-held.lock"
  exec 5>"$RG/.git/worktree-locks/rt-heldpresent.lock"
  flock -n 6
  flock -n 5
  out=$(remove "$(remove_payload "$WH" "$RG")" "$RG")
  err=$(cat "$TMP/err")
  eq 'allocation held, gone: exits 0' 0 "$(cat "$TMP/rc")"
  eq 'allocation held, gone: nothing on stdout' '' "$out"
  eq 'allocation held, gone: the teardown script did NOT run' yes "$(exists "$DB/held")"
  eq 'allocation held, gone: the ledger entry is kept' yes "$(exists "$RG/.git/worktree-ledger/held")"
  contains 'allocation held, gone: stderr says why' 'releasing its runtime allocation' "$err"
  out=$(remove "$(remove_payload "$WP" "$RG")" "$RG")
  err=$(cat "$TMP/err")
  exec 6>&- 5>&-
  eq 'allocation held, present: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
  eq 'allocation held, present: the worktree is kept' yes "$(exists "$WP/.env.worktree.local")"
  eq 'allocation held, present: the teardown script did NOT run' yes "$(exists "$DB/heldpresent")"
  eq 'allocation held, present: the ledger entry is kept' yes \
    "$(exists "$RG/.git/worktree-ledger/heldpresent")"
  contains 'allocation held, present: stderr says why' 'releasing its runtime allocation' "$err"
  out=$(remove "$(remove_payload "$WH" "$RG")" "$RG")
  eq 'allocation free again: the gone one is torn down' no "$(exists "$DB/held")"
  eq '...and its entry forgotten' no "$(exists "$RG/.git/worktree-ledger/held")"
  out=$(remove "$(remove_payload "$WP" "$RG")" "$RG")
  eq 'allocation free again: the present one is removed' no "$(exists "$WP")"
else
  printf 'SKIP no flock to hold the allocation lock with\n' >&2
fi

WG=$(create "$RG" gone)
port_gone=$(grep '^SERVER_PORT=' "$WG/.env.worktree.local" | cut -d= -f2)
git -C "$RG" worktree remove --force "$WG"
eq 'fixture: native removal took the admin dir too' no "$(exists "$RG/.git/worktrees/gone")"
out=$(remove "$(remove_payload "$WG" "$RG")" "$RG")
err=$(cat "$TMP/err")
log=$(cat "$LOGS/gone.log" 2>/dev/null)
eq 'already gone: exits 0' 0 "$(cat "$TMP/rc")"
eq 'already gone: nothing on stdout' '' "$out"
eq 'already gone: the teardown script dropped the database' no "$(exists "$DB/gone")"
contains 'already gone: it ran from the main checkout' "PWD=$RG" "$log"
contains 'already gone: with the recorded port' "WT_PORT=$port_gone" "$log"
contains 'already gone: and the recorded path' "WT_PATH=$WG" "$log"
eq 'already gone: the ledger entry is forgotten' no "$(exists "$RG/.git/worktree-ledger/gone")"
eq 'already gone: the branch is kept' yes \
  "$(git -C "$RG" show-ref --verify --quiet refs/heads/worktree-gone && echo yes || echo no)"

# ---------------------------------------------------------------------------
# Payloads that name nothing removable
# ---------------------------------------------------------------------------

WK=$(create "$R" keep)
for payload in "$(remove_payload "$R" "$R")" 'not json{' '' \
  "{\"hook_event_name\":\"WorktreeRemove\",\"cwd\":\"$R\"}"; do
  out=$(remove "$payload" "$R")
  eq "refused payload [$payload]: exits 0" 0 "$(cat "$TMP/rc")"
  eq "refused payload [$payload]: nothing on stdout" '' "$out"
  eq "refused payload [$payload]: the main checkout is intact" yes "$(exists "$R/.git/HEAD")"
  eq "refused payload [$payload]: a live worktree is untouched" yes "$(exists "$WK/.env.worktree.local")"
  eq "refused payload [$payload]: its database is untouched" yes "$(exists "$DB/keep")"
done
remove "$(remove_payload "$R" "$R")" "$R" >/dev/null
contains 'the main checkout is refused by name' 'main checkout' "$(cat "$TMP/err")"

# stdin closed outright, not merely empty.
rc=0
out=$( (cd "$R" && bash "$REMOVE_HOOK" </dev/null 2>"$TMP/err") ) || rc=$?
eq 'no stdin at all: exits 0' 0 "$rc"
eq 'no stdin at all: nothing on stdout' '' "$out"
eq 'no stdin at all: the live worktree is untouched' yes "$(exists "$WK")"
lacks 'no stdin at all: and nothing was torn down' 'tearing down' "$(cat "$TMP/err")"

# ---------------------------------------------------------------------------
# A bootstrap still running in the worktree: nothing is torn down under it
# ---------------------------------------------------------------------------
#
# The lock is held from this shell on a descriptor of its own, exactly as bootstrap.sh holds it.

RB=$TMP/repo-busy
make_repo "$RB"
WB=$(create "$RB" busy)
busy_lock=$RB/.git/worktrees/busy/worktree-bootstrap-state.lock
if command -v flock >/dev/null 2>&1; then
  exec 7>"$busy_lock"
  flock -n 7
  out=$(remove "$(remove_payload "$WB" "$RB")" "$RB")
  err=$(cat "$TMP/err")
  exec 7>&-
  eq 'lock held: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
  eq 'lock held: nothing on stdout' '' "$out"
  eq 'lock held: the worktree is kept' yes "$(exists "$WB/.env.worktree.local")"
  eq 'lock held: the teardown script did NOT run' yes "$(exists "$DB/busy")"
  eq 'lock held: the ledger entry is kept' yes "$(exists "$RB/.git/worktree-ledger/busy")"
  contains 'lock held: stderr says why' 'a bootstrap is still running in it' "$err"

  # A lock that cannot even be tried is no proof that nothing holds it.
  rm -f "$busy_lock"
  ln -s "$TMP/lock-target" "$busy_lock"
  out=$(remove "$(remove_payload "$WB" "$RB")" "$RB")
  err=$(cat "$TMP/err")
  rm -f "$busy_lock"
  eq 'unusable lock: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
  eq 'unusable lock: the worktree is kept' yes "$(exists "$WB/.env.worktree.local")"
  eq 'unusable lock: the teardown script did NOT run' yes "$(exists "$DB/busy")"
  eq 'unusable lock: the symlink target was not created' no "$(exists "$TMP/lock-target")"
  contains 'unusable lock: stderr says why' 'could not check for a running bootstrap' "$err"

  # A /pitlane-serve holding the serve lock may be starting a server it has not recorded yet. The
  # holder is a background process of its own, as /pitlane-serve is; exec makes $! the holder.
  WSL=$(create "$RB" serving)
  serve_lock=$RB/.git/worktrees/serving/worktree-serve.lock
  rm -f "$TMP/serve-held"
  ( flock -n 9 || exit 1; touch "$TMP/serve-held"; exec sleep 60 ) 9>"$serve_lock" &
  holder=$!
  SERVED="$SERVED $holder"
  for _ in $(seq 1 50); do [ -e "$TMP/serve-held" ] && break; sleep 0.1; done
  out=$(remove "$(remove_payload "$WSL" "$RB")" "$RB")
  err=$(cat "$TMP/err")
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  eq 'serve lock held: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
  eq 'serve lock held: nothing on stdout' '' "$out"
  eq 'serve lock held: the worktree is kept' yes "$(exists "$WSL/.env.worktree.local")"
  eq 'serve lock held: the teardown script did NOT run' yes "$(exists "$DB/serving")"
  contains 'serve lock held: stderr says why' 'a /pitlane-serve is starting the app in it' "$err"

  rm -f "$serve_lock"
  ln -s "$TMP/serve-lock-target" "$serve_lock"
  out=$(remove "$(remove_payload "$WSL" "$RB")" "$RB")
  err=$(cat "$TMP/err")
  rm -f "$serve_lock"
  eq 'unusable serve lock: exits 1' 1 "$(cat "$TMP/rc")"
  eq 'unusable serve lock: the worktree is kept' yes "$(exists "$WSL/.env.worktree.local")"
  eq 'unusable serve lock: the teardown script did NOT run' yes "$(exists "$DB/serving")"
  eq 'unusable serve lock: the symlink target was not created' no "$(exists "$TMP/serve-lock-target")"
  contains 'unusable serve lock: stderr says why' 'could not check for a running /pitlane-serve' "$err"
else
  printf 'SKIP no flock to hold the bootstrap lock with\n' >&2
fi

# Stock macOS has no flock. Bootstrap already runs unlocked there, and refusing would mean teardown
# never works on that platform, so it proceeds and says so.
out=$(PATH=$NOFLOCK remove "$(remove_payload "$WB" "$RB")" "$RB")
err=$(cat "$TMP/err")
eq 'no flock: exits 0' 0 "$(cat "$TMP/rc")"
eq 'no flock: nothing on stdout' '' "$out"
eq 'no flock: the worktree is removed' no "$(exists "$WB")"
eq 'no flock: the teardown script ran' no "$(exists "$DB/busy")"
contains 'no flock: stderr says a running bootstrap could not be ruled out' \
  'cannot tell whether a bootstrap is still running' "$err"

# ---------------------------------------------------------------------------
# A teardown script that cannot be run: the worktree goes, the ledger entry stays
# ---------------------------------------------------------------------------

RX=$TMP/repo-noexec
make_repo "$RX"
chmod -x "$RX/.claude/worktree-teardown.sh"
git -C "$RX" commit -qam 'teardown script not executable'
WX=$(create "$RX" noexec)
out=$(remove "$(remove_payload "$WX" "$RX")" "$RX")
err=$(cat "$TMP/err")
eq 'not executable: exits 0' 0 "$(cat "$TMP/rc")"
eq 'not executable: nothing on stdout' '' "$out"
eq 'not executable: the worktree is removed' no "$(exists "$WX")"
eq 'not executable: its database is still there' yes "$(exists "$DB/noexec")"
eq 'not executable: so the ledger entry is KEPT' yes "$(exists "$RX/.git/worktree-ledger/noexec")"
contains 'not executable: stderr says so' 'missing or not executable' "$err"

# A committed symlink to a script outside the checkout is not the branch's script.
RY=$TMP/repo-outside
make_repo "$RY"
printf '#!/usr/bin/env bash\ntouch "%s/outside-ran"\n' "$TMP" >"$TMP/outside.sh"
chmod +x "$TMP/outside.sh"
rm -f "$RY/.claude/worktree-teardown.sh"
ln -s "$TMP/outside.sh" "$RY/.claude/worktree-teardown.sh"
git -C "$RY" add -A .claude
git -C "$RY" commit -qm 'teardown script is a symlink out of the repository'
WY=$(create "$RY" outside)
out=$(remove "$(remove_payload "$WY" "$RY")" "$RY")
err=$(cat "$TMP/err")
eq 'symlinked outside: exits 0' 0 "$(cat "$TMP/rc")"
eq 'symlinked outside: the outside script did NOT run' no "$(exists "$TMP/outside-ran")"
eq 'symlinked outside: the worktree is removed' no "$(exists "$WY")"
eq 'symlinked outside: its database is still there' yes "$(exists "$DB/outside")"
eq 'symlinked outside: so the ledger entry is KEPT' yes "$(exists "$RY/.git/worktree-ledger/outside")"
contains 'symlinked outside: stderr says why' 'refusing to run the teardown script' "$err"

# ---------------------------------------------------------------------------
# What was allocated comes from the record, and only from the record
# ---------------------------------------------------------------------------

# No rt record anywhere: nothing was allocated, so there is nothing for the script to undo — and a
# slug invented for it could name another worktree's database.
WN=$(create "$R" nort)
rm -f "$R/.git/worktrees/nort/worktree-bootstrap-state" "$R/.git/worktree-ledger/nort"
logs_before=$(ls -A "$LOGS")
out=$(remove "$(remove_payload "$WN" "$R")" "$R")
err=$(cat "$TMP/err")
eq 'no record: exits 0' 0 "$(cat "$TMP/rc")"
eq 'no record: the worktree is still removed' no "$(exists "$WN")"
eq 'no record: the teardown script did NOT run' yes "$(exists "$DB/nort")"
eq 'no record: and left no log under any slug' "$logs_before" "$(ls -A "$LOGS")"
lacks 'no record: nothing claims to tear down' 'tearing down' "$err"
rm -f "$DB/nort"

# The state file lost, the ledger entry kept: the ledger is the same record, so the environment is
# rebuilt from it.
WS=$(create "$R" stateless)
port_stateless=$(grep '^SERVER_PORT=' "$WS/.env.worktree.local" | cut -d= -f2)
rm -f "$R/.git/worktrees/stateless/worktree-bootstrap-state"
out=$(remove "$(remove_payload "$WS" "$R")" "$R")
log=$(cat "$LOGS/stateless.log" 2>/dev/null)
eq 'ledger only: exits 0' 0 "$(cat "$TMP/rc")"
eq 'ledger only: the worktree is removed' no "$(exists "$WS")"
eq 'ledger only: the teardown script dropped the database' no "$(exists "$DB/stateless")"
contains 'ledger only: WT_NAME from the ledger' 'WT_NAME=stateless' "$log"
contains 'ledger only: the recorded port' "WT_PORT=$port_stateless" "$log"
contains 'ledger only: the recorded env file' 'WT_ENV_FILE=.env.worktree.local' "$log"
eq 'ledger only: the ledger entry is forgotten' no "$(exists "$R/.git/worktree-ledger/stateless")"

# ---------------------------------------------------------------------------
# A seed that never ran: nothing of the plugin's to tear down
# ---------------------------------------------------------------------------
# The record still holds a slug, and a database by that name may belong to someone else — a live
# sibling on the same slug, or a clone a developer made by hand. The teardown script must not run.

RN=$TMP/never-seeded
make_repo "$RN"
chmod -x "$RN/.claude/worktree-seed.sh"
git -C "$RN" update-index --chmod=-x .claude/worktree-seed.sh
git -C "$RN" commit -qm 'seed not executable'
printf 'someone_elses\n' >"$DB/unseeded"
WN=$(create "$RN" unseeded)
eq 'never seeded: fixture — the seed did not run' 'someone_elses' "$(cat "$DB/unseeded" 2>/dev/null)"
remove "$(remove_payload "$WN" "$RN")" "$RN"
errN=$(cat "$TMP/err")
eq 'never seeded: the worktree is still removed' no "$(exists "$WN")"
eq 'never seeded: the teardown script did not run' no "$(exists "$LOGS/unseeded.log")"
eq 'never seeded: so the database of that name is untouched' 'someone_elses' "$(cat "$DB/unseeded" 2>/dev/null)"
contains 'never seeded: and it says why' 'the seed never ran for slug=unseeded' "$errN"
eq 'never seeded: the ledger entry is let go — there is nothing left to undo' no \
  "$(exists "$RN/.git/worktree-ledger/unseeded")"

# ---------------------------------------------------------------------------
# A hostile worktree name, through the whole cycle
# ---------------------------------------------------------------------------
#
# git refuses a space in a branch name, so WorktreeCreate cannot make "a b'c;é" at all. A native
# `claude -w` worktree is named by its DIRECTORY, which can be — so this one is created the native
# way and bootstrapped through SessionStart, and the name reaches both scripts from the path.

hostile="a b'c;é"
WHN=$R/.claude/worktrees/$hostile
ledger_before=$(ls -A "$R/.git/worktree-ledger")
git -C "$R" worktree add -q "$WHN" -b hostile-name
( cd "$WHN" && printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$WHN" \
  | bash "$CREATE_HOOK" >/dev/null 2>"$TMP/create-err" )
hostile_slug=$(
  # shellcheck source=../hooks/scripts/lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPTS/lib.sh"
  wt_slugify "$hostile"
) 2>/dev/null
eq 'hostile: fixture: the seed made its database' yes "$(exists "$DB/$hostile_slug")"
eq 'hostile: fixture: the ledger records it' yes \
  "$([ "$(ls -A "$R/.git/worktree-ledger")" != "$ledger_before" ] && echo yes || echo no)"
out=$(remove "$(remove_payload "$WHN" "$R")" "$R")
err=$(cat "$TMP/err")
log=$(cat "$LOGS/$hostile_slug.log" 2>/dev/null)
eq 'hostile: exits 0' 0 "$(cat "$TMP/rc")"
eq 'hostile: nothing on stdout' '' "$out"
eq 'hostile: the worktree is removed' no "$(exists "$WHN")"
eq 'hostile: the teardown script dropped the database the seed made' no "$(exists "$DB/$hostile_slug")"
contains 'hostile: WT_NAME is the name the seed saw' "WT_NAME=$hostile" "$log"
contains 'hostile: WT_PATH is the worktree' "WT_PATH=$WHN" "$log"
eq 'hostile: its ledger entry is forgotten' "$ledger_before" "$(ls -A "$R/.git/worktree-ledger")"

# ---------------------------------------------------------------------------
# A nested WorktreeCreate name survives a later SessionStart
# ---------------------------------------------------------------------------
#
# WorktreeCreate seeds with the payload's name, `alice/fix-99`, in the flattened directory
# `alice-fix-99`. A SessionStart in that worktree has no payload name and derives `alice-fix-99`
# from the path, and it rewrites the rt record — so the ledger must keep the name first recorded,
# or the teardown script is handed a WT_NAME the seed never saw.

WA=$(create "$R" alice/fix-99)
eq 'nested name: fixture: flattened directory' "$R/.claude/worktrees/alice-fix-99" "$WA"
seed_name=$(cat "$LOGS/alice_fix_99.seed-name" 2>/dev/null)
eq 'nested name: fixture: the seed saw the payload name' 'alice/fix-99' "$seed_name"
( cd "$WA" && printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$WA" \
  | bash "$CREATE_HOOK" >/dev/null 2>"$TMP/create-err" )
out=$(remove "$(remove_payload "$WA" "$R")" "$R")
log=$(cat "$LOGS/alice_fix_99.log" 2>/dev/null)
eq 'nested name: exits 0' 0 "$(cat "$TMP/rc")"
eq 'nested name: the teardown script dropped the database' no "$(exists "$DB/alice_fix_99")"
contains 'nested name: teardown gets the WT_NAME the seed saw' "WT_NAME=$seed_name"$'\n' "$log"

# ---------------------------------------------------------------------------
# The app /pitlane-serve started is stopped, and nothing else (ADR-021)
# ---------------------------------------------------------------------------

if command -v setsid >/dev/null 2>&1 && [ -d /proc/self ]; then
SVR=$TMP/repo-serves
make_repo "$SVR"
# serve stays in the foreground (stopped by signal); serve_daemon detaches and exits 0, so it is
# stopped by runtime.stop, which records what it was run with outside the worktree.
python3 - "$SVR/.claude/worktree-profile.json" "$TMP" <<'PY'
import json, sys
p, tmp = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["runtime"]["serve"] = "exec python3 -m http.server {port} --bind 127.0.0.1"
d["runtime"]["url"] = "http://127.0.0.1:{port}/"
json.dump(d, open(p, "w"), indent=2)
PY
git -C "$SVR" commit -qam serve
MIRRORS=$SVR/.git/worktree-servers

# The main checkout's own server, started by hand: no recorded server of any worktree is it, so
# every teardown below must leave it running.
main_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# Started straight from this shell: a $(...) subshell inherits the EXIT trap, so bash would not exec
# the server, and the subshell would hold the substitution's pipe open for as long as it runs.
( cd "$SVR" && exec setsid python3 -m http.server "$main_port" --bind 127.0.0.1 ) </dev/null >/dev/null 2>&1 &
main_srv=$!
SERVED="$SERVED $main_srv"

# Foreground: stopped by its recorded group, before the worktree and its state go.
WS=$(create "$SVR" served)
out=$(serve "$WS" --serve)
spid=$(served_pid "$WS")
SERVED="$SERVED $spid"
contains 'serve fixture: /pitlane-serve started the app' 'Pitlane: serving at' "$out"
eq 'serve fixture: it is mirrored outside the admin dir' 1 "$(count_in "$MIRRORS")"
out=$(remove "$(remove_payload "$WS" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'served: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'served: nothing on stdout' '' "$out"
eq 'served: the worktree is removed' no "$(exists "$WS")"
eq 'served: its server is stopped' no "$(alive "$spid")"
eq '...and every process of its group' 0 "$(pgrep -g "$spid" 2>/dev/null | wc -l | tr -d ' ')"
contains '...and stderr says so' "stopped the app /pitlane-serve started at" "$err"
eq '...its mirror is forgotten' '' "$(ls -A "$MIRRORS" 2>/dev/null)"
eq 'served: the main checkout'"'"'s own server is still running' yes "$(alive "$main_srv")"

# A recorded PID that now belongs to another process (simulated: an unrelated process with a start
# identity that cannot match) is never signalled; the record is dropped and teardown completes.
WR=$(create "$SVR" recycled)
setsid sleep 300 </dev/null >/dev/null 2>&1 &
other=$!
SERVED="$SERVED $other"
# shellcheck disable=SC1091  # the engine itself, sourced to write a record as /pitlane-serve does
( . "$SCRIPTS/bootstrap-lib.sh"
  wt_serve_record_write "$WR" "$other" "$other" 'stat:1' 'ck' 'http://127.0.0.1:1/' )
eq 'recycled fixture: the record is mirrored' 1 "$(count_in "$MIRRORS")"
out=$(remove "$(remove_payload "$WR" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'recycled: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'recycled: the worktree is removed' no "$(exists "$WR")"
eq 'recycled: the process holding the PID is NOT signalled' yes "$(alive "$other")"
contains '...stderr says it is not ours' 'now belongs to another process — not ours, left alone' "$err"
eq '...and the record is dropped with its mirror' '' "$(ls -A "$MIRRORS" 2>/dev/null)"
kill "$other" 2>/dev/null

# Daemonized: stopped by runtime.stop — only when approved, and a stop that fails does not stop the
# teardown. The server's pid file and runtime.stop's log live outside the worktree. Each worktree
# commits its own profile, kept on a second branch so the commit is not work the guard keeps.
daemon_worktree() {  # $1 = name, $2 = runtime.stop; sets WC, then serves it and sets dpid
  WC=$(create "$SVR" "$1")
  python3 -c 'import json, sys
p, tmp, stop = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(p))
d["runtime"]["serve"] = "setsid python3 -m http.server {port} --bind 127.0.0.1 </dev/null >/dev/null 2>&1 & echo $! > %s/daemon.pid" % tmp
d["runtime"]["stop"] = stop
json.dump(d, open(p, "w"), indent=2)' "$WC/.claude/worktree-profile.json" "$TMP" "$2"
  git -C "$WC" commit -qam "$1"
  git -C "$WC" branch "kept-$1"
  rm -f "$TMP/daemon.pid"
  serve "$WC" --serve >/dev/null
  dpid=$(cat "$TMP/daemon.pid" 2>/dev/null)
  SERVED="$SERVED $dpid"
}
STOP_CMD="echo stop {port} >> $TMP/stop.log; kill \$(cat $TMP/daemon.pid)"

daemon_worktree daemon-held "$STOP_CMD"
eq 'daemon fixture: recorded as stopped by runtime.stop' command "$(served_field "$WC" 7)"
eq 'daemon fixture: the app answers' yes "$(alive "$dpid")"
out=$(PITLANE_TRUST_PROFILES='' remove "$(remove_payload "$WC" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'unapproved stop: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'unapproved stop: the worktree is still removed' no "$(exists "$WC")"
eq 'unapproved stop: runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...the server is left running' yes "$(alive "$dpid")"
contains '...and stderr says why' 'runtime.stop is not approved' "$err"
eq '...its mirror is kept for /pitlane-tidy' 1 "$(count_in "$MIRRORS")"
kill "$dpid" 2>/dev/null
rm -f "$MIRRORS"/*

daemon_worktree daemon-stopped "$STOP_CMD"
port_c=$(served_field "$WC" 5)
port_c=${port_c##*:}
out=$(remove "$(remove_payload "$WC" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'approved stop: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'approved stop: the worktree is removed' no "$(exists "$WC")"
eq 'approved stop: runtime.stop ran, expanded' "stop ${port_c%/}" "$(cat "$TMP/stop.log" 2>/dev/null)"
eq '...and the server is stopped' no "$(alive "$dpid")"
eq '...its mirror is forgotten' '' "$(ls -A "$MIRRORS" 2>/dev/null)"
rm -f "$TMP/stop.log"

# runtime.stop fails: a server holds no work, so the teardown completes and the mirror is kept.
daemon_worktree daemon-unstoppable 'exit 3'
out=$(remove "$(remove_payload "$WC" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'failed stop: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'failed stop: the worktree is still removed' no "$(exists "$WC")"
contains '...stderr says the stop failed and teardown carried on' 'runtime.stop failed (exit 3); carrying on with the teardown' "$err"
eq '...its mirror is kept for /pitlane-tidy' 1 "$(count_in "$MIRRORS")"
kill "$dpid" 2>/dev/null
rm -f "$MIRRORS"/*

# Removed natively after its daemon had already gone: nothing answers at the URL, so the mirror is
# dropped and runtime.stop — which could only reach whatever holds that port now — is not run.
daemon_worktree daemon-quiet "$STOP_CMD"
kill "$dpid" 2>/dev/null
for _ in $(seq 1 50); do [ "$(alive "$dpid")" = no ] && break; sleep 0.1; done
git -C "$SVR" worktree remove --force "$WC"
out=$(remove "$(remove_payload "$WC" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'gone, quiet daemon: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq '...runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...the mirror is forgotten' '' "$(ls -A "$MIRRORS" 2>/dev/null)"
contains '...and stderr says why' 'record dropped, runtime.stop not run' "$err"

# Removed natively while its daemon still answers, after a live worktree was handed its port: the
# main checkout's runtime.stop, expanded with that port, could stop the live worktree's app. It is
# refused, the mirror kept for /pitlane-tidy, and the teardown still completes.
python3 - "$SVR/.claude/worktree-profile.json" "$STOP_CMD" <<'PY'
import json, sys
p, stop = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["runtime"]["stop"] = stop
json.dump(d, open(p, "w"), indent=2)
PY
git -C "$SVR" commit -qam stop
daemon_worktree daemon-reallocated "$STOP_CMD"
WL=$(create "$SVR" holder)
# shellcheck disable=SC1091  # the engine itself, sourced to read the live worktree's allocation
held_port=$( . "$SCRIPTS/bootstrap-lib.sh"
  wt_runtime_state_read "$(wt_state_path "$WL")" port )
eq 'reallocated fixture: the live worktree holds a port' yes "$([ -n "$held_port" ] && echo yes || echo no)"
python3 - "$MIRRORS" "$held_port" <<'PY'
import os, sys
d, port = sys.argv[1], sys.argv[2]
(name,) = os.listdir(d)
recs = open(os.path.join(d, name), encoding="latin-1").read().split("\x1e")
for i, rec in enumerate(recs):
    f = rec.split("\x1f")
    if f[0] == "worktree":
        f[5] = port
        recs[i] = "\x1f".join(f)
open(os.path.join(d, name), "w", encoding="latin-1").write("\x1e".join(recs))
PY
git -C "$SVR" worktree remove --force "$WC"
out=$(remove "$(remove_payload "$WC" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'gone, reallocated port: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq '...runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...the app is left running' yes "$(alive "$dpid")"
contains '...and stderr names the worktree that holds the port' "is now $WL's" "$err"
eq '...its mirror is kept for /pitlane-tidy' 1 "$(count_in "$MIRRORS")"
kill "$dpid" 2>/dev/null
rm -f "$MIRRORS"/*
remove "$(remove_payload "$WL" "$SVR")" "$SVR" >/dev/null

# Removed natively first (directory and admin dir gone, as Claude Code does): the hook that
# fires after finds the server through its mirror.
WN=$(create "$SVR" native)
serve "$WN" --serve >/dev/null
npid=$(served_pid "$WN")
SERVED="$SERVED $npid"
git -C "$SVR" worktree remove --force "$WN"
out=$(remove "$(remove_payload "$WN" "$SVR")" "$SVR")
err=$(cat "$TMP/err")
eq 'already gone: teardown exits 0' 0 "$(cat "$TMP/rc")"
eq 'already gone: the server its mirror records is stopped' no "$(alive "$npid")"
eq '...and the mirror forgotten' '' "$(ls -A "$MIRRORS" 2>/dev/null)"

eq 'serves: the main checkout'"'"'s own server survived every teardown' yes "$(alive "$main_srv")"
kill "$main_srv" 2>/dev/null
sleep 0.2
eq 'serves: nothing started here is left running' '' "$(running_under "$TMP")"
else
  printf 'SKIP serve teardown: needs setsid and /proc\n' >&2
fi

# ---------------------------------------------------------------------------
# The rm -rf fallback deletes only what was checked, and says when it could not
# ---------------------------------------------------------------------------

# The teardown script swaps the worktree for a symlink to where it moved it. The second guard
# follows the link and finds a clean checkout; the fallback must still refuse to delete through it.
RS=$TMP/repo-swaps
# shellcheck disable=SC2016  # $WT_PATH belongs to the teardown script.
make_repo "$RS" 'mv "$WT_PATH" "$WT_PATH.moved" && ln -s "$WT_PATH.moved" "$WT_PATH"'
WSW=$(create "$RS" swapped)
out=$(PATH=$TMP/shim:$PATH remove "$(remove_payload "$WSW" "$RS")" "$RS")
err=$(cat "$TMP/err")
eq 'swapped for a symlink: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
eq 'swapped for a symlink: nothing on stdout' '' "$out"
eq 'swapped for a symlink: the directory it points at survives' yes "$(exists "$WSW.moved/app.txt")"
eq 'swapped for a symlink: the ledger entry is kept' yes "$(exists "$RS/.git/worktree-ledger/swapped")"
contains 'swapped for a symlink: stderr says why' 'no longer resolves to the worktree that was checked' "$err"
lacks 'swapped for a symlink: and does not claim a removal' 'removed ' "$err"

# A gitignored directory rm cannot empty: the guard is right that it holds no work, and the
# fallback must say it left the directory behind rather than claim the removal.
if [ "$(id -u)" != 0 ]; then
  WU=$(create "$R" undeletable)
  mkdir -p "$WU/vendor/sealed"
  printf 'x\n' >"$WU/vendor/sealed/file"
  chmod 555 "$WU/vendor/sealed"
  out=$(PATH=$TMP/shim:$PATH remove "$(remove_payload "$WU" "$R")" "$R")
  err=$(cat "$TMP/err")
  chmod 755 "$WU/vendor/sealed"
  eq 'undeletable: exits 1, so Claude Code reports the worktree kept rather than removed' 1 "$(cat "$TMP/rc")"
  eq 'undeletable: nothing on stdout' '' "$out"
  eq 'undeletable: the directory is still there' yes "$(exists "$WU/vendor/sealed/file")"
  eq 'undeletable: the ledger entry is kept' yes "$(exists "$R/.git/worktree-ledger/undeletable")"
  contains 'undeletable: stderr says to remove it by hand' 'remove it by hand' "$err"
  lacks 'undeletable: and does not claim a removal' "removed $WU" "$err"
else
  printf 'SKIP running as root, so no directory is undeletable\n' >&2
fi
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_teardown.sh\n' >&2
      printf '      Or set WT_TEST_ALLOW_MISSING_BACKEND=1 to accept a one-sided run.\n' >&2
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
BACKEND=none

printf '%d passed, %d failed, %d backend(s) exercised\n' "$pass" "$fail" "$backends_run" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
