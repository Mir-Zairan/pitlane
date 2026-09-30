#!/usr/bin/env bash
# shellcheck shell=bash
# SC2034: the WT_RM_* and WT_TD_* globals are this file's RESULTS, read by the script that sources
# it, where the linter cannot see them used.
# shellcheck disable=SC2034
#
# The teardown DECISIONS, and the teardown STEPS that act on them. Sourced by teardown.sh and the
# prune sweep, after lib.sh and bootstrap-lib.sh, by nothing else.
#
# Two questions every destructive path must answer before it touches anything, answered once here
# so the hook and the sweep cannot come to different conclusions about the same directory:
#
#   wt_resolve_worktree_path    WHICH worktree a path names, and whether it is ours to act on.
#   wt_resolve_removal_target   the same, for the path a WorktreeRemove payload names.
#   wt_worktree_holds_work      whether removing it would lose anything the user made.
#
# The prune sweep calls wt_resolve_worktree_path once per candidate — a ledger entry's recorded path
# or a `git worktree list` path, with the main checkout as the hint — then wt_worktree_holds_work on
# each one it resolved as present. Every call starts from empty results, so a loop cannot act on a
# previous candidate's target after a refusal. What to do with a worktree that may go is the second
# half of this file ("Tearing down what was allocated"), which both callers run in the same order.
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

# Results of wt_resolve_worktree_path and wt_resolve_removal_target. Every one is reset on entry, so a refusal never leaves a
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
  # git lists a worktree off its admin dir's gitdir file, so a .git file naming ANOTHER worktree's
  # admin dir would pass registration and then be torn down against that worktree's state.
  if ! pointer=$(wt_read_git_pointer "$admin/gitdir" "$admin") \
    || [ "$(wt_physical_path "$pointer")" != "$wt/.git" ]; then
    wt_log "refusing to tear down $wt: its .git file and the admin dir $admin do not point at each other"
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

# True if $1 is a linked worktree's admin dir, `<git dir>/worktrees/<id>`: holding `gitdir` and
# `commondir` files is not enough, since any committed directory can, and its pointers would then
# steer resolution at whatever they name. The directory must sit directly under the `worktrees/`
# of a real git dir, have no `.git` of its own, and name that git dir as its commondir.
wt_rm_is_admin_dir() {  # $1 = physical directory
  local dir=$1 gitroot pointer common
  [ ! -e "$dir/.git" ] || return 1
  gitroot=${dir%/*}
  [ "${gitroot##*/}" = worktrees ] || return 1
  gitroot=${gitroot%/worktrees}
  [ -n "$gitroot" ] && [ -f "$gitroot/HEAD" ] && [ -d "$gitroot/refs" ] && [ -d "$gitroot/objects" ] \
    || return 1
  pointer=$(wt_read_git_pointer "$dir/commondir" "$dir") || return 1
  common=$(cd -P "$pointer" 2>/dev/null && pwd -P) || return 1
  [ "$common" = "$gitroot" ]
}

# Resolve the worktree an absolute path names into the WT_RM_* globals above. The path may be the
# checkout or its admin dir, and either may already be gone. $2, when given, is a directory inside
# the repository, tried first when only a ledger entry is left to find it by — the payload's cwd,
# or the main checkout for a caller sweeping one repository.
#
#   0  resolved; WT_RM_* describe it
#   1  refused, with the reason on stderr; WT_RM_* are empty
#   2  the directory is gone and nothing of ours records it; WT_RM_* are empty
wt_resolve_worktree_path() {  # $1 = absolute path, $2 = directory inside its repository, or empty
  local target=${1-} hint=${2-} physical home admin pointer id gitroot root entry recorded

  WT_RM_WORKTREE='' WT_RM_ROOT='' WT_RM_ADMIN='' WT_RM_LEDGER_ENTRY='' WT_RM_PRESENT=0

  if [ -z "$target" ]; then
    wt_log "the removal names no worktree — doing nothing"
    return 1
  fi
  # No worktree Claude Code creates has one, and every reader of this plugin's records folds or
  # strips them, so a path carrying one could only ever match the wrong record.
  case $target in
    *[[:cntrl:]]*)
      wt_log "refusing to tear down \"$target\": it contains a control character"
      return 1
      ;;
  esac
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
    wt_log "refusing to tear down /: it is / or the home directory"
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
  if [ -z "$physical" ] || [ "$physical" = / ] || { [ -n "$home" ] && [ "$physical" = "$home" ]; }; then
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
      if ! wt_rm_is_admin_dir "$admin"; then
        wt_log "refusing to tear down $target: it holds gitdir and commondir files but is not a linked worktree admin dir (<git dir>/worktrees/<id>)"
        return 1
      fi
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
      wt_rm_accept_gone "$physical" "$hint" "${gitroot%/.git}"
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
  wt_rm_accept_gone "$physical" "$hint" "$gitroot"
}

# Resolve the worktree a WorktreeRemove payload names, exactly as wt_resolve_worktree_path does,
# with the payload's cwd as the repository hint. Same return codes.
#
# The payload is the JSON text bootstrap.sh already reads into HOOK_INPUT (wt_read_input), so this
# takes it the way wt_read_field does: as $1, defaulting to HOOK_INPUT. stdin is drained once, by
# the entrypoint.
#
# AN ENCODED CONTROL CHARACTER ANYWHERE IN THE PAYLOAD IS REFUSED, not just in the fields read. The
# JSON readers fold CR and LF to a space and strip US and RS (see WT_RS in lib.sh), so a path
# encoding one arrives here as a DIFFERENT path — possibly a real worktree's — and no test after
# extraction can tell. JSON forbids the raw bytes inside a string, so the escapes are all there is
# to find; `\\` pairs are dropped first so an escaped backslash before an `n` is not one.
wt_resolve_removal_target() {  # $1 = payload JSON (default: $HOOK_INPUT)
  local json=${1-${HOOK_INPUT-}} fields named given cwd target escaped_backslash="\\\\" unescaped

  WT_RM_WORKTREE='' WT_RM_ROOT='' WT_RM_ADMIN='' WT_RM_LEDGER_ENTRY='' WT_RM_PRESENT=0

  unescaped=${json//"$escaped_backslash"/}
  case $unescaped in
    *'\n'* | *'\r'* | *'\t'* | *'\b'* | *'\f'* | *'\u00'[01]*)
      wt_log "refusing the removal payload: it encodes a control character, which the JSON reader would fold away, so the path it names is a guess — doing nothing"
      return 1
      ;;
  esac

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
  wt_resolve_worktree_path "$target" "$cwd"
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
# bisect half done; a `git worktree lock`, which is someone saying "not this one"; another
# registered worktree nested inside it; commits that nothing else keeps — no OTHER local branch and
# no remote-tracking ref contains them; and the same for any initialized submodule, whose refs die
# with the admin dir. A detached HEAD is the sharp case: its commits have no branch at all, so
# removal orphans them.
#
# THE ANSWER MUST BE ABOUT $1 ITSELF. git walks up from a directory it cannot read as a checkout,
# so $1 must be what git reports as its own top level, with a git dir that is a linked worktree's
# admin dir pointing back at it. Anything else is "could not verify".
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
  local wt=${1%/} resolved top gitdir common pointer status line code path holds=0 marker why
  local tip branch count rc listed
  local staged=0 modified=0 untracked=0 first_staged='' first_modified='' first_untracked=''
  local exclude=()

  if ! wt=$(cd -P "$wt" 2>/dev/null && pwd -P) \
    || ! resolved=$(wt_git "$wt" rev-parse --show-toplevel --git-dir --git-common-dir 2>/dev/null); then
    printf 'could not verify: git cannot read %s as a worktree\n' "${1%/}"
    return 0
  fi
  { IFS= read -r top; IFS= read -r gitdir; IFS= read -r common; } <<<"$resolved"
  # git walks UP from a directory it cannot read as a checkout: with the .git file gone, or from a
  # subdirectory, every answer below would be about some other checkout — typically the main one,
  # which ignores .claude/worktrees/ and so reads clean.
  top=$(cd -P "$top" 2>/dev/null && pwd -P) || top=''
  if [ "$top" != "$wt" ]; then
    printf 'could not verify: git resolves %s to the checkout %s, not to itself\n' "$wt" "${top:-(none)}"
    return 0
  fi
  case $gitdir in /*) ;; *) gitdir=$wt/$gitdir ;; esac
  case $common in /*) ;; *) common=$wt/$common ;; esac
  gitdir=$(cd -P "$gitdir" 2>/dev/null && pwd -P) || gitdir=''
  common=$(cd -P "$common" 2>/dev/null && pwd -P) || common=''
  if [ -z "$gitdir" ] || [ -z "$common" ] || [ "${gitdir%/*}" != "$common/worktrees" ]; then
    printf 'could not verify: %s is not a linked worktree (its git dir is %s)\n' "$wt" "${gitdir:-unknown}"
    return 0
  fi
  if ! pointer=$(wt_read_git_pointer "$gitdir/gitdir" "$gitdir") \
    || [ "$(wt_physical_path "$pointer")" != "$wt/.git" ]; then
    printf 'could not verify: the admin dir %s does not point back at %s\n' "$gitdir" "$wt"
    return 0
  fi

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

  # Another worktree inside this one goes with it, and a repository that ignores
  # .claude/worktrees/ hides it from status.
  if listed=$(wt_git "$wt" worktree list --porcelain 2>/dev/null); then
    while IFS= read -r line; do
      case $line in
        'worktree '*) line=${line#worktree } ;;
        *) continue ;;
      esac
      [ -d "$line" ] || continue
      line=$(cd -P "$line" 2>/dev/null && pwd -P) || line=''
      case $line in
        "$wt"/*)
          printf 'a registered worktree is nested inside it: %s\n' "$line"
          holds=1
          ;;
      esac
    done <<<"$listed"
  else
    printf 'could not verify: cannot list the worktrees registered alongside %s\n' "$wt"
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

  wt_submodules_hold_commits "$wt" '' && holds=1

  if ! tip=$(wt_git "$wt" rev-parse --verify -q HEAD 2>/dev/null) || [ -z "$tip" ]; then
    printf 'could not verify: HEAD in %s does not name a commit\n' "$wt"
    return 0
  fi
  # rc captured this way so a detached HEAD (1) does not abort a `set -e` caller.
  branch=$(wt_git "$wt" symbolic-ref -q HEAD 2>/dev/null) && rc=0 || rc=$?
  case $rc in
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

# Print a reason for every initialized submodule under $1, at any depth, holding commits that no
# remote-tracking ref of its own contains, and return 0 if there was one. A linked worktree's
# submodules keep their git dirs under ITS admin dir (`<admin>/modules/<name>`), so removing the
# worktree deletes every ref in them — branches, tags and stash alike, hence `--all`. Their dirty
# files are already the superproject status's to report. Anything git cannot answer is a reason.
#
# ls-files ends with a sentinel record, which has no tab where every real record has one, so a
# listing cut short by a failure is told apart from a complete one.
wt_submodules_hold_commits() {  # $1 = checkout, $2 = its path under the worktree, `/`-terminated, or empty
  local dir=$1 prefix=${2-} rec path sub top count rc=1 complete=0 tab=$'\t'
  while IFS= read -r -d '' rec; do
    case $rec in
      "$tab"end) complete=1; continue ;;
      160000' '*"$tab"*) path=${rec#*"$tab"} ;;
      *) continue ;;
    esac
    sub=$dir/$path
    [ -e "$sub/.git" ] || continue
    top=$(wt_git "$sub" rev-parse --show-toplevel 2>/dev/null) && top=$(cd -P "$top" 2>/dev/null && pwd -P) \
      || top=''
    if [ -z "$top" ] || [ "$top" != "$(cd -P "$sub" 2>/dev/null && pwd -P)" ]; then
      printf 'could not verify: submodule %s%s is not a repository git can read\n' "$prefix" "$path"
      rc=0
      continue
    fi
    if ! count=$(wt_git "$sub" rev-list --count --all --not --remotes 2>/dev/null) || [ -z "$count" ]; then
      printf 'could not verify: submodule %s%s: cannot list the commits only it has\n' "$prefix" "$path"
      rc=0
    elif [ "$count" -gt 0 ]; then
      printf '%d commit(s) in submodule %s%s that no remote-tracking ref of its own contains\n' \
        "$count" "$prefix" "$path"
      rc=0
    fi
    wt_submodules_hold_commits "$sub" "$prefix$path/" && rc=0
  done < <(wt_git "$dir" ls-files --stage -z 2>/dev/null && printf '\tend\0')
  if [ "$complete" != 1 ]; then
    printf 'could not verify: cannot list the submodules of %s\n' "$dir"
    rc=0
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Tearing down what was allocated
# ---------------------------------------------------------------------------
#
# The steps between "this worktree may go" and "it is gone", in the order teardown.sh calls them.
# Here so the prune sweep runs the SAME steps on a ledger entry with no payload and no hook — a
# second copy of the environment rebuild that drifted would send a teardown script after another
# worktree's database.
#
#   wt_acquire_teardown_lock   keep out of a bootstrap still running in the worktree.
#   wt_acquire_allocation_lock keep out of another teardown or prune releasing the same entry.
#   wt_read_allocation         what was allocated, from ONE record: the state file, else the ledger.
#   wt_run_teardown_script     runtime.teardown, with the environment the seed had.
#   wt_record_seed_undone      a worktree that outlives its teardown must seed again.
#   wt_report_kept             why a worktree was kept, and that nothing was removed.
#   wt_settle_ledger_entry     forget the ledger entry, or keep it for prune.
#
# Results, each reset by the function that sets it:
#   WT_TD_KEEP_REASON  the lock functions' reason for keeping the worktree, when they return 1.
#   WT_TD_SOURCE       where the allocation was read: the state file's path, `ledger`, or empty
#                      when nothing records one.
#   WT_TD_NAME         the name the seed saw: the one the ledger entry first recorded, else
#                      wt_name_from_path's — which differs for a WorktreeCreate name with a `/`
#                      (`alice/fix-99` lives in `alice-fix-99/`) when the ledger entry is missing.
#   WT_TD_SLUG, WT_TD_PORT, WT_TD_PORTSOURCE, WT_TD_ENVFILE, WT_TD_ENVSTATE
#                      the `rt` record's fields, empty when WT_TD_SOURCE is.
#   WT_TD_STATUS       the teardown script's outcome: none (nothing to run), done, failed, timeout,
#                      or skipped (a script that could not be run, or no time left to run it).
#   WT_TD_LEDGER       what became of the ledger entry: forgotten, kept, or none (there was none).
WT_TD_KEEP_REASON='' WT_TD_SOURCE='' WT_TD_NAME='' WT_TD_SLUG='' WT_TD_PORT='' WT_TD_PORTSOURCE=''
WT_TD_ENVFILE='' WT_TD_ENVSTATE='' WT_TD_STATUS=none WT_TD_LEDGER=none

# Take the per-worktree lock bootstrap holds while it runs, on descriptor $2, and keep it until the
# caller releases it (wt_lock_release) or exits. Returns 0 when teardown may go on, 1 when the
# worktree must be kept, with the reason in WT_TD_KEEP_REASON.
#
# A lock that cannot even be TRIED — a symlink, an unopenable path — is a reason to keep: it is no
# proof that nothing holds it. NO flock AT ALL is not: bootstrap already runs unlocked on such a
# host (stock macOS), so refusing would make teardown never work there, for a race bootstrap
# itself does not guard against. The lock file lives in the admin dir and goes with it, which an
# open descriptor survives.
wt_acquire_teardown_lock() {  # $1 = worktree, $2 = fd number
  local wt=${1%/} fd=${2-} rc
  WT_TD_KEEP_REASON=''
  if ! command -v flock >/dev/null 2>&1; then
    wt_log "flock is not on PATH — cannot tell whether a bootstrap is still running in $wt; tearing it down anyway"
    return 0
  fi
  wt_lock_acquire "$(wt_state_path "$wt").lock" 5 "$fd"
  rc=$?
  case $rc in
    0) return 0 ;;
    1) WT_TD_KEEP_REASON='a bootstrap is still running in it' ;;
    *) WT_TD_KEEP_REASON='could not check for a running bootstrap: its lock file cannot be opened' ;;
  esac
  return 1
}

# Where the lock on ledger entry $2's allocation lives, or return 1 for a string that is no entry
# name. Keyed on the ENTRY, not the worktree: once the worktree is gone the entry is all that
# teardown.sh and the prune sweep have in common, and both read it, run the teardown script against
# it and forget it.
wt_allocation_lock_path() {  # $1 = main checkout, $2 = ledger entry
  local common
  wt_ledger_is_entry_name "${2-}" || return 1
  common=$(wt_git_common_dir "$1") || return 1
  printf '%s/worktree-locks/rt-%s.lock' "$common" "$2"
}

# Take the lock on ledger entry $2's allocation on descriptor $3, and keep it until the caller
# releases it or exits. Held from reading the allocation to settling the entry, so two releases of
# one allocation cannot both run its teardown script, nor one forget an entry the other is still
# tearing down. After it is taken the caller re-checks that the entry still exists: the holder it
# waited on may have forgotten it. Returns 0 when the release may go on, 1 when it must not, with
# the reason in WT_TD_KEEP_REASON. No flock at all is 0, for wt_acquire_teardown_lock's reason.
wt_acquire_allocation_lock() {  # $1 = main checkout, $2 = ledger entry, $3 = fd number
  local lock rc
  WT_TD_KEEP_REASON=''
  if ! command -v flock >/dev/null 2>&1; then
    wt_log "flock is not on PATH — the release of ledger entry $2 is not serialised against another teardown or prune"
    return 0
  fi
  if ! lock=$(wt_allocation_lock_path "$1" "$2"); then
    WT_TD_KEEP_REASON="could not check for another release of its runtime allocation: ledger entry $2 has no lock path"
    return 1
  fi
  wt_lock_acquire "$lock" 5 "$3"
  rc=$?
  case $rc in
    0) return 0 ;;
    1) WT_TD_KEEP_REASON='another teardown or /worktree-prune is releasing its runtime allocation' ;;
    *) WT_TD_KEEP_REASON='could not check for another release of its runtime allocation: its lock file cannot be opened' ;;
  esac
  return 1
}

# Read what was allocated for the worktree at $4 into WT_TD_*. Returns 0 when a record was found,
# 1 when nothing records an allocation (WT_TD_NAME is set either way).
#
# The state file is the record bootstrap reads; the ledger entry is its copy that outlives the admin
# dir. Both hold the same `rt` record, so ONE source is picked and every field is read from it —
# mixing them could pair one allocation's slug with another's port. The prune sweep passes an empty
# state file for a worktree already gone, and the ledger is then the only record.
wt_read_allocation() {  # $1 = state file or empty, $2 = main checkout, $3 = ledger entry or empty, $4 = worktree path
  local state=${1-} root=${2-} entry=${3-} wt=${4-} field value

  WT_TD_SOURCE='' WT_TD_NAME='' WT_TD_SLUG='' WT_TD_PORT='' WT_TD_PORTSOURCE=''
  WT_TD_ENVFILE='' WT_TD_ENVSTATE=''

  # The ledger keeps the first name recorded for this allocation (wt_ledger_write), even when the
  # state file is the source: the rt record holds no name. Without an entry it is derived exactly as
  # the SessionStart branch of bootstrap.sh derives it — the flattened directory name, not a
  # WorktreeCreate payload's `/`-separated one.
  [ -n "$entry" ] && { WT_TD_NAME=$(wt_ledger_field "$root" "$entry" name) || WT_TD_NAME=''; }
  [ -n "$WT_TD_NAME" ] || WT_TD_NAME=$(wt_name_from_path "$wt")

  if [ -n "$state" ] && wt_runtime_state_read "$state" slug >/dev/null; then
    WT_TD_SOURCE=$state
  elif [ -n "$entry" ] && wt_ledger_field "$root" "$entry" slug >/dev/null; then
    WT_TD_SOURCE=ledger
  else
    return 1
  fi

  for field in slug port portsource envfile envstate; do
    if [ "$WT_TD_SOURCE" = ledger ]; then
      value=$(wt_ledger_field "$root" "$entry" "$field") || value=''
    else
      value=$(wt_runtime_state_read "$WT_TD_SOURCE" "$field") || value=''
    fi
    case $field in
      slug) WT_TD_SLUG=$value ;;
      port) WT_TD_PORT=$value ;;
      portsource) WT_TD_PORTSOURCE=$value ;;
      envfile) WT_TD_ENVFILE=$value ;;
      envstate) WT_TD_ENVSTATE=$value ;;
    esac
  done
  return 0
}

# Run the loaded profile's runtime.teardown from $1 against the allocation wt_read_allocation read,
# and set WT_TD_STATUS. Always returns 0: every outcome is a status, and only `done`, or `none` for
# an allocation that was read, let the ledger entry go (wt_settle_ledger_entry).
#
# NO RECORD, NO SCRIPT: nothing was allocated, so there is nothing for it to undo, and running it
# with an invented slug could drop a database some other worktree owns.
#
# BOUNDED BY timeouts.seedSeconds. The profile schema has no teardown key, and undoing a seed is the
# same order of work as doing it; a new key would be one more number to calibrate for no gain. It
# is capped by what is left before $4, which the hook measures from its own start so that the
# platform never kills it mid-removal. An empty deadline leaves only that cap and lib.sh's default.
#
# THE ENVIRONMENT IS THE SEED'S, rebuilt from the record rather than re-derived: a profile edited
# since the seed ran would otherwise send the script after a database it never made.
#
# THE SCRIPT IS THE COMMITTED ONE. When the worktree is present the guard has just shown it clean,
# so the file under it is what its branch committed — the same trust the seed ran under (ADR-008).
# Once it is gone, $1 is the main checkout. A path that leaves $1 through a symlink is refused.
wt_run_teardown_script() {  # $1 = directory to run in, $2 = worktree path, $3 = main checkout, $4 = deadline (epoch seconds) or empty
  local rundir=${1-} wt=${2-} root=${3-} deadline=${4-} rel=${PROFILE_RT_TEARDOWN:-} esc secs left rc

  WT_TD_STATUS=none
  [ -n "$WT_TD_SOURCE" ] || return 0
  # A profile that exists but was not loaded says nothing about whether a script must run, and
  # `none` would let the entry go.
  if [ "${PROFILE_PRESENT:-0}" != 1 ] && [ -n "${PROFILE_PATH:-}" ] \
    && { [ -e "$PROFILE_PATH" ] || [ -L "$PROFILE_PATH" ]; }; then
    WT_TD_STATUS=skipped
    wt_log "runtime: $PROFILE_PATH could not be loaded, so whether a teardown script must run is unknown — none run"
    return 0
  fi
  [ "${PROFILE_PRESENT:-0}" = 1 ] && [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "$rel" ] || return 0

  WT_TD_STATUS=skipped
  if ! wt_is_safe_relpath "$rel" || wt_has_symlinked_parent "$rundir" "$rel" || [ -L "$rundir/$rel" ]; then
    wt_log "runtime: refusing to run the teardown script $rel — not a plain file inside $rundir"
    return 0
  fi
  if [ ! -f "$rundir/$rel" ] || [ ! -x "$rundir/$rel" ]; then
    wt_log "runtime: the teardown script $rel is missing or not executable in $rundir — not run"
    return 0
  fi

  secs=${PROFILE_SEED_TIMEOUT:-$WT_DEFAULT_TIMEOUT}
  wt_is_seconds "$secs" || secs=$WT_DEFAULT_TIMEOUT
  secs=$((10#$secs))
  left=$(wt_budget_left "$deadline")
  [ "$left" -ge "$secs" ] || secs=$left
  # `timeout 0` means no limit at all, so no time left is a skip, not a zero bound.
  if [ "$secs" -le 0 ]; then
    wt_log "runtime: no time left under the hook timeout to run the teardown script $rel — not run"
    return 0
  fi

  esc=${rel//\'/\'\\\'\'}
  wt_log "runtime: tearing down slug=$WT_TD_SLUG${WT_TD_PORT:+ port=$WT_TD_PORT} with $rel (up to ${secs}s)"
  (
    WT_NAME=$WT_TD_NAME
    WT_SLUG=$WT_TD_SLUG
    WT_PORT=$WT_TD_PORT
    WT_PATH=$wt
    WT_ROOT=$root
    WT_ENV_FILE=${WT_TD_ENVFILE%%:*}
    WT_ENV_FILES=${WT_TD_ENVFILE//:/$WT_NL}
    export WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT WT_ENV_FILE WT_ENV_FILES
    wt_run_in_shell "./'$esc'" "$rundir" "$secs"
  )
  rc=$?
  case $rc in
    0) WT_TD_STATUS="done" ;;
    124)
      WT_TD_STATUS=timeout
      wt_log "runtime: the teardown script ran past ${secs}s and was stopped — its database or containers may still exist"
      ;;
    *)
      WT_TD_STATUS=failed
      wt_log "runtime: the teardown script failed (exit $rc) — its database or containers may still exist"
      ;;
  esac
  return 0
}

# Take the plugin's block out of every override file the record says is `ours` (ADR-012). $2 and
# $3 are the record's `:`-joined, aligned file list and dispositions; a file whose slot is `theirs`
# or empty is the developer's, or was never written, and is not opened at all. The recorded list,
# never the profile's current one: a profile edited since would name files the plugin never wrote.
wt_release_env_overrides() {  # $1 = worktree, $2 = recorded env files, $3 = recorded dispositions
  local worktree=${1%/} files=${2-} states=${3-} f st
  while [ -n "$files" ]; do
    f=${files%%:*}
    st=${states%%:*}
    if [ "$f" = "$files" ]; then files=''; else files=${files#*:}; fi
    if [ "$st" = "$states" ]; then states=''; else states=${states#*:}; fi
    [ "$st" = ours ] || continue
    wt_runtime_env_release "$worktree" "$f" \
      || wt_log "could not remove the plugin's block from $f"
  done
  return 0
}

# A worktree that survives a successful teardown script points at an allocation that is gone, and
# its state still says the seed is done — so the next session would skip the seed and run against
# a dropped database. Recording the seed as not run makes that session seed again. Only when the
# allocation was read from the worktree's own state file: a ledger-only record has no state file
# left to correct.
wt_record_seed_undone() {  # $1 = worktree
  [ "$WT_TD_STATUS" = "done" ] && [ -n "$WT_TD_SOURCE" ] && [ "$WT_TD_SOURCE" != ledger ] \
    || return 0
  # WT_NAME is what the ledger copy of the record is written under.
  WT_NAME=$WT_TD_NAME wt_runtime_state_set "$1" "$WT_TD_SLUG" "$WT_TD_PORT" "$WT_TD_PORTSOURCE" \
    "$WT_TD_ENVFILE" "$WT_TD_ENVSTATE" none '' \
    || wt_log "runtime: could not record that the seed must run again — delete the database marker by hand if the next session skips it"
}

wt_report_kept() {  # $1 = worktree, $2 = reasons, one per line
  local reason
  wt_log "keeping ${1%/} — it holds work:"
  while IFS= read -r reason; do
    [ -n "$reason" ] && wt_log "  - $reason"
  done <<<"${2-}"
  wt_log 'nothing was removed; /worktree-prune will list it'
}

# Forget the ledger entry once nothing it records can still exist, or keep it and say so. It goes
# only when the worktree is gone ($3 = 1) AND the teardown script left nothing behind: it ran to
# `done`, or it was `none` for an allocation wt_read_allocation DID read — a loaded profile with no
# script to run. A kept worktree still owns its allocation; a failed, stopped or skipped script may
# have left its database; and an allocation that could not be read was never looked at. In each
# the entry is the only record of what may still exist.
wt_settle_ledger_entry() {  # $1 = main checkout, $2 = ledger entry or empty, $3 = 1 if the worktree is gone
  local root=${1-} entry=${2-} gone=${3:-0} released=0
  WT_TD_LEDGER=none
  [ -n "$entry" ] || return 0
  case $WT_TD_STATUS in
    "done") released=1 ;;
    none) [ -n "$WT_TD_SOURCE" ] && released=1 ;;
  esac
  if [ "$gone" = 1 ] && [ "$released" = 1 ]; then
    if wt_ledger_forget "$root" "$entry"; then
      WT_TD_LEDGER=forgotten
      return 0
    fi
    WT_TD_LEDGER=kept
    wt_log "could not remove the runtime ledger entry $entry; /worktree-prune will list it"
    return 0
  fi
  WT_TD_LEDGER=kept
  wt_log "the runtime ledger entry $entry is kept; /worktree-prune will list it"
}
