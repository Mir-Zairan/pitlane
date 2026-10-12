#!/usr/bin/env bash
#
# `box.sh <command> [args…]`, run from inside a worktree whose profile's commands run in the Docker box:
# runs the command there exactly as a Pitlane step runs (wt_box_exec_argv) — as the developer's
# uid:gid, in the box's path of the current directory, with Pitlane's variables passed by name and
# the names the worktree's env files decide cleared — so a session's own tests, console and package
# tools see this worktree's folder and databases, not the main checkout's. SessionStart exports its
# path as PITLANE_BOX when the box is selected.
#
# A CLI, not a hook: stdin, stdout, stderr and the exit status are the command's own, and there is no
# tty. When the command cannot run in the box, ONE line on stderr says why and the status is 125,
# docker's own for "the command never started". Each argument reaches the command as one argument:
# they are quoted into the one `sh -c` string a step's command is, which the box evaluates once.
# Stopping box.sh (Ctrl-C, TERM, HUP) stops the command in the box (WT_BOX_STEP_HOST).
#
# Not `set -e`, like the hooks: the libraries test every status themselves.
set -uo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bootstrap-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bootstrap-lib.sh"

box_refuse() {  # $1 = why
  printf 'Pitlane: not run — %s.\n' "$1" >&2
  exit 125
}

# The arguments as one POSIX shell string that evaluates back to exactly them: each single-quoted,
# a quote inside one written as '\''.
box_shell_words() {  # $@ = arguments
  local arg words='' word
  for arg in "$@"; do
    word=''
    while :; do
      case $arg in
        *\'*)
          word+="${arg%%\'*}'\\''"
          arg=${arg#*\'}
          ;;
        *)
          word+=$arg
          break
          ;;
      esac
    done
    words+="${words:+ }'$word'"
  done
  printf '%s' "$words"
}

# Why wt_toolchain_is_box said no for this run, from what it decided and what it would have said.
box_not_selected_why() {
  local direct='run the command directly'
  case ${PITLANE_TOOLCHAIN:-auto} in
    shell | host)
      printf 'PITLANE_TOOLCHAIN=%s keeps the profile'"'"'s commands out of the box — %s' "$PITLANE_TOOLCHAIN" "$direct"
      return 0
      ;;
  esac
  if [ "${PROFILE_HAS_BOX:-0}" != 1 ]; then
    printf 'the profile at %s names no box — %s' "$PROFILE_PATH" "$direct"
    return 0
  fi
  if [ "$WT_BOX_DOWN" = 1 ]; then
    # shellcheck disable=SC2016  # the backquotes are the line's own
    case $WT_BOX_PROBE_WHY in
      paths) printf 'box.compose or box.envFiles names a path that is not inside the main checkout, so the box cannot be used' ;;
      slow) printf 'docker did not answer within %ss, so the box (compose service %s) cannot be reached' "$WT_BOX_PROBE_SECONDS" "$PROFILE_BOX_SERVICE" ;;
      *) printf 'the box, compose service %s, is not running — start it with `%s`, then run this again' \
           "$PROFILE_BOX_SERVICE" "$(wt_box_up_command "$PROFILE_BOX_SERVICE")" ;;
    esac
    return 0
  fi
  if wt_box_logged nodocker; then
    printf 'docker is not installed here, so the box cannot be used'
  elif wt_box_logged outside || wt_box_logged noroot; then
    printf 'this worktree is not inside its main checkout, the only part of this machine the box sees'
  elif [ -z "${PROFILE_SHELL:-}" ]; then
    printf 'the profile names no toolchain shell, so its box is used only with PITLANE_TOOLCHAIN=box — %s' "$direct"
  else
    printf 'the profile'"'"'s toolchain, %s, is installed here, so the box is not used — %s' "$WT_SHELL_PROGRAM" "$direct"
  fi
}

[ "$#" -gt 0 ] || box_refuse 'give the command to run in the box: box.sh <command> [args…]'
wt_has_json || box_refuse 'neither jq nor python3 is on PATH, so the profile cannot be read'
# From a directory under .claude/worktrees/ that is not a worktree, git answers with the main checkout.
wt_worktree_guard "$PWD" 2>/dev/null \
  || box_refuse 'run box.sh from inside a worktree under .claude/worktrees/ — this is not one'
worktree=$WT_LINKED_WORKTREE root=$WT_LINKED_ROOT
# What a step is given: the slug the runtime recorded, which the worktree's env files are named after.
WT_NAME=$(wt_name_from_path "$worktree")
WT_SLUG=$(wt_worktree_slug "$worktree" "$WT_NAME")
WT_PATH=$worktree
WT_ROOT=$root
export WT_NAME WT_SLUG WT_PATH WT_ROOT
wt_load_profile_for "$worktree" "$root" 2>/dev/null
[ "${PROFILE_PRESENT:-0}" = 1 ] \
  || box_refuse "there is no usable profile at $PROFILE_PATH, so this worktree has no box; /pitlane-setup writes one"
wt_approval_check "$worktree" 2>/dev/null
[ "${WT_APPROVAL:-}" != no ] \
  || box_refuse "this worktree's profile is not approved in its current form, so nothing runs in its box; run /pitlane-finish to review it"
wt_toolchain_is_box "$worktree" 'not running the command' 2>/dev/null \
  || box_refuse "$(box_not_selected_why)"
wt_box_exec_argv "$(box_shell_words "$@")" "$PWD" 2>/dev/null \
  || box_refuse "$PWD is outside the main checkout $root, the only part of this machine the box sees"
exec "${WT_CMD_ARGV[@]}"
