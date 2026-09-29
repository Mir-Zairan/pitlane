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
  local label bad
  for label in 'the main checkout' 'the common git dir' '/' 'HOME' 'a non-worktree directory' \
    'a directory inside a worktree' 'a relative path' 'an unregistered copy of a worktree'; do
    case $label in
      'the main checkout') bad=$R ;;
      'the common git dir') bad=$R/.git ;;
      /) bad=/ ;;
      HOME) bad=$HOME ;;
      'a non-worktree directory') bad=$SCRATCH ;;
      'a directory inside a worktree') mkdir -p "$W1/sub"; bad=$W1/sub ;;
      'a relative path') bad='.claude/worktrees/my fix' ;;
      'an unregistered copy of a worktree') bad=$R/.claude/worktrees/copied ;;
    esac
    WT_RM_WORKTREE=stale
    resolve "{\"worktree_path\":\"$(jstr "$bad")\",\"cwd\":\"$(jstr "$R")\"}"
    eq "refuses $label" 1 "$rc"
    eq "...and resolves nothing for it" '' "$WT_RM_WORKTREE$WT_RM_ROOT$WT_RM_ADMIN$WT_RM_LEDGER_ENTRY"
    contains "...saying why" 'worktree: ' "$(cat "$TMP/resolve-err")"
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
contains '...naming it' 'sub' "$reasons"

holds 'a directory that is not there cannot be verified, so it holds work' 0 "$SCRATCH/nowhere"
contains '...saying it could not verify' 'could not verify' "$reasons"
cp "$HW/.git" "$HW/.git.good"
printf 'gitdir: %s\n' "$SCRATCH/nowhere/.git" >"$HW/.git"
holds 'a worktree git cannot read holds work' 0 "$HW"
contains '...saying it could not verify' 'could not verify' "$reasons"
eq '...and prints nothing but reasons on stdout' '' "$(printf '%s\n' "$reasons" | grep -v '^could not verify: ')"
mv "$HW/.git.good" "$HW/.git"
holds 'repaired, it is clean again' 1 "$HW"

printf '%d passed, %d failed, %d backend(s) exercised\n' "$pass" "$fail" "$backends_run" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
