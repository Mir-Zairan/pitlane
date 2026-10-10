#!/usr/bin/env bash
#
# SubagentStart entrypoint: tells a subagent which worktree it runs in, that worktree's own app
# port and URL, and the profile's approved agent note.
#
# Measured (ADR-024): a subagent with isolation "worktree" gets a worktree from WorktreeCreate, but no
# SessionStart fires for it, WorktreeCreate gets no CLAUDE_ENV_FILE, and the subagent INHERITS the
# parent session's environment — so the WORKTREE_PORT and WORKTREE_URL it sees are the PARENT's
# worktree's, the wrong app. SubagentStart fires after WorktreeCreate with cwd set to the subagent's
# directory, and its additionalContext reaches the subagent. The hook's own environment does NOT
# carry the session's exported variables, so what the parent exported is read from where it came
# from: CLAUDE_PROJECT_DIR, the directory the parent session started in.
#
# stdout is the hook protocol: one JSON object or nothing. Deterministic, read-only, and it never
# fails the subagent: every path exits 0.
set -uo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bootstrap-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bootstrap-lib.sh"

# The Pitlane worktree directory $1 is in, its main checkout and its recorded port, into
# WT_SA_WORKTREE, WT_SA_ROOT and WT_SA_PORT. Returns 1 when $1 is not inside a linked worktree under
# <root>/.claude/worktrees/ (wt_linked_worktree_at) — the same rule /pitlane-serve applies.
wt_subagent_worktree() {  # $1 = directory
  WT_SA_WORKTREE='' WT_SA_ROOT='' WT_SA_PORT=''
  wt_linked_worktree_at "${1-}" || return 1
  WT_SA_WORKTREE=$WT_LINKED_WORKTREE WT_SA_ROOT=$WT_LINKED_ROOT
  WT_SA_PORT=$(wt_runtime_state_get "$WT_SA_WORKTREE" port) || WT_SA_PORT=''
  wt_is_posint "$WT_SA_PORT" || WT_SA_PORT=''
  return 0
}

# A JSON string body: backslash and quote escaped, control characters dropped — but with $2 = lines,
# a line feed becomes the escape `\n` instead, so a block of lines reaches the subagent as lines. One
# function for both, so the two cannot drift. In-process: LC_ALL=C so the ranges match bytes, and
# every other byte is kept.
wt_subagent_json_escape() {  # $1 = text, $2 = lines or empty
  wt_json_text "$@"
}

# The one line for the subagent, in WT_SUBAGENT_NOTE, or empty when it has nothing to be told; and
# the profile's agent note, in WT_SUBAGENT_AGENT_NOTE, when the subagent works in a worktree whose
# profile carries one approved for it — empty otherwise, so a held note is never shown.
wt_subagent_note() {  # $1 = the subagent's directory, $2 = the directory the parent session started in
  local here=${1-} parent=${2-} name url='' inherited='' parent_name='' slug
  WT_SUBAGENT_NOTE='' WT_SUBAGENT_AGENT_NOTE=''
  # What the parent session exported (wt_session_env_export): a port, if it started in a Pitlane
  # worktree that has one. Read from the hook's own environment too, should a release pass it on.
  if [ -n "${WORKTREE_PORT:-}${WORKTREE_URL:-}" ]; then
    inherited=1
  fi
  if [ -n "$parent" ] && wt_subagent_worktree "$parent" && [ -n "$WT_SA_PORT" ]; then
    inherited=1 parent_name=$(wt_name_from_path "$WT_SA_WORKTREE")
  fi

  if wt_subagent_worktree "$here"; then
    name=$(wt_name_from_path "$WT_SA_WORKTREE")
    # One load, shared by the port line and the agent note: with a port, as it always was; without
    # one, only when the profile may carry a note at all (wt_profile_may_carry_agent_note), so the
    # common worktree, with neither, starts no interpreter. The note's approval is decided for this
    # worktree, as the start-up hook decides it — what the parent session was shown says nothing
    # about the files here.
    if [ -n "$WT_SA_PORT" ] || wt_profile_may_carry_agent_note "$WT_SA_WORKTREE" "$WT_SA_ROOT"; then
      wt_load_profile_for "$WT_SA_WORKTREE" "$WT_SA_ROOT" 2>/dev/null
      if wt_profile_has_agent_note; then
        wt_approval_check "$WT_SA_WORKTREE" 2>/dev/null
        if wt_agent_note_is_approved; then
          # The slug the runtime named this worktree's state after, as start-up uses it; with no
          # runtime record, the slugified name start-up would use.
          slug=$(wt_runtime_state_get "$WT_SA_WORKTREE" slug 2>/dev/null) || slug=''
          [ -n "$slug" ] || slug=$(wt_slugify "$name") || slug=''
          WT_SUBAGENT_AGENT_NOTE=$(wt_agent_note_block "$slug")
        fi
      fi
    fi
    if [ -n "$WT_SA_PORT" ]; then
      if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_URL:-}" ]; then
        WT_PORT=$WT_SA_PORT
        WT_SLUG=$(wt_runtime_state_get "$WT_SA_WORKTREE" slug) || WT_SLUG=''
        export WT_PORT WT_SLUG
        url=$(wt_expand_url "$PROFILE_RT_URL") || url=''
      fi
      WT_SUBAGENT_NOTE="Pitlane: this worktree is $name; its app port is $WT_SA_PORT${url:+ and URL $url} — use these, not any inherited WORKTREE_PORT/WORKTREE_URL"
      if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_SERVE:-}" ]; then
        WT_SUBAGENT_NOTE+="; start it with /pitlane-serve"
      fi
      return 0
    fi
    [ -n "$inherited" ] || return 0
    WT_SUBAGENT_NOTE="Pitlane: this worktree, $name, has no app port of its own — the WORKTREE_PORT/WORKTREE_URL this subagent inherited${parent_name:+ belong to worktree $parent_name and} do not apply here"
    return 0
  fi
  [ -n "$inherited" ] || return 0
  WT_SUBAGENT_NOTE="Pitlane: this directory is not a Pitlane worktree — the WORKTREE_PORT/WORKTREE_URL this subagent inherited${parent_name:+ belong to worktree $parent_name and} do not apply here"
}

main() {
  local here context
  wt_read_input
  wt_has_json || return 0
  here=$(wt_read_field cwd) || here=$PWD
  wt_subagent_note "$here" "${CLAUDE_PROJECT_DIR:-}"
  [ -n "$WT_SUBAGENT_NOTE$WT_SUBAGENT_AGENT_NOTE" ] || return 0
  # The Pitlane line first, then the note on lines of its own, as at start-up.
  context=$(wt_subagent_json_escape "$WT_SUBAGENT_NOTE")
  if [ -n "$WT_SUBAGENT_AGENT_NOTE" ]; then
    context+=${context:+\\n}$(wt_subagent_json_escape "$WT_SUBAGENT_AGENT_NOTE" lines)
  fi
  printf '{"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"%s"}}\n' "$context"
}

# In a subshell, so even an error `set -u` makes fatal ends there and the hook still exits 0. Nothing
# reaches stdout but the one object.
( main ) 2>/dev/null
exit 0
