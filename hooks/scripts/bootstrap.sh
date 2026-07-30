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
# WorktreeCreate branch exists so the contract is satisfied the moment Phase 3 wires it,
# rather than being written under pressure then.
#
# ADR-003 governs everything below: warn on stderr, still emit the path, exit 0. `set -e`
# is deliberately NOT used — a bootstrap that aborts halfway costs the user their session,
# which is strictly worse than a worktree missing its dependencies.
set -uo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

wt_read_input

event=$(wt_read_field hook_event_name) || event=''
name=$(wt_read_field name) || name=''
payload_cwd=$(wt_read_field cwd) || payload_cwd=''
here=${payload_cwd:-$PWD}

# Where Claude Code puts worktrees. Used to tell "this session is in a worktree" from
# "this session is in the main checkout", which is how the SessionStart path stays inert
# for ordinary sessions.
WT_SUBPATH='/.claude/worktrees/'

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
    # can still contain a slash, which would create nested directories.
    dir=${name//\//-}
    worktree="$root/.claude/worktrees/$dir"

    if [ -d "$worktree" ]; then
      # Reopening. Measured: the hook is re-invoked for an existing name, so this is a
      # normal path, not an error.
      wt_log "reopening existing worktree $worktree"
    else
      branch="worktree-$dir"
      if ! out=$(wt_git "$root" worktree add -b "$branch" "$worktree" 2>&1); then
        if ! out=$(wt_git "$root" worktree add "$worktree" 2>&1); then
          out=$(wt_git "$root" worktree add --detach "$worktree" 2>&1) || true
        fi
      fi
      [ -n "${out:-}" ] && wt_log "$out"
    fi

    WT_NAME=$name
    WT_SLUG=$(wt_slugify "$name") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile "$root"
    wt_log "worktree=$worktree slug=$WT_SLUG profile=$([ "$PROFILE_PRESENT" = 1 ] && echo "$PROFILE_PATH" || echo none)"
    wt_log "Phase 1 does no bootstrapping yet — no files copied, no dependencies installed."

    # The one line that must reach stdout.
    printf '%s\n' "$worktree"
    exit 0
    ;;

  SessionStart | '')
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

    WT_NAME=${worktree##*/}
    WT_SLUG=$(wt_slugify "$WT_NAME") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile "$root"

    wt_log "worktree $WT_NAME at $worktree (main checkout $root, slug $WT_SLUG)"
    if [ "$PROFILE_PRESENT" = 1 ]; then
      wt_log "profile $PROFILE_PATH: shell=${PROFILE_SHELL:-<host>} runtime=$([ "$PROFILE_HAS_RUNTIME" = 1 ] && echo yes || echo no)"
    else
      wt_log "no usable profile at $PROFILE_PATH — run /worktree-calibrate to create one"
    fi
    wt_log "Phase 1 does no bootstrapping yet — no files copied, no dependencies installed."
    # NOTHING to stdout: for SessionStart, stdout becomes model context.
    exit 0
    ;;

  *)
    wt_log "unexpected hook event \"$event\" — doing nothing"
    exit 0
    ;;
esac
