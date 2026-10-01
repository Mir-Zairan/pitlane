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
# Abandoned subagent worktrees (ADR-014)
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
# Adoption: worktrees that predate the plugin (ADR-013)
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
