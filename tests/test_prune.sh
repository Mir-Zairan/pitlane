#!/usr/bin/env bash
#
# End-to-end tests for hooks/scripts/prune.sh — the /worktree-prune sweep — against worktrees that
# bootstrap.sh itself created from a WorktreeCreate payload, so every state file and ledger entry is
# the real one, then broken the ways real machines break them: a checkout deleted by hand, an admin
# dir pruned under a checkout, a ledger write that failed, a main checkout that moved.
#
# What is asserted is the contract the skill relies on: the report changes nothing on disk; an apply
# frees exactly the ids it was given and nothing else; a live worktree is never touched whatever id
# is passed; everything is re-judged at apply time; and ids are stable between runs.
#
# The seed and teardown scripts stand a marker file OUTSIDE the repository in for a database, as in
# tests/test_teardown.sh, so "the teardown ran" is observable after the worktree is gone.
#
# The profile is read through the JSON layer, so the whole suite runs once per backend:
#
#   tests/test_prune.sh                            # every backend present on this machine
#   nix shell nixpkgs#jq -c tests/test_prune.sh    # ...including jq, if it isn't installed
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

SCRIPTS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)
CREATE_HOOK=$SCRIPTS/bootstrap.sh
PRUNE=$SCRIPTS/prune.sh
SCRATCH=$(mktemp -d)
SCRATCH=$(cd -P "$SCRATCH" && pwd -P)
TMP=$SCRATCH
trap 'chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
unset XDG_CONFIG_HOME
HOME=$SCRATCH/home
mkdir -p "$HOME"
export HOME

pass=0 fail=0 backends_run=0
BACKEND=none
TAB=$'\t'

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

du_bytes() { echo $(( $(du -sk -- "$1" | cut -f1) * 1024 )); }

# A repository whose profile hardlinks vendor/ and isolates a runtime whose seed creates
# "$DB/<slug>" and whose teardown logs its environment and removes it. $2 is extra teardown shell.
make_repo() {  # $1 = dir, $2 = extra teardown shell
  local dir=$1 extra=${2-}
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
  cat >"$dir/.claude/worktree-profile.json" <<'JSON'
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
  "timeouts": { "bootstrapSeconds": 60, "seedSeconds": 20 }
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

create() {  # $1 = repo, $2 = name; prints the worktree path
  ( cd "$1" && printf '{"hook_event_name":"WorktreeCreate","name":"%s","cwd":"%s"}' "$2" "$1" \
    | bash "$CREATE_HOOK" 2>"$TMP/create-err" )
}

# Run the sweep from $1 with the rest as arguments: stdout to $TMP/out, stderr to $TMP/err, the
# exit status to $TMP/rc.
prune() {  # $1 = directory to run from, $@ = arguments
  local dir=$1 rc=0
  shift
  ( cd "$dir" && bash "$PRUNE" "$@" >"$TMP/out" 2>"$TMP/err" ) || rc=$?
  printf '%s' "$rc" >"$TMP/rc"
}

# A field of the report line for the item of kind $1 at path $2: 1 id, 4 bytes, 5 action, 6 reason.
field() {  # $1 = kind, $2 = path, $3 = field number
  awk -F'\t' -v k="$1" -v p="$2" -v n="$3" '$2 == k && $3 == p { print $n; exit }' "$TMP/out"
}

# Every path under the given roots with each file's checksum: what "changed nothing" is compared by.
snapshot() {  # $@ = roots
  find "$@" -print 2>/dev/null | LC_ALL=C sort
  find "$@" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
}

run_suite() {
TMP=$SCRATCH/$BACKEND
DB=$TMP/databases
LOGS=$TMP/teardown-logs
mkdir -p "$DB" "$LOGS"

# ---------------------------------------------------------------------------
# One repository holding one of everything
# ---------------------------------------------------------------------------

R=$TMP/repo
make_repo "$R"
WTS=$R/.claude/worktrees
LEDGER=$R/.git/worktree-ledger

# orphan: a checkout whose admin dir was deleted under it. Its files are committed or ignored.
O=$(create "$R" orph)
eq 'fixture: orph was created' "$WTS/orph" "$O"
rm -rf "$R/.git/worktrees/orph"
# gone: a checkout deleted by hand — the admin dir and ledger entry stay behind.
G=$(create "$R" gone)
rm -rf "$G"
# stateonly: the same, where the ledger write had failed, so the state file is the only record.
S=$(create "$R" stateonly)
rm -f "$LEDGER/stateonly"
rm -rf "$S"
# Leftover directories git never knew: one holding a note nothing committed, one empty, and one
# holding only a copy of a committed file, nested beside a live worktree.
N=$WTS/notes-left
mkdir -p "$N"
printf 'my own notes\n' >"$N/note.txt"
E=$WTS/empty-left
mkdir -p "$E"
git -C "$R" worktree add -q "$WTS/bob/live" -b bob-live 2>/dev/null
BO=$WTS/bob/old
mkdir -p "$BO"
cp "$R/app.txt" "$BO/app.txt"
# live worktrees: one clean, one holding an untracked file.
L1=$(create "$R" liveclean)
L2=$(create "$R" livedirty)
printf 'wip\n' >"$L2/scratch.txt"
# ledger junk: an abandoned temp file, a fresh one, and an entry no version can read.
printf 'half' >"$LEDGER/.wtledger.old"
touch -t 202001010000 "$LEDGER/.wtledger.old"
printf 'half' >"$LEDGER/.wtledger.new"
printf 'garbage' >"$LEDGER/garbage"

eq 'fixture: the stale admin dirs are there' 'yes yes' \
  "$(exists "$R/.git/worktrees/gone") $(exists "$R/.git/worktrees/stateonly")"
eq 'fixture: all three seeds ran' 'yes yes yes' "$(exists "$DB/orph") $(exists "$DB/gone") $(exists "$DB/stateonly")"

# --- report ----------------------------------------------------------------------------------

marker=$TMP/before-report
before=$(snapshot "$R" "$DB" "$LOGS")
touch "$marker"
sleep 1
prune "$R"
after=$(snapshot "$R" "$DB" "$LOGS")
report=$(cat "$TMP/out")
eq 'report: exits 0' 0 "$(cat "$TMP/rc")"
eq 'report: changes nothing on disk, .git included' "$before" "$after"
eq 'report: modifies nothing' '' "$(find "$R" "$DB" "$LOGS" -newer "$marker" 2>/dev/null)"

eq 'report: the orphan checkout is deleted' delete "$(field orphan-dir "$O" 5)"
eq 'report: its bytes are du' "$(du_bytes "$O")" "$(field orphan-dir "$O" 4)"
contains 'report: and it says the hardlinked vendor/ is shared' 'shared with other hardlinks' \
  "$(field orphan-dir "$O" 6)"
eq 'report: an empty leftover is deleted' delete "$(field orphan-dir "$E" 5)"
eq 'report: with bytes du' "$(du_bytes "$E")" "$(field orphan-dir "$E" 4)"
eq 'report: a nested leftover holding committed content is deleted' delete "$(field orphan-dir "$BO" 5)"
eq 'report: a leftover holding uncommitted content is refused' refuse "$(field orphan-dir "$N" 5)"
contains 'report: saying it cannot verify it' 'cannot verify, refusing' "$(field orphan-dir "$N" 6)"
contains 'report: and naming the file' 'note.txt' "$(field orphan-dir "$N" 6)"
eq 'report: the parent of a live nested worktree is not an orphan' '' \
  "$(field orphan-dir "$WTS/bob" 1)"

eq 'report: the stale admin dir is deleted' delete "$(field stale-admin "$R/.git/worktrees/gone" 5)"
eq 'report: with bytes du' "$(du_bytes "$R/.git/worktrees/gone")" \
  "$(field stale-admin "$R/.git/worktrees/gone" 4)"
eq 'report: its leftover allocation is torn down' teardown "$(field runtime-leftover "$G" 5)"
eq 'report: with bytes unknown' - "$(field runtime-leftover "$G" 4)"
contains 'report: and says why' 'size unknown' "$(field runtime-leftover "$G" 6)"

eq 'report: the state-only allocation is reported as runtime' teardown \
  "$(field runtime-leftover "$S" 5)"
contains 'report: from the state file' 'recorded only in the state file' "$(field runtime-leftover "$S" 6)"
eq 'report: and its admin dir waits for it' refuse "$(field stale-admin "$R/.git/worktrees/stateonly" 5)"
contains 'report: naming the id to apply first' "apply $(field runtime-leftover "$S" 1) first" \
  "$(field stale-admin "$R/.git/worktrees/stateonly" 6)"

eq 'report: the orphan'\''s allocation waits for its directory' refuse "$(field runtime-leftover "$O" 5)"
contains 'report: naming the orphan item' "$(field orphan-dir "$O" 1)" "$(field runtime-leftover "$O" 6)"

eq 'report: the dirty live worktree is held' none "$(field held "$L2" 5)"
contains 'report: with its reasons' 'untracked files' "$(field held "$L2" 6)"
lacks 'report: the clean live worktree is not listed' "$L1$TAB" "$report"
lacks 'report: nor its allocation' "$L1" "$report"
lacks 'report: nor the live nested worktree' "$WTS/bob/live$TAB" "$report"

eq 'report: an abandoned temp entry is deleted' delete "$(field ledger-junk "$LEDGER/.wtledger.old" 5)"
eq 'report: a fresh temp entry is not listed' '' "$(field ledger-junk "$LEDGER/.wtledger.new" 1)"
eq 'report: an unreadable entry is listed, not deleted' none "$(field ledger-junk "$LEDGER/garbage" 5)"

contains 'report: the summary gives the exact command' "--apply" "$report"
contains 'report: which names an applicable id' "$(field orphan-dir "$O" 1)" "$(grep '^# to apply' "$TMP/out")"
eq 'report: the last line is complete' 1 "$(tail -c1 "$TMP/out" | wc -l | tr -d ' ')"
lacks 'report: and no held one' "$(field held "$L2" 1)" "$(grep '^# to apply' "$TMP/out")"

prune "$R"
eq 'ids: a second report is identical' "$report" "$(cat "$TMP/out")"
prune "$L1" --repo "$L1"
eq 'ids: and the same from inside a worktree' "$report" "$(cat "$TMP/out")"

# --- apply -----------------------------------------------------------------------------------

ids=''
for spec in "orphan-dir$TAB$O" "orphan-dir$TAB$E" "orphan-dir$TAB$BO" \
  "stale-admin$TAB$R/.git/worktrees/gone" "stale-admin$TAB$R/.git/worktrees/stateonly" \
  "runtime-leftover$TAB$G" "runtime-leftover$TAB$S" "runtime-leftover$TAB$O" \
  "ledger-junk$TAB$LEDGER/.wtledger.old"; do
  ids="$ids $(field "${spec%%"$TAB"*}" "${spec#*"$TAB"}" 1)"
done
o_id=$(field orphan-dir "$O" 1)
o_bytes=$(field orphan-dir "$O" 4)
held_id=$(field held "$L2" 1)
garbage_id=$(field ledger-junk "$LEDGER/garbage" 1)
# The id the clean live worktree WOULD have as an orphan: forged with the script's own formula.
forged=$(printf 'p%08x' "$(printf 'orphan-dir\037%s' "$L1" | cksum | cut -d' ' -f1)")

keep=$(snapshot "$R/app.txt" "$R/vendor" "$R/.env" "$R/.claude/worktree-profile.json" "$N" \
  "$WTS/bob/live" "$L1" "$L2" "$R/.git/worktrees/live" "$R/.git/worktrees/liveclean" \
  "$R/.git/worktrees/livedirty" "$R/.git/refs" "$R/.git/objects" "$LEDGER/liveclean" \
  "$LEDGER/livedirty" "$LEDGER/.wtledger.new" "$LEDGER/garbage" "$DB/liveclean" "$DB/livedirty")
# shellcheck disable=SC2086  # ids is a word list
prune "$R" --apply $ids "$held_id" "$garbage_id" "$forged" p00000000
out=$(cat "$TMP/out")
err=$(cat "$TMP/err")
eq 'apply: exits 1, since some ids were refused' 1 "$(cat "$TMP/rc")"
eq 'apply: nothing else was touched' "$keep" "$(snapshot "$R/app.txt" "$R/vendor" "$R/.env" \
  "$R/.claude/worktree-profile.json" "$N" "$WTS/bob/live" "$L1" "$L2" "$R/.git/worktrees/live" \
  "$R/.git/worktrees/liveclean" "$R/.git/worktrees/livedirty" "$R/.git/refs" "$R/.git/objects" \
  "$LEDGER/liveclean" "$LEDGER/livedirty" "$LEDGER/.wtledger.new" "$LEDGER/garbage" \
  "$DB/liveclean" "$DB/livedirty")"
eq 'apply: the orphans are gone' 'no no no' "$(exists "$O") $(exists "$E") $(exists "$BO")"
eq 'apply: the parent of the live nested worktree stays' yes "$(exists "$WTS/bob/live/app.txt")"
eq 'apply: the stale admin dirs are gone' 'no no' \
  "$(exists "$R/.git/worktrees/gone") $(exists "$R/.git/worktrees/stateonly")"
eq 'apply: every leftover allocation was torn down' 'no no no' \
  "$(exists "$DB/orph") $(exists "$DB/gone") $(exists "$DB/stateonly")"
eq 'apply: and its ledger entry forgotten' 'no no' "$(exists "$LEDGER/orph") $(exists "$LEDGER/gone")"
eq 'apply: the abandoned temp entry is gone' no "$(exists "$LEDGER/.wtledger.old")"
contains 'apply: the teardown ran from the main checkout' "PWD=$R" "$(cat "$LOGS/gone.log")"
contains 'apply: with the recorded worktree path' "WT_PATH=$G" "$(cat "$LOGS/gone.log")"
contains 'apply: and the recorded name' 'WT_NAME=gone' "$(cat "$LOGS/gone.log")"
contains 'apply: and the recorded env file' 'WT_ENV_FILE=.env.worktree.local' "$(cat "$LOGS/gone.log")"
contains 'apply: the state-only allocation got its recorded slug' 'WT_SLUG=stateonly' \
  "$(cat "$LOGS/stateonly.log")"
contains 'apply: freed bytes are reported per item, matching the report' \
  "applied$TAB$o_id${TAB}orphan-dir$TAB$O$TAB$o_bytes$TAB" "$out"
contains 'apply: the held worktree is refused' "refused$TAB$held_id" "$out"
contains 'apply: the unreadable entry is refused' "refused$TAB$garbage_id" "$out"
contains 'apply: the forged id is refused' "refused$TAB$forged" "$out"
contains 'apply: an unknown id is refused' "refused${TAB}p00000000" "$out"
contains 'apply: refusals are loud on stderr' "REFUSED $held_id" "$err"
eq 'apply: exactly nine applied' 9 "$(grep -c '^applied' "$TMP/out")"

prune "$R" --apply p00000000
eq 'apply: an unknown id alone exits 1' 1 "$(cat "$TMP/rc")"

# ---------------------------------------------------------------------------
# Changed between report and apply: re-judged, and refused
# ---------------------------------------------------------------------------

D=$(create "$R" dirtied)
rm -rf "$R/.git/worktrees/dirtied"
K=$(create "$R" relinked)
cp -a "$R/.git/worktrees/relinked" "$TMP/relinked-admin"
rm -rf "$R/.git/worktrees/relinked"
prune "$R"
d_id=$(field orphan-dir "$D" 1)
k_id=$(field orphan-dir "$K" 1)
eq 'changed: both were orphans at report time' 'delete delete' \
  "$(field orphan-dir "$D" 5) $(field orphan-dir "$K" 5)"
printf 'written after the report\n' >"$D/late.txt"
mv "$TMP/relinked-admin" "$R/.git/worktrees/relinked"
prune "$R" --apply "$d_id" "$k_id"
eq 'changed: exits 1' 1 "$(cat "$TMP/rc")"
eq 'changed: the dirtied one survives with its new file' yes "$(exists "$D/late.txt")"
eq 'changed: the relinked one survives' yes "$(exists "$K/app.txt")"
contains 'changed: the dirtied one is refused as unverifiable' "refused$TAB$d_id" "$(cat "$TMP/out")"
contains 'changed: saying why' 'late.txt' "$(cat "$TMP/out")"
contains 'changed: the relinked one is refused' "refused$TAB$k_id" "$(cat "$TMP/out")"

# ---------------------------------------------------------------------------
# A teardown script that fails keeps the entry
# ---------------------------------------------------------------------------

RF=$TMP/repo-failing
make_repo "$RF" 'exit 1'
F=$(create "$RF" failing)
rm -rf "$F"
prune "$RF"
f_id=$(field runtime-leftover "$F" 1)
eq 'failing: reported as teardown' teardown "$(field runtime-leftover "$F" 5)"
prune "$RF" --apply "$f_id"
eq 'failing: exits 1' 1 "$(cat "$TMP/rc")"
eq 'failing: the ledger entry is kept' yes "$(exists "$RF/.git/worktree-ledger/failing")"
contains 'failing: refused with the outcome' 'outcome was failed' "$(cat "$TMP/out")"
prune "$RF"
eq 'failing: and listed again, with the same id' teardown "$(field runtime-leftover "$F" 5)"

# No teardown script: the entry is only forgotten, and the report says to do so by hand.
RN=$TMP/repo-noscript
make_repo "$RN"
NW=$(create "$RN" noscript)
rm -rf "$NW"
sed 's/"teardown": ".claude\/worktree-teardown.sh"/"teardown": ""/' \
  "$RN/.claude/worktree-profile.json" >"$TMP/profile" && mv "$TMP/profile" "$RN/.claude/worktree-profile.json"
prune "$RN"
eq 'no script: reported as forget' forget "$(field runtime-leftover "$NW" 5)"
contains 'no script: saying to release it by hand' 'released it by hand' "$(field runtime-leftover "$NW" 6)"
prune "$RN" --apply "$(field runtime-leftover "$NW" 1)"
eq 'no script: exits 0' 0 "$(cat "$TMP/rc")"
eq 'no script: the entry is forgotten' no "$(exists "$RN/.git/worktree-ledger/noscript")"
eq 'no script: and nothing was run' yes "$(exists "$DB/noscript")"

# ---------------------------------------------------------------------------
# A main checkout moved since creation: nothing can be proven, so nothing is done
# ---------------------------------------------------------------------------

RM=$TMP/repo-moved
make_repo "$RM"
create "$RM" moved >/dev/null
mv "$RM" "$TMP/repo-moved-elsewhere"
RM2=$TMP/repo-moved-elsewhere
WM2=$RM2/.claude/worktrees/moved
before=$(snapshot "$RM2" "$DB")
prune "$RM2"
eq 'moved: the checkout is refused' refuse "$(field orphan-dir "$WM2" 5)"
contains 'moved: pointing at git worktree repair' 'git worktree repair' "$(field orphan-dir "$WM2" 6)"
eq 'moved: its admin dir is refused' refuse "$(field stale-admin "$RM2/.git/worktrees/moved" 5)"
eq 'moved: its allocation is refused' refuse "$(field runtime-leftover "$RM/.claude/worktrees/moved" 5)"
moved_ids=$(awk -F'\t' '$1 ~ /^p/ { print $1 }' "$TMP/out")
# shellcheck disable=SC2086  # a word list
prune "$RM2" --apply $moved_ids
eq 'moved: apply exits 1' 1 "$(cat "$TMP/rc")"
eq 'moved: nothing was applied' 0 "$(grep -c '^applied' "$TMP/out")"
# The sweep's own lock file is the one thing an apply may create, and it is shared state it keeps.
eq 'moved: nothing changed but the sweep'\''s lock file' "$before" \
  "$(snapshot "$RM2" "$DB" | grep -v '/worktree-locks/prune\.lock$')"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

prune "$R" --apply
eq 'usage: --apply with no ids exits 2' 2 "$(cat "$TMP/rc")"
prune "$TMP" --repo "$TMP"
eq 'usage: outside any repository exits 2' 2 "$(cat "$TMP/rc")"
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_prune.sh\n' >&2
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
