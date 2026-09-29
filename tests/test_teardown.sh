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
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)
CREATE_HOOK=$SCRIPTS/bootstrap.sh
REMOVE_HOOK=$SCRIPTS/teardown.sh
TMP=$(mktemp -d)
TMP=$(cd -P "$TMP" && pwd -P)
listener_pid=''
trap '[ -n "$listener_pid" ] && kill "$listener_pid" 2>/dev/null; rm -rf "$TMP"' EXIT

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset XDG_CONFIG_HOME
HOME=$TMP/home
mkdir -p "$HOME"
export HOME

DB=$TMP/databases
LOGS=$TMP/teardown-logs
mkdir -p "$DB" "$LOGS"

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

exists() { [ -e "$1" ] && echo yes || echo no; }

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
    "port": { "var": "SERVER_PORT", "base": 3786, "span": 200 },
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
  } >"$dir/.claude/worktree-seed.sh"
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\n'
    printf '{ for v in WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT WT_ENV_FILE; do printf "%%s=%%s\\n" "$v" "${!v-<unset>}"; done\n'
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
  "$(stat -c %h "$R/vendor/autoload.php" 2>/dev/null)"
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
contains 'and ran inside the worktree' "PWD=$W" "$log"

# Disk-neutral apart from what is shared on purpose.
eq 'the main checkout and its git dir are back to their files' "$before_files" "$(footprint "$R")"
eq 'the hardlink source is untouched' 'shared' "$(cat "$R/vendor/autoload.php")"
eq 'and is no longer linked from anywhere' 1 "$(stat -c %h "$R/vendor/autoload.php" 2>/dev/null)"
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
eq 'dirty: exits 0' 0 "$(cat "$TMP/rc")"
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
contains 'failing teardown: and that prune will list it' '/worktree-prune will list it' "$err"

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
eq 'script leaves work: exits 0' 0 "$(cat "$TMP/rc")"
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

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
