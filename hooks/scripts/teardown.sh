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

# Print why the worktree is being kept and that nothing was removed. $1 = the guard's reasons.
wt_report_kept() {  # $1 = reasons, one per line
  local reason
  wt_log "keeping $worktree — it holds work:"
  while IFS= read -r reason; do
    [ -n "$reason" ] && wt_log "  - $reason"
  done <<<"$1"
  # shellcheck disable=SC2016  # the backticks are literal text
  wt_log 'nothing was removed; /worktree-prune will list it'
}

# --- 1. the guard, before anything is read, run or removed -----------------------------------
if [ "$present" = 1 ]; then
  if reasons=$(wt_worktree_holds_work "$worktree"); then
    wt_report_kept "$reasons"
    exit 0
  fi
  # A bootstrap still running in this worktree holds its per-worktree lock (bootstrap.sh). Tearing
  # down under it would race an install and a seed. Held until exit; the lock file lives in the
  # admin dir and goes with it, which an open descriptor survives.
  if [ -n "$admin" ] && command -v flock >/dev/null 2>&1; then
    wt_lock_acquire "$admin/worktree-bootstrap-state.lock" 5 8
    if [ $? = 1 ]; then
      wt_report_kept 'a bootstrap is still running in it'
      exit 0
    fi
  fi
fi

# --- 2. what this plugin allocated, read BEFORE anything is deleted ---------------------------
# The state file in the admin dir is the record bootstrap reads; the ledger entry is its copy that
# outlives the admin dir. Both hold the same `rt` record, so one source is picked and every field
# is read from it — mixing them could pair one allocation's slug with another's port.
allocation_state=''
if [ -n "$admin" ] && wt_runtime_state_read "$admin/worktree-bootstrap-state" slug >/dev/null; then
  allocation_state=$admin/worktree-bootstrap-state
elif [ -n "$entry" ] && wt_ledger_field "$root" "$entry" slug >/dev/null; then
  allocation_state=ledger
fi

wt_allocation_field() {  # $1 = rt field name
  if [ "$allocation_state" = ledger ]; then
    wt_ledger_field "$root" "$entry" "$1"
  else
    wt_runtime_state_read "$allocation_state" "$1"
  fi
}

slug='' port='' portsource='' envfile='' envstate=''
if [ -n "$allocation_state" ]; then
  slug=$(wt_allocation_field slug) || slug=''
  port=$(wt_allocation_field port) || port=''
  portsource=$(wt_allocation_field portsource) || portsource=''
  envfile=$(wt_allocation_field envfile) || envfile=''
  envstate=$(wt_allocation_field envstate) || envstate=''
fi

# The name the seed saw. The ledger recorded it; without an entry it is derived exactly as the
# SessionStart branch of bootstrap.sh derives it, from the path under the worktrees directory.
name=''
[ -n "$entry" ] && { name=$(wt_ledger_field "$root" "$entry" name) || name=''; }
if [ -z "$name" ]; then
  name=${worktree##*"$WT_SUBPATH"}
  [ "$name" != "$worktree" ] || name=${worktree##*/}
fi

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
# Sets teardown_status: none (nothing to run), done, failed, timeout, or skipped (the profile names
# a script that cannot be run). Only `none` and `done` let the ledger entry go.
#
# NO rt RECORD, NO SCRIPT: nothing was allocated, so there is nothing for it to undo, and running
# it with an invented slug could drop a database some other worktree owns.
#
# BOUNDED BY timeouts.seedSeconds. The profile schema has no teardown key, and undoing a seed is the
# same order of work as doing it; a new key would be one more number to calibrate for no gain.
# Clamped below the hook's own timeout so the platform never kills the hook mid-removal.
#
# THE ENVIRONMENT IS THE SEED'S, rebuilt from the record rather than re-derived: a profile edited
# since the seed ran would otherwise send the script after a database it never made.
#
# THE SCRIPT IS THE COMMITTED ONE. When the worktree is present the guard has just shown it clean,
# so the file under it is what its branch committed — the same trust the seed ran under (ADR-008).
wt_run_teardown_script() {
  local rel=${PROFILE_RT_TEARDOWN:-} abs esc secs rc

  teardown_status=none
  [ -n "$allocation_state" ] || return 0
  [ "${PROFILE_PRESENT:-0}" = 1 ] && [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "$rel" ] || return 0

  teardown_status=skipped
  if ! wt_is_safe_relpath "$rel" || wt_has_symlinked_parent "$rundir" "$rel" || [ -L "$rundir/$rel" ]; then
    wt_log "runtime: refusing to run the teardown script $rel — not a plain file inside $rundir"
    return 0
  fi
  abs=$rundir/$rel
  if [ ! -f "$abs" ] || [ ! -x "$abs" ]; then
    wt_log "runtime: the teardown script $rel is missing or not executable in $rundir — not run"
    return 0
  fi

  secs=${PROFILE_SEED_TIMEOUT:-$WT_DEFAULT_TIMEOUT}
  wt_is_seconds "$secs" || secs=$WT_DEFAULT_TIMEOUT
  if [ "$((10#$secs))" -gt $((WT_HOOK_TIMEOUT - WT_TEARDOWN_RESERVE)) ]; then
    secs=$((WT_HOOK_TIMEOUT - WT_TEARDOWN_RESERVE))
  fi

  esc=${rel//\'/\'\\\'\'}
  wt_log "runtime: tearing down slug=$slug${port:+ port=$port} with $rel (up to ${secs}s)"
  (
    export WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT WT_ENV_FILE
    WT_NAME=$name
    WT_SLUG=$slug
    WT_PORT=$port
    WT_PATH=$worktree
    WT_ROOT=$root
    WT_ENV_FILE=$envfile
    wt_run_in_shell "./'$esc'" "$rundir" "$secs"
  )
  rc=$?
  case $rc in
    0) teardown_status="done" ;;
    124)
      teardown_status=timeout
      wt_log "runtime: the teardown script ran past ${secs}s and was stopped — its database or containers may still exist"
      ;;
    *)
      teardown_status=failed
      wt_log "runtime: the teardown script failed (exit $rc) — its database or containers may still exist"
      ;;
  esac
  return 0
}
wt_run_teardown_script

# A worktree that survives a successful teardown script points at an allocation that is gone, and
# its state still says the seed is done — so the next session would skip the seed and run against
# a dropped database. Recording the seed as not run makes that session seed again.
wt_mark_unseeded() {
  [ "$teardown_status" = "done" ] && [ "$allocation_state" = "$admin/worktree-bootstrap-state" ] \
    || return 0
  WT_NAME=$name
  export WT_NAME
  wt_runtime_state_set "$worktree" "$slug" "$port" "$portsource" "$envfile" "$envstate" none '' \
    || wt_log "runtime: could not record that the seed must run again — delete the database marker by hand if the next session skips it"
}

wt_report_ledger_kept() {
  [ -n "$entry" ] || return 0
  wt_log "the runtime ledger entry $entry is kept; /worktree-prune will list it"
}

# --- 4. the directory ------------------------------------------------------------------------
if [ "$present" = 1 ]; then
  # The script ran IN the worktree and may have left something there — a dump, a log, a commit.
  if reasons=$(wt_worktree_holds_work "$worktree"); then
    wt_mark_unseeded
    wt_report_kept "$reasons"
    wt_report_ledger_kept
    exit 0
  fi

  # Only a file this plugin wrote and still carries its marker. The recorded name, never the
  # profile's current one: a profile edited since would name a file we never made. It goes before
  # the checkout does, so a removal that fails halfway does not leave the override behind.
  #
  # Nothing else is unlinked first: the state records no symlink this plugin made (dependencies
  # are hardlinked or installed, config is copied), and neither `git worktree remove` nor `rm -rf`
  # follows a symlink out of the tree.
  if [ "$envstate" = ours ] && [ -n "$envfile" ] && wt_is_safe_relpath "$envfile" \
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
      wt_mark_unseeded
      wt_report_ledger_kept
      exit 0
    fi
    rm -rf -- "${worktree:?}" 2>/dev/null
    if [ -e "$worktree" ]; then
      wt_log "could not delete $worktree completely — remove it by hand"
      wt_mark_unseeded
      wt_report_ledger_kept
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
if [ -n "$entry" ]; then
  case $teardown_status in
    none | "done")
      wt_ledger_forget "$root" "$entry" \
        || wt_log "could not remove the runtime ledger entry $entry; /worktree-prune will list it"
      ;;
    *) wt_report_ledger_kept ;;
  esac
fi
exit 0
