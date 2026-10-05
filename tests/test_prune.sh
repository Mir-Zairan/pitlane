#!/usr/bin/env bash
#
# End-to-end tests for hooks/scripts/prune.sh — the /pitlane-tidy sweep — against worktrees that
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
# Every server a test starts is killed on the way out, by its group, whatever happened.
SERVED=''
kill_served() {
  local g
  for g in $SERVED; do kill -s KILL -- "-$g" "$g" 2>/dev/null; done
}
trap 'kill_served; chmod -R u+w "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
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
    "port": { "var": "SERVER_PORT", "base": 4100, "span": 200 },
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
# Its admin dir is still registered, and a registered admin dir may belong to a worktree that was
# moved: the allocation waits until that is settled, and is released in the same apply after it.
eq 'report: its leftover allocation waits for the admin dir' refuse "$(field runtime-leftover "$G" 5)"
eq 'report: with bytes unknown' - "$(field runtime-leftover "$G" 4)"
contains 'report: naming the admin dir item' "$(field stale-admin "$R/.git/worktrees/gone" 1)" \
  "$(field runtime-leftover "$G" 6)"

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
rows=$(grep -v '^#' "$TMP/out")
eq 'report: distinct items have distinct ids' '' "$(printf '%s\n' "$rows" | cut -f1 | LC_ALL=C sort | uniq -d)"
applicable_bytes=$(printf '%s\n' "$rows" | awk -F'\t' \
  '($5 == "delete" || $5 == "teardown" || $5 == "forget") && $4 ~ /^[0-9]+$/ { s += $4 } END { print s + 0 }')
contains 'report: the bytes to free are the sum of the applicable rows' "frees $applicable_bytes bytes" "$report"
eq 'report: the counts are the rows' "$(printf '%s\n' "$rows" | awk -F'\t' -v root="$R" '
  { n++ } $5 == "delete" || $5 == "teardown" || $5 == "forget" { a++ } $5 == "refuse" { r++ }
  $5 == "none" { h++ }
  END { printf "# %d item(s) in %s: %d can be applied, %d refused, %d listed only", n, root, a, r, h }')" \
  "$(grep '^# [0-9]* item' "$TMP/out")"
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
eq 'apply: the summary totals are the rows' "# $(grep -c '^applied' "$TMP/out") applied, $(grep -c '^refused' "$TMP/out") refused, $(awk -F'\t' '$1 == "applied" && $5 ~ /^[0-9]+$/ { s += $5 } END { print s + 0 }' "$TMP/out") bytes freed by du" \
  "$(grep '^# ' "$TMP/out")"

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
git -C "$RF" worktree remove --force "$F"
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
git -C "$RN" worktree remove --force "$NW"
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
# Never released: a registered or locked worktree, an unloadable profile, a held allocation
# ---------------------------------------------------------------------------

RS=$TMP/repo-safety
make_repo "$RS"
WS=$RS/.claude/worktrees
LS=$RS/.git/worktree-ledger

# Moved with `git worktree move`: the ledger still names the old path, but the admin dir says where
# the worktree is now.
MV=$(create "$RS" movedwt)
git -C "$RS" worktree move "$MV" "$TMP/movedwt-elsewhere"
# Locked, and its directory absent: a worktree on a removable disk.
LK=$(create "$RS" lockedwt)
git -C "$RS" worktree lock --reason 'on a usb disk' "$LK"
rm -rf "$LK"
prune "$RS"
mv_id=$(field runtime-leftover "$MV" 1)
lk_id=$(field runtime-leftover "$LK" 1)
lk_admin_id=$(field stale-admin "$RS/.git/worktrees/lockedwt" 1)
eq 'moved: its allocation is refused' refuse "$(field runtime-leftover "$MV" 5)"
contains 'moved: because its admin dir is still registered' 'still registered' \
  "$(field runtime-leftover "$MV" 6)"
eq 'locked: its admin dir is refused' refuse "$(field stale-admin "$RS/.git/worktrees/lockedwt" 5)"
contains 'locked: saying so' 'locked with' "$(field stale-admin "$RS/.git/worktrees/lockedwt" 6)"
eq 'locked: its allocation is refused' refuse "$(field runtime-leftover "$LK" 5)"
contains 'locked: because the worktree is locked' 'locked' "$(field runtime-leftover "$LK" 6)"
prune "$RS" --apply "$mv_id" "$lk_id" "$lk_admin_id"
eq 'registered: apply exits 1' 1 "$(cat "$TMP/rc")"
eq 'registered: nothing applied' 0 "$(grep -c '^applied' "$TMP/out")"
eq 'registered: no teardown ran' 'yes yes' "$(exists "$DB/movedwt") $(exists "$DB/lockedwt")"
eq 'registered: both ledger entries are kept' 'yes yes' "$(exists "$LS/movedwt") $(exists "$LS/lockedwt")"
eq 'registered: the locked admin dir is kept' yes "$(exists "$RS/.git/worktrees/lockedwt")"
eq 'registered: the moved worktree is untouched' yes "$(exists "$TMP/movedwt-elsewhere/app.txt")"

# Every other reason a stale admin dir is kept. Plain `git worktree add`, so no allocation is mixed in.
git -C "$RS" worktree add -q --detach "$WS/det" 2>/dev/null
git -C "$WS/det" commit -q --allow-empty -m 'on no branch'
git -C "$RS" worktree add -q "$WS/mrg" -b mrg 2>/dev/null
git -C "$RS" worktree add -q "$WS/rbs" -b rbs 2>/dev/null
git -C "$RS" worktree add -q "$WS/bis" -b bis 2>/dev/null
git -C "$RS" worktree add -q "$WS/ugd" -b ugd 2>/dev/null
rm -rf "$WS/det" "$WS/mrg" "$WS/rbs" "$WS/bis" "$WS/ugd"
touch "$RS/.git/worktrees/mrg/MERGE_HEAD" "$RS/.git/worktrees/bis/BISECT_LOG"
mkdir "$RS/.git/worktrees/rbs/rebase-merge"
chmod 000 "$RS/.git/worktrees/ugd/gitdir"
prune "$RS"
stale_ids=''
for spec in 'det:no branch' 'mrg:merge in progress' 'rbs:rebase in progress' \
  'bis:bisect in progress' 'ugd:cannot be read'; do
  a=$RS/.git/worktrees/${spec%%:*}
  eq "stale admin ${spec%%:*}: refused" refuse "$(field stale-admin "$a" 5)"
  contains "stale admin ${spec%%:*}: saying why" "${spec#*:}" "$(field stale-admin "$a" 6)"
  stale_ids="$stale_ids $(field stale-admin "$a" 1)"
done
# shellcheck disable=SC2086  # a word list
prune "$RS" --apply $stale_ids
eq 'stale admin: apply exits 1' 1 "$(cat "$TMP/rc")"
eq 'stale admin: nothing applied' 0 "$(grep -c '^applied' "$TMP/out")"
eq 'stale admin: every admin dir survives' 'yes yes yes yes yes' \
  "$(for a in det mrg rbs bis ugd; do printf '%s ' "$(exists "$RS/.git/worktrees/$a")"; done | sed 's/ $//')"
chmod 644 "$RS/.git/worktrees/ugd/gitdir"

# Leftover directories whose content cannot be proven committed, and one with hostile characters
# in its name whose content can.
mkdir -p "$WS/nested" "$WS/linky" "$WS/nl"
git init -q "$WS/nested/sub"
git init -q "$WS/ownrepo"
printf 'keep me\n' >"$TMP/outside-target"
ln -s "$TMP/outside-target" "$WS/linky/link"
printf 'x\n' >"$WS/nl/a"$'\n'"b"
HN=$WS/tab$'\t'nl$'\n'semi\;x
mkdir -p "$HN"
cp "$RS/app.txt" "$HN/app.txt"
hn_id=$(printf 'p%08x' "$(printf 'orphan-dir\037%s' "$HN" | cksum | cut -d' ' -f1)")
prune "$RS"
orphan_ids=''
for spec in 'nested:a repository of its own' 'ownrepo:its .git is a directory' \
  'linky:in no commit' 'nl:newline'; do
  d=$WS/${spec%%:*}
  eq "orphan ${spec%%:*}: refused" refuse "$(field orphan-dir "$d" 5)"
  contains "orphan ${spec%%:*}: saying why" "${spec#*:}" "$(field orphan-dir "$d" 6)"
  orphan_ids="$orphan_ids $(field orphan-dir "$d" 1)"
done
eq 'hostile name: listed under its real key, printed flattened' \
  "orphan-dir$TAB$WS/tab nl semi;x${TAB}delete" \
  "$(awk -F'\t' -v id="$hn_id" '$1 == id { print $2 "\t" $3 "\t" $5 }' "$TMP/out")"
# shellcheck disable=SC2086  # a word list
prune "$RS" --apply $orphan_ids "$hn_id"
eq 'orphans: apply exits 1' 1 "$(cat "$TMP/rc")"
eq 'orphans: only the provable one is applied' "applied$TAB$hn_id" "$(grep '^applied' "$TMP/out" | cut -f1-2)"
eq 'orphans: the hostile-named directory is gone' no "$(exists "$HN")"
eq 'orphans: every refused one survives' 'yes yes yes yes' \
  "$(exists "$WS/nested/sub/.git") $(exists "$WS/ownrepo/.git") $(exists "$WS/linky/link") $(exists "$WS/nl/a"$'\n'"b")"
eq 'orphans: the symlink target is untouched' 'keep me' "$(cat "$TMP/outside-target")"

# A directory registered again between the apply's discovery and its delete: the applier re-checks.
# A du on PATH that re-registers it on its second call on that directory — the discovery measures it
# first, the applier's before-size second, just before the delete.
RR=$WS/rereg
git -C "$RS" worktree add -q "$RR" -b rereg 2>/dev/null
mv "$RS/.git/worktrees/rereg" "$TMP/rereg-admin"
SHIM=$TMP/du-shim
mkdir -p "$SHIM"
printf '2\n' >"$TMP/du-calls"
# shellcheck disable=SC2016  # the $ references belong to the shim, not to this file.
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${!#}" = %q ] && [ -f %q ]; then\n' "$RR" "$TMP/du-calls"
  printf '  n=$(( $(cat %q) - 1 )); printf "%%s\\n" "$n" >%q\n' "$TMP/du-calls" "$TMP/du-calls"
  printf '  [ "$n" -eq 0 ] && rm -f %q && mv %q %q\n' "$TMP/du-calls" "$TMP/rereg-admin" "$RS/.git/worktrees/rereg"
  printf 'fi\n'
  printf 'exec %q "$@"\n' "$(command -v du)"
} >"$SHIM/du"
chmod +x "$SHIM/du"
prune "$RS"
rr_id=$(field orphan-dir "$RR" 1)
eq 'reregistered: an orphan at report time' delete "$(field orphan-dir "$RR" 5)"
PATH=$SHIM:$PATH prune "$RS" --apply "$rr_id"
eq 'reregistered: the shim ran' no "$(exists "$TMP/du-calls")"
eq 'reregistered: refused' "refused$TAB$rr_id" "$(grep "^refused$TAB$rr_id" "$TMP/out" | cut -f1-2)"
contains 'reregistered: as live' 'live worktree now' "$(cat "$TMP/out")"
eq 'reregistered: the worktree survives' yes "$(exists "$RR/app.txt")"

# The main checkout's profile cannot be loaded: whether a teardown script must run is unknown.
RP=$TMP/repo-badprofile
make_repo "$RP"
BP=$(create "$RP" badprof)
git -C "$RP" worktree remove --force "$BP"
printf 'not json{' >"$RP/.claude/worktree-profile.json"
prune "$RP"
bp_id=$(field runtime-leftover "$BP" 1)
eq 'bad profile: its allocation is refused' refuse "$(field runtime-leftover "$BP" 5)"
contains 'bad profile: saying why' 'cannot be loaded' "$(field runtime-leftover "$BP" 6)"
prune "$RP" --apply "$bp_id"
eq 'bad profile: apply exits 1' 1 "$(cat "$TMP/rc")"
eq 'bad profile: the teardown did not run' yes "$(exists "$DB/badprof")"
eq 'bad profile: the ledger entry is kept' yes "$(exists "$RP/.git/worktree-ledger/badprof")"

if command -v flock >/dev/null 2>&1; then
  # An allocation teardown.sh is releasing right now: held on its entry's lock, as teardown.sh holds it.
  HT=$(create "$RS" rtheld)
  git -C "$RS" worktree remove --force "$HT"
  prune "$RS"
  ht_id=$(field runtime-leftover "$HT" 1)
  eq 'held allocation: applicable when nothing holds it' teardown "$(field runtime-leftover "$HT" 5)"
  mkdir -p "$RS/.git/worktree-locks"
  exec 6>"$RS/.git/worktree-locks/rt-rtheld.lock"
  flock -n 6
  prune "$RS" --apply "$ht_id"
  exec 6>&-
  eq 'held allocation: apply exits 1' 1 "$(cat "$TMP/rc")"
  contains 'held allocation: refused as in release elsewhere' 'releasing' "$(cat "$TMP/out")"
  eq 'held allocation: the teardown did not run' yes "$(exists "$DB/rtheld")"
  eq 'held allocation: the ledger entry is kept' yes "$(exists "$LS/rtheld")"
  prune "$RS" --apply "$ht_id"
  eq 'held allocation: released once the lock is free' 0 "$(cat "$TMP/rc")"
  eq 'held allocation: and torn down then' no "$(exists "$DB/rtheld")"

  # Another prune applying in this repository.
  exec 6>"$RS/.git/worktree-locks/prune.lock"
  flock -n 6
  prune "$RS" --apply "$hn_id" p00000000
  exec 6>&-
  eq 'prune lock held: exits 1' 1 "$(cat "$TMP/rc")"
  eq 'prune lock held: every id refused' 2 "$(grep -c '^refused' "$TMP/out")"
  contains 'prune lock held: saying why' 'another prune is applying' "$(cat "$TMP/out")"
  eq 'prune lock held: the summary still closes the output' '# 0 applied, 2 refused, 0 bytes freed by du' \
    "$(tail -n1 "$TMP/out")"
else
  printf 'SKIP no flock to hold the allocation and prune locks with\n' >&2
fi

# ---------------------------------------------------------------------------
# Abandoned subagent worktrees
# ---------------------------------------------------------------------------
# Claude Code leaves a subagent worktree that a WorktreeCreate hook made, and fires no WorktreeRemove
# for it (measured, 2.1.286). Only an `agent-<hex>` worktree that is unlocked, holds no work and has
# been untouched for the threshold is offered — and applying it runs the teardown hook itself.
RB=$TMP/abandon
make_repo "$RB"
backdate() { find "$1" -exec touch -h -t 202001010000 {} + 2>/dev/null; }
WAB=$(create "$RB" agent-a1b2c3)
WRC=$(create "$RB" agent-d4e5f6)          # recent
WDY=$(create "$RB" agent-0a0b0c)          # stale, but holds work
WLK=$(create "$RB" agent-9f9f9f)          # stale, but locked (a running agent)
WNM=$(create "$RB" feature-x)             # stale and clean, but not a subagent worktree
eq 'abandoned: fixture — the seed made a database for the subagent worktree' yes "$(exists "$DB/agent_a1b2c3")"
printf 'edited\n' >>"$WDY/app.txt"
git -C "$RB" worktree lock "$WLK"
for w in "$WAB" "$WDY" "$WLK" "$WNM"; do backdate "$w"; done
prune "$RB"
id_ab=$(field abandoned "$WAB" 1)
eq 'abandoned: a stale, clean, unlocked subagent worktree is offered for teardown' teardown \
  "$(field abandoned "$WAB" 5)"
contains 'abandoned: saying why nothing else would remove it' 'fires no WorktreeRemove' "$(field abandoned "$WAB" 6)"
eq 'abandoned: a recently touched one is not offered' '' "$(field abandoned "$WRC" 5)"
eq 'abandoned: one holding work is held, never abandoned' 'none' "$(field held "$WDY" 5)"
eq 'abandoned: and is not offered as abandoned' '' "$(field abandoned "$WDY" 5)"
eq 'abandoned: a locked one is not offered' '' "$(field abandoned "$WLK" 5)"
eq 'abandoned: a worktree not named like a subagent one is not offered' '' "$(field abandoned "$WNM" 5)"
prune "$RB" --apply "$id_ab"
eq 'abandoned: apply exits 0' 0 "$(cat "$TMP/rc")"
eq 'abandoned: the worktree is gone' no "$(exists "$WAB")"
eq 'abandoned: its seeded database was released by the teardown script' no "$(exists "$DB/agent_a1b2c3")"
eq 'abandoned: its ledger entry is forgotten' no "$(exists "$RB/.git/worktree-ledger/agent-a1b2c3")"
eq 'abandoned: its branch is kept' yes \
  "$(git -C "$RB" show-ref --verify --quiet refs/heads/worktree-agent-a1b2c3 && echo yes || echo no)"
# Re-judged at apply: a worktree that picked up work since the report is refused, and kept.
WRJ=$(create "$RB" agent-777777)
backdate "$WRJ"
prune "$RB"
id_rj=$(field abandoned "$WRJ" 1)
printf 'late work\n' >"$WRJ/new-file.txt"
touch -h -t 202001010000 "$WRJ/new-file.txt" "$WRJ"
prune "$RB" --apply "$id_rj"
eq 'abandoned: work since the report refuses the item' 1 "$(cat "$TMP/rc")"
contains 'abandoned: refused, because discovery now lists it as held' 'refused' "$(cat "$TMP/out")"
prune "$RB"
eq 'abandoned: which the next report shows' 'none' "$(field held "$WRJ" 5)"
eq 'abandoned: and the worktree is still there' yes "$(exists "$WRJ/new-file.txt")"
git -C "$RB" worktree unlock "$WLK" 2>/dev/null

# ---------------------------------------------------------------------------
# Adoption: worktrees that predate the plugin
# ---------------------------------------------------------------------------
# Made with plain git, set up by hand, never bootstrapped: no state file, no ledger entry. A report
# over them must offer nothing for a live one, and must never claim a runtime allocation — any
# database such a worktree uses was made by hand, and the plugin cannot see it.
RA=$TMP/adopt
git init -q -b main "$RA"
git -C "$RA" config user.email t@example.com; git -C "$RA" config user.name t
printf '.claude/worktrees/\n.env.local\n' >"$RA/.gitignore"
printf 'tracked\n' >"$RA/app.txt"
git -C "$RA" add -A; git -C "$RA" commit -qm init
for n in handclean handdirty agent-a1; do
  git -C "$RA" worktree add -q "$RA/.claude/worktrees/$n" -b "worktree-$n" 2>/dev/null
  printf 'DB=hand_clone_%s\n' "$n" >"$RA/.claude/worktrees/$n/.env.local"
done
printf 'edited\n' >>"$RA/.claude/worktrees/handdirty/app.txt"
prune "$RA"
eq 'adoption: the report exits 0' 0 "$(cat "$TMP/rc")"
eq 'adoption: a clean live worktree is not offered' '' "$(grep "worktrees/handclean" "$TMP/out")"
eq 'adoption: nor an old-looking subagent worktree that is still live' '' "$(grep "worktrees/agent-a1" "$TMP/out")"
eq 'adoption: a dirty one is listed as held, with nothing to apply' 'none' \
  "$(field held "$RA/.claude/worktrees/handdirty" 5)"
eq 'adoption: no runtime allocation is invented for them' 0 \
  "$(grep -c "$(printf '\t')runtime-leftover$(printf '\t')" "$TMP/out" | tr -d ' ')"

# ---------------------------------------------------------------------------
# Servers /pitlane-serve started in worktrees removed without their teardown (ADR-015)
# ---------------------------------------------------------------------------

if command -v setsid >/dev/null 2>&1 && [ -d /proc/self ]; then
RV=$TMP/repo-serves
make_repo "$RV"
python3 -c 'import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["runtime"]["serve"] = "exec python3 -m http.server {port} --bind 127.0.0.1"
d["runtime"]["url"] = "http://127.0.0.1:{port}/"
json.dump(d, open(p, "w"), indent=2)' "$RV/.claude/worktree-profile.json"
git -C "$RV" commit -qam serve
RVM=$RV/.git/worktree-servers

# The main checkout's own server, started by hand: nothing records it, so nothing may touch it.
main_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
( cd "$RV" && exec setsid python3 -m http.server "$main_port" --bind 127.0.0.1 ) </dev/null >/dev/null 2>&1 &
main_srv=$!
SERVED="$SERVED $main_srv"

# A live worktree serving: its server is /pitlane-serve's to stop, never an item.
VL=$(create "$RV" servelive)
serve "$VL" --serve >/dev/null
lpid=$(served_pid "$VL")
SERVED="$SERVED $lpid"
# Removed natively while serving: directory, admin dir and state file gone; the mirror is left.
VG=$(create "$RV" servegone)
serve "$VG" --serve >/dev/null
gpid=$(served_pid "$VG")
SERVED="$SERVED $gpid"
git -C "$RV" worktree remove --force "$VG"
# Removed natively, its recorded PID since given to an unrelated process (simulated by a start
# identity that cannot match): never signalled, only forgotten.
VR=$(create "$RV" serverecycled)
setsid sleep 300 </dev/null >/dev/null 2>&1 &
other=$!
SERVED="$SERVED $other"
# shellcheck disable=SC1091  # the engine itself, sourced to write a record as /pitlane-serve does
( . "$SCRIPTS/bootstrap-lib.sh"
  wt_serve_record_write "$VR" "$other" "$other" 'stat:1' 'ck' 'http://127.0.0.1:1/' )
git -C "$RV" worktree remove --force "$VR"
eq 'serve fixture: the live, gone and recycled servers are each mirrored' 3 "$(count_in "$RVM")"
eq 'serve fixture: the servers are running' 'yes yes yes yes' \
  "$(alive "$main_srv") $(alive "$lpid") $(alive "$gpid") $(alive "$other")"

before=$(snapshot "$RV")
prune "$RV"
eq 'serve report: exits 0' 0 "$(cat "$TMP/rc")"
eq 'serve report: the gone worktree'"'"'s server is offered to stop' stop "$(field server-leftover "$VG" 5)"
contains '...naming its pid' "pid $gpid" "$(field server-leftover "$VG" 6)"
eq '...with no size' - "$(field server-leftover "$VG" 4)"
eq 'serve report: the recycled PID is offered only to forget' forget "$(field server-leftover "$VR" 5)"
contains '...saying it belongs to another process' 'belongs to another process' "$(field server-leftover "$VR" 6)"
eq 'serve report: the live worktree'"'"'s server is not an item' '' "$(grep -F "$VL" "$TMP/out")"
eq 'serve report: nor is the main checkout'"'"'s' '' "$(grep -F "$main_port" "$TMP/out")"
eq 'serve report: changes nothing on disk' "$before" "$(snapshot "$RV")"
eq 'serve report: and stops nothing' 'yes yes yes yes' \
  "$(alive "$main_srv") $(alive "$lpid") $(alive "$gpid") $(alive "$other")"
contains 'serve report: the stop is in the apply command' "$(field server-leftover "$VG" 1)" "$(grep '^# to apply' "$TMP/out")"

# Only what is confirmed: applying the recycled item first leaves the other server running.
id_g=$(field server-leftover "$VG" 1)
id_r=$(field server-leftover "$VR" 1)
prune "$RV" --apply "$id_r"
eq 'serve apply: forgetting the recycled record exits 0' 0 "$(cat "$TMP/rc")"
contains '...and says nothing was signalled' 'nothing was signalled or run' "$(grep "^applied" "$TMP/out")"
eq '...the process holding the PID is NOT signalled' yes "$(alive "$other")"
eq '...and the unconfirmed server still runs' yes "$(alive "$gpid")"
eq '...one mirror fewer' 2 "$(count_in "$RVM")"
prune "$RV" --apply "$id_g"
eq 'serve apply: stopping the confirmed server exits 0' 0 "$(cat "$TMP/rc")"
contains '...and says what it stopped' "stopped (pid $gpid" "$(grep "^applied" "$TMP/out")"
eq '...it is stopped' no "$(alive "$gpid")"
eq '...with every process of its group' 0 "$(pgrep -g "$gpid" 2>/dev/null | wc -l | tr -d ' ')"
eq '...its mirror is forgotten, the live one kept' 1 "$(count_in "$RVM")"
eq 'serve apply: the live worktree'"'"'s server still runs' yes "$(alive "$lpid")"
eq 'serve apply: and the main checkout'"'"'s' yes "$(alive "$main_srv")"
prune "$RV" --apply "$id_g"
eq 'serve apply: the same id again is refused' 1 "$(cat "$TMP/rc")"
kill "$other" 2>/dev/null

US=$'\x1f' RSEP=$'\x1e'
# Write serve mirror $1 as /pitlane-serve would: for worktree path $2 with slug $3 and port $4, a
# server of pid $5 at URL $6 stopped by $7; $8 is the wtstate version (default 1).
mirror_put() {  # $1 = file name, $2 = path, $3 = slug, $4 = port, $5 = pid, $6 = url, $7 = stopby, $8 = version
  printf '%s' "wtstate${US}${8:-1}${RSEP}worktree$US$2$US${2##*/}$US${2##*/}$US$3$US$4${RSEP}serve$US$5$US$US${US}ck$US$6${US}1$US$7$RSEP" \
    >"$RVM/$1"
}

# A daemonized server whose profile names no runtime.stop: nothing can stop it but the developer.
VN=$RV/.claude/worktrees/servenostop
mirror_put servenostop.4250.1 "$VN" servenostop "$main_port" 4250 "http://127.0.0.1:$main_port/" command
prune "$RV"
eq 'serve report: no runtime.stop in the main profile refuses a daemonized server' refuse "$(field server-leftover "$VN" 5)"
contains '...saying to stop it by hand' 'profile names none — stop it by hand' "$(field server-leftover "$VN" 6)"
rm -f "$RVM/servenostop.4250.1"

# Daemonized (stopped by command): only the main checkout's APPROVED runtime.stop may stop it.
# shellcheck disable=SC2016  # the $(...) belongs to runtime.stop, kept literal.
python3 -c 'import json, sys
p, tmp = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["runtime"]["stop"] = "echo stop {port} {slug} >> %s/stop.log; kill $(cat %s/daemon.pid)" % (tmp, tmp)
json.dump(d, open(p, "w"), indent=2)' "$RV/.claude/worktree-profile.json" "$TMP"
git -C "$RV" commit -qam stop
dport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
( cd "$TMP" && exec setsid python3 -m http.server "$dport" --bind 127.0.0.1 ) </dev/null >/dev/null 2>&1 &
dpid=$!
SERVED="$SERVED $dpid"
printf '%s\n' "$dpid" >"$TMP/daemon.pid"
for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$dport") 2>/dev/null && break; sleep 0.1; done
printf '%s' "wtstate${US}1${RSEP}worktree$US$RV/.claude/worktrees/servedaemon${US}servedaemon${US}servedaemon${US}servedaemon${US}$dport${RSEP}serve${US}4242${US}${US}${US}ck${US}http://127.0.0.1:$dport/${US}1${US}command$RSEP" \
  >"$RVM/servedaemon.4242.1"
VD=$RV/.claude/worktrees/servedaemon
PITLANE_TRUST_PROFILES='' prune "$RV"
eq 'serve report: a daemonized server under an unapproved profile is refused' refuse "$(field server-leftover "$VD" 5)"
contains '...saying to approve it first' 'not approved' "$(field server-leftover "$VD" 6)"
id_d=$(field server-leftover "$VD" 1)
PITLANE_TRUST_PROFILES='' prune "$RV" --apply "$id_d"
eq 'serve apply: unapproved, it is refused' 1 "$(cat "$TMP/rc")"
eq '...runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...and the server still runs' yes "$(alive "$dpid")"
prune "$RV"
eq 'serve report: approved, it is offered to stop' stop "$(field server-leftover "$VD" 5)"
prune "$RV" --apply "$id_d"
eq 'serve apply: approved, runtime.stop stops it' 0 "$(cat "$TMP/rc")"
eq '...expanded with the port and slug the mirror recorded' "stop $dport servedaemon" "$(cat "$TMP/stop.log" 2>/dev/null)"
eq '...the server is stopped' no "$(alive "$dpid")"
eq '...and the mirror forgotten, the live one kept' 1 "$(count_in "$RVM")"

# A daemonized server's port or slug handed to a live worktree since: what answers at the URL is
# that worktree's app, which runtime.stop would stop. Refused in the report and at apply.
rm -f "$TMP/stop.log"
lurl=$(served_field "$VL" 5)
lport=${lurl##*:}
lport=${lport%/}
eq 'reallocated fixture: the live worktree holds slug servelive' yes "$(exists "$DB/servelive")"
VP=$RV/.claude/worktrees/serveport
mirror_put serveport.4251.1 "$VP" serveport "$lport" 4251 "$lurl" command
VS=$RV/.claude/worktrees/serveslug
mirror_put serveslug.4252.1 "$VS" servelive '' 4252 "$lurl" command
prune "$RV"
eq 'serve report: a port now held by a live worktree is refused' refuse "$(field server-leftover "$VP" 5)"
contains '...naming the worktree that holds it' "is now $VL's" "$(field server-leftover "$VP" 6)"
eq 'serve report: so is a slug now held by one' refuse "$(field server-leftover "$VS" 5)"
id_p=$(field server-leftover "$VP" 1)
id_s=$(field server-leftover "$VS" 1)
prune "$RV" --apply "$id_p" "$id_s"
eq 'serve apply: both are refused' 1 "$(cat "$TMP/rc")"
eq '...runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...the live worktree'"'"'s app still runs' yes "$(alive "$lpid")"
eq '...and both mirrors are kept' 'yes yes' "$(exists "$RVM/serveport.4251.1") $(exists "$RVM/serveslug.4252.1")" 
rm -f "$RVM/serveport.4251.1" "$RVM/serveslug.4252.1"

# A daemonized server whose URL no longer answers: nothing to stop, so the record is only forgotten.
qport=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
VQ=$RV/.claude/worktrees/servequiet
mirror_put servequiet.4253.1 "$VQ" servequiet "$qport" 4253 "http://127.0.0.1:$qport/" command
prune "$RV"
eq 'serve report: a daemonized server that no longer answers is only forgotten' forget "$(field server-leftover "$VQ" 5)"
prune "$RV" --apply "$(field server-leftover "$VQ" 1)"
eq 'serve apply: forgetting it exits 0' 0 "$(cat "$TMP/rc")"
eq '...runtime.stop did not run' no "$(exists "$TMP/stop.log")"
eq '...and the mirror is gone' no "$(exists "$RVM/servequiet.4253.1")"

# A mirror swapped for a symlink between the report and the apply is refused, and what it points
# at is left as it was.
mirror_put servesym.4254.1 "$RV/.claude/worktrees/servesym" servesym "$qport" 4254 "http://127.0.0.1:$qport/" command
prune "$RV"
id_y=$(field server-leftover "$RV/.claude/worktrees/servesym" 1)
eq 'symlinked mirror fixture: offered to forget' forget "$(field server-leftover "$RV/.claude/worktrees/servesym" 5)"
mv "$RVM/servesym.4254.1" "$TMP/precious"
ln -s "$TMP/precious" "$RVM/servesym.4254.1"
before=$(cksum <"$TMP/precious")
prune "$RV" --apply "$id_y"
eq 'symlinked mirror: apply exits 1' 1 "$(cat "$TMP/rc")"
contains '...refusing it' 'refused' "$(cat "$TMP/out")"
eq '...the symlink is kept' yes "$([ -L "$RVM/servesym.4254.1" ] && echo yes || echo no)"
eq '...and its target is untouched' "$before" "$(cksum <"$TMP/precious" 2>/dev/null)"
rm -f "$RVM/servesym.4254.1"

# A mirror of another format version: listed, never acted on, never deleted.
mirror_put serveformat.4255.1 "$RV/.claude/worktrees/serveformat" serveformat '' 4255 "http://127.0.0.1:$qport/" signal 99
prune "$RV"
eq 'serve report: a mirror of another version is listed only' none "$(field server-leftover "$RVM/serveformat.4255.1" 5)"
prune "$RV" --apply "$(field server-leftover "$RVM/serveformat.4255.1" 1)"
eq 'serve apply: it is refused' 1 "$(cat "$TMP/rc")"
eq '...and the file is still there' yes "$(exists "$RVM/serveformat.4255.1")"
rm -f "$RVM/serveformat.4255.1"

# Re-entered: a live worktree at the path of an earlier, gone one. Its own record is
# /pitlane-serve's and not an item; an earlier server's mirror for that path is listed — and one
# stopped by command is refused, since runtime.stop cannot tell it from the new worktree's app.
VE=$(create "$RV" servereenter)
setsid sleep 300 </dev/null >/dev/null 2>&1 &
eother=$!
SERVED="$SERVED $eother"
# shellcheck disable=SC1091  # the engine itself, sourced to write a record as /pitlane-serve does
( . "$SCRIPTS/bootstrap-lib.sh"
  wt_serve_record_write "$VE" "$eother" "$eother" 'stat:1' 'ck' 'http://127.0.0.1:1/' )
mirror_put servereenter.4256.1 "$VE" servereenter '' 4256 'http://127.0.0.1:1/' signal
mirror_put servereenter.4257.1 "$VE" servereenter '' 4257 "$lurl" command
prune "$RV"
eq 're-entered: its own server is not an item' '' "$(grep -F "pid $eother," "$TMP/out")"
contains 're-entered: the earlier server'"'"'s mirror is listed' 'an earlier worktree at' \
  "$(grep -F 'pid 4256,' "$TMP/out" | cut -f6)"
eq 're-entered, stopped by command: refused' refuse "$(grep -F 'pid 4257,' "$TMP/out" | cut -f5)"
contains '...saying to stop it by hand' 'cannot tell it from the app of the worktree now at that path — stop it by hand' \
  "$(grep -F 'pid 4257,' "$TMP/out" | cut -f6)"
eq '...and the live app is left running' yes "$(alive "$lpid")"
rm -f "$RVM/servereenter.4256.1" "$RVM/servereenter.4257.1"
kill "$eother" 2>/dev/null

# A serve record abandoned half-written is swept with the ledger's junk; a fresh one is a write in
# progress and is left alone.
printf 'half' >"$RVM/.wtserve.old"
touch -t 202001010000 "$RVM/.wtserve.old"
printf 'half' >"$RVM/.wtserve.new"
prune "$RV"
eq 'serve temp: an abandoned one is offered for deletion' delete "$(field ledger-junk "$RVM/.wtserve.old" 5)"
eq 'serve temp: a fresh one is not listed' '' "$(grep -F '.wtserve.new' "$TMP/out")"
eq 'serve temp: neither is read as a server' '' "$(grep -F '.wtserve.' "$TMP/out" | grep -F server-leftover)"
prune "$RV" --apply "$(field ledger-junk "$RVM/.wtserve.old" 1)"
eq 'serve temp: apply exits 0' 0 "$(cat "$TMP/rc")"
eq '...the abandoned one is gone, the fresh one kept' 'no yes' "$(exists "$RVM/.wtserve.old") $(exists "$RVM/.wtserve.new")"
rm -f "$RVM/.wtserve.new"

eq 'serves: the main checkout'"'"'s own server survived the sweep' yes "$(alive "$main_srv")"
kill "$main_srv" "$lpid" 2>/dev/null
sleep 0.2
eq 'serves: nothing started here is left running' '' "$(running_under "$TMP")"
else
  printf 'SKIP serve sweep: needs setsid and /proc\n' >&2
fi

# ---------------------------------------------------------------------------
# Dependency dirs a fresh install moved aside (wt_clear_linked_dep) and could not remove
# ---------------------------------------------------------------------------
# Looked for only beside the profile's hardlink dirs, by the exact name bootstrap gives them, in the
# main checkout and each live worktree; removed only on --apply, re-proved there.
RL=$TMP/leftovers
make_repo "$RL"
WL=$(create "$RL" lefty)
eq 'removed dep: fixture — the worktree was created' "$RL/.claude/worktrees/lefty" "$WL"
prune "$RL"
eq 'removed dep: none listed when there are none' '' "$(grep -F "${TAB}removed-dep-leftover$TAB" "$TMP/out")"

LW=$WL/.vendor.pitlane-removed.4242.17
mkdir -p "$LW/pkg"
head -c 20000 /dev/zero >"$LW/pkg/big.bin"
LM=$RL/.vendor.pitlane-removed.1.2
mkdir -p "$LM"
printf 'x\n' >"$LM/f"
# Shaped like ours, but not beside a hardlink dir, not of that dir, or not quite our name.
mkdir -p "$WL/sub/.vendor.pitlane-removed.5.6" "$WL/.node_modules.pitlane-removed.5.6" \
  "$WL/.vendor.pitlane-removed.5" "$WL/.vendor.pitlane-removed.5.x" "$WL/.vendor.pitlane-removed.5.6.7" \
  "$WL/vendor/.vendor.pitlane-removed.5.6"
# A symlink with our name, pointing at a tree that must never be touched.
TGT=$TMP/leftover-target
mkdir -p "$TGT"
printf 'keep\n' >"$TGT/precious"
LS=$WL/.vendor.pitlane-removed.7.7
ln -s "$TGT" "$LS"

prune "$RL"
eq 'removed dep: the report exits 0' 0 "$(cat "$TMP/rc")"
eq 'removed dep: the leftover in the worktree is offered for deletion' delete \
  "$(field removed-dep-leftover "$LW" 5)"
eq 'removed dep: with its bytes by du' "$(du_bytes "$LW")" "$(field removed-dep-leftover "$LW" 4)"
contains 'removed dep: naming the worktree it is in' "in $WL" "$(field removed-dep-leftover "$LW" 6)"
eq 'removed dep: one in the main checkout is offered too' delete "$(field removed-dep-leftover "$LM" 5)"
eq 'removed dep: a symlink with the name is refused' refuse "$(field removed-dep-leftover "$LS" 5)"
contains 'removed dep: saying it is never followed' 'never followed' "$(field removed-dep-leftover "$LS" 6)"
eq 'removed dep: exactly those three are listed' 3 \
  "$(grep -c -F "${TAB}removed-dep-leftover$TAB" "$TMP/out" | tr -d ' ')"
id_lw=$(field removed-dep-leftover "$LW" 1)
id_lm=$(field removed-dep-leftover "$LM" 1)
id_ls=$(field removed-dep-leftover "$LS" 1)
lw_bytes=$(field removed-dep-leftover "$LW" 4)

# The worktree's bootstrap lock held: skipped, with the reason, and kept.
if command -v flock >/dev/null 2>&1; then
  LOCKF=$(git -C "$WL" rev-parse --absolute-git-dir)/worktree-bootstrap-state.lock
  ( exec 7>"$LOCKF"; flock 7; exec sleep 30 ) &
  holder=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    flock -n "$LOCKF" true 2>/dev/null || break
    sleep 0.1
  done
  prune "$RL" --apply "$id_lw"
  eq 'removed dep: with the bootstrap lock held, apply exits 1' 1 "$(cat "$TMP/rc")"
  contains 'removed dep: saying a run holds the lock' 'holds the bootstrap lock' "$(cat "$TMP/out")"
  eq 'removed dep: and the leftover is kept' yes "$(exists "$LW/pkg/big.bin")"
  kill "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
fi

prune "$RL" --apply "$id_lw" "$id_lm" "$id_ls"
out=$(cat "$TMP/out")
eq 'removed dep: apply exits 1, the symlink being refused' 1 "$(cat "$TMP/rc")"
contains 'removed dep: the leftover is applied, freeing what was reported' \
  "applied$TAB$id_lw${TAB}removed-dep-leftover$TAB$LW$TAB$lw_bytes$TAB" "$out"
contains 'removed dep: the main checkout'"'"'s too' "applied$TAB$id_lm" "$out"
contains 'removed dep: the symlink is refused' "refused$TAB$id_ls" "$out"
eq 'removed dep: both are gone' 'no no' "$(exists "$LW") $(exists "$LM")"
eq 'removed dep: the symlink is kept' yes "$( [ -L "$LS" ] && echo yes || echo no)"
eq 'removed dep: and its target untouched' keep "$(cat "$TGT/precious")"
eq 'removed dep: the look-alikes are untouched' 'yes yes yes yes yes yes' \
  "$(exists "$WL/sub/.vendor.pitlane-removed.5.6") $(exists "$WL/.node_modules.pitlane-removed.5.6") $(exists "$WL/.vendor.pitlane-removed.5") $(exists "$WL/.vendor.pitlane-removed.5.x") $(exists "$WL/.vendor.pitlane-removed.5.6.7") $(exists "$WL/vendor/.vendor.pitlane-removed.5.6")"
eq 'removed dep: the dependency dir itself is untouched' yes "$(exists "$WL/vendor/autoload.php")"

# Replaced by a symlink between the report and the apply: refused, the target untouched.
LR=$WL/.vendor.pitlane-removed.8.8
mkdir -p "$LR"
prune "$RL"
id_lr=$(field removed-dep-leftover "$LR" 1)
eq 'removed dep: the new leftover is offered' delete "$(field removed-dep-leftover "$LR" 5)"
rmdir "$LR"
ln -s "$TGT" "$LR"
prune "$RL" --apply "$id_lr"
eq 'removed dep: swapped for a symlink, apply exits 1' 1 "$(cat "$TMP/rc")"
contains 'removed dep: and refuses it' "refused$TAB$id_lr" "$(cat "$TMP/out")"
eq 'removed dep: the symlink is kept, its target untouched' 'yes keep' \
  "$( [ -L "$LR" ] && echo yes || echo no) $(cat "$TGT/precious")"
rm -f "$LR" "$LS"

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
