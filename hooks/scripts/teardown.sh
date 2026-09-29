#!/usr/bin/env bash
#
# WorktreeRemove entrypoint. Tears a worktree down — its runtime allocation, its env override file,
# the checkout and its git registration — but ONLY when the worktree holds no work. A worktree that
# does is left exactly as it is: nothing is run, nothing is removed, the reasons go to stderr, and
# /worktree-prune lists it later. Deleting the wrong thing destroys work; leaving the right thing
# costs disk (docs/phases/phase-5-teardown.md).
#
# WHO REMOVES THE DIRECTORY. Because this plugin registers WorktreeCreate, Claude Code does not run
# `git worktree remove` for the worktrees that hook created, so this hook must. A launch-time
# `claude -w` worktree was created natively and Claude Code may remove it itself, before or after
# this hook — so a worktree whose directory, and even admin dir, is already gone is a normal input:
# its runtime ledger entry is then the only record of what was allocated, and the teardown script
# runs from the main checkout.
#
# WHAT IS NEVER DONE, whatever the state says:
#   * no process is killed. The state records a port, not a PID, so "the process on that port is
#     still ours" cannot be proven — and a developer's machine reuses ports. The repo's
#     runtime.teardown script is the only thing that may stop what its seed started.
#   * the branch is never deleted. It is the user's, and a clean worktree can still be reopened.
#   * shared state is never touched: the main checkout a dependency was hardlinked from, package
#     caches, the dependency locks in <common>/worktree-locks/, other worktrees' ledger entries.
#   * no `git worktree remove -f -f`. A locked worktree is someone saying "not this one", and the
#     guard already counts it as work.
#
# ADR-003 governs everything below: on any internal failure warn on stderr and exit 0. A nonzero
# exit would fail the removal, which helps nobody. `set -e` is deliberately NOT used, as in
# bootstrap.sh. stdout stays EMPTY: nothing here has anything to say to the protocol channel.
set -uo pipefail

# SC1091: see bootstrap.sh — the gate lints each file on its own; `shellcheck -x` follows these.
# teardown-lib.sh sources bootstrap-lib.sh, which sources lib.sh; each guards against a second load.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bootstrap-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bootstrap-lib.sh"
# shellcheck source=teardown-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/teardown-lib.sh"

# Room left under the hook's own timeout for everything after the teardown script — the second
# guard, `git worktree remove`, and the rm -rf fallback on a large checkout. Wider than bootstrap's
# 30s because deleting a populated node_modules is slower than anything bootstrap does after its
# budget runs out.
WT_TEARDOWN_RESERVE=60

# Measured from here, not from when the script starts: the guard, the lock wait and the profile
# load all come out of the same hook timeout.
started=$(date +%s 2>/dev/null) || started=''
deadline=''
[ -n "$started" ] && deadline=$((started + WT_HOOK_TIMEOUT - WT_TEARDOWN_RESERVE))

wt_read_input

if ! wt_has_json; then
  wt_log "neither jq nor python3 is on PATH — cannot read the removal payload, removing nothing"
  exit 0
fi

# The resolver has already said why on stderr for both non-zero codes: 1 is a refusal, 2 is a
# worktree already gone that nothing of ours records.
wt_resolve_removal_target
case $? in
  0) ;;
  *) exit 0 ;;
esac
worktree=$WT_RM_WORKTREE
root=$WT_RM_ROOT
admin=$WT_RM_ADMIN
entry=$WT_RM_LEDGER_ENTRY
present=$WT_RM_PRESENT

# --- 1. the guard, before anything is read, run or removed -----------------------------------
state=''
if [ "$present" = 1 ]; then
  if reasons=$(wt_worktree_holds_work "$worktree"); then
    wt_report_kept "$worktree" "$reasons"
    exit 0
  fi
  # Held until exit.
  if ! wt_acquire_teardown_lock "$worktree" 8; then
    wt_report_kept "$worktree" "$WT_TD_KEEP_REASON"
    exit 0
  fi
  state=$(wt_state_path "$worktree")
fi

# --- 2. what this plugin allocated, read BEFORE anything is deleted ---------------------------
wt_read_allocation "$state" "$root" "$entry" "$worktree"

# The profile the worktree was set up with: its own committed copy wins (ADR-008). Once the
# directory is gone, the main checkout's is the only one left.
if [ "$present" = 1 ]; then
  rundir=$worktree
  wt_load_profile_for "$worktree" "$root"
else
  rundir=$root
  wt_load_profile "$root"
fi

# --- 3. runtime.teardown ---------------------------------------------------------------------
wt_run_teardown_script "$rundir" "$worktree" "$root" "$deadline"

# --- 4. the directory ------------------------------------------------------------------------
if [ "$present" = 1 ]; then
  # The script ran IN the worktree and may have left something there — a dump, a log, a commit.
  if reasons=$(wt_worktree_holds_work "$worktree"); then
    wt_record_seed_undone "$worktree"
    wt_report_kept "$worktree" "$reasons"
    wt_settle_ledger_entry "$root" "$entry" 0
    exit 0
  fi

  # Only a file this plugin wrote and still carries its marker. The recorded name, never the
  # profile's current one: a profile edited since would name a file we never made. It goes before
  # the checkout does, so a removal that fails halfway does not leave the override behind.
  #
  # Nothing else is unlinked first: the state records no symlink this plugin made (dependencies
  # are hardlinked or installed, config is copied), and neither `git worktree remove` nor `rm -rf`
  # follows a symlink out of the tree.
  envfile=$WT_TD_ENVFILE
  if [ "$WT_TD_ENVSTATE" = ours ] && [ -n "$envfile" ] && wt_is_safe_relpath "$envfile" \
    && ! wt_has_symlinked_parent "$worktree" "$envfile" \
    && [ "$(wt_runtime_env_state "$worktree" "$envfile")" = ours ]; then
    rm -f -- "${worktree:?}/${envfile:?}" 2>/dev/null \
      || wt_log "could not remove the env override file $envfile"
  fi

  # A single --force: it takes the gitignored dependency directories with it. Never -f -f.
  out=$(wt_git "$root" worktree remove --force "$worktree" 2>&1) || {
    [ -n "$out" ] && wt_log "git worktree remove: $out"
  }
  if [ -e "$worktree" ]; then
    # git refuses some clean worktrees outright — one containing a submodule, for one. Only the
    # directory the resolver proved is deleted: re-checked here, since the script ran in between.
    if [ -L "$worktree" ] || [ "$(cd -P "$worktree" 2>/dev/null && pwd -P)" != "$worktree" ]; then
      wt_log "not deleting $worktree: it no longer resolves to the worktree that was checked"
      wt_record_seed_undone "$worktree"
      wt_settle_ledger_entry "$root" "$entry" 0
      exit 0
    fi
    rm -rf -- "${worktree:?}" 2>/dev/null
    if [ -e "$worktree" ]; then
      wt_log "could not delete $worktree completely — remove it by hand"
      wt_record_seed_undone "$worktree"
      wt_settle_ledger_entry "$root" "$entry" 0
      exit 0
    fi
    # Only THIS worktree's registration, and only while it still points here. A repository-wide
    # `git worktree prune` would also erase every other missing worktree's admin dir, and the state
    # file in it that /worktree-prune reads.
    if [ -n "$admin" ] && [ -d "$admin" ] \
      && pointer=$(wt_read_git_pointer "$admin/gitdir" "$admin") \
      && [ "$(wt_physical_path "$pointer")" = "$worktree/.git" ]; then
      rm -rf -- "${admin:?}" 2>/dev/null || wt_log "could not remove the stale git registration $admin — \`git worktree prune\` will"
    fi
  fi
  wt_log "removed $worktree (its branch is kept)"
fi
# A directory already gone keeps any admin dir git left behind: its checkout cannot be read, so the
# guard cannot vouch for it, and `git worktree prune` or /worktree-prune owns that decision.

# --- 5. the ledger ---------------------------------------------------------------------------
wt_settle_ledger_entry "$root" "$entry" 1
exit 0
