#!/usr/bin/env bash
# shellcheck shell=bash
# SC2034: the WT_RM_* globals are this file's RESULTS, read by the script that sources it, where
# the linter cannot see them used.
# shellcheck disable=SC2034
#
# The teardown DECISIONS. Sourced by teardown.sh and the prune sweep, after lib.sh and
# bootstrap-lib.sh, by nothing else.
#
# Two questions every destructive path must answer before it touches anything, answered once here
# so the hook and the sweep cannot come to different conclusions about the same directory:
#
#   wt_resolve_removal_target   WHICH worktree a removal names, and whether it is ours to act on.
#   wt_worktree_holds_work      whether removing it would lose anything the user made.
#
# THE ASYMMETRY IS THE DESIGN (docs/phases/phase-5-teardown.md). Creating the wrong thing wastes
# disk; deleting the wrong thing destroys work. So both functions fail CLOSED: a path that cannot be
# proven to be a registered linked worktree is refused, and a worktree whose state git cannot report
# is treated as holding work. A refusal costs the user a stale directory; a wrong answer costs them
# a branch.
#
# Everything here inherits lib.sh's three rules (docs/01-decisions.md):
#   1. No model, no network, no prompting (ADR-002).
#   2. NOTHING here calls `exit`. Functions return a code; the entrypoint decides what to skip.
#   3. stdout is a protocol. Every message goes to stderr via wt_log(); the only stdout is
#      wt_worktree_holds_work's reasons, which are its documented result.
#
# Same portability floor as lib.sh: bash 3.2, git 2.7, POSIX tools, no jq dependency.

[ -n "${WT_TEARDOWN_LIB_SOURCED:-}" ] && return 0
WT_TEARDOWN_LIB_SOURCED=1

# The state file, the ledger readers and the profile chooser all live in the bootstrap engine, and
# teardown must read them exactly as bootstrap wrote them. bootstrap-lib.sh sources lib.sh itself.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=bootstrap-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bootstrap-lib.sh"

# ---------------------------------------------------------------------------
# Which worktree a removal names
# ---------------------------------------------------------------------------
#
# THE PAYLOAD IS NOT MEASURED. The platform documents `worktree_path` (absolute) on WorktreeRemove,
# the source conversation's scripts read `path`, and the documented example points INTO
# `<repo>/.git/worktrees/<id>` — the admin directory, not the checkout. All three shapes are
# accepted, and each is proven against git before it is believed.
#
# THE DIRECTORY MAY ALREADY BE GONE. A launch-time `claude -w` worktree is created natively, and
# there is no evidence either way on whether native removal runs before or after this hook. So a
# missing directory is a normal input: the runtime ledger (bootstrap-lib.sh) outlives the worktree
# and is the only proof left that the path was ever ours.
#
# PATHS ARE COMPARED PHYSICALLY. git records a worktree by its real path, and every path this
# plugin wrote to the ledger came from `pwd -P` or `--show-toplevel`. A symlinked ANCESTOR is
# resolved rather than refused: it is ordinary on real machines (a symlinked home, macOS's
# /var -> /private/var), and refusing it would make teardown a no-op there. A symlink AT THE LEAF is
# refused: Claude Code refuses to create a worktree whose directory is a symlink (bootstrap.sh's
# wt_symlink_refuses copies that rule), so no worktree it removes is named by one, and a payload
# that is one would be steering a destructive operation at whatever the link points to.

# Results of wt_resolve_removal_target. Every one is reset on entry, so a refusal never leaves a
# previous call's target in place for a careless caller to act on.
#   WT_RM_WORKTREE      the worktree, as an absolute physical path. May no longer exist.
#   WT_RM_ROOT          its main checkout.
#   WT_RM_ADMIN         its git admin dir, `<common>/worktrees/<id>` — where its state file is —
#                       or empty when git has already deleted it.
#   WT_RM_LEDGER_ENTRY  the name of its runtime ledger entry (wt_ledger_field takes it), or empty.
#   WT_RM_PRESENT       1 if the worktree directory exists, 0 if only its ledger entry is left.
WT_RM_WORKTREE='' WT_RM_ROOT='' WT_RM_ADMIN='' WT_RM_LEDGER_ENTRY='' WT_RM_PRESENT=0

# $1 with every symlink resolved in the part of it that exists; the part that does not is appended
# as given. Prints nothing and returns 1 when not even `/` can be entered.
wt_physical_path() {  # $1 = absolute path
  local existing=${1%/} missing=''
  while [ -n "$existing" ] && [ ! -d "$existing" ]; do
    missing=/${existing##*/}$missing
    existing=${existing%/*}
  done
  existing=$(cd -P "${existing:-/}" 2>/dev/null && pwd -P) || return 1
  printf '%s%s' "${existing%/}" "$missing"
}

# The path a git pointer file names, anchored at $2 when it is relative. `.git` files carry a
# `gitdir: ` prefix; an admin dir's `gitdir` and `commondir` files do not. Relative pointers are
# what `worktree.useRelativePaths` (git 2.48+) writes, relative to the directory holding the file.
wt_read_git_pointer() {  # $1 = pointer file, $2 = directory it is relative to
  local target
  [ -f "$1" ] && [ -r "$1" ] || return 1
  IFS= read -r target <"$1" || [ -n "$target" ] || return 1
  target=${target#gitdir: }
  [ -n "$target" ] || return 1
  case $target in
    /*) ;;
    *) target=${2%/}/$target ;;
  esac
  printf '%s' "$(wt_collapse_dotdot "$target")"
}

# The ledger entry recording the worktree at $2, or the admin id $3, in the repository of $1.
# Several can match: an entry is set aside as `<id>.<when>` rather than overwritten (see
# wt_ledger_write), so one path can own the live entry and older ones. The live entry is the one
# still named after its own admin id; failing that, the most recent. Returns 1 when none match.
wt_ledger_entry_for() {  # $1 = main checkout, $2 = worktree path or empty, $3 = admin id or empty
  local want_path=${2-} want_admin=${3-} entry path admin rest when best='' best_when=-1
  while IFS=$WT_US read -r -d "$WT_RS" entry path admin rest; do
    [ -z "$want_path" ] || [ "$path" = "$want_path" ] || continue
    [ -z "$want_admin" ] || [ "$admin" = "$want_admin" ] || continue
    if [ "$entry" = "$admin" ]; then
      best=$entry
      break
    fi
    when=${rest##*"$WT_US"}
    case $when in '' | *[!0-9]*) when=0 ;; esac
    if [ "$when" -gt "$best_when" ]; then
      best=$entry
      best_when=$when
    fi
  done < <(wt_ledger_entries "$1" 2>/dev/null)
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# Accept $1 as a LIVE linked worktree, or refuse it. $2, when given, is the admin dir the caller
# reached it through, which must be the one the worktree itself points at.
#
# The main checkout is read off the worktree's own `.git` file -> admin dir -> `commondir`, not
# asked of git from inside the worktree: when the main checkout has been moved, git from inside
# only says "not a git repository", and the file chain is what can say WHICH checkout vanished.
# That case is refused outright — the worktree's state, ledger and branch all live under a main
# checkout this hook can no longer find, so any action would be on a guess.
wt_rm_accept_live() {  # $1 = physical worktree path, $2 = expected admin dir or empty
  local wt=$1 expect=${2-} pointer admin common root listed line found=0 first=1

  if [ -d "$wt/.git" ]; then
    wt_log "refusing to tear down $wt: it is a main checkout, not a linked worktree"
    return 1
  fi
  if [ -f "$wt/HEAD" ] && [ -d "$wt/refs" ]; then
    wt_log "refusing to tear down $wt: it is a git directory, not a worktree"
    return 1
  fi
  if ! pointer=$(wt_read_git_pointer "$wt/.git" "$wt"); then
    wt_log "refusing to tear down $wt: it is not a git worktree (no readable .git file)"
    return 1
  fi
  if [ ! -d "$pointer" ]; then
    case $pointer in
      */.git/worktrees/*)
        wt_log "refusing to tear down $wt: its main checkout ${pointer%/.git/worktrees/*} no longer exists — it was moved or renamed. Run \`git worktree repair\` from its new location; doing nothing"
        ;;
      *)
        wt_log "refusing to tear down $wt: the git admin dir it points at ($pointer) no longer exists; doing nothing"
        ;;
    esac
    return 1
  fi
  admin=$(cd -P "$pointer" 2>/dev/null && pwd -P) || admin=''
  if [ -z "$admin" ] || { [ -n "$expect" ] && [ "$admin" != "$expect" ]; }; then
    wt_log "refusing to tear down $wt: its .git file and the admin dir ${expect:-$pointer} do not point at each other"
    return 1
  fi
  if ! pointer=$(wt_read_git_pointer "$admin/commondir" "$admin") \
    || ! common=$(cd -P "$pointer" 2>/dev/null && pwd -P); then
    wt_log "refusing to tear down $wt: it is not a linked worktree (its git dir $admin has no usable commondir — a submodule, or damaged)"
    return 1
  fi
  # The same rule wt_main_root applies: only `<root>/.git` says where the main checkout is. A
  # --separate-git-dir repository does not record it, and a guess here would be a guess at what to
  # delete.
  case $common in
    */.git) root=${common%/.git} ;;
    *)
      wt_log "refusing to tear down $wt: its shared git dir is $common, not <root>/.git, so its main checkout cannot be located"
      return 1
      ;;
  esac
  if [ ! -d "$root" ] || [ "$root" = "$wt" ]; then
    wt_log "refusing to tear down $wt: its main checkout $root no longer exists; doing nothing"
    return 1
  fi

  # REGISTRATION IS THE PROOF. A copied directory carries a valid-looking .git file naming a real
  # admin dir; only git's own list says which checkout that admin dir belongs to. The first entry
  # is the main checkout and is never a candidate.
  if ! listed=$(wt_git "$root" worktree list --porcelain 2>/dev/null); then
    wt_log "refusing to tear down $wt: could not list the worktrees of $root"
    return 1
  fi
  while IFS= read -r line; do
    case $line in
      'worktree '*) ;;
      *) continue ;;
    esac
    if [ "$first" = 1 ]; then
      first=0
      continue
    fi
    line=${line#worktree }
    [ -d "$line" ] && line=$(cd -P "$line" 2>/dev/null && pwd -P)
    if [ "$line" = "$wt" ]; then
      found=1
      break
    fi
  done <<<"$listed"
  if [ "$found" != 1 ]; then
    wt_log "refusing to tear down $wt: it is not a registered worktree of $root"
    return 1
  fi

  WT_RM_WORKTREE=$wt
  WT_RM_ROOT=$root
  WT_RM_ADMIN=$admin
  WT_RM_PRESENT=1
  WT_RM_LEDGER_ENTRY=$(wt_ledger_entry_for "$root" "$wt" '') || WT_RM_LEDGER_ENTRY=''
  return 0
}

# Accept $1, whose directory is gone, as a worktree the ledger recorded. $2, $3 are candidate
# directories to find its repository from — the payload's cwd first, then the prefix before
# `.claude/worktrees/` of the path itself, mirroring how bootstrap names a worktree by that same
# split. Neither is trusted to be right: only an entry recording this exact path is proof.
#
# Returns 2, not 1, when no entry records it: nothing was refused, there is just nothing of ours.
wt_rm_accept_gone() {  # $1 = physical worktree path, $@ = candidate directories
  local wt=$1 dir root entry id common pointer
  shift
  for dir in "$@"; do
    [ -n "$dir" ] && [ -d "$dir" ] || continue
    root=$(wt_main_root "$dir" 2>/dev/null) || continue
    entry=$(wt_ledger_entry_for "$root" "$wt" '') || continue
    WT_RM_WORKTREE=$wt
    WT_RM_ROOT=$root
    WT_RM_LEDGER_ENTRY=$entry
    WT_RM_PRESENT=0
    # The admin dir survives a checkout deleted by hand until `git worktree prune`, and its state
    # file with it. Kept only while its gitdir still points at this path: a reused id is another
    # worktree's.
    id=$(wt_ledger_field "$root" "$entry" admin 2>/dev/null) || id=''
    common=$(wt_git_common_dir "$root") || common=''
    if [ -n "$id" ] && [ -n "$common" ] && [ -d "$common/worktrees/$id" ] \
      && pointer=$(wt_read_git_pointer "$common/worktrees/$id/gitdir" "$common/worktrees/$id") \
      && [ "$(wt_physical_path "$pointer")" = "$wt/.git" ]; then
      WT_RM_ADMIN=$(cd -P "$common/worktrees/$id" 2>/dev/null && pwd -P) || WT_RM_ADMIN=''
    fi
    return 0
  done
  wt_log "$wt is already gone and no ledger entry records it — nothing of this plugin's to tear down"
  return 2
}

# Resolve the worktree a WorktreeRemove payload names into the WT_RM_* globals above.
#
# The payload is the JSON text bootstrap.sh already reads into HOOK_INPUT (wt_read_input), so this
# takes it the way wt_read_field does: as $1, defaulting to HOOK_INPUT. stdin is drained once, by
# the entrypoint.
#
#   0  resolved; WT_RM_* describe it
#   1  refused, with the reason on stderr; WT_RM_* are empty
#   2  the directory is gone and nothing of ours records it; WT_RM_* are empty
wt_resolve_removal_target() {  # $1 = payload JSON (default: $HOOK_INPUT)
  local json=${1-${HOOK_INPUT-}} fields named given cwd target physical home pointer admin
  local id gitroot root entry recorded

  WT_RM_WORKTREE='' WT_RM_ROOT='' WT_RM_ADMIN='' WT_RM_LEDGER_ENTRY='' WT_RM_PRESENT=0

  fields=''
  if [ -n "$json" ] && wt_has_json; then
    fields=$(printf '%s' "$json" | wt_json_get worktree_path path cwd 2>/dev/null) || fields=''
  fi
  IFS=$WT_US read -r named given cwd <<<"$fields"
  target=${named:-$given}

  if [ -z "$target" ]; then
    wt_log "the removal payload names no worktree (no worktree_path or path) — doing nothing"
    return 1
  fi
  case $target in
    /*) ;;
    *)
      wt_log "refusing to tear down \"$target\": not an absolute path"
      return 1
      ;;
  esac
  case $target/ in
    */./* | */../*)
      wt_log "refusing to tear down \"$target\": it has . or .. segments, so what it names is a guess"
      return 1
      ;;
  esac
  while [ "$target" != / ] && [ "${target%/}" != "$target" ]; do
    target=${target%/}
  done
  if [ "$target" = / ]; then
    wt_log "refusing to tear down /"
    return 1
  fi
  if [ -L "$target" ]; then
    wt_log "refusing to tear down $target: it is a symlink, and no worktree Claude Code creates is one"
    return 1
  fi
  if ! physical=$(wt_physical_path "$target"); then
    wt_log "refusing to tear down $target: cannot resolve its physical path"
    return 1
  fi
  home=''
  [ -n "${HOME-}" ] && home=$(cd -P "$HOME" 2>/dev/null && pwd -P)
  if [ "$physical" = / ] || { [ -n "$home" ] && [ "$physical" = "$home" ]; }; then
    wt_log "refusing to tear down $target: it is / or the home directory"
    return 1
  fi

  if [ -e "$physical" ]; then
    if [ ! -d "$physical" ]; then
      wt_log "refusing to tear down $target: not a directory"
      return 1
    fi
    # An admin dir `<common>/worktrees/<id>`: git keeps a `gitdir` pointer to the checkout's .git
    # file there, and a `commondir` that no checkout has.
    if [ -f "$physical/gitdir" ] && [ -f "$physical/commondir" ]; then
      admin=$physical
      if ! pointer=$(wt_read_git_pointer "$admin/gitdir" "$admin"); then
        wt_log "refusing to tear down $target: its gitdir file is unreadable"
        return 1
      fi
      case $pointer in
        */.git) ;;
        *)
          wt_log "refusing to tear down $target: its gitdir file ($pointer) does not name a worktree's .git"
          return 1
          ;;
      esac
      physical=$(wt_physical_path "${pointer%/.git}") || physical=''
      if [ -z "$physical" ] || [ -L "${pointer%/.git}" ]; then
        wt_log "refusing to tear down $target: the worktree it names (${pointer%/.git}) cannot be resolved"
        return 1
      fi
      if [ -d "$physical" ]; then
        wt_rm_accept_live "$physical" "$admin"
        return
      fi
      gitroot=${admin%/worktrees/*}
      wt_rm_accept_gone "$physical" "$cwd" "${gitroot%/.git}"
      return
    fi
    wt_rm_accept_live "$physical" ''
    return
  fi

  # Gone, and named by its admin dir: git pruned that too, so only the id in the path is left to
  # find the ledger entry by. `<G>/worktrees/<id>` counts only when G is a git directory.
  case $physical in
    */worktrees/*)
      id=${physical##*/}
      gitroot=${physical%/*}
      gitroot=${gitroot%/worktrees}
      if [ "$gitroot/worktrees/$id" = "$physical" ] && [ -f "$gitroot/HEAD" ] && [ -d "$gitroot/refs" ]; then
        case $gitroot in
          */.git) root=${gitroot%/.git} ;;
          *)
            wt_log "refusing to tear down $target: $gitroot is not <root>/.git, so its main checkout cannot be located"
            return 1
            ;;
        esac
        if ! entry=$(wt_ledger_entry_for "$root" '' "$id"); then
          wt_log "$target is already gone and no ledger entry records it — nothing of this plugin's to tear down"
          return 2
        fi
        recorded=$(wt_ledger_field "$root" "$entry" path 2>/dev/null) || recorded=''
        if [ -z "$recorded" ] || [ -e "$recorded" ]; then
          wt_log "refusing to tear down $target: its ledger entry names ${recorded:-no path}, which is not gone, so the id may belong to another worktree now"
          return 1
        fi
        WT_RM_WORKTREE=$recorded
        WT_RM_ROOT=$root
        WT_RM_LEDGER_ENTRY=$entry
        WT_RM_PRESENT=0
        return 0
      fi
      ;;
  esac

  case $physical in
    *"$WT_SUBPATH"*) gitroot=${physical%"$WT_SUBPATH"*} ;;
    *) gitroot='' ;;
  esac
  wt_rm_accept_gone "$physical" "$cwd" "$gitroot"
}

# ---------------------------------------------------------------------------
# Whether a worktree holds work
# ---------------------------------------------------------------------------
#
# A PREDICATE, and it reads as one: `if wt_worktree_holds_work "$wt"; then refuse`. Returns 0 when
# the worktree HOLDS work, printing one human-readable reason per line on stdout, and 1 when it is
# provably clean. There is no third answer: anything git cannot report is a reason, prefixed
# `could not verify: `, because "unknown" treated as "clean" is how work gets deleted.
#
# WORK IS what `git worktree remove --force` would lose: changes to tracked files, staged or not;
# untracked files that are not ignored; dirty submodules; a merge, rebase, cherry-pick, revert or
# bisect half done; a `git worktree lock`, which is someone saying "not this one"; and commits that
# nothing else keeps — no OTHER local branch and no remote-tracking ref contains them. A detached
# HEAD is the sharp case: its commits have no branch at all, so removal orphans them.
#
# GITIGNORED FILES ARE NEVER WORK. vendor/, node_modules/ and the env override file are what the
# bootstrap put there, and the override is only ever written when it is gitignored
# (wt_runtime_env_write) — so it cannot make its own worktree look busy.
#
# The status flags are explicit so the repository's config cannot talk the guard round:
# status.showUntrackedFiles=no would hide untracked files, and submodule.<name>.ignore=all a dirty
# submodule. GIT_OPTIONAL_LOCKS=0 keeps the index refresh from writing: a read-only question must
# not race a session still using the worktree.
wt_worktree_holds_work() {  # $1 = worktree
  local wt=${1%/} gitdir status line code path holds=0 marker why tip branch count
  local staged=0 modified=0 untracked=0 first_staged='' first_modified='' first_untracked=''
  local exclude=()

  if ! gitdir=$(wt_git "$wt" rev-parse --git-dir 2>/dev/null) || [ -z "$gitdir" ]; then
    printf 'could not verify: git cannot read %s as a worktree\n' "$wt"
    return 0
  fi
  case $gitdir in
    /*) ;;
    *) gitdir=$wt/$gitdir ;;
  esac

  if status=$(GIT_OPTIONAL_LOCKS=0 wt_git "$wt" status --porcelain \
    --untracked-files=normal --ignore-submodules=none 2>/dev/null); then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      code=${line:0:2}
      path=${line:3}
      if [ "$code" = '??' ]; then
        untracked=$((untracked + 1))
        [ -n "$first_untracked" ] || first_untracked=$path
        continue
      fi
      if [ "${code:0:1}" != ' ' ]; then
        staged=$((staged + 1))
        [ -n "$first_staged" ] || first_staged=$path
      fi
      if [ "${code:1:1}" != ' ' ]; then
        modified=$((modified + 1))
        [ -n "$first_modified" ] || first_modified=$path
      fi
    done <<<"$status"
  else
    printf 'could not verify: git status failed in %s\n' "$wt"
    holds=1
  fi
  if [ "$staged" -gt 0 ]; then
    printf 'staged changes: %d (first: %s)\n' "$staged" "$first_staged"
    holds=1
  fi
  if [ "$modified" -gt 0 ]; then
    printf 'modified tracked files or submodules: %d (first: %s)\n' "$modified" "$first_modified"
    holds=1
  fi
  if [ "$untracked" -gt 0 ]; then
    printf 'untracked files: %d (first: %s)\n' "$untracked" "$first_untracked"
    holds=1
  fi

  for marker in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase \
    CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect; do
    if [ -e "$gitdir/${marker%%:*}" ]; then
      printf '%s in progress\n' "${marker#*:}"
      holds=1
    fi
  done

  if [ -e "$gitdir/locked" ]; then
    why=''
    IFS= read -r why <"$gitdir/locked" 2>/dev/null || true
    # shellcheck disable=SC2016  # the backticks are literal text
    printf 'locked with `git worktree lock`%s\n' "${why:+: $why}"
    holds=1
  fi

  if ! tip=$(wt_git "$wt" rev-parse --verify -q HEAD 2>/dev/null) || [ -z "$tip" ]; then
    printf 'could not verify: HEAD in %s does not name a commit\n' "$wt"
    return 0
  fi
  branch=$(wt_git "$wt" symbolic-ref -q HEAD 2>/dev/null)
  case $? in
    0) branch=${branch#refs/heads/}; exclude=("--exclude=$branch") ;;
    1) branch='' ;;
    *)
      printf 'could not verify: cannot tell which branch %s is on\n' "$wt"
      return 0
      ;;
  esac
  # --exclude applies to the --branches after it, and takes the name without refs/heads/.
  if ! count=$(wt_git "$wt" rev-list --count "$tip" --not ${exclude[@]+"${exclude[@]}"} \
    --branches --remotes 2>/dev/null) || [ -z "$count" ]; then
    printf 'could not verify: cannot list the commits only %s has\n' "$wt"
    return 0
  fi
  if [ "$count" -gt 0 ]; then
    if [ -n "$branch" ]; then
      printf '%d commit(s) on %s that no other branch and no remote-tracking ref contains\n' \
        "$count" "$branch"
    else
      printf '%d commit(s) on a detached HEAD that no branch and no remote-tracking ref contains\n' \
        "$count"
    fi
    holds=1
  fi
  [ "$holds" = 1 ]
}
