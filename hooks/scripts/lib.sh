#!/usr/bin/env bash
# shellcheck shell=bash
#
# Shared library for the worktree plugin's hooks. Sourced, never executed.
#
# Everything here obeys three rules that come from docs/01-decisions.md:
#
#   1. No model, no network, no prompting (ADR-002). This is plain bash reading a JSON
#      file that /worktree-calibrate wrote earlier.
#   2. Nothing in here ever calls `exit`. A library that exits kills its caller, and the
#      caller's contract is to always exit 0 and still print the worktree path (ADR-003).
#      Functions signal failure with a return code; the caller decides what to skip.
#   3. stdout is a protocol. Only the hook entrypoint writes to stdout, and only the
#      worktree path. Every message in here goes to stderr via wt_log().
#
# Every public name is prefixed `wt_`, matching the `hyg_` convention in the same
# author's hygiene plugin. This is not cosmetic: an unprefixed `expand()` shadows
# coreutils `expand(1)`, so any later pipeline in the hook process that filtered through
# `expand` would silently receive this function's output — on the stdout channel that
# carries the worktree path, during the window where a stray byte breaks the session.
#
# Portability floor: bash 3.2 (stock macOS /bin/bash) and git 2.7. Notably NOT used:
# ${var,,} (bash 4), associative arrays (bash 4), `git rev-parse --path-format` (2.31).
# A bad ${...} operator is a *fatal* expansion error, not a returnable failure, so a
# bash-4-only construct here would take the entrypoint down before it printed the path.
#
# Deliberately NOT set here: `set -euo pipefail`. A sourced file that changes the
# caller's shell options is a trap — the entrypoints set their own.

# Double-source guard: bootstrap.sh may source this both directly and via a helper.
[ -n "${WT_LIB_SOURCED:-}" ] && return 0
WT_LIB_SOURCED=1

# Record separator for the multi-value readers below. US (\037) rather than TAB because
# TAB is IFS-whitespace: bash `read` collapses runs of it and drops empty fields, which
# would shift every column as soon as one profile value is absent.
WT_US=$'\037'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# Every informational message, warning and error goes to stderr, prefixed so the user
# can tell which plugin is talking. stdout belongs to the worktree path alone.
#
# EVERY line is prefixed, not just the first: callers log captured command output
# (`wt_log "$(git worktree add …)"`), and an unprefixed continuation line in a session's
# startup noise reads like it came from Claude Code itself.
wt_log() {
  local line
  while IFS= read -r line; do
    printf 'worktree: %s\n' "$line" >&2
  done <<<"$*"
}

# ---------------------------------------------------------------------------
# git invocation
# ---------------------------------------------------------------------------

# git, with the ambient repository forgotten.
#
# `git -C <dir>` does NOT override an inherited GIT_DIR/GIT_WORK_TREE — those win, and
# the command silently operates on a different repository. That matters here because
# hooks launch from the user's host shell, and GIT_DIR is exported by every git hook and
# by `git rebase --exec`: a `claude` started from inside one would otherwise bootstrap
# the worktree against the wrong repo.
wt_git() {  # $1 = directory, $@ = git arguments
  local dir=$1
  shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$dir" "$@"
}

# ---------------------------------------------------------------------------
# JSON access layer — jq (fast path) OR python3 (fallback)
#
# Bash cannot parse JSON, and hooks run from the host shell where neither tool is
# guaranteed. Routing every read through here means the plugin works on any machine
# with EITHER — which is not hypothetical: the machine this was developed on has
# python3 and no jq at all.
#
# Both branches must return byte-identical results, so both are exercised by
# tests/test_lib.sh. WT_JSON_BACKEND=python3 forces the python3 branch even where jq
# exists, so the fallback cannot silently rot on a jq machine.
#
# Known and accepted divergence: numbers in exponent notation (`1e3` -> jq `1E+3`,
# python `1000.0`) and `1e400` (`1E+400` vs `inf`). No field in the profile schema is
# specified as a float, let alone an exponent, so this is documented rather than fixed.
# ---------------------------------------------------------------------------

# True if any supported JSON backend is available. Callers that find neither must
# degrade to defaults, never fail — a missing dependency of ours is not the user's
# problem to have their session broken by.
wt_has_json() { command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; }

# Backend selector. See WT_JSON_BACKEND above.
wt_use_jq() { [ "${WT_JSON_BACKEND:-}" != "python3" ] && command -v jq >/dev/null 2>&1; }

# Preamble for every inline python3 script.
#
# newline="\n": a native Windows python writes CRLF, which leaves a trailing \r on any
# value consumed by a bash `read` loop (command substitution strips it, `read` does not).
#
# stdin as utf-8-sig: a profile saved with a UTF-8 BOM is accepted by jq, so python must
# accept it too. Without this the two backends disagree about whether the profile exists
# at all — and since the profile is committed (ADR-008), one teammate would get the full
# toolchain and another bare defaults from the same file.
#
# try/except keeps ancient pythons harmless.
WT_PY_LF='import sys
try:
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stdin.reconfigure(encoding="utf-8-sig")
except Exception:
    pass
'

# Core reader: JSON on stdin, one or more dotted paths as arguments, the values joined
# by WT_US on a single line of stdout.
#
#   missing / null / a non-object on the way down -> empty string
#   true / false                                  -> "true" / "false", never python's True/False
#   object / array                                -> compact JSON, so a caller can test presence
#
# One invocation for N fields on purpose: this runs on the session-start path before the
# UI renders, and a cold `python3 -c` is ~150-200ms. Reading a five-field profile with
# five calls measured ~1s; one call is ~0.2s.
#
# Paths are passed as data (jq --args, python argv) and never interpolated into the
# program text. The reference implementation in the source conversation built both the
# jq filter and the *python source* by string interpolation, so a field name containing
# a quote or a dot broke it — and its python branch printed `True` for a boolean.
#
# ensure_ascii=False so a non-ASCII object matches jq's output byte for byte.
wt_json_get() {  # $@ = dotted paths
  [ "$#" -gt 0 ] || return 1
  if wt_use_jq; then
    jq -rj --args '
      def val:
        if . == null then ""
        elif type == "string" then .
        elif type == "boolean" or type == "number" then tostring
        else tojson end;
      . as $doc
      | [ $ARGS.positional[]
          | . as $p
          | (try ($doc | getpath($p | split("."))) catch null) | val ]
      | join("")' "$@" 2>/dev/null
  else
    python3 -c "${WT_PY_LF}"'import json,sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def get(path):
    v = doc
    for seg in path.split("."):
        if isinstance(v, dict) and seg in v:
            v = v[seg]
        else:
            return ""
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return json.dumps(v, separators=(",", ":"), ensure_ascii=False)

sys.stdout.write("\x1f".join(get(p) for p in sys.argv[1:]))' "$@" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Hook payload
# ---------------------------------------------------------------------------

# Read the hook payload from stdin ONCE into HOOK_INPUT.
#
# stdin is a pipe: a second `cat` returns nothing, so every field read must come out of
# a variable rather than out of stdin again.
#
# The `-t 0` guard is not decoration. `cat` returns on EOF, not on "nothing available",
# so on a terminal — a developer running the hook by hand, or a child process that
# inherited the tty — an unguarded read blocks forever and the session never starts.
# Measured: with the guard a pty run returns immediately; without it, it hangs.
#
# What the guard does NOT cover, measured and accepted: a non-tty pipe that is open but
# never written to and never closed still blocks (`< <(sleep 20)` times out). Claude Code
# writes the payload and closes, so that case needs a caller doing something unusual; a
# `read -t` would risk truncating a large payload, which is worse.
#
# HOOK_INPUT and the guard are exported so a helper subprocess that sources this library
# inherits the payload instead of blocking on a pipe its parent already drained.
wt_read_input() {
  [ -n "${WT_INPUT_READ:-}" ] && return 0
  export WT_INPUT_READ=1
  if [ -t 0 ]; then
    export HOOK_INPUT=''
  else
    HOOK_INPUT=$(cat 2>/dev/null || true)
    export HOOK_INPUT
  fi
  return 0
}

# A field from the hook payload. `wt_read_field name`, `wt_read_field tool_input.file_path`.
# Second argument overrides the JSON text (used by the tests).
#
# Returns 1 and prints nothing when the field is absent OR is the empty string. Phase 2
# will need a presence-vs-value accessor for any field where "" is meaningful; no field
# in the current schema is.
wt_read_field() {  # $1 = dotted path, $2 = JSON text (default: $HOOK_INPUT)
  local json=${2-${HOOK_INPUT-}} out
  [ -n "${1:-}" ] || return 1
  [ -n "$json" ] || return 1
  wt_has_json || return 1
  out=$(printf '%s' "$json" | wt_json_get "$1") || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# A field from a JSON *file*, same path syntax and same empty-is-absent rule.
wt_read_file_field() {  # $1 = file, $2 = dotted path
  local out
  [ -n "${2:-}" ] || return 1
  [ -f "$1" ] && [ -r "$1" ] || return 1
  wt_has_json || return 1
  out=$(wt_json_get "$2" <"$1") || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Repository geometry
# ---------------------------------------------------------------------------

# Root of the working tree containing $1 (default: $PWD).
#
# Note this is the *containing* working tree: called from inside a worktree it returns
# the worktree, not the main checkout. That is what {worktree} wants; {root} wants
# wt_main_root() below.
wt_repo_root() {  # $1 = directory (default: $PWD)
  local dir=${1:-$PWD} out
  [ -d "$dir" ] || return 1
  # `|| return 1` so the contract is one failure code, not git's 128 for "not a repo"
  # and 1 for everything else.
  out=$(wt_git "$dir" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Root of the MAIN checkout, even when called from inside a linked worktree.
#
# Phase 3 computes hardlink stores and relative symlinks from {root}, and Claude Code
# puts worktrees at <root>/.claude/worktrees/<name>, so a wrong answer here writes
# dependency trees into the wrong directory. Two plausible one-liners are both wrong:
#
#   * `rev-parse --git-common-dir` with a trailing `/.git` stripped. For a submodule the
#     common dir is <super>/.git/modules/<name>, and for a --separate-git-dir repo it is
#     an arbitrary directory, so the strip silently no-ops and returns a path INSIDE the
#     git directory with a success code. Measured, both cases. It also needs git 2.31
#     for --path-format=absolute; Ubuntu 20.04 ships 2.25.
#   * the first entry of `git worktree list --porcelain`. Documented as the main working
#     tree, and it is — except for a --separate-git-dir repo, where git 2.34 reports the
#     *git dir* (measured: `worktree /tmp/sepgit` for a checkout at /tmp/sep).
#
# So: whether we are in the main working tree at all is decided by comparing the
# per-worktree git dir with the shared one — equal means main — and in that case
# --show-toplevel is already the answer, for a plain repo, a submodule and a
# --separate-git-dir repo alike. Only a linked worktree needs deriving, and there the
# common dir genuinely is <root>/.git for every layout except --separate-git-dir.
#
# For a linked worktree of a --separate-git-dir repository there is no correct answer to
# return: git itself does not record where the main checkout lives (its own `worktree
# list` names the git dir). This returns 1 and warns rather than handing back a path
# inside the git directory — a caller that skips a step is recoverable, one that
# hardlinks 400MB into .git is not.
#
# Both paths are resolved with `cd ... && pwd -P` rather than --path-format, to keep the
# git floor at 2.5. Note that resolves symlinks, so a checkout reached through a symlink
# is reported by its real path.
wt_main_root() {  # $1 = directory (default: $PWD)
  local dir=${1:-$PWD} gitdir common
  [ -d "$dir" ] || return 1
  gitdir=$(wt_git "$dir" rev-parse --git-dir 2>/dev/null) || return 1
  common=$(wt_git "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  # Both may be relative to $dir; resolve without needing git 2.31.
  gitdir=$(cd "$dir" && cd "$gitdir" 2>/dev/null && pwd -P) || return 1
  common=$(cd "$dir" && cd "$common" 2>/dev/null && pwd -P) || return 1

  if [ "$gitdir" = "$common" ]; then
    wt_repo_root "$dir"   # main working tree; also fails cleanly on a bare repo
    return
  fi

  case $common in
    */.git) printf '%s' "${common%/.git}" ;;
    *)
      wt_log "cannot locate the main checkout for the worktree at $dir: its shared git dir is $common, not <root>/.git (a --separate-git-dir repository, which git does not record the main checkout of)"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Slugs and placeholders
# ---------------------------------------------------------------------------

# A worktree name reduced to something safe to embed in a database name, an env var
# value or a filename: lowercased, every run of characters outside [a-z0-9_] collapsed
# to a single _, and leading/trailing _ trimmed.
#
#   colleague/QT-999  ->  colleague_qt_999
#   feature/AB--12    ->  feature_ab_12
#
# `tr` rather than bash's ${s,,} because ${s,,} is bash 4.0+ and stock macOS ships 3.2,
# where it is a fatal expansion error that would take the whole hook down. LC_ALL=C keeps
# the ranges ASCII, so a non-ASCII name degrades to _ instead of depending on collation.
#
# The slug keys a database name and a port derived as base + crc32(slug) % span, so it
# must be stable for a given name and — just as important — DISTINCT for distinct names.
# A name made only of separators (or entirely non-ASCII, e.g. a colleague's branch in
# Japanese) would otherwise slug to the empty string, and every such worktree would land
# on one shared database and one shared port. Those fall back to a checksum of the raw
# name instead: still deterministic across runs and machines, but still distinct.
wt_slugify() {  # $1 = worktree name
  local s ck
  s=$(printf '%s' "${1-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  s=${s//[!a-z0-9_]/_}
  while [ "${s//__/_}" != "$s" ]; do s=${s//__/_}; done
  s=${s#_}
  s=${s%_}
  if [ -z "$s" ]; then
    ck=$(printf '%s' "${1-}" | cksum) || return 1
    s="wt_${ck%% *}"
  fi
  printf '%s' "$s"
}

# Substitute the profile placeholders in $1 from the WT_* environment:
#
#   {name} -> $WT_NAME   {slug} -> $WT_SLUG   {port} -> $WT_PORT
#   {worktree} -> $WT_PATH   {root} -> $WT_ROOT
#
# Unknown placeholders and unbalanced braces pass through verbatim, so a shell snippet
# containing `${FOO}` or an awk program survives expansion untouched.
#
# Single-pass left-to-right by design, and substituted values are never rescanned: a
# worktree literally named "{root}" expands to the string "{root}", not to the repo
# path. A naive chain of ${s//\{name\}/...} substitutions would rescan and let a
# worktree name inject a later placeholder.
#
# SUBSTITUTION IS NOT QUOTING. {slug} and {port} are constrained by construction
# ([a-z0-9_] and digits), but {name}, {worktree} and {root} are raw text that can come
# from a colleague's branch name — `{name}` expanding inside a command string turns
# `q; rm -rf x` into two commands. A caller placing an unconstrained placeholder in
# command position must quote it itself; Phase 3 owns that.
wt_expand() {  # $1 = template
  local rest=${1-} out='' pre tok
  while [ "${rest#*\{}" != "$rest" ]; do
    pre=${rest%%\{*}
    rest=${rest#*\{}
    out+=$pre
    if [ "${rest#*\}}" = "$rest" ]; then   # a { with no closing }
      out+='{'
      break
    fi
    tok=${rest%%\}*}
    case $tok in
      name)     out+=${WT_NAME-};  rest=${rest#*\}} ;;
      slug)     out+=${WT_SLUG-};  rest=${rest#*\}} ;;
      port)     out+=${WT_PORT-};  rest=${rest#*\}} ;;
      worktree) out+=${WT_PATH-};  rest=${rest#*\}} ;;
      root)     out+=${WT_ROOT-};  rest=${rest#*\}} ;;
      *)        out+='{' ;;                # not ours — emit the brace, keep scanning
    esac
  done
  printf '%s' "$out$rest"
}

# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------

# The only schemaVersion this build understands. A profile written by a newer plugin
# warns and falls back to defaults rather than acting on fields it may misread.
WT_SCHEMA_VERSION=1

# Default for both timeouts, in seconds.
WT_DEFAULT_TIMEOUT=600

# True if $1 is a positive whole number of seconds.
#
# A timeout is taken from a file that ADR-008 says is committed, so it arrives with
# other people's branches. `timeout 0` means *no timeout at all*, which would turn the
# one guard against a hanging bootstrap into an unbounded hang — the exact way ADR-003
# says a user must never lose a session. Anything non-numeric makes `timeout` exit 125,
# which a consumer would misread as "the bootstrap failed".
wt_is_seconds() {  # $1 = candidate
  local n=${1-}
  case $n in
    '' | *[!0-9]*) return 1 ;;
  esac
  while [ "${n#0}" != "$n" ]; do n=${n#0}; done   # strip leading zeros
  [ -n "$n" ]                                      # "0" and "000" strip to empty
}

# Load .claude/worktree-profile.json from $1 (default: $PWD) into PROFILE_* variables,
# falling back to safe defaults when it is absent, unreadable, unparseable, or a version
# we don't know. Always returns 0 — a missing profile is a normal state, not an error,
# and ADR-002 forbids the hook from going and detecting anything itself.
#
# Sets:
#   PROFILE_PATH            where it looked
#   PROFILE_PRESENT         1 if a usable profile was loaded, else 0
#   PROFILE_SCHEMA_VERSION  as read, or empty
#   PROFILE_SHELL           toolchain wrapper, e.g. "nix develop --command"; "" = host shell
#   PROFILE_HAS_RUNTIME     1 if a runtime block exists (ADR-006: absent means touch nothing)
#   PROFILE_BOOTSTRAP_TIMEOUT / PROFILE_SEED_TIMEOUT   seconds, validated
#
# Phase 1 reads scalars only. The deps[] and runtime{} bodies are Phase 2's schema and
# Phase 3's consumers; this is the stub loader those phases grow.
#
# SC2034: every PROFILE_* assignment below looks unused to shellcheck because they ARE
# this function's return value — the callers that read them live in other files.
# shellcheck disable=SC2034
wt_load_profile() {  # $1 = repo root (default: $PWD)
  local root=${1:-$PWD} raw version shell runtime boot seed

  PROFILE_PATH="${root%/}/.claude/worktree-profile.json"
  PROFILE_PRESENT=0
  PROFILE_SCHEMA_VERSION=''
  PROFILE_SHELL=''
  PROFILE_HAS_RUNTIME=0
  PROFILE_BOOTSTRAP_TIMEOUT=$WT_DEFAULT_TIMEOUT
  PROFILE_SEED_TIMEOUT=$WT_DEFAULT_TIMEOUT

  [ -e "$PROFILE_PATH" ] || return 0

  if [ ! -f "$PROFILE_PATH" ]; then
    wt_log "$PROFILE_PATH is not a regular file — using defaults"
    return 0
  fi
  if [ ! -r "$PROFILE_PATH" ]; then
    wt_log "$PROFILE_PATH is not readable — using defaults"
    return 0
  fi
  if ! wt_has_json; then
    wt_log "neither jq nor python3 is on PATH — ignoring $PROFILE_PATH and using defaults"
    return 0
  fi

  # One backend invocation for every field; see wt_json_get.
  raw=$(wt_json_get schemaVersion shell runtime timeouts.bootstrapSeconds timeouts.seedSeconds \
        <"$PROFILE_PATH")
  if [ -z "$raw" ]; then
    wt_log "$PROFILE_PATH could not be parsed as JSON — using defaults"
    return 0
  fi
  # `|| true` because a short record makes `read` return 1, which would abort a caller
  # running under `set -e`. Assumes no profile value contains a newline or a US byte.
  IFS=$WT_US read -r version shell runtime boot seed <<<"$raw" || true

  if [ -z "$version" ]; then
    wt_log "$PROFILE_PATH has no schemaVersion — ignoring it and using defaults"
    return 0
  fi
  PROFILE_SCHEMA_VERSION=$version

  if [ "$version" != "$WT_SCHEMA_VERSION" ]; then
    wt_log "$PROFILE_PATH is schemaVersion $version, this plugin understands $WT_SCHEMA_VERSION — using defaults"
    return 0
  fi

  PROFILE_PRESENT=1
  PROFILE_SHELL=$shell

  # An explicit `false` or an empty block means the same as absent: touch nothing (ADR-006).
  case $runtime in
    '' | 'false' | 'null' | '{}') PROFILE_HAS_RUNTIME=0 ;;
    *) PROFILE_HAS_RUNTIME=1 ;;
  esac

  if [ -n "$boot" ]; then
    if wt_is_seconds "$boot"; then
      PROFILE_BOOTSTRAP_TIMEOUT=$boot
    else
      wt_log "timeouts.bootstrapSeconds is \"$boot\", not a positive number of seconds — using $WT_DEFAULT_TIMEOUT"
    fi
  fi
  if [ -n "$seed" ]; then
    if wt_is_seconds "$seed"; then
      PROFILE_SEED_TIMEOUT=$seed
    else
      wt_log "timeouts.seedSeconds is \"$seed\", not a positive number of seconds — using $WT_DEFAULT_TIMEOUT"
    fi
  fi
  return 0
}
