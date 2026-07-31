#!/usr/bin/env bash
#
# Bootstrap entrypoint. Phase 1: resolves paths, loads the profile, logs what it found,
# and satisfies each event's contract. It deliberately copies nothing, installs nothing
# and changes nothing — installing this plugin must be a behavioural no-op until Phase 3.
#
# It handles BOTH events it could ever be wired to, because the contracts differ in a way
# that is easy to get fatally wrong:
#
#   SessionStart    stdout is INJECTED INTO THE MODEL'S CONTEXT. Nothing may go there.
#                   Phase 1 measured that the session blocks until this hook returns, so
#                   this is the safe place to do work the model must not race.
#   WorktreeCreate  stdout IS the worktree path and nothing else. It also REPLACES native
#                   creation, so if it is wired it must create the worktree itself.
#
# Phase 1 wires only SessionStart — see hooks/hooks.json and ADR-009 for why. The
# WorktreeCreate branch is written but has never run in anger; Phase 3 owns making it
# production-worthy, and the guard rails below exist so its failure modes are refusals
# rather than silent damage.
#
# ADR-003 governs everything below: warn on stderr, still emit the path, exit 0. `set -e`
# is deliberately NOT used — a bootstrap that aborts halfway costs the user their session,
# which is strictly worse than a worktree missing its dependencies.
set -uo pipefail

# SC1091: shellcheck only FOLLOWS a sourced file when invoked with -x, and the pre-commit
# gate lints each changed file on its own. The two directives below still tell it where
# lib.sh is for anyone running `shellcheck -x`.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

wt_read_input

# Probe the JSON backend explicitly and SAY SO when it is missing. Without this the hook
# is indistinguishable from a no-op: every field read returns empty, the event can't be
# identified, and the user gets no clue why nothing happened.
if ! wt_has_json; then
  wt_log "neither jq nor python3 is on PATH — cannot read the hook payload, doing nothing"
  exit 0
fi

event=$(wt_read_field hook_event_name) || event=''
name=$(wt_read_field name) || name=''
source_kind=$(wt_read_field source) || source_kind=''
payload_cwd=$(wt_read_field cwd) || payload_cwd=''
here=${payload_cwd:-$PWD}

# Where Claude Code puts worktrees. Used to tell "this session is in a worktree" from
# "this session is in the main checkout", which is how the SessionStart path stays inert
# for ordinary sessions.
WT_SUBPATH='/.claude/worktrees/'

# The profile is committed (ADR-008), so a branch that adds a dependency also updates it.
# The worktree's own checked-out copy therefore wins over the main checkout's — otherwise
# a worktree gets bootstrapped from whatever main happens to have, while Phase 3 reads its
# *lockfiles* from the worktree, and the two disagree.
wt_load_profile_for() {  # $1 = worktree, $2 = main checkout
  local which=$1
  [ -f "$1/.claude/worktree-profile.json" ] || which=$2
  wt_load_profile "$which"
}

case $event in
  WorktreeCreate)
    # stdout is the path. Every message below goes to stderr.
    root=$(wt_main_root "$here") || root=$(wt_repo_root "$here") || root=''
    if [ -z "$root" ]; then
      # No path we could print would be enterable, so say why and let Claude Code report
      # the failure rather than emitting a guess.
      wt_log "cannot resolve a repository from $here — leaving worktree creation to Claude Code"
      exit 0
    fi

    if [ -z "$name" ]; then
      wt_log "WorktreeCreate payload had no name; cannot derive a worktree path"
      exit 0
    fi

    # `name` arrives already resolved (measured: `claude -w "#1"` delivers `pr-1`), but it
    # is still untrusted text and it is about to become BOTH a path component and the one
    # line on the stdout protocol channel.
    case $name in
      *$'\n'* | *$'\r'*)
        # A newline would put a second line on stdout, which breaks the protocol outright.
        wt_log "refusing a worktree name containing a newline"
        exit 0
        ;;
    esac
    dir=${name//\//-}
    case $dir in
      '' | '.' | '..')
        # "." and ".." would escape the worktrees directory and hand back .claude itself.
        wt_log "refusing the unsafe worktree name \"$name\""
        exit 0
        ;;
    esac

    worktree="$root/.claude/worktrees/$dir"
    branch="worktree-$dir"

    if [ -d "$worktree" ]; then
      # Reopening. Measured: the hook is re-invoked for an existing name, so this is a
      # normal path, not an error.
      wt_log "reopening existing worktree $worktree"
    elif wt_git "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      # The branch already exists — check it out rather than inventing a new name, which
      # would orphan whatever the user kept on it.
      out=$(wt_git "$root" worktree add "$worktree" "$branch" 2>&1) || true
      [ -n "$out" ] && wt_log "$out"
    else
      out=$(wt_git "$root" worktree add -b "$branch" "$worktree" 2>&1) || true
      [ -n "$out" ] && wt_log "$out"
    fi

    # Never print a path that isn't there. Claude Code would fail the session on a path it
    # cannot enter, and a bare "Preparing worktree" line in the log reads like success.
    if [ ! -d "$worktree" ]; then
      wt_log "could not create $worktree — leaving worktree creation to Claude Code"
      exit 0
    fi

    WT_NAME=$name
    WT_SLUG=$(wt_slugify "$name") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile_for "$worktree" "$root"
    wt_log "worktree=$worktree slug=$WT_SLUG profile=$([ "$PROFILE_PRESENT" = 1 ] && echo "$PROFILE_PATH" || echo none)"
    wt_log "Phase 1 does no bootstrapping yet — no files copied, no dependencies installed."

    # The one line that must reach stdout.
    printf '%s\n' "$worktree"
    exit 0
    ;;

  SessionStart)
    # Only a genuinely new or resumed session can need bootstrapping. `compact` fires
    # mid-session, where the "the model cannot race the hook" measurement in ADR-009 —
    # taken at startup — does not apply, and where re-running a bootstrap would be pure
    # cost. Stay silent rather than logging on every compaction.
    case $source_kind in
      startup | resume | '') ;;
      *) exit 0 ;;
    esac

    # Measured: for `claude -w <name>` this fires with cwd already set to the worktree.
    # For a session in the main checkout there is nothing to bootstrap, so stay silent —
    # a plugin that logs on every single session start is a plugin people uninstall.
    case "$here/" in
      *"$WT_SUBPATH"*) ;;
      *) exit 0 ;;
    esac

    worktree=$(wt_repo_root "$here") || worktree=$here
    root=$(wt_main_root "$here") || root=''
    if [ -z "$root" ]; then
      wt_log "could not resolve the main checkout for $worktree — skipping bootstrap"
      exit 0
    fi

    # SessionStart carries no `name`, so it comes from the directory. Claude Code names the
    # directory after the worktree, so these agree for every name it accepts.
    WT_NAME=${worktree##*/}
    WT_SLUG=$(wt_slugify "$WT_NAME") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile_for "$worktree" "$root"

    wt_log "worktree $WT_NAME at $worktree (main checkout $root, slug $WT_SLUG)"
    if [ "$PROFILE_PRESENT" = 1 ]; then
      wt_log "profile $PROFILE_PATH: shell=${PROFILE_SHELL:-<host>} runtime=$([ "$PROFILE_HAS_RUNTIME" = 1 ] && echo yes || echo no)"
    else
      wt_log "no usable profile at $PROFILE_PATH — Phase 2 adds /worktree-calibrate to write one"
    fi
    wt_log "Phase 1 does no bootstrapping yet — no files copied, no dependencies installed."
    # NOTHING to stdout: for SessionStart, stdout becomes model context.
    exit 0
    ;;

  '')
    # An unreadable or empty payload. Never treat this as SessionStart: on the
    # WorktreeCreate path an unexplained empty stdout costs the user their session, so it
    # has to be visible.
    wt_log "could not read hook_event_name from the payload — doing nothing"
    exit 0
    ;;

  *)
    wt_log "unexpected hook event \"$event\" — doing nothing"
    exit 0
    ;;
esac
