#!/usr/bin/env bash
#
# Exercises hooks/scripts/teardown-lib.sh — the two decisions every destructive path stands on:
# which worktree a removal names, and whether that worktree holds work.
#
# The resolver READS THE PAYLOAD, so unlike tests/test_bootstrap_lib.sh its half of this suite runs
# once per JSON backend, with the same missing-backend rule as tests/test_lib.sh:
#
#   tests/test_teardown_lib.sh                            # every backend present on this machine
#   nix shell nixpkgs#jq -c tests/test_teardown_lib.sh    # ...including jq, if it isn't installed
#
# The holds-work predicate parses no JSON and runs once.
#
# Every scratch repository sits under a directory whose name contains a space, and the worktrees
# use a spaced name and a nested one, because those are the names a path comparison gets wrong.
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)
TMP=$(mktemp -d)
TMP=$(cd -P "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
# The approval gate has its own section in test_bootstrap.sh; everywhere else the fixture profiles
# are the suite's own, so they are trusted the way a developer who opens only their own branches would.
PITLANE_TRUST_PROFILES=1
export PITLANE_TRUST_PROFILES
export HOME=$TMP/home
mkdir -p "$HOME"

# shellcheck source=../hooks/scripts/lib.sh
# shellcheck disable=SC1091
. "$HERE/lib.sh"
# shellcheck source=../hooks/scripts/bootstrap-lib.sh
# shellcheck disable=SC1091
. "$HERE/bootstrap-lib.sh"
# shellcheck source=../hooks/scripts/teardown-lib.sh
# shellcheck disable=SC1091
. "$HERE/teardown-lib.sh"

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

make_repo() {  # $1 = directory
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  printf 'x\n' >"$1/f.txt"
  printf 'vendor/\n.env.worktree.local\n' >"$1/.gitignore"
  git -C "$1" add f.txt .gitignore
  git -C "$1" commit -qm init
}

# A worktree the way either creation path leaves one: under .claude/worktrees/, on its own branch.
# A branch name cannot hold a space, so the branch flattens both `/` and ` ` to `-`.
add_worktree() {  # $1 = repo, $2 = name relative to .claude/worktrees/
  local branch=${2//\//-}
  git -C "$1" worktree add -q "$1/.claude/worktrees/$2" -b "worktree-${branch// /-}"
}

# A JSON string body for a path. Only `"` and `\` need escaping for the names used here.
jstr() {  # $1 = text
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

# Run the resolver in THIS shell, so its globals are visible, capturing only its return code and
# its messages.
resolve() {  # $1 = payload
  wt_resolve_removal_target "$1" 2>"$TMP/resolve-err"
  rc=$?
}

SCRATCH="$TMP/scratch dir"
mkdir -p "$SCRATCH"
R=$SCRATCH/repo
make_repo "$R"
add_worktree "$R" 'my fix'
add_worktree "$R" alice/fix-99
W1=$R/.claude/worktrees/my\ fix
W2=$R/.claude/worktrees/alice/fix-99
ADMIN2=$(cd -P "$(git -C "$W2" rev-parse --git-dir)" && pwd -P)

# A worktree with a ledger entry whose checkout is then deleted by hand, and one without an entry.
add_worktree "$R" 'gone one'
W3=$R/.claude/worktrees/gone\ one
ADMIN3=$(cd -P "$(git -C "$W3" rev-parse --git-dir)" && pwd -P)
WT_NAME='gone one'
wt_runtime_state_set "$W3" gone_one 3900 derived .env.worktree.local ours "done" SCL 2>/dev/null
unset WT_STATE_PATH_FOR WT_STATE_PATH_IS
add_worktree "$R" 'gone two'
W4=$R/.claude/worktrees/gone\ two
rm -rf "$W3" "$W4"
git -C "$R" worktree prune

# The same deletion, but with the admin directory still there because nothing pruned yet.
add_worktree "$R" 'half gone'
W5=$R/.claude/worktrees/half\ gone
ADMIN5=$(cd -P "$(git -C "$W5" rev-parse --git-dir)" && pwd -P)
WT_NAME='half gone'
wt_runtime_state_set "$W5" half_gone 3901 derived .env.worktree.local ours "done" SCL 2>/dev/null
unset WT_STATE_PATH_FOR WT_STATE_PATH_IS
rm -rf "$W5"

# A copy of a live worktree: its .git file names a real admin dir, but git never registered it.
cp -a "$W1" "$R/.claude/worktrees/copied"

# A repository whose main checkout is moved after the worktree was made.
MOVED=$SCRATCH/moved
make_repo "$MOVED"
add_worktree "$MOVED" x
mv "$MOVED" "$SCRATCH/moved-away"

# A non-ASCII name and one near the per-component length limit, which a byte-mangling reader or a
# truncating buffer would get wrong on one backend and not the other.
add_worktree "$R" 'café ü'
W6=$R/.claude/worktrees/café\ ü
LONG_A=$(printf 'a%.0s' $(seq 1 110))
LONG_B=$(printf 'b%.0s' $(seq 1 110))
add_worktree "$R" "long/$LONG_A/$LONG_B"
W7=$R/.claude/worktrees/long/$LONG_A/$LONG_B

ln -s "$W1" "$TMP/link to worktree"
ln -s "$SCRATCH" "$TMP/alias"

run_resolver_suite() {
  local rc

  resolve "{\"worktree_path\":\"$(jstr "$W1")\",\"cwd\":\"$(jstr "$R")\"}"
  eq 'worktree_path resolves a live worktree' 0 "$rc"
  eq '...to that worktree' "$W1" "$WT_RM_WORKTREE"
  eq '...whose main checkout comes from its .git file' "$R" "$WT_RM_ROOT"
  eq '...and which is present' 1 "$WT_RM_PRESENT"
  # git sanitises the admin id, so the space in the name is a `-` there.
  eq '...with its admin dir' "$R/.git/worktrees/my-fix" "$WT_RM_ADMIN"
  eq '...and no ledger entry, since none was written' '' "$WT_RM_LEDGER_ENTRY"

  resolve "{\"path\":\"$(jstr "$W2")\"}"
  eq 'path is read when worktree_path is absent, and needs no cwd' 0 "$rc"
  eq '...resolving a nested name' "$W2" "$WT_RM_WORKTREE"
  eq '...to its own admin dir' "$ADMIN2" "$WT_RM_ADMIN"

  resolve "{\"worktree_path\":\"$(jstr "$W2")/\"}"
  eq 'a trailing slash names the same worktree' "$W2" "$WT_RM_WORKTREE"

  resolve "{\"worktree_path\":\"$(jstr "$ADMIN2")\"}"
  eq 'an admin-dir path is mapped to its worktree' 0 "$rc"
  eq '...via that dir'"'"'s gitdir file' "$W2" "$WT_RM_WORKTREE"
  eq '...keeping the admin dir' "$ADMIN2" "$WT_RM_ADMIN"

  resolve "{\"worktree_path\":\"$(jstr "$W1")\",\"path\":\"$(jstr "$W2")\"}"
  eq 'worktree_path wins over path' "$W1" "$WT_RM_WORKTREE"

  # --- refusals: nothing of any refused target may survive in the globals ---
  local label bad why saved_home=$HOME
  for label in 'the main checkout' 'the common git dir' '/' 'HOME' 'a non-worktree directory' \
    'a directory inside a worktree' 'a relative path' 'an unregistered copy of a worktree'; do
    case $label in
      'the main checkout') bad=$R why='it is a main checkout' ;;
      'the common git dir') bad=$R/.git why='it is a git directory' ;;
      /) bad=/ why='it is / or the home directory' ;;
      # HOME is a registered worktree here, so only the HOME guard stands between it and success.
      HOME) HOME=$W1 bad=$W1 why='it is / or the home directory' ;;
      'a non-worktree directory') bad=$SCRATCH why='no readable .git file' ;;
      'a directory inside a worktree') mkdir -p "$W1/sub"; bad=$W1/sub why='no readable .git file' ;;
      'a relative path') bad='.claude/worktrees/my fix' why='not an absolute path' ;;
      'an unregistered copy of a worktree') bad=$R/.claude/worktrees/copied why='do not point at each other' ;;
    esac
    WT_RM_WORKTREE=stale
    resolve "{\"worktree_path\":\"$(jstr "$bad")\",\"cwd\":\"$(jstr "$R")\"}"
    HOME=$saved_home
    eq "refuses $label" 1 "$rc"
    eq "...and resolves nothing for it" '' "$WT_RM_WORKTREE$WT_RM_ROOT$WT_RM_ADMIN$WT_RM_LEDGER_ENTRY"
    contains "...saying why ($label)" "$why" "$(cat "$TMP/resolve-err")"
  done
  rmdir "$W1/sub"

  resolve "{\"worktree_path\":\"$(jstr "$R/./.claude/worktrees/../worktrees/my fix")\"}"
  eq 'refuses a path with . or .. segments rather than guessing what it means' 1 "$rc"

  resolve ''
  eq 'refuses an empty payload' 1 "$rc"
  resolve '{}'
  eq 'refuses a payload naming no path' 1 "$rc"
  resolve 'not json'
  eq 'refuses an unparseable payload' 1 "$rc"
  contains '...saying no worktree was named' 'names no worktree' "$(cat "$TMP/resolve-err")"

  # The readers fold CR/LF to a space and strip US/RS, so an encoded control character would reach
  # the resolver as a DIFFERENT path — here, a real worktree's.
  resolve "{\"worktree_path\":\"$(jstr "$R/.claude/worktrees/my")\\nfix\"}"
  eq 'refuses a path encoding a newline, which the reader folds into the space of a real worktree' 1 "$rc"
  eq '...resolving nothing' '' "$WT_RM_WORKTREE"
  contains '...saying why' 'encodes a control character' "$(cat "$TMP/resolve-err")"
  resolve "{\"worktree_path\":\"$(jstr "$R/.claude/worktrees/my")\\u001F fix\"}"
  eq 'refuses a path encoding a unit separator, which the reader strips' 1 "$rc"
  contains '...saying why' 'encodes a control character' "$(cat "$TMP/resolve-err")"
  resolve "{\"worktree_path\":\"$(jstr "$W1")\",\"cwd\":\"$(jstr "$R")\\r\"}"
  eq 'refuses a payload whose cwd encodes a carriage return' 1 "$rc"
  contains '...saying why' 'encodes a control character' "$(cat "$TMP/resolve-err")"
  resolve "{\"worktree_path\":\"$(jstr "$R/.claude/worktrees/my\\nfix")\"}"
  eq 'an escaped backslash before an n is a backslash, not a newline' 2 "$rc"
  lacks '...and is not refused as one' 'control character' "$(cat "$TMP/resolve-err")"

  resolve "{\"worktree_path\":\"$(jstr "$W6")\"}"
  eq 'a non-ASCII worktree name resolves' 0 "$rc"
  eq '...to the same bytes' "$W6" "$WT_RM_WORKTREE"
  resolve "{\"worktree_path\":\"$(jstr "$W7")\"}"
  eq 'a long worktree path resolves' 0 "$rc"
  eq '...untruncated' "$W7" "$WT_RM_WORKTREE"

  resolve "{\"worktree_path\":\"$(jstr "$SCRATCH/moved-away/.claude/worktrees/x")\"}"
  eq 'refuses a worktree whose main checkout has moved' 1 "$rc"
  eq '...resolving nothing' '' "$WT_RM_WORKTREE$WT_RM_ROOT"
  contains '...and names the vanished checkout' "checkout $SCRATCH/moved no longer exists" "$(cat "$TMP/resolve-err")"

  # --- symlinks ---
  resolve "{\"worktree_path\":\"$(jstr "$TMP/link to worktree")\"}"
  eq 'refuses a symlink that leads to a registered worktree from elsewhere' 1 "$rc"
  eq '...resolving nothing' '' "$WT_RM_WORKTREE"
  contains '...and says it is a symlink' 'symlink' "$(cat "$TMP/resolve-err")"

  resolve "{\"worktree_path\":\"$(jstr "$TMP/alias/repo/.claude/worktrees/my fix")\"}"
  eq 'a path through a symlinked ANCESTOR resolves' 0 "$rc"
  eq '...to the registered, physical path' "$W1" "$WT_RM_WORKTREE"
  eq '...and the physical main checkout' "$R" "$WT_RM_ROOT"

  # --- the directory is already gone ---
  resolve "{\"worktree_path\":\"$(jstr "$W3")\",\"cwd\":\"$(jstr "$R")\"}"
  eq 'a gone worktree with a ledger entry resolves' 0 "$rc"
  eq '...as not present' 0 "$WT_RM_PRESENT"
  eq '...to its recorded path' "$W3" "$WT_RM_WORKTREE"
  eq '...and its entry' 'gone-one' "$WT_RM_LEDGER_ENTRY"
  eq '...with no admin dir, since git pruned it' '' "$WT_RM_ADMIN"
  eq '...and the main checkout of cwd' "$R" "$WT_RM_ROOT"

  resolve "{\"worktree_path\":\"$(jstr "$W3")\",\"cwd\":\"$(jstr "$W3")\"}"
  eq 'a gone worktree whose cwd is gone too is found through its own path' 0 "$rc"
  eq '...with the same entry' 'gone-one' "$WT_RM_LEDGER_ENTRY"

  resolve "{\"worktree_path\":\"$(jstr "$ADMIN3")\",\"cwd\":\"$(jstr "$R")\"}"
  eq 'a pruned admin-dir path with a ledger entry resolves by its id' 0 "$rc"
  eq '...to the recorded worktree' "$W3" "$WT_RM_WORKTREE"
  eq '...as not present' 0 "$WT_RM_PRESENT"

  resolve "{\"worktree_path\":\"$(jstr "$W5")\",\"cwd\":\"$(jstr "$R")\"}"
  eq 'a deleted checkout whose admin dir survives resolves' 0 "$rc"
  eq '...keeping the admin dir, where its state file still is' "$ADMIN5" "$WT_RM_ADMIN"
  eq '...and its entry' 'half-gone' "$WT_RM_LEDGER_ENTRY"

  resolve "{\"worktree_path\":\"$(jstr "$W4")\",\"cwd\":\"$(jstr "$R")\"}"
  eq 'a gone worktree with no ledger entry is nothing of ours' 2 "$rc"
  eq '...and resolves nothing' '' "$WT_RM_WORKTREE$WT_RM_LEDGER_ENTRY"

  # A present worktree with an entry reports it too, so teardown reads one place either way.
  # SC2034: read by the sourced ledger writer.
  # shellcheck disable=SC2034
  WT_NAME=alice/fix-99
  wt_runtime_state_set "$W2" alice_fix_99 3902 derived .env.worktree.local ours "done" SCL 2>/dev/null
  unset WT_STATE_PATH_FOR WT_STATE_PATH_IS
  resolve "{\"worktree_path\":\"$(jstr "$W2")\"}"
  eq 'a live worktree reports its ledger entry' 'fix-99' "$WT_RM_LEDGER_ENTRY"
  rm -f "$R/.git/worktree-ledger/fix-99"
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_teardown_lib.sh\n' >&2
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
  run_resolver_suite
done
BACKEND=none

# ---------------------------------------------------------------------------
# wt_resolve_worktree_path — the path entry point the prune sweep calls. No JSON, so it runs once.
# ---------------------------------------------------------------------------

resolve_path() {  # $@ = path, repository hint
  wt_resolve_worktree_path "$@" 2>"$TMP/resolve-err"
  rc=$?
}
err() { cat "$TMP/resolve-err"; }

resolve_path "$W1"
eq 'a path resolves a live worktree' 0 "$rc"
eq '...to it' "$W1" "$WT_RM_WORKTREE"
resolve_path "$SCRATCH"
eq 'a refused path after a resolved one' 1 "$rc"
eq '...leaves nothing of the previous target behind' '' \
  "$WT_RM_WORKTREE$WT_RM_ROOT$WT_RM_ADMIN$WT_RM_LEDGER_ENTRY"
resolve_path "$R/.claude/worktrees/my"$'\n'"fix"
eq 'refuses a path containing a newline' 1 "$rc"
contains '...saying why' 'contains a control character' "$(err)"
resolve_path ''
eq 'refuses an empty path' 1 "$rc"
resolve_path "$W3" "$R"
eq 'a gone path is found through the repository hint' 0 "$rc"
eq '...by its ledger entry' 'gone-one' "$WT_RM_LEDGER_ENTRY"

resolve_path "$R/f.txt"
eq 'refuses a file' 1 "$rc"
contains '...saying why' 'not a directory' "$(err)"

# A registered worktree whose .git file names ANOTHER worktree's admin dir: git still lists it, so
# only the pairing check stops it being torn down against the other's state.
cp "$W1/.git" "$TMP/w1.git"
printf 'gitdir: %s\n' "$ADMIN2" >"$W1/.git"
resolve_path "$W1"
eq 'refuses a worktree whose .git names an admin dir that points elsewhere' 1 "$rc"
contains '...saying why' 'do not point at each other' "$(err)"
cp "$TMP/w1.git" "$W1/.git"

cp "$ADMIN2/gitdir" "$TMP/admin2.gitdir"
printf '%s\n' "$W1/.git" >"$ADMIN2/gitdir"
resolve_path "$ADMIN2"
eq 'refuses an admin dir naming a worktree that points at a different admin dir' 1 "$rc"
contains '...saying why' 'do not point at each other' "$(err)"
cp "$TMP/admin2.gitdir" "$ADMIN2/gitdir"

mv "$ADMIN2/commondir" "$TMP/admin2.commondir"
resolve_path "$W2"
eq 'refuses a worktree whose git dir has no commondir' 1 "$rc"
contains '...saying why' 'no usable commondir' "$(err)"
mv "$TMP/admin2.commondir" "$ADMIN2/commondir"

# useRelativePaths: the .git file names its admin dir relative to the worktree.
printf 'gitdir: ../../../../.git/worktrees/%s\n' "${ADMIN2##*/}" >"$W2/.git"
resolve_path "$W2"
eq 'a relative .git pointer resolves' 0 "$rc"
eq '...to its admin dir' "$ADMIN2" "$WT_RM_ADMIN"
printf 'gitdir: %s\n' "$ADMIN2" >"$W2/.git"

cp "$ADMIN5/gitdir" "$TMP/admin5.gitdir"
printf '%s\n' "$SCRATCH/elsewhere" >"$ADMIN5/gitdir"
resolve_path "$ADMIN5"
eq 'refuses an admin dir whose gitdir does not name a .git' 1 "$rc"
contains '...saying why' "does not name a worktree's .git" "$(err)"
printf '%s\n' "$SCRATCH/elsewhere/.git" >"$ADMIN5/gitdir"
resolve_path "$W5" "$R"
eq 'a gone worktree whose admin id now belongs elsewhere still resolves' 0 "$rc"
eq '...but without that admin dir' '' "$WT_RM_ADMIN"
cp "$TMP/admin5.gitdir" "$ADMIN5/gitdir"

resolve_path "$ADMIN5"
eq 'a surviving admin dir of a deleted checkout resolves' 0 "$rc"
eq '...to the checkout it recorded' "$W5" "$WT_RM_WORKTREE"
eq '...as not present' 0 "$WT_RM_PRESENT"
eq '...keeping the admin dir' "$ADMIN5" "$WT_RM_ADMIN"
eq '...and its entry' 'half-gone' "$WT_RM_LEDGER_ENTRY"

mkdir "$W3"
resolve_path "$ADMIN3"
eq 'refuses a pruned admin id whose recorded worktree path exists again' 1 "$rc"
contains '...saying why' 'which is not gone' "$(err)"
rmdir "$W3"

# A committed directory that merely holds files named gitdir and commondir is not an admin dir,
# however well its pointers are aimed.
mkdir "$R/fake admin"
printf '%s\n' "$W3/.git" >"$R/fake admin/gitdir"
printf '../.git\n' >"$R/fake admin/commondir"
resolve_path "$R/fake admin"
eq 'refuses a look-alike admin dir' 1 "$rc"
eq '...resolving nothing' '' "$WT_RM_WORKTREE$WT_RM_LEDGER_ENTRY"
contains '...saying why' 'not a linked worktree admin dir' "$(err)"
rm -rf "$R/fake admin"

SEP=$SCRATCH/sep
git init -q --separate-git-dir "$SCRATCH/sep-git" "$SEP"
git -C "$SEP" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
git -C "$SEP" worktree add -q "$SEP/.claude/worktrees/s" -b s
resolve_path "$SEP/.claude/worktrees/s"
eq 'refuses a worktree of a --separate-git-dir repository' 1 "$rc"
contains '...saying why' 'not <root>/.git' "$(err)"

# ---------------------------------------------------------------------------
# wt_ledger_entry_for — which of several entries for one path is the live one
# ---------------------------------------------------------------------------

# An entry's `when` is the last field of its last record.
ledger_copy_with_when() {  # $1 = source entry file, $2 = destination, $3 = when
  local body
  body=$(cat "$1"; printf x)
  body=${body%x}
  body=${body%"$WT_RS"}
  printf '%s%s%s%s' "${body%"$WT_US"*}" "$WT_US" "$3" "$WT_RS" >"$2"
}
# shellcheck disable=SC2034  # read by the sourced ledger writer
WT_NAME=alice/fix-99
wt_runtime_state_set "$W2" alice_fix_99 3902 derived .env.worktree.local ours "done" SCL 2>/dev/null
unset WT_STATE_PATH_FOR WT_STATE_PATH_IS
L=$R/.git/worktree-ledger
cp "$L/fix-99" "$TMP/fix-99.orig"
# Name order and age order disagree, so neither first-seen nor last-seen can pass for newest.
ledger_copy_with_when "$TMP/fix-99.orig" "$L/fix-99.1" 200
ledger_copy_with_when "$TMP/fix-99.orig" "$L/fix-99.2" 300
ledger_copy_with_when "$TMP/fix-99.orig" "$L/fix-99.3" 100
ledger_copy_with_when "$TMP/fix-99.orig" "$L/fix-99" 50
eq 'the live entry wins over newer set-aside ones' 'fix-99' "$(wt_ledger_entry_for "$R" "$W2" '')"
rm -f "$L/fix-99"
eq 'without it, the newest set-aside entry wins' 'fix-99.2' "$(wt_ledger_entry_for "$R" "$W2" '')"
rm -f "$L"/fix-99.*

# ---------------------------------------------------------------------------
# wt_worktree_holds_work
# ---------------------------------------------------------------------------

H=$SCRATCH/holds
make_repo "$H"
add_worktree "$H" 'my fix'
add_worktree "$H" alice/fix-99
HW=$H/.claude/worktrees/my\ fix
HN=$H/.claude/worktrees/alice/fix-99

# Asserts the verdict and captures the reasons.
holds() {  # $1 = label, $2 = expected rc (0 holds, 1 clean), $3 = worktree
  reasons=$(wt_worktree_holds_work "$3" 2>"$TMP/holds-err")
  eq "$1" "$2" "$?"
}

holds 'a fresh worktree holds no work' 1 "$HW"
eq '...and gives no reasons' '' "$reasons"
holds 'a fresh nested worktree holds no work' 1 "$HN"

printf 'changed\n' >"$HW/f.txt"
holds 'a modified tracked file is work' 0 "$HW"
contains '...reported as modified' 'modified' "$reasons"
git -C "$HW" checkout -q -- f.txt

printf 'new\n' >"$HW/g.txt"
git -C "$HW" add g.txt
holds 'a staged file is work' 0 "$HW"
contains '...reported as staged' 'staged' "$reasons"
lacks '...and not as untracked' 'untracked' "$reasons"
git -C "$HW" rm -q --cached g.txt
holds 'an untracked file is work' 0 "$HW"
contains '...reported as untracked' 'untracked' "$reasons"
contains '...naming it' 'g.txt' "$reasons"
rm -f "$HW/g.txt"

mkdir -p "$HW/vendor/pkg"
printf 'dep\n' >"$HW/vendor/pkg/a.php"
printf 'DB=x\n' >"$HW/.env.worktree.local"
holds 'gitignored files alone are not work' 1 "$HW"

# The worktree's status config must not be able to hide untracked files from the guard.
git -C "$H" config status.showUntrackedFiles no
printf 'new\n' >"$HW/h.txt"
holds 'status.showUntrackedFiles=no does not hide an untracked file' 0 "$HW"
rm -f "$HW/h.txt"
git -C "$H" config --unset status.showUntrackedFiles

# A merge in progress: two branches changing the same line.
git -C "$H" branch side
printf 'mine\n' >"$HW/f.txt"; git -C "$HW" commit -qam mine
git -C "$H" checkout -q side
printf 'theirs\n' >"$H/f.txt"; git -C "$H" commit -qam theirs
git -C "$H" checkout -q main
git -C "$HW" merge -q side >/dev/null 2>&1
holds 'a merge in progress is work' 0 "$HW"
contains '...reported as a merge' 'merge in progress' "$reasons"
git -C "$HW" merge --abort
git -C "$HW" reset -q --hard main

git -C "$H" worktree lock --reason 'agent running' "$HW"
holds 'a locked worktree is work' 0 "$HW"
contains '...reported with its lock reason' 'agent running' "$reasons"
git -C "$H" worktree unlock "$HW"
holds 'unlocked again, it is clean' 1 "$HW"

# Every in-progress marker, each on its own, so a misspelt marker name cannot hide behind another.
HW_GITDIR=$(cd -P "$(git -C "$HW" rev-parse --git-dir)" && pwd -P)
for marker in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase \
  CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect; do
  case ${marker%%:*} in
    rebase-*) mkdir "$HW_GITDIR/${marker%%:*}" ;;
    *) git -C "$HW" rev-parse HEAD >"$HW_GITDIR/${marker%%:*}" ;;
  esac
  holds "${marker%%:*} is work" 0 "$HW"
  contains "...reported as ${marker#*:} in progress" "${marker#*:} in progress" "$reasons"
  rm -rf "${HW_GITDIR:?}/${marker%%:*}"
done
holds 'with every marker gone, it is clean' 1 "$HW"

git -C "$HW" symbolic-ref HEAD refs/heads/never-born
holds 'an unborn HEAD cannot be verified, so it holds work' 0 "$HW"
contains '...saying HEAD names no commit' 'does not name a commit' "$reasons"
git -C "$HW" symbolic-ref HEAD refs/heads/worktree-my-fix

cp "$HW_GITDIR/index" "$TMP/hw.index"
printf 'not an index\n' >"$HW_GITDIR/index"
holds 'a status git cannot produce holds work' 0 "$HW"
contains '...saying status failed' 'git status failed' "$reasons"
cp "$TMP/hw.index" "$HW_GITDIR/index"

# A git whose symbolic-ref dies, as it does on a corrupt HEAD, while everything else answers.
mkdir -p "$TMP/shim"
REAL_GIT=$(command -v git)
export REAL_GIT
cat >"$TMP/shim/git" <<'SHIM'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = symbolic-ref ] && exit 128; done
exec "$REAL_GIT" "$@"
SHIM
chmod +x "$TMP/shim/git"
reasons=$(PATH="$TMP/shim:$PATH" wt_worktree_holds_work "$HW" 2>/dev/null)
eq 'a branch git cannot name holds work' 0 "$?"
contains '...saying so' 'cannot tell which branch' "$reasons"

printf 'b\n' >"$HW/b.txt"; git -C "$HW" add b.txt; git -C "$HW" commit -qm 'on branch'
holds 'a commit on no other branch is work' 0 "$HW"
contains '...reported as a commit only here' '1 commit' "$reasons"
BRANCH_TIP=$(git -C "$HW" rev-parse HEAD)

git -C "$H" update-ref refs/remotes/origin/pushed "$BRANCH_TIP"
holds 'a commit a remote-tracking ref contains is not work' 1 "$HW"
git -C "$H" update-ref -d refs/remotes/origin/pushed

git -C "$H" merge -q --ff-only "worktree-my-fix"
holds 'a commit that exists on main is not work' 1 "$HW"

git -C "$HN" checkout -q --detach
printf 'd\n' >"$HN/d.txt"; git -C "$HN" add d.txt; git -C "$HN" commit -qm detached
holds 'a detached HEAD with a new commit is work' 0 "$HN"
contains '...reported as detached' 'detached' "$reasons"
eq '...and does not abort a set -e caller' reached \
  "$( set -e; wt_worktree_holds_work "$HN" >/dev/null 2>&1; echo reached )"
git -C "$HN" checkout -q "worktree-alice-fix-99"
holds 'the nested worktree back on its branch is clean' 1 "$HN"

# A dirty submodule: the superproject's status reports it, whatever submodule.ignore says.
SUB=$SCRATCH/sub
make_repo "$SUB"
git -C "$H" -c protocol.file.allow=always submodule add -q "$SUB" sub >/dev/null 2>&1
git -C "$H" commit -qm 'add sub'
git -C "$H" config submodule.sub.ignore all
add_worktree "$H" 'with sub'
HS=$H/.claude/worktrees/with\ sub
git -C "$HS" -c protocol.file.allow=always submodule update -q --init >/dev/null 2>&1
holds 'a worktree with a clean submodule is clean' 1 "$HS"
printf 'dirty\n' >"$HS/sub/f.txt"
holds 'a dirty submodule is work, even with submodule.ignore=all' 0 "$HS"
contains '...naming it' '(first: sub)' "$reasons"
git -C "$HS/sub" checkout -q -- f.txt
holds '...and clean again once reverted' 1 "$HS"

# A commit only the submodule has lives in its git dir, which sits under the worktree's admin dir
# and goes with it. Back on the recorded commit, the superproject's status cannot see it.
SUB_TIP=$(git -C "$HS/sub" rev-parse HEAD)
git -C "$HS/sub" checkout -q -b local-only
printf 's\n' >"$HS/sub/s.txt"; git -C "$HS/sub" add s.txt
git -C "$HS/sub" -c user.email=t@example.com -c user.name=t commit -qm 'only here'
git -C "$HS/sub" checkout -q --detach "$SUB_TIP"
holds 'a commit only an initialized submodule has is work' 0 "$HS"
contains '...naming the submodule' '1 commit(s) in submodule sub ' "$reasons"
git -C "$HS/sub" branch -q -D local-only
holds '...and clean once that branch is gone' 1 "$HS"

# The same, two submodules down.
INNER=$SCRATCH/inner
OUTER=$SCRATCH/outer
S=$SCRATCH/super
make_repo "$INNER"
make_repo "$OUTER"
git -C "$OUTER" -c protocol.file.allow=always submodule add -q "$INNER" inner >/dev/null 2>&1
git -C "$OUTER" commit -qm 'add inner'
make_repo "$S"
git -C "$S" -c protocol.file.allow=always submodule add -q "$OUTER" outer >/dev/null 2>&1
git -C "$S" commit -qm 'add outer'
add_worktree "$S" nest
SN=$S/.claude/worktrees/nest
git -C "$SN" -c protocol.file.allow=always submodule update -q --init --recursive >/dev/null 2>&1
holds 'a worktree with clean nested submodules is clean' 1 "$SN"
INNER_TIP=$(git -C "$SN/outer/inner" rev-parse HEAD)
git -C "$SN/outer/inner" checkout -q -b deep
printf 'i\n' >"$SN/outer/inner/i.txt"; git -C "$SN/outer/inner" add i.txt
git -C "$SN/outer/inner" -c user.email=t@example.com -c user.name=t commit -qm deep
git -C "$SN/outer/inner" checkout -q --detach "$INNER_TIP"
holds 'a commit only a nested submodule has is work' 0 "$SN"
contains '...naming it by its path' 'in submodule outer/inner ' "$reasons"
git -C "$SN/outer/inner" branch -q -D deep

cp "$SN/outer/.git" "$TMP/outer.git"
printf 'gitdir: %s\n' "$SCRATCH/nowhere" >"$SN/outer/.git"
holds 'a submodule git cannot read holds work' 0 "$SN"
contains '...saying which' 'could not verify: submodule outer ' "$reasons"
cp "$TMP/outer.git" "$SN/outer/.git"
holds '...and clean once repaired' 1 "$SN"

holds 'a directory that is not there cannot be verified, so it holds work' 0 "$SCRATCH/nowhere"
contains '...saying it could not verify' 'could not verify' "$reasons"
cp "$HW/.git" "$HW/.git.good"
printf 'gitdir: %s\n' "$SCRATCH/nowhere/.git" >"$HW/.git"
holds 'a worktree git cannot read holds work' 0 "$HW"
contains '...saying it could not verify' 'could not verify' "$reasons"
eq '...and prints nothing but reasons on stdout' '' "$(printf '%s\n' "$reasons" | grep -v '^could not verify: ')"
mv "$HW/.git.good" "$HW/.git"
holds 'repaired, it is clean again' 1 "$HW"

# A repository that ignores .claude/worktrees/, as a real one does: git walking up out of a broken
# worktree then lands on a clean main checkout, and nested worktrees vanish from status.
G=$SCRATCH/ignoring
make_repo "$G"
printf '.claude/worktrees/\n' >>"$G/.gitignore"
git -C "$G" commit -qam 'ignore worktrees'
add_worktree "$G" a
GA=$G/.claude/worktrees/a
GA_ADMIN=$(cd -P "$(git -C "$GA" rev-parse --git-dir)" && pwd -P)
holds 'a fresh worktree of an ignoring repository is clean' 1 "$GA"

mv "$GA/.git" "$TMP/ga.git"
printf 'mine\n' >"$GA/untracked.txt"
holds 'a worktree whose .git is gone cannot be verified, though git would read the main checkout' 0 "$GA"
contains '...saying git resolved something else' 'could not verify: git resolves' "$reasons"
rm -f "$GA/untracked.txt"
mv "$TMP/ga.git" "$GA/.git"

mkdir "$GA/deeper"
holds 'a subdirectory of a worktree is not that worktree' 0 "$GA/deeper"
contains '...saying git resolved something else' 'could not verify: git resolves' "$reasons"
rmdir "$GA/deeper"

cp "$GA_ADMIN/gitdir" "$TMP/ga.gitdir"
printf '%s\n' "$SCRATCH/elsewhere/.git" >"$GA_ADMIN/gitdir"
holds 'a worktree whose admin dir points elsewhere cannot be verified' 0 "$GA"
contains '...saying so' 'does not point back at' "$reasons"
cp "$TMP/ga.gitdir" "$GA_ADMIN/gitdir"

git -C "$G" worktree add -q "$GA/.claude/worktrees/b" -b wb
holds 'a registered worktree nested inside is work' 0 "$GA"
contains '...naming it' "a registered worktree is nested inside it: $GA/.claude/worktrees/b" "$reasons"
holds '...while the nested one itself is clean' 1 "$GA/.claude/worktrees/b"
git -C "$G" worktree remove "$GA/.claude/worktrees/b"
holds 'without it, the outer one is clean again' 1 "$GA"

holds 'the main checkout is not a linked worktree' 0 "$G"
contains '...saying so' 'is not a linked worktree' "$reasons"

# ---------------------------------------------------------------------------
# The teardown steps, called the way the prune sweep calls them: a ledger entry and the main
# checkout, no payload. No JSON, so they run once.
# ---------------------------------------------------------------------------

T="$SCRATCH/steps repo"
git init -q "$T"
git -C "$T" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
TW=$T/.claude/worktrees/bob/fix-7
git -C "$T" worktree add -q "$TW" -b bob-fix-7
unset WT_STATE_PATH_FOR WT_STATE_PATH_IS
TSTATE=$(wt_state_path "$TW")
# shellcheck disable=SC2034  # read by the sourced ledger writer
WT_NAME='bob/fix 7'
wt_runtime_state_set "$TW" bob_fix_7 3911 derived .env.worktree.local ours "done" SCK 2>/dev/null
TENTRY=fix-7
eq 'fixture: the ledger entry is named after the admin id' yes \
  "$([ -f "$T/.git/worktree-ledger/$TENTRY" ] && echo yes || echo no)"

wt_read_allocation '' "$T" "$TENTRY" "$TW"
eq 'allocation: with no state file it is read from the ledger' 0 $?
eq '...saying so' ledger "$WT_TD_SOURCE"
eq '...with the name the seed saw, not one derived from the path' 'bob/fix 7' "$WT_TD_NAME"
eq '...and every rt field' 'bob_fix_7|3911|derived|.env.worktree.local|ours' \
  "$WT_TD_SLUG|$WT_TD_PORT|$WT_TD_PORTSOURCE|$WT_TD_ENVFILE|$WT_TD_ENVSTATE"

wt_read_allocation "$TSTATE" "$T" "$TENTRY" "$TW"
eq 'allocation: the state file wins when it has a record' "$TSTATE" "$WT_TD_SOURCE"

wt_read_allocation "$TSTATE" "$T" '' "$TW"
eq 'allocation: with no entry the name comes from the path' 'bob/fix-7' "$WT_TD_NAME"

wt_read_allocation "$SCRATCH/no-such-state" "$T" '' "$TW"
eq 'allocation: nothing records one' 1 $?
eq '...and no field survives from the previous call' '' \
  "$WT_TD_SOURCE$WT_TD_SLUG$WT_TD_PORT$WT_TD_PORTSOURCE$WT_TD_ENVFILE$WT_TD_ENVSTATE"

# PROFILE_* are what wt_load_profile publishes; set by hand so no profile file is needed.
# shellcheck disable=SC2034
PROFILE_PRESENT=1 PROFILE_HAS_RUNTIME=1 PROFILE_RT_TEARDOWN=down.sh PROFILE_SEED_TIMEOUT=20
# shellcheck disable=SC2016  # the $WT_* references belong to the script.
printf '#!/usr/bin/env bash\nprintf "%%s|%%s|%%s|%%s" "$WT_NAME" "$WT_SLUG" "$WT_PORT" "$WT_PATH" > ran\n' \
  >"$T/down.sh"
chmod +x "$T/down.sh"

wt_run_teardown_script "$T" "$TW" "$T" '' 2>/dev/null
eq 'teardown script: no allocation, nothing run' none "$WT_TD_STATUS"
eq '...really not run' no "$([ -e "$T/ran" ] && echo yes || echo no)"

wt_read_allocation '' "$T" "$TENTRY" "$TW"
wt_run_teardown_script "$T" "$TW" "$T" "$(( $(date +%s) - 1 ))" 2>"$TMP/steps-err"
eq 'teardown script: a deadline already passed skips it' skipped "$WT_TD_STATUS"
eq '...rather than running it unbounded' no "$([ -e "$T/ran" ] && echo yes || echo no)"
contains '...saying why' 'no time left' "$(cat "$TMP/steps-err")"

wt_run_teardown_script "$T" "$TW" "$T" '' 2>/dev/null
eq 'teardown script: run from the main checkout with the recorded environment' "done" "$WT_TD_STATUS"
eq '...seeing the seed'"'"'s name, slug, port and path' "bob/fix 7|bob_fix_7|3911|$TW" \
  "$(cat "$T/ran" 2>/dev/null)"
rm -f "$T/ran"

WT_TD_STATUS=failed
wt_settle_ledger_entry "$T" "$TENTRY" 1 2>/dev/null
eq 'ledger: a failed teardown keeps the entry' kept "$WT_TD_LEDGER"
WT_TD_STATUS=skipped
wt_settle_ledger_entry "$T" "$TENTRY" 1 2>/dev/null
eq 'ledger: so does a skipped one' kept "$WT_TD_LEDGER"
WT_TD_STATUS="done"
wt_settle_ledger_entry "$T" "$TENTRY" 0 2>/dev/null
eq 'ledger: a worktree still there keeps its entry' kept "$WT_TD_LEDGER"
eq '...on disk' yes "$([ -f "$T/.git/worktree-ledger/$TENTRY" ] && echo yes || echo no)"
wt_settle_ledger_entry "$T" '' 1 2>/dev/null
eq 'ledger: no entry, nothing to settle' none "$WT_TD_LEDGER"
# Nothing was run because nothing could be read: the entry is then the only trace of an allocation.
WT_TD_STATUS=none WT_TD_SOURCE=''
wt_settle_ledger_entry "$T" "$TENTRY" 1 2>/dev/null
eq 'ledger: an allocation that could not be read keeps the entry' kept "$WT_TD_LEDGER"
wt_read_allocation '' "$T" "$TENTRY" "$TW"
WT_TD_STATUS="done"
wt_settle_ledger_entry "$T" "$TENTRY" 1 2>/dev/null
eq 'ledger: a gone worktree whose teardown finished forgets it' forgotten "$WT_TD_LEDGER"
eq '...on disk' no "$([ -e "$T/.git/worktree-ledger/$TENTRY" ] && echo yes || echo no)"
wt_runtime_state_set "$TW" bob_fix_7 3911 derived .env.worktree.local ours "done" SCK 2>/dev/null
wt_read_allocation '' "$T" "$TENTRY" "$TW"
WT_TD_STATUS=none
wt_settle_ledger_entry "$T" "$TENTRY" 1 2>/dev/null
eq 'ledger: a read allocation with no script to run forgets it' forgotten "$WT_TD_LEDGER"

# A profile that exists but could not be loaded cannot say there is no teardown script.
wt_runtime_state_set "$TW" bob_fix_7 3911 derived .env.worktree.local ours "done" SCK 2>/dev/null
wt_read_allocation '' "$T" "$TENTRY" "$TW"
printf 'not json{' >"$T/broken-profile.json"
# shellcheck disable=SC2034
PROFILE_PRESENT=0 PROFILE_PATH=$T/broken-profile.json
wt_run_teardown_script "$T" "$TW" "$T" '' 2>"$TMP/steps-err"
eq 'teardown script: an unloadable profile skips it' skipped "$WT_TD_STATUS"
contains '...saying why' 'could not be loaded' "$(cat "$TMP/steps-err")"
# shellcheck disable=SC2034
PROFILE_PATH=$T/no-such-profile.json
wt_run_teardown_script "$T" "$TW" "$T" '' 2>/dev/null
eq 'teardown script: no profile at all has none to run' none "$WT_TD_STATUS"

# The allocation lock: one per ledger entry, in the shared git dir, because once the worktree is
# gone the entry is all teardown.sh and the prune sweep have in common.
eq 'allocation lock: keyed on the entry' "$T/.git/worktree-locks/rt-$TENTRY.lock" \
  "$(wt_allocation_lock_path "$T" "$TENTRY")"
wt_allocation_lock_path "$T" '..' >/dev/null
eq 'allocation lock: not for a string that is no entry name' 1 $?
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$T/.git/worktree-locks"
  exec 6>"$T/.git/worktree-locks/rt-$TENTRY.lock"
  flock -n 6
  ( wt_acquire_allocation_lock "$T" "$TENTRY" 5 || { printf '%s' "$WT_TD_KEEP_REASON"; exit 1; } ) \
    >"$TMP/lock-out" 2>/dev/null
  eq 'allocation lock: held elsewhere, not taken' 1 $?
  contains '...saying why' 'releasing its runtime allocation' "$(cat "$TMP/lock-out")"
  exec 6>&-
  ( wt_acquire_allocation_lock "$T" "$TENTRY" 5 )
  eq 'allocation lock: free, taken' 0 $?
else
  printf 'SKIP no flock to hold the allocation lock with\n' >&2
fi
# shellcheck disable=SC2034
PROFILE_PRESENT=0 PROFILE_HAS_RUNTIME=0 PROFILE_RT_TEARDOWN='' PROFILE_SEED_TIMEOUT=''

# wt_release_env_overrides: the block comes out of every file the record says is ours,
# by the RECORDED list and its aligned dispositions — a `theirs` or empty slot is not opened.
RW=$TMP/release-wt
mkdir -p "$RW/sub"
blk=$(printf '%s\nA=1\n%s' "$WT_ENV_BEGIN" "$WT_ENV_END")
printf 'KEEP=1\n%s\n' "$blk" >"$RW/.env.a"
printf '%s\n' "$blk" >"$RW/sub/.env.b"
printf 'MINE=1\n%s\n' "$blk" >"$RW/.env.c"
printf 'NEVER=1\n%s\n' "$blk" >"$RW/.env.d"
wt_release_env_overrides "$RW" '.env.a:sub/.env.b:.env.c:.env.d' 'ours:ours:theirs:'
eq 'release: an ours file keeps its own lines' 'KEEP=1' "$(cat "$RW/.env.a")"
eq 'release: an ours file that was only the block is removed' no \
  "$([ -e "$RW/sub/.env.b" ] && echo yes || echo no)"
eq 'release: a theirs slot is not opened' "MINE=1|$WT_ENV_BEGIN|A=1|$WT_ENV_END" \
  "$(paste -sd '|' - <"$RW/.env.c")"
eq 'release: an empty slot is not opened' "NEVER=1|$WT_ENV_BEGIN|A=1|$WT_ENV_END" \
  "$(paste -sd '|' - <"$RW/.env.d")"
# A record from before env files became a list is the same shape with one element.
printf 'OLD=1\n%s\n' "$blk" >"$RW/.env.e"
wt_release_env_overrides "$RW" '.env.e' 'ours'
eq 'release: a single-file record still works' 'OLD=1' "$(cat "$RW/.env.e")"
wt_release_env_overrides "$RW" '' ''
eq 'release: an empty record is a no-op' 0 $?

printf '%d passed, %d failed, %d backend(s) exercised\n' "$pass" "$fail" "$backends_run" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
