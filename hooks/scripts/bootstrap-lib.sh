#!/usr/bin/env bash
# shellcheck shell=bash
#
# The bootstrap ENGINE. Sourced by bootstrap.sh, by nothing else.
#
# WHY THIS IS NOT IN lib.sh. lib.sh is the primitive layer — JSON access, repository geometry,
# slugs and placeholders, the profile — and every hook this plugin will ever ship sources it on
# the session-start path. Teardown (Phase 5) and the calibrate skill's helpers need all of that
# and none of what is in here: dependency strategies, locking, per-worktree state. Keeping the
# engine separate is the same split `detect.sh` already uses — a large consumer sitting on top of
# lib.sh, with its own test file — and it keeps a phase-sized feature out of the diff of the file
# whose byte-for-byte dual-backend behaviour 700-odd assertions pin.
#
# Everything here inherits lib.sh's three rules (docs/01-decisions.md):
#   1. No model, no network, no prompting (ADR-002).
#   2. NOTHING here calls `exit`. Functions return a code; the entrypoint decides what to skip.
#      Its contract is to always exit 0 and still print the worktree path (ADR-003).
#   3. stdout is a protocol. Every message goes to stderr via wt_log().
#
# Same portability floor as lib.sh: bash 3.2, git 2.7, POSIX tools, no jq dependency.

[ -n "${WT_BOOTSTRAP_LIB_SOURCED:-}" ] && return 0
WT_BOOTSTRAP_LIB_SOURCED=1

# Source the primitive layer rather than assuming the entrypoint did it first. Everything here
# uses wt_log, wt_is_seconds and WT_DEFAULT_TIMEOUT, and under `set -u` a wrong source order is a
# crash, not a missing function. lib.sh's own WT_LIB_SOURCED guard makes this idempotent, and
# detect.sh already does the same.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# Running a command inside the project's toolchain
# ---------------------------------------------------------------------------

# Build the argv that runs $1 inside the profile's toolchain, into WT_CMD_ARGV.
#
# Separate from wt_run_in_shell so the CONSTRUCTION can be asserted without executing anything.
# Getting this wrong does not fail loudly — `nix-shell --run composer install` reads `install` as
# a nix file to load, and `nix develop --command "composer install"` looks for a binary literally
# named "composer install" — so the argv is exactly the thing worth pinning in tests.
#
# HOW THE WRAPPER TAKES ITS COMMAND is read from the profile's `shellArgs`, NOT derived by matching
# the `shell` string. Phase 2 added that field precisely because string-matching only covers
# wrappers already on the list: a hand-written `shell` such as `docker compose run --rm app`, an
# `sh -c` wrapper, or a repo's own `./dev` script has no entry to match. The string-match below is
# the FALLBACK for a profile that omits the field, not the primary path. (This discharges the
# phase-3 task that said: honour shellArgs, or delete it from the schema.)
#
#   argv    the command follows as separate arguments:  nix develop --command bash -lc '<cmd>'
#   string  the command must be ONE argument:           nix-shell --run '<cmd>'
#
# In argv mode we interpose `bash -lc` ourselves because a profile's `install` is a command STRING
# that may legitimately contain a pipe, a redirect or a `&&`; handing its words to `--command`
# directly would exec the first word with the rest as arguments. In string mode we must NOT: the
# wrapper already hands the string to a shell, and wrapping twice would need another layer of
# quoting for no gain.
#
# THE COMMAND IS NEVER RE-SPLIT AND NEVER EVAL'D TWICE. It reaches exactly one shell, as one
# argument. That matters because `{name}`, `{worktree}` and `{root}` expand raw text into it —
# a colleague's branch name — and wt_expand substitutes without quoting. One shell means the
# profile author's own quoting is the only quoting, which is the same trust boundary a Makefile
# or a package.json `scripts` entry has (ADR-008); two would let the WORKTREE NAME, which comes
# from a different and less trusted party than the profile, start a second command.
#
# Note there is no `cd` here: the caller runs this with the worktree as its working directory.
# That is why `nix develop` needs no explicit path argument, which the phase document's sketch
# (`nix develop <worktree> --command`) added by hand.
wt_build_shell_argv() {  # $1 = command string; sets WT_CMD_ARGV
  local cmd=${1-} shell=${PROFILE_SHELL-} mode=${PROFILE_SHELLARGS-}

  WT_CMD_ARGV=()

  if [ -z "$mode" ]; then
    # No shellArgs in the profile. Match the shell string against the wrappers we know take one
    # string, and assume argv otherwise — argv is right for everything except `--run`- and
    # `-c`-shaped wrappers.
    case $shell in
      *' --run' | *' -c') mode=string ;;
      *) mode=argv ;;
    esac
  fi

  if [ -z "$shell" ]; then
    # No toolchain wrapper: the host shell, as a login shell so the user's PATH is set up.
    WT_CMD_ARGV=(bash -lc "$cmd")
    return 0
  fi

  # SC2206: word splitting is DELIBERATE and is the whole point — `shell` is a command prefix
  # ("nix develop --command"), so its words are separate argv entries. Globbing is disabled
  # around the split so a prefix containing `*` cannot expand against the worktree's contents.
  local oldglob=1
  case $- in *f*) oldglob=0 ;; esac
  set -f
  # shellcheck disable=SC2206
  WT_CMD_ARGV=($shell)
  [ "$oldglob" -eq 1 ] && set +f

  # A `shell` that is non-empty but splits to NO words — one that is all spaces or tabs, which
  # nothing in the schema forbids — would leave the array empty. Expanding an empty array under
  # `set -u` is a FATAL unbound-variable error on bash 3.2, this file's stated portability floor
  # and the stock macOS shell, and it would happen in the hook's own shell rather than a
  # subshell: the entrypoint would die before printing the worktree path, which is precisely the
  # ADR-003 failure this layer exists to prevent. Treat it as no wrapper at all.
  if [ "${#WT_CMD_ARGV[@]}" -eq 0 ]; then
    wt_log "the profile's shell is set but contains no command — running on the host shell"
    WT_CMD_ARGV=(bash -lc "$cmd")
    return 0
  fi

  if [ "$mode" = string ]; then
    WT_CMD_ARGV=("${WT_CMD_ARGV[@]}" "$cmd")
  else
    WT_CMD_ARGV=("${WT_CMD_ARGV[@]}" bash -lc "$cmd")
  fi
  return 0
}

# True if the profile's shell is a nix wrapper whose input file is missing from $1.
#
# A worktree is a fresh checkout of a branch, and a branch can genuinely not have the flake the
# profile was calibrated against. Running `nix develop` there fails with a message about the
# flake, which reads like a broken nix install rather than a missing file, so the source
# conversation's nix_run() fell back to the host shell with a warning and that behaviour is kept.
wt_nix_shell_missing() {  # $1 = directory the command will run in
  local dir=${1-} shell=${PROFILE_SHELL-}
  case $shell in
    nix\ develop*) [ ! -e "${dir%/}/flake.nix" ] ;;
    nix-shell*) [ ! -e "${dir%/}/shell.nix" ] && [ ! -e "${dir%/}/default.nix" ] ;;
    *) return 1 ;;
  esac
}

# Run $1 inside the profile's toolchain, in directory $2, with a timeout of $3 seconds.
#
# Returns the command's own exit status, or 124 when `timeout` killed it — which the caller must
# distinguish, because a killed install leaves a half-written directory and a failed one usually
# does not.
#
# It NEVER lets a failure escape as a shell error: the caller is a hook that must exit 0 whatever
# happens (ADR-003), so every path here returns a status rather than tripping `set -e`.
wt_run_in_shell() {  # $1 = command, $2 = directory, $3 = timeout seconds
  local cmd=${1-} dir=${2-} secs=${3-} rc=0 host=0

  [ -n "$cmd" ] || return 0
  if [ ! -d "$dir" ]; then
    wt_log "cannot run in $dir: no such directory"
    return 1
  fi
  wt_is_seconds "$secs" || secs=$WT_DEFAULT_TIMEOUT

  if wt_nix_shell_missing "$dir"; then
    wt_log "the profile's shell is \"$PROFILE_SHELL\" but this branch has no flake.nix/shell.nix — running on the host shell instead, which may not have the project's toolchain"
    host=1
  fi

  if [ "$host" -eq 1 ]; then
    WT_CMD_ARGV=(bash -lc "$cmd")
  else
    wt_build_shell_argv "$cmd"
  fi

  # THE CHILD'S STDOUT GOES TO STDERR. Not tidiness — stdout is a protocol: on WorktreeCreate it
  # IS the worktree path and nothing else, and on SessionStart it is injected into the model's
  # context. `composer install` and `pnpm install` both print progress, and a single such line
  # reaching stdout would break worktree creation outright. Doing it HERE rather than at each
  # call site means the guarantee does not depend on every future caller remembering `>&2`.
  #
  # stdin from /dev/null so an install that decides to prompt gets EOF and fails, instead of
  # blocking a session start that nobody is watching.
  #
  # A subshell so the `cd` cannot leak into the caller's working directory — the entrypoint's
  # later steps, and the worktree path it prints, are relative to where it started.
  #
  # `|| rc=$?` rather than a bare call followed by `rc=$?`: the latter reads the status fine here,
  # but would abort the caller outright under `set -e`, which would make this file's promise that
  # nothing escapes as a shell error true only by accident of the current entrypoint's options.
  if command -v timeout >/dev/null 2>&1; then
    ( cd "$dir" && exec timeout "$secs" "${WT_CMD_ARGV[@]}" ) </dev/null >&2 || rc=$?
  else
    # No coreutils `timeout` (a stock macOS host). Run unbounded rather than not at all, and say
    # so once: an unbounded install is a risk, but refusing to install is a certainty.
    wt_log "coreutils timeout is not on PATH — running \"$cmd\" without a time limit"
    ( cd "$dir" && exec "${WT_CMD_ARGV[@]}" ) </dev/null >&2 || rc=$?
  fi
  return $rc
}
