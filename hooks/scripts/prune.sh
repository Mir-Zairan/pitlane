#!/usr/bin/env bash
# SC2329: the finders and appliers are called by name, from WT_PRUNE_FINDERS and the item's kind,
# where the linter cannot see them used — and it then flags every helper only they call.
# shellcheck disable=SC2329
#
# The /worktree-prune sweep: finds what this plugin's worktrees left behind, reports it, and removes
# exactly the items a developer confirmed. The skill (skills/worktree-prune) shows the report and
# asks; this script never asks anything, and is deterministic shell like the hooks (ADR-002).
#
#   prune.sh [--repo <dir>]                   REPORT. Changes nothing on disk, not even in .git.
#   prune.sh [--repo <dir>] --apply <id>...   act on exactly those items, and nothing else.
#
# <dir> is any directory of the repository (default: $PWD); the sweep runs from its main checkout.
#
# THE REPORT is one item per line, six TAB-separated fields, then summary lines starting `# `:
#
#   id  kind  path  bytes  action  reason
#
#   id      stable for the same item across runs: `p` + the cksum of its kind and key, in hex.
#   kind    orphan-dir | stale-admin | runtime-leftover | ledger-junk | held; `store` is reserved
#           for Phase 7's unreferenced dependency stores, so a reader must accept it already.
#   bytes   `du -sk` x 1024, or `-` where there is nothing to measure — a runtime allocation is a
#           database or a container, which only the repo's teardown script can see.
#   action  delete    remove the path.
#           teardown  run the main checkout's runtime.teardown with the recorded environment, then
#                     forget the ledger entry.
#           forget    forget the entry without running anything: the profile has no teardown script.
#           refuse    not safe now, and the reason says why. Still accepted by --apply, which
#                     re-judges it — an item waiting on another (a leftover whose directory is
#                     still there) becomes applicable once that one is gone.
#           none      listed so the developer sees why it is kept. Never applicable.
#   A tab or newline inside a path or reason is printed as a space; the item's own key, not the
#   printed path, is what --apply acts on.
#
# --APPLY takes the repository's prune lock, then re-runs discovery and every check before each
# item, in report order, so an item that changed since the report is judged as it is now. A runtime
# allocation is released under its ledger entry's lock too — the one teardown.sh holds — and
# re-checked once that is held. Each outcome is one line, and a summary line always closes them:
#
#   applied  id  kind  path  freed-bytes  detail      freed = du before - du after
#   refused  id  kind  path  -            reason      also said on stderr
#   # <applied> applied, <refused> refused, <freed> bytes freed by du
#
# Exit status: 0 every id was applied, 1 at least one was refused (the others still ran), 2 a usage
# error, or a repository that cannot be resolved or surveyed.
#
# WHAT IS NEVER DONE, whatever an item says:
#   * no live registered worktree is touched — the ones Claude Code created natively and the
#     developer's own `--worktree` ones included. One that holds work is listed as `held`.
#   * no process is killed; the repo's teardown script is the only thing that may stop what its
#     seed started.
#   * no shared state is removed: the main checkout a dependency was hardlinked from, package
#     caches, <common>/worktree-locks/ (only lock files are created there: this script's own, and
#     the per-entry allocation locks it shares with teardown.sh), and no repository-wide
#     `git worktree prune`.
#   * no allocation whose worktree git still registers or locks is released, wherever the ledger
#     says the worktree was: `git worktree move` changes the one and not the other.
#   * nothing that cannot be proven safe is removed. Every check fails CLOSED, into `refuse`.
#
# AN ORPHAN DIRECTORY CANNOT BE ASKED "DO YOU HOLD WORK": git no longer knows it, so there is no
# index and no HEAD to compare against. The rule instead is that deleting it must lose no file
# content: every file in it that git would not ignore must already exist, byte for byte, as a blob
# in the repository's object store — so it was committed or staged at some point, and survives the
# directory. Gitignored files are never work (the same rule as the holds-work guard). Anything
# unprovable — a nested repository, a path with a newline, a file git cannot hash — refuses. This
# rejects clean checkouts of repos whose committed bytes differ from the working ones (CRLF
# conversion, LFS), because hashing runs without filters: a clean filter could write into .git,
# and report mode writes nothing. A `.git` file that still names an existing admin dir, or an admin
# dir anywhere but this repository's, is not an orphan at all: it refuses, pointing at
# `git worktree repair`. That is also what a moved or renamed main checkout looks like.
#
# BYTES COUNT HARDLINKED FILES IN FULL. `du` counts each inode once per invocation, and every item
# is measured on its own, so a dependency directory hardlinked from the main checkout shows its
# whole size although deleting it releases only what no other link holds. The reason says so,
# with the number of such files, rather than hiding it; the freed bytes at apply are measured the
# same way, so the two numbers agree with each other and with `du`.
#
# NOT `set -e`. Discovery asks dozens of questions whose non-zero answer is information, and an
# apply that aborted halfway would leave some items done and no line saying which. Every failure
# becomes a refusal of that one item; the exit status is computed, not inherited. Unlike the hooks
# it may exit non-zero: nothing waits on it, and a refusal is what the caller needs to see.
set -uo pipefail

# SC1091: see bootstrap.sh — the gate lints each file on its own; `shellcheck -x` follows these.
# teardown-lib.sh sources bootstrap-lib.sh, which sources lib.sh.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=teardown-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/teardown-lib.sh"

# How old a half-written ledger entry must be before it counts as abandoned. A writer holds its
# temp file for milliseconds; minutes is room for a stalled one without guessing at seconds.
WT_PRUNE_TEMP_MINUTES=10

# The finders, in report order, which is also the order --apply works in. Each one adds items with
# wt_prune_add, and each kind an item can be applied as has a `wt_apply_<kind>` function (dashes as
# underscores) that performs it. Order matters where one item waits on another: a leftover's
# directory goes before its runtime allocation, and an allocation recorded only in a stale admin
# dir is released before that admin dir goes (wt_find_stale_admin_dirs lists the two in that order).
WT_PRUNE_FINDERS=(
  wt_find_orphan_dirs
  wt_find_stale_admin_dirs
  wt_find_runtime_leftovers
  wt_find_ledger_junk
  wt_find_held_worktrees
  # TODO(phase-7): wt_find_unreferenced_stores — dependency stores under the store root that no live
  # worktree's links resolve into, kind `store`, applied by a wt_apply_store that re-counts the
  # references before it deletes.
)

# ---------------------------------------------------------------------------
# Items
# ---------------------------------------------------------------------------

# One discovery's items, index-aligned. PRUNE_KEY is what the applier acts on (a physical path,
# `ledger:<entry>` or `state:<state file>`); PRUNE_MEASURE is the path whose size the item frees,
# or empty.
PRUNE_ID=() PRUNE_KIND=() PRUNE_PATH=() PRUNE_BYTES=() PRUNE_ACTION=() PRUNE_REASON=()
PRUNE_KEY=() PRUNE_MEASURE=()

wt_prune_item_id() {  # $1 = kind, $2 = key
  local sum
  sum=$(printf '%s%s%s' "$1" "$WT_US" "$2" | cksum 2>/dev/null) || sum=0
  printf 'p%08x' "${sum%% *}"
}

wt_prune_add() {  # $1 = kind, $2 = key, $3 = path shown, $4 = bytes, $5 = action, $6 = reason, $7 = path measured
  local n=${#PRUNE_ID[@]}
  PRUNE_ID[n]=$(wt_prune_item_id "$1" "$2")
  PRUNE_KIND[n]=$1
  PRUNE_KEY[n]=$2
  PRUNE_PATH[n]=$3
  PRUNE_BYTES[n]=$4
  PRUNE_ACTION[n]=$5
  PRUNE_REASON[n]=$6
  PRUNE_MEASURE[n]=${7-}
}

# The index of the item with id $1 in the current discovery, or return 1.
wt_prune_find_item() {  # $1 = id
  local i
  for i in ${PRUNE_ID[@]+"${!PRUNE_ID[@]}"}; do
    [ "${PRUNE_ID[i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# Reasons are gathered one per line and printed joined, so a finder can add them as it goes.
wt_prune_join_reasons() {  # $1 = reasons, one per line
  local line out=''
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    out=${out:+$out; }$line
  done <<<"${1-}"
  printf '%s' "$out"
}

wt_prune_printable() {  # $1 = text
  local text=${1-}
  text=${text//$'\t'/ }
  text=${text//$'\n'/ }
  printf '%s' "${text//$'\r'/ }"
}

# `du -sk` of $1 in bytes; 0 for a path that is gone. du still prints a total when part of the tree
# is unreadable, and that total is what is reported.
wt_prune_bytes() {  # $1 = path
  local kib
  [ -e "$1" ] || [ -L "$1" ] || { printf 0; return 0; }
  kib=$(du -sk -- "$1" 2>/dev/null | cut -f1)
  wt_is_posint "$kib" || kib=0
  printf '%s' "$((kib * 1024))"
}

# A note for the reason when files under $1 have other hardlinks, or nothing.
wt_prune_shared_note() {  # $1 = path
  local count
  count=$(find "$1" -type f -links +1 2>/dev/null | wc -l | tr -d ' ')
  wt_is_posint "$count" && [ "$count" -gt 0 ] || return 0
  printf '%s file(s) are shared with other hardlinks (a dependency dir hardlinked from the main checkout), so deleting frees less than this' "$count"
}

# ---------------------------------------------------------------------------
# The survey every finder reads
# ---------------------------------------------------------------------------
#
#   WT_PRUNE_ROOT      the main checkout, physical
#   WT_PRUNE_COMMON    its shared git dir, physical
#   WT_PRUNE_WTDIR     <root>/.claude/worktrees, physical, or empty when there is none (or it is a
#                      symlink, which is never followed)
#   WT_PRUNE_LIVE      every registered linked worktree whose directory exists, physical
#   WT_PRUNE_LOCKED    every locked linked worktree whose directory does not, as git lists it — on
#                      a disk that is not mounted, say, and as much in use as a live one
#   WT_PRUNE_ORPHANS   the largest directories under WT_PRUNE_WTDIR that are not a live worktree,
#                      not inside one, and hold none
#   WT_PRUNE_TEARDOWN  what a runtime leftover would be applied as: teardown, forget, or refuse
#                      with WT_PRUNE_TEARDOWN_WHY
WT_PRUNE_ROOT='' WT_PRUNE_COMMON='' WT_PRUNE_WTDIR='' WT_PRUNE_TEARDOWN='' WT_PRUNE_TEARDOWN_WHY=''
WT_PRUNE_LIVE=() WT_PRUNE_LOCKED=() WT_PRUNE_ORPHANS=()

wt_prune_list_live() {
  local listed line wt='' physical n=0
  WT_PRUNE_LIVE=() WT_PRUNE_LOCKED=()
  listed=$(wt_git "$WT_PRUNE_ROOT" worktree list --porcelain 2>/dev/null) || return 1
  while IFS= read -r line; do
    case $line in
      'worktree '*)
        wt=${line#worktree }
        n=$((n + 1))
        # The first entry is the main checkout.
        [ "$n" -gt 1 ] && [ -d "$wt" ] || continue
        physical=$(cd -P "$wt" 2>/dev/null && pwd -P) || continue
        WT_PRUNE_LIVE[${#WT_PRUNE_LIVE[@]}]=$physical
        ;;
      locked | 'locked '*)
        [ "$n" -gt 1 ] && [ ! -d "$wt" ] && WT_PRUNE_LOCKED[${#WT_PRUNE_LOCKED[@]}]=$wt
        ;;
    esac
  done <<<"$listed"
  return 0
}

wt_prune_is_live() {  # $1 = physical path
  local live
  for live in ${WT_PRUNE_LIVE[@]+"${WT_PRUNE_LIVE[@]}"}; do
    [ "$live" = "$1" ] && return 0
  done
  return 1
}

wt_prune_is_locked() {  # $1 = recorded worktree path
  local locked
  for locked in ${WT_PRUNE_LOCKED[@]+"${WT_PRUNE_LOCKED[@]}"}; do
    [ "$locked" = "$1" ] && return 0
  done
  return 1
}

wt_prune_holds_live() {  # $1 = physical directory
  local live
  for live in ${WT_PRUNE_LIVE[@]+"${WT_PRUNE_LIVE[@]}"}; do
    case $live in "$1"/*) return 0 ;; esac
  done
  return 1
}

# Nested names put worktrees at `alice/fix-99`, so `alice/` is walked into while it holds a live
# worktree, and whatever else is in it is judged on its own. Symlinks are never followed.
wt_prune_walk_orphans() {  # $1 = physical directory
  local child
  for child in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ -d "$child" ] && [ ! -L "$child" ] || continue
    wt_prune_is_live "$child" && continue
    if wt_prune_holds_live "$child"; then
      wt_prune_walk_orphans "$child"
    else
      WT_PRUNE_ORPHANS[${#WT_PRUNE_ORPHANS[@]}]=$child
    fi
  done
}

# What the main checkout's CURRENT profile would do with a leftover allocation. The worktree's own
# committed profile is gone with it, so the main checkout's is the only one left — the same choice
# teardown.sh makes for a worktree already removed.
wt_prune_judge_teardown() {
  WT_PRUNE_TEARDOWN='' WT_PRUNE_TEARDOWN_WHY=''
  wt_load_profile "$WT_PRUNE_ROOT" 2>/dev/null
  if [ -e "$WT_PRUNE_ROOT/.claude/worktree-profile.json" ] && [ "${PROFILE_PRESENT:-0}" != 1 ]; then
    WT_PRUNE_TEARDOWN=refuse
    WT_PRUNE_TEARDOWN_WHY='the main checkout'\''s profile cannot be loaded (invalid, or no jq/python3), so whether a teardown script must run is unknown'
  elif [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_TEARDOWN:-}" ]; then
    WT_PRUNE_TEARDOWN=teardown
  else
    WT_PRUNE_TEARDOWN=forget
    WT_PRUNE_TEARDOWN_WHY='no teardown script in the profile; forget the entry with --apply only if you released it by hand'
  fi
}

wt_prune_survey() {  # $1 = main checkout
  WT_PRUNE_ROOT=$1
  WT_PRUNE_COMMON='' WT_PRUNE_WTDIR='' WT_PRUNE_ORPHANS=()
  WT_PRUNE_COMMON=$(wt_git_common_dir "$WT_PRUNE_ROOT") \
    && WT_PRUNE_COMMON=$(cd -P "$WT_PRUNE_COMMON" 2>/dev/null && pwd -P) || return 1
  wt_prune_list_live || return 1
  if [ -d "$WT_PRUNE_ROOT/.claude/worktrees" ]; then
    if [ -L "$WT_PRUNE_ROOT/.claude/worktrees" ] || [ -L "$WT_PRUNE_ROOT/.claude" ]; then
      wt_log "not sweeping $WT_PRUNE_ROOT/.claude/worktrees: it is reached through a symlink"
    else
      WT_PRUNE_WTDIR=$WT_PRUNE_ROOT/.claude/worktrees
      wt_prune_walk_orphans "$WT_PRUNE_WTDIR"
    fi
  fi
  wt_prune_judge_teardown
}

# Run every finder against a fresh survey. Returns 1 when the repository cannot be surveyed.
wt_prune_discover() {  # $1 = main checkout
  local finder
  PRUNE_ID=() PRUNE_KIND=() PRUNE_PATH=() PRUNE_BYTES=() PRUNE_ACTION=() PRUNE_REASON=()
  PRUNE_KEY=() PRUNE_MEASURE=()
  wt_prune_survey "$1" || return 1
  for finder in "${WT_PRUNE_FINDERS[@]}"; do
    "$finder"
  done
  return 0
}

# ---------------------------------------------------------------------------
# Finders
# ---------------------------------------------------------------------------

# Print a reason for every file under $1 whose content deleting it would lose, and return 0 if
# there was one — the predicate shape of wt_worktree_holds_work. Returns 1 only when every file git
# would not ignore is provably already a blob in the object store.
#
# The listing runs against an index that does not exist, so every non-ignored file is listed
# (tracked or not, there is no index to say which) and nothing is written: ls-files, hash-object
# without -w and cat-file only read. The ignore rules are the directory's own .gitignore files and
# the repository's info/exclude — what the checkout was ignoring when it was live.
wt_dir_holds_unsaved_content() {  # $1 = physical directory
  local dir=$1 common=$WT_PRUNE_COMMON noindex path rel paths=() links=() hashes checked
  local line n=0 missing=0 first='' hash complete=0 tab=$'\t'
  noindex=$common/worktree-prune-no-index.$$
  if [ -e "$noindex" ]; then
    printf 'could not verify: %s is in the way of an empty index\n' "$noindex"
    return 0
  fi
  # The listing ends with a sentinel no file name git prints can equal — it has a tab where a
  # complete listing has none — so one cut short by a failure is told apart from an empty one.
  while IFS= read -r -d '' rel; do
    case $rel in
      "$tab"end) complete=1; continue ;;
      */)
        printf 'could not verify: %s is a repository of its own\n' "$rel"
        return 0
        ;;
      *$'\n'*)
        printf 'could not verify: a file name contains a newline\n'
        return 0
        ;;
    esac
    path=$dir/$rel
    if [ -L "$path" ]; then
      links[${#links[@]}]=$rel
    else
      paths[${#paths[@]}]=$rel
    fi
  done < <(cd "$dir" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE GIT_INDEX_FILE="$noindex" \
    GIT_OPTIONAL_LOCKS=0 git --git-dir="$common" --work-tree="$dir" \
    ls-files --others --exclude-standard -z 2>/dev/null && printf '\tend\0')
  if [ "$complete" != 1 ]; then
    printf 'could not verify: git cannot list the files in %s\n' "$dir"
    return 0
  fi
  [ ${#paths[@]} -gt 0 ] || [ ${#links[@]} -gt 0 ] || return 1

  # A symlink is stored as its target text; hash-object would follow it and hash the target file.
  hashes=''
  if [ ${#paths[@]} -gt 0 ]; then
    if ! hashes=$(printf '%s\n' "${paths[@]}" | (cd "$dir" && env -u GIT_DIR -u GIT_WORK_TREE \
      git --git-dir="$common" hash-object --no-filters --stdin-paths 2>/dev/null)) \
      || [ "$(printf '%s\n' "$hashes" | wc -l | tr -d ' ')" != "${#paths[@]}" ]; then
      printf 'could not verify: git cannot hash the files in %s\n' "$dir"
      return 0
    fi
  fi
  for rel in ${links[@]+"${links[@]}"}; do
    if ! hash=$(readlink "$dir/$rel" 2>/dev/null | tr -d '\n' | env -u GIT_DIR -u GIT_WORK_TREE \
      git --git-dir="$common" hash-object --stdin 2>/dev/null) || [ -z "$hash" ]; then
      printf 'could not verify: cannot read the symlink %s\n' "$rel"
      return 0
    fi
    hashes=${hashes:+$hashes$'\n'}$hash
    paths[${#paths[@]}]=$rel
  done
  if ! checked=$(printf '%s\n' "$hashes" | env -u GIT_DIR -u GIT_WORK_TREE \
    git --git-dir="$common" cat-file --batch-check 2>/dev/null); then
    printf 'could not verify: git cannot look up the files of %s\n' "$dir"
    return 0
  fi
  while IFS= read -r line; do
    case $line in
      *' missing')
        missing=$((missing + 1))
        [ -n "$first" ] || first=${paths[n]}
        ;;
    esac
    n=$((n + 1))
  done <<<"$checked"
  if [ "$n" != "${#paths[@]}" ]; then
    printf 'could not verify: git answered for %s of %s files\n' "$n" "${#paths[@]}"
    return 0
  fi
  if [ "$missing" -gt 0 ]; then
    printf '%d file(s) whose content is in no commit (first: %s)\n' "$missing" "$first"
    return 0
  fi
  return 1
}

# Judge one orphan candidate into WT_PRUNE_VERDICT (delete | refuse) and WT_PRUNE_WHY.
wt_prune_judge_orphan() {  # $1 = physical directory
  local dir=$1 pointer reasons
  WT_PRUNE_VERDICT=refuse WT_PRUNE_WHY=''
  if [ -e "$dir/.git" ] || [ -L "$dir/.git" ]; then
    if [ -d "$dir/.git" ]; then
      WT_PRUNE_WHY='a repository of its own (its .git is a directory), not a former worktree'
      return 0
    fi
    if ! pointer=$(wt_read_git_pointer "$dir/.git" "$dir"); then
      WT_PRUNE_WHY='its .git file cannot be read, so what it belonged to is unknown'
      return 0
    fi
    if [ -e "$pointer" ]; then
      WT_PRUNE_WHY="not an orphan: its .git still links the admin dir $pointer — run \`git worktree repair $dir\` to register it again"
      return 0
    fi
    if [ "$(wt_physical_path "$pointer")" != "$WT_PRUNE_COMMON/worktrees/${pointer##*/}" ]; then
      WT_PRUNE_WHY="its .git names $pointer, which is not in this repository's git dir — its main checkout was probably moved or renamed; run \`git worktree repair $dir\` from the main checkout"
      return 0
    fi
  fi
  if reasons=$(wt_dir_holds_unsaved_content "$dir"); then
    WT_PRUNE_WHY="cannot verify, refusing: $(wt_prune_join_reasons "$reasons")"
    return 0
  fi
  WT_PRUNE_VERDICT=delete
  WT_PRUNE_WHY='git no longer lists it as a worktree, and every file it holds is either gitignored or already in the repository'
}

wt_find_orphan_dirs() {
  local dir bytes note
  for dir in ${WT_PRUNE_ORPHANS[@]+"${WT_PRUNE_ORPHANS[@]}"}; do
    wt_prune_judge_orphan "$dir"
    bytes=$(wt_prune_bytes "$dir")
    note=$(wt_prune_shared_note "$dir")
    wt_prune_add orphan-dir "$dir" "$dir" "$bytes" "$WT_PRUNE_VERDICT" "$WT_PRUNE_WHY${note:+; $note}" "$dir"
  done
}

# Why the worktree an admin dir or ledger entry recorded may still be alive somewhere, one reason
# per line, or nothing. $2 is the admin id when there is one.
wt_prune_alive_elsewhere() {  # $1 = recorded worktree path, $2 = admin id or empty
  local wt=$1 id=${2-} dir pointer
  case $wt in
    "$WT_PRUNE_ROOT$WT_SUBPATH"*) ;;
    *)
      printf 'it was recorded at %s, not under this main checkout'\''s .claude/worktrees — the main checkout was moved or renamed, or it is not a worktree this plugin manages\n' "$wt"
      ;;
  esac
  if [ -e "$wt" ] || [ -L "$wt" ]; then
    printf 'its directory %s still exists\n' "$wt"
  fi
  [ -n "$id" ] || return 0
  for dir in ${WT_PRUNE_ORPHANS[@]+"${WT_PRUNE_ORPHANS[@]}"}; do
    [ -f "$dir/.git" ] || continue
    pointer=$(wt_read_git_pointer "$dir/.git" "$dir") || continue
    case $pointer in
      */worktrees/"$id")
        # shellcheck disable=SC2016  # the backticks are literal text
        printf 'the directory %s still links an admin dir named %s — it may have moved; run `git worktree repair` there\n' "$dir" "$id"
        ;;
    esac
  done
  return 0
}

# Why the allocation a ledger entry records may still belong to a worktree in use, one reason per
# line, or nothing: everything wt_prune_alive_elsewhere says, and whether git still registers the
# entry's admin dir or lists its worktree as locked. A registered admin dir is left to its own
# stale-admin item, whatever it points at — after `git worktree move` it points at the worktree's
# new home, which the ledger does not know.
wt_prune_list_allocation_holds() {  # $1 = recorded worktree path, $2 = admin id or empty
  local wt=$1 id=${2-}
  wt_prune_alive_elsewhere "$wt" "$id"
  if [ -n "$id" ] && { [ -e "$WT_PRUNE_COMMON/worktrees/$id" ] || [ -L "$WT_PRUNE_COMMON/worktrees/$id" ]; }; then
    printf 'its admin dir %s is still registered — the worktree may have been moved or locked\n' \
      "$WT_PRUNE_COMMON/worktrees/$id"
  fi
  if wt_prune_is_locked "$wt"; then
    # shellcheck disable=SC2016  # the backticks are literal text
    printf 'its worktree is locked with `git worktree lock`\n'
  fi
  return 0
}

wt_find_stale_admin_dirs() {
  local admin id pointer wt alive why marker head count slug entry rt_id state bytes shared
  [ -d "$WT_PRUNE_COMMON/worktrees" ] || return 0
  for admin in "$WT_PRUNE_COMMON"/worktrees/*; do
    [ -d "$admin" ] && [ ! -L "$admin" ] || continue
    wt_rm_is_admin_dir "$admin" || continue
    id=${admin##*/}
    bytes=$(wt_prune_bytes "$admin")
    if ! pointer=$(wt_read_git_pointer "$admin/gitdir" "$admin"); then
      wt_prune_add stale-admin "$admin" "$admin" "$bytes" refuse \
        'its gitdir file cannot be read, so which checkout it served is unknown' "$admin"
      continue
    fi
    # A checkout that still has its .git file is live as far as git is concerned.
    [ -e "$pointer" ] && continue
    wt=${pointer%/.git}

    alive=$(wt_prune_alive_elsewhere "$wt" "$id")
    if [ -e "$admin/locked" ]; then
      why=''
      IFS= read -r why <"$admin/locked" 2>/dev/null || true
      alive=${alive:+$alive$'\n'}"locked with \`git worktree lock\`${why:+: $why}"
    fi
    why=$alive
    for marker in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase \
      CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect; do
      [ -e "$admin/${marker%%:*}" ] && why=${why:+$why$'\n'}"${marker#*:} in progress"
    done
    # Its HEAD dies with it; its branch does not. So only commits no branch or remote holds are lost.
    if ! head=$(wt_git "$WT_PRUNE_ROOT" --git-dir="$admin" rev-parse --verify -q HEAD 2>/dev/null) \
      || [ -z "$head" ]; then
      why=${why:+$why$'\n'}'could not verify: its HEAD does not name a commit'
    elif ! count=$(wt_git "$WT_PRUNE_ROOT" --git-dir="$admin" rev-list --count "$head" --not \
      --branches --remotes 2>/dev/null) || [ -z "$count" ]; then
      why=${why:+$why$'\n'}'could not verify: cannot list the commits only its HEAD has'
    elif [ "$count" -gt 0 ]; then
      why=${why:+$why$'\n'}"$count commit(s) on its HEAD that no branch and no remote-tracking ref contains"
    fi

    # The ledger write can fail; the state file is then the only record of the allocation, and it
    # goes with this admin dir — so the allocation is released first, as its own item.
    state=$admin/worktree-bootstrap-state
    if slug=$(wt_runtime_state_read "$state" slug 2>/dev/null) \
      && ! entry=$(wt_ledger_entry_for "$WT_PRUNE_ROOT" "$wt" "$id"); then
      rt_id=$(wt_prune_item_id runtime-leftover "state:$state")
      if [ -n "$alive" ]; then
        wt_prune_add runtime-leftover "state:$state" "$wt" - refuse \
          "$(wt_prune_join_reasons "$alive")" ''
      else
        wt_prune_add runtime-leftover "state:$state" "$wt" - "$WT_PRUNE_TEARDOWN" \
          "$(wt_prune_join_reasons "allocation slug=$slug recorded only in the state file of the stale admin dir $admin (no ledger entry)"$'\n'"size unknown: a database or containers only the teardown script can see"$'\n'"$WT_PRUNE_TEARDOWN_WHY")" ''
      fi
      why=${why:+$why$'\n'}"its state file is the only record of an allocation (slug=$slug) — apply $rt_id first"
    fi

    shared=$(wt_prune_shared_note "$admin")
    if [ -n "$why" ]; then
      wt_prune_add stale-admin "$admin" "$admin" "$bytes" refuse "$(wt_prune_join_reasons "$why")" "$admin"
    else
      wt_prune_add stale-admin "$admin" "$admin" "$bytes" delete \
        "the git registration of $wt, which no longer exists${shared:+; $shared}" "$admin"
    fi
  done
}

wt_find_runtime_leftovers() {
  local entry path admin slug rest holds why waits_on
  while IFS=$WT_US read -r -d "$WT_RS" entry path admin _ slug rest; do
    wt_prune_is_live "$path" && continue
    holds=$(wt_prune_list_allocation_holds "$path" "$admin")
    if [ -n "$holds" ]; then
      why=$(wt_prune_join_reasons "$holds")
      # Orphans are keyed physically; the ledger recorded the path as the worktree saw it.
      waits_on=$(wt_prune_item_id orphan-dir "$(wt_physical_path "$path")")
      wt_prune_find_item "$waits_on" >/dev/null && why="$why — remove it first ($waits_on)"
      if [ -n "$admin" ]; then
        waits_on=$(wt_prune_item_id stale-admin "$WT_PRUNE_COMMON/worktrees/$admin")
        wt_prune_find_item "$waits_on" >/dev/null && why="$why — settle its admin dir first ($waits_on)"
      fi
      wt_prune_add runtime-leftover "ledger:$entry" "$path" - refuse "$why" ''
      continue
    fi
    wt_prune_add runtime-leftover "ledger:$entry" "$path" - "$WT_PRUNE_TEARDOWN" \
      "$(wt_prune_join_reasons "ledger entry $entry: allocation slug=$slug of a worktree that no longer exists"$'\n'"size unknown: a database or containers only the teardown script can see"$'\n'"${WT_PRUNE_TEARDOWN_WHY}")" ''
  done < <(wt_ledger_entries "$WT_PRUNE_ROOT" 2>/dev/null)
}

wt_find_ledger_junk() {
  local ledger=$WT_PRUNE_COMMON/$WT_LEDGER_DIRNAME file
  [ -d "$ledger" ] && [ ! -L "$ledger" ] || return 0
  while IFS= read -r file; do
    [ -n "$file" ] && [ -f "$file" ] && [ ! -L "$file" ] || continue
    wt_prune_add ledger-junk "$file" "$file" "$(wt_prune_bytes "$file")" delete \
      "a ledger entry abandoned half-written over $WT_PRUNE_TEMP_MINUTES minutes ago" "$file"
  done < <(find "$ledger" -maxdepth 1 -type f -name "${WT_LEDGER_TMP_PREFIX}*" \
    -mmin +"$WT_PRUNE_TEMP_MINUTES" 2>/dev/null)
  for file in "$ledger"/*; do
    [ -e "$file" ] || continue
    wt_ledger_is_entry_name "${file##*/}" || continue
    wt_ledger_parse "$file" && continue
    wt_prune_add ledger-junk "$file" "$file" "$(wt_prune_bytes "$file")" none \
      'a ledger entry this version cannot read — perhaps a newer format; not deleted' ''
  done
}

wt_find_held_worktrees() {
  local wt reasons
  [ -n "$WT_PRUNE_WTDIR" ] || return 0
  for wt in ${WT_PRUNE_LIVE[@]+"${WT_PRUNE_LIVE[@]}"}; do
    case $wt in "$WT_PRUNE_WTDIR"/*) ;; *) continue ;; esac
    reasons=$(wt_worktree_holds_work "$wt") || continue
    wt_prune_add held "$wt" "$wt" "$(wt_prune_bytes "$wt")" none \
      "a live worktree holding work: $(wt_prune_join_reasons "$reasons")" ''
  done
}

# ---------------------------------------------------------------------------
# Appliers — one per kind that can be applied. Each is given the item's index in a discovery made
# just before it, re-checks what it is about to act on, and returns 0 when applied or 1 when
# refused, with a detail or reason in WT_PRUNE_DETAIL.
# ---------------------------------------------------------------------------

WT_PRUNE_DETAIL=''

# True if $1 still resolves physically to itself: no symlink swapped in since discovery.
wt_prune_still_itself() {  # $1 = physical path
  [ ! -L "$1" ] && [ "$(cd -P "$1" 2>/dev/null && pwd -P)" = "$1" ]
}

wt_prune_remove_dir() {  # $1 = physical directory
  rm -rf -- "${1:?}" 2>/dev/null
  if [ -e "$1" ]; then
    WT_PRUNE_DETAIL="could not delete $1 completely — remove the rest by hand"
    return 1
  fi
  return 0
}

wt_apply_orphan_dir() {  # $1 = item index
  local dir=${PRUNE_KEY[$1]}
  case $dir in
    "$WT_PRUNE_WTDIR"/*) ;;
    *) WT_PRUNE_DETAIL="$dir is not under $WT_PRUNE_ROOT/.claude/worktrees"; return 1 ;;
  esac
  if ! wt_prune_still_itself "$dir"; then
    WT_PRUNE_DETAIL="$dir no longer resolves to the directory that was checked"
    return 1
  fi
  if ! wt_prune_list_live || wt_prune_is_live "$dir" || wt_prune_holds_live "$dir"; then
    WT_PRUNE_DETAIL="$dir is a live worktree now, or holds one"
    return 1
  fi
  wt_prune_remove_dir "$dir" || return 1
  WT_PRUNE_DETAIL='deleted'
}

wt_apply_stale_admin() {  # $1 = item index
  local admin=${PRUNE_KEY[$1]} pointer
  if [ "${admin%/*}" != "$WT_PRUNE_COMMON/worktrees" ] || ! wt_prune_still_itself "$admin" \
    || ! wt_rm_is_admin_dir "$admin"; then
    WT_PRUNE_DETAIL="$admin is no longer an admin dir of this repository"
    return 1
  fi
  if [ -e "$admin/locked" ] || ! pointer=$(wt_read_git_pointer "$admin/gitdir" "$admin") \
    || [ -e "$pointer" ] || [ -e "${pointer%/.git}" ]; then
    WT_PRUNE_DETAIL="$admin is locked or its checkout is back"
    return 1
  fi
  wt_prune_remove_dir "$admin" || return 1
  WT_PRUNE_DETAIL='deleted (only this admin dir; no repository-wide prune)'
}

# The descriptor an allocation's lock is held on while one runtime-leftover is applied; the prune
# lock holds 8.
WT_PRUNE_ALLOCATION_FD=9

# The allocation is read from ONE record, as teardown.sh reads it, and the teardown script runs from
# the main checkout with the environment the seed had — wt_run_teardown_script does both. All of it
# happens under the lock teardown.sh takes on the same record: its ledger entry's allocation lock,
# or, for a record only a state file holds, the worktree's own lock that bootstrap takes.
wt_apply_runtime_leftover() {  # $1 = item index
  local key=${PRUNE_KEY[$1]} rc
  case $key in
    ledger:*)
      if ! wt_acquire_allocation_lock "$WT_PRUNE_ROOT" "${key#ledger:}" "$WT_PRUNE_ALLOCATION_FD"; then
        WT_PRUNE_DETAIL=$WT_TD_KEEP_REASON
        return 1
      fi
      ;;
    state:*)
      if command -v flock >/dev/null 2>&1 \
        && ! wt_lock_acquire "${key#state:}.lock" 5 "$WT_PRUNE_ALLOCATION_FD"; then
        WT_PRUNE_DETAIL='a bootstrap or teardown holds its worktree, or its lock cannot be taken'
        return 1
      fi
      ;;
    *) WT_PRUNE_DETAIL="unknown record $key"; return 1 ;;
  esac
  wt_prune_release_allocation "$1"
  rc=$?
  wt_lock_release "$WT_PRUNE_ALLOCATION_FD"
  return "$rc"
}

# Why the allocation of item $1 must not be released now, re-checked under its lock, or nothing.
# The holder the lock waited on may have released it already, or the worktree come back.
wt_prune_recheck_allocation() {  # $1 = item index
  local key=${PRUNE_KEY[$1]} wt=${PRUNE_PATH[$1]} entry admin state pointer
  if ! wt_prune_list_live; then
    printf 'git cannot list the worktrees now\n'
    return 0
  fi
  if wt_prune_is_live "$(wt_physical_path "$wt")"; then
    printf '%s is a live worktree now\n' "$wt"
    return 0
  fi
  case $key in
    ledger:*)
      entry=${key#ledger:}
      if ! admin=$(wt_ledger_field "$WT_PRUNE_ROOT" "$entry" admin); then
        printf 'its ledger entry %s is gone — another teardown or prune released it\n' "$entry"
        return 0
      fi
      wt_prune_list_allocation_holds "$wt" "$admin"
      ;;
    state:*)
      state=${key#state:}
      if [ ! -f "$state" ] || [ -L "$state" ]; then
        printf 'its state file %s is gone\n' "$state"
        return 0
      fi
      [ -e "${state%/*}/locked" ] && printf 'its admin dir is locked now\n'
      if ! pointer=$(wt_read_git_pointer "${state%/*}/gitdir" "${state%/*}") || [ -e "$pointer" ]; then
        printf 'its admin dir no longer names a checkout that is gone\n'
      fi
      wt_prune_alive_elsewhere "$wt" ''
      ;;
  esac
  return 0
}

# Release the allocation of item $1 with its lock held: nothing is forgotten unless the teardown
# script ran to `done`, or the action is `forget` and the allocation could be read.
wt_prune_release_allocation() {  # $1 = item index
  local key=${PRUNE_KEY[$1]} wt=${PRUNE_PATH[$1]} action=${PRUNE_ACTION[$1]} entry='' state='' why record
  case $key in
    ledger:*) entry=${key#ledger:}; record="the ledger entry $entry" ;;
    state:*) state=${key#state:}; record="the state file $state" ;;
  esac
  why=$(wt_prune_recheck_allocation "$1")
  if [ -n "$why" ]; then
    WT_PRUNE_DETAIL="not released: $(wt_prune_join_reasons "$why")"
    return 1
  fi
  if ! wt_read_allocation "$state" "$WT_PRUNE_ROOT" "$entry" "$wt"; then
    WT_PRUNE_DETAIL="the allocation in $record cannot be read — nothing was run, and the record is kept"
    return 1
  fi
  WT_TD_STATUS=none
  if [ "$action" = teardown ]; then
    # Loaded again because the discovery's load may be minutes old in a long apply.
    wt_load_profile "$WT_PRUNE_ROOT"
    if [ "${PROFILE_PRESENT:-0}" != 1 ] || [ "${PROFILE_HAS_RUNTIME:-0}" != 1 ] \
      || [ -z "${PROFILE_RT_TEARDOWN:-}" ]; then
      WT_PRUNE_DETAIL='the profile no longer names a teardown script — re-run the report'
      return 1
    fi
    wt_run_teardown_script "$WT_PRUNE_ROOT" "$wt" "$WT_PRUNE_ROOT" ''
    if [ "$WT_TD_STATUS" != "done" ]; then
      WT_PRUNE_DETAIL="the teardown script's outcome was $WT_TD_STATUS — $record is kept, and its database or containers may still exist"
      return 1
    fi
  fi
  if [ -n "$entry" ]; then
    wt_settle_ledger_entry "$WT_PRUNE_ROOT" "$entry" 1
    if [ "$WT_TD_LEDGER" != forgotten ]; then
      WT_PRUNE_DETAIL="could not forget $record"
      return 1
    fi
  else
    # The state file's only remaining purpose was this record; the admin dir around it is its own
    # stale-admin item.
    if ! rm -f -- "${state:?}" 2>/dev/null || [ -e "$state" ]; then
      WT_PRUNE_DETAIL="could not remove $record"
      return 1
    fi
  fi
  case $action in
    teardown) WT_PRUNE_DETAIL="teardown script ran (slug=$WT_TD_SLUG); record forgotten" ;;
    *) WT_PRUNE_DETAIL="record forgotten without running anything (slug=$WT_TD_SLUG)" ;;
  esac
}

wt_apply_ledger_junk() {  # $1 = item index
  local file=${PRUNE_KEY[$1]}
  case ${file##*/} in
    "$WT_LEDGER_TMP_PREFIX"*) ;;
    *) WT_PRUNE_DETAIL="$file is not a half-written entry"; return 1 ;;
  esac
  if [ "${file%/*}" != "$WT_PRUNE_COMMON/$WT_LEDGER_DIRNAME" ] || [ -L "$file" ] || [ ! -f "$file" ]; then
    WT_PRUNE_DETAIL="$file is no longer a plain file in the ledger"
    return 1
  fi
  if ! rm -f -- "${file:?}" 2>/dev/null || [ -e "$file" ]; then
    WT_PRUNE_DETAIL="could not remove $file"
    return 1
  fi
  WT_PRUNE_DETAIL='deleted'
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------

wt_prune_command_for() {  # $@ = ids
  local script
  script=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/prune.sh
  printf 'bash %q --repo %q --apply' "$script" "$WT_PRUNE_ROOT"
  [ $# -gt 0 ] && printf ' %s' "$@"
  printf '\n'
}

wt_prune_report() {
  local i total=0 applicable=() refused=0 held=0
  for i in ${PRUNE_ID[@]+"${!PRUNE_ID[@]}"}; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${PRUNE_ID[i]}" "${PRUNE_KIND[i]}" \
      "$(wt_prune_printable "${PRUNE_PATH[i]}")" "${PRUNE_BYTES[i]}" "${PRUNE_ACTION[i]}" \
      "$(wt_prune_printable "${PRUNE_REASON[i]}")"
    case ${PRUNE_ACTION[i]} in
      delete | teardown | forget)
        applicable[${#applicable[@]}]=${PRUNE_ID[i]}
        wt_is_posint "${PRUNE_BYTES[i]}" && total=$((total + PRUNE_BYTES[i]))
        ;;
      refuse) refused=$((refused + 1)) ;;
      none) held=$((held + 1)) ;;
    esac
  done
  printf '# %d item(s) in %s: %d can be applied, %d refused, %d listed only\n' \
    "${#PRUNE_ID[@]}" "$WT_PRUNE_ROOT" "${#applicable[@]}" "$refused" "$held"
  if [ ${#applicable[@]} -eq 0 ]; then
    printf '# nothing to apply\n'
    return 0
  fi
  printf '# applying them frees %d bytes by du (hardlinked files counted in full), plus any runtime allocation the teardown script releases\n' "$total"
  printf '# to apply: %s\n' "$(wt_prune_command_for "${applicable[@]}")"
}

wt_prune_refuse() {  # $1 = id, $2 = kind, $3 = path, $4 = reason
  printf 'refused\t%s\t%s\t%s\t-\t%s\n' "$1" "$2" "$(wt_prune_printable "$3")" "$(wt_prune_printable "$4")"
  wt_log "REFUSED $1${2:+ ($2 ${3})}: $4"
}

# Refuse every id in $2..., adding to the refusal count in WT_PRUNE_REFUSALS.
wt_prune_refuse_all() {  # $1 = reason, $@ = ids
  local reason=$1 id
  shift
  for id in "$@"; do
    wt_prune_refuse "$id" '' '' "$reason"
    WT_PRUNE_REFUSALS=$((WT_PRUNE_REFUSALS + 1))
  done
}

WT_PRUNE_REFUSALS=0

# Returns 0 when every id was applied, 1 when one was refused, 2 when the repository could not be
# surveyed once the lock was held. The summary line closes the output on every path.
wt_prune_apply() {  # $1 = main checkout, $@ = ids
  local root=$1 id i ordered=() requested=() seen applier before after freed applied=0 total=0 fd=8
  local status=0
  shift
  WT_PRUNE_REFUSALS=0
  for id in "$@"; do
    case " ${requested[*]-} " in *" $id "*) continue ;; esac
    requested[${#requested[@]}]=$id
  done

  # One sweep at a time: each judges its items against a discovery the other would be changing
  # under it. Discovery starts only once this is held, so no item is judged on a stale one.
  if ! WT_PRUNE_COMMON=$(wt_git_common_dir "$root") \
    || ! WT_PRUNE_COMMON=$(cd -P "$WT_PRUNE_COMMON" 2>/dev/null && pwd -P); then
    wt_prune_refuse_all "the shared git dir of $root cannot be found" "${requested[@]}"
    status=2
  elif command -v flock >/dev/null 2>&1; then
    if ! wt_lock_acquire "$WT_PRUNE_COMMON/worktree-locks/prune.lock" 5 "$fd"; then
      wt_prune_refuse_all 'another prune is applying in this repository, or its lock cannot be taken' \
        "${requested[@]}"
      status=1
    fi
  else
    wt_log "flock is not on PATH — not serialising against another prune of this repository"
  fi
  if [ "$status" = 0 ] && ! wt_prune_discover "$root"; then
    wt_log "cannot survey the worktrees of $root — nothing applied"
    wt_prune_refuse_all 'the repository cannot be surveyed' "${requested[@]}"
    status=2
  fi
  if [ "$status" != 0 ]; then
    wt_lock_release "$fd"
    printf '# 0 applied, %d refused, 0 bytes freed by du\n' "$WT_PRUNE_REFUSALS"
    return "$status"
  fi

  # Report order, so an item another waits on goes first.
  for i in ${PRUNE_ID[@]+"${!PRUNE_ID[@]}"}; do
    case " ${requested[*]} " in *" ${PRUNE_ID[i]} "*) ordered[${#ordered[@]}]=${PRUNE_ID[i]} ;; esac
  done
  for id in "${requested[@]}"; do
    case " ${ordered[*]-} " in *" $id "*) continue ;; esac
    wt_prune_refuse_all 'no such item now — it is gone or changed since the report; re-run the report' "$id"
  done

  # The discovery that ordered the ids is the first item's; every later one gets its own.
  seen=0
  for id in ${ordered[@]+"${ordered[@]}"}; do
    if [ "$seen" = 1 ] && ! wt_prune_discover "$root"; then
      wt_prune_refuse_all "the repository can no longer be surveyed" "$id"
      continue
    fi
    seen=1
    if ! i=$(wt_prune_find_item "$id"); then
      wt_prune_refuse_all 'no such item now — it is gone or changed since the report; re-run the report' "$id"
      continue
    fi
    case ${PRUNE_ACTION[i]} in
      refuse | none)
        wt_prune_refuse "$id" "${PRUNE_KIND[i]}" "${PRUNE_PATH[i]}" "${PRUNE_REASON[i]}"
        WT_PRUNE_REFUSALS=$((WT_PRUNE_REFUSALS + 1))
        continue
        ;;
    esac
    applier=wt_apply_${PRUNE_KIND[i]//-/_}
    if ! declare -F "$applier" >/dev/null; then
      wt_prune_refuse "$id" "${PRUNE_KIND[i]}" "${PRUNE_PATH[i]}" 'nothing knows how to apply this kind'
      WT_PRUNE_REFUSALS=$((WT_PRUNE_REFUSALS + 1))
      continue
    fi
    before=0
    [ -n "${PRUNE_MEASURE[i]}" ] && before=$(wt_prune_bytes "${PRUNE_MEASURE[i]}")
    WT_PRUNE_DETAIL=''
    if "$applier" "$i"; then
      after=0
      [ -n "${PRUNE_MEASURE[i]}" ] && after=$(wt_prune_bytes "${PRUNE_MEASURE[i]}")
      freed=$((before - after))
      [ -n "${PRUNE_MEASURE[i]}" ] || freed=-
      [ "$freed" = - ] || total=$((total + freed))
      printf 'applied\t%s\t%s\t%s\t%s\t%s\n' "$id" "${PRUNE_KIND[i]}" \
        "$(wt_prune_printable "${PRUNE_PATH[i]}")" "$freed" "$(wt_prune_printable "$WT_PRUNE_DETAIL")"
      applied=$((applied + 1))
    else
      wt_prune_refuse "$id" "${PRUNE_KIND[i]}" "${PRUNE_PATH[i]}" "$WT_PRUNE_DETAIL"
      WT_PRUNE_REFUSALS=$((WT_PRUNE_REFUSALS + 1))
    fi
  done
  wt_lock_release "$fd"
  printf '# %d applied, %d refused, %d bytes freed by du\n' "$applied" "$WT_PRUNE_REFUSALS" "$total"
  [ "$WT_PRUNE_REFUSALS" -eq 0 ]
}

wt_prune_usage() {
  printf 'usage: prune.sh [--repo <dir>] [--apply <id>...]\n' >&2
}

repo=$PWD
mode=report
ids=()
while [ $# -gt 0 ]; do
  case $1 in
    --repo)
      [ $# -ge 2 ] || { wt_prune_usage; exit 2; }
      repo=$2
      shift 2
      ;;
    --apply)
      mode=apply
      shift
      while [ $# -gt 0 ]; do
        case $1 in --*) break ;; esac
        ids[${#ids[@]}]=$1
        shift
      done
      ;;
    -h | --help) wt_prune_usage; exit 0 ;;
    *) wt_prune_usage; exit 2 ;;
  esac
done

if ! root=$(wt_main_root "$repo") || [ -z "$root" ]; then
  wt_log "$repo is not inside a git checkout whose main checkout can be found — nothing to sweep"
  exit 2
fi
root=$(cd -P "$root" 2>/dev/null && pwd -P) || exit 2

if [ "$mode" = apply ]; then
  if [ ${#ids[@]} -eq 0 ]; then
    wt_prune_usage
    exit 2
  fi
  wt_prune_apply "$root" "${ids[@]}"
  exit $?
fi
if ! wt_prune_discover "$root"; then
  wt_log "cannot survey the worktrees of $root — nothing reported"
  exit 2
fi
wt_prune_report
exit 0
