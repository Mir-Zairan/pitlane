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

# Field separator for the multi-value readers below. US (\037) rather than TAB because
# TAB is IFS-whitespace: bash `read` collapses runs of it and drops empty fields, which
# would shift every column as soon as one profile value is absent.
WT_US=$'\037'

# Record separator for wt_json_records. RS (\036) rather than newline, because a record
# reader delimited by newlines silently shifts every subsequent column the moment one
# value contains one — and `deps[].install` is a command string, where a line
# continuation is entirely legal. A caller cannot detect that corruption.
#
# Choosing an exotic byte is NOT on its own a guarantee, and an earlier revision of this
# comment wrongly claimed it was. JSON can encode  and  perfectly legally, and
# the profile arrives from other people's branches, so a value carrying either would inject
# a phantom field or end a record early — measured, on both backends. What actually makes
# it impossible is that both readers STRIP these bytes when rendering a value (`desep` in
# wt_json_get and wt_json_records). The separator choice then only has to survive ordinary
# text, which it does; the stripping handles the hostile case.
#
# desep also folds CR and LF to a space, and that is not tidiness — it closes a hole that
# was measured. Both readers are consumed by a LINE-delimited bash `read`, so one newline in
# an early value truncates the record and blanks every field after it. In wt_validate_profile
# that meant a single `\n` in a committed profile disabled the whole validator: every later
# check saw an empty field and passed. It also stopped a value forging an extra line on the
# one-violation-per-line output contract.
#
# SC2034: unused *within this file*. It is part of the public contract — every caller of
# wt_json_records needs it for `read -d "$WT_RS"` — so it belongs here beside WT_US
# rather than being re-declared by each consumer.
# shellcheck disable=SC2034
WT_RS=$'\036'

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
# UI renders, and a cold `python3 -c` dominates the cost. Measured on the python3 backend,
# 10 reps: reading the five profile fields with five separate calls is ~590ms; one call for
# all five is ~120ms.
#
# Paths are passed as data (jq --args, python argv) and never interpolated into the
# program text. The reference implementation in the source conversation built both the
# jq filter and the *python source* by string interpolation, so a field name containing
# a quote or a dot broke it — and its python branch printed `True` for a boolean.
#
# ensure_ascii=False so a non-ASCII object matches jq's output byte for byte.
wt_json_get() {  # $@ = dotted paths
  [ "$#" -gt 0 ] || return 1
  local _p
  for _p in "$@"; do [ -n "$_p" ] || return 1; done
  if wt_use_jq; then
    jq -rj --args --slurp '
      def val:
        if . == null then ""
        elif type == "string" then .
        elif type == "boolean" or type == "number" then tostring
        else tojson end;
      def desep: gsub("[]"; "") | gsub("[\r\n]+"; " ");
      if length != 1 then empty
      else
        .[0] as $doc
        | [ $ARGS.positional[]
            | . as $p
            | (try ($doc | getpath($p | split("."))) catch null) | val | desep ]
        | join("")
      end' -- "$@" 2>/dev/null
  else
    python3 -c "${WT_PY_LF}"'import json,re,sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)

def desep(s):
    # Newlines as well as the two separators: the bash side reads these with a
    # LINE-delimited read, so an embedded newline truncates the record and silently
    # blanks every field after it. (No backticks in this comment -- shellcheck reads
    # them as command substitution even inside the single-quoted python program.)
    return re.sub(r"[\r\n]+", " ", s.replace("\x1f", "").replace("\x1e", ""))

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
        return desep(v)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return desep(json.dumps(v, separators=(",", ":"), ensure_ascii=False))

sys.stdout.write("\x1f".join(get(p) for p in sys.argv[1:]))' "$@" 2>/dev/null
  fi
}

# Read an ARRAY of objects in one backend invocation: $1 is the dotted path to the array,
# every remaining argument is a dotted path WITHIN each element. Emits one record per
# element, fields joined by WT_US, each record terminated by WT_RS.
#
# Why this exists rather than a loop over wt_json_get: wt_json_get cannot address array
# elements at all. Measured on both backends — `deps.0.dir` returns the empty string,
# because jq's getpath() rejects a string segment on an array (the error is caught and
# becomes null) and the python branch guards with `isinstance(v, dict)`. Teaching it
# numeric segments would mean editing the one function whose byte-for-byte agreement
# across two backends is load-bearing, and whose behaviour 284 existing assertions pin.
# A separate reader that does its own traversal leaves all of that untouched.
#
# It is also the only shape that keeps the cost right. deps[] has ~6 fields per element,
# so a per-element or per-field call would be 6N cold interpreter starts on the
# session-start path, where a cold python3 already dominates (measured: 5 fields cost
# ~590ms as five calls and ~120ms as one).
#
# Value rendering is IDENTICAL to wt_json_get, deliberately duplicated rather than shared:
#   missing / null / a non-object element / a non-object on the way down -> empty string
#   true / false                                                        -> "true" / "false"
#   object / array                                                      -> compact JSON
#   an embedded US, RS, CR or LF byte                                   -> stripped, see WT_RS
#
# A field path of "." means THE ELEMENT ITSELF, which is how an array of bare strings such
# as copy[] is read — no dotted path can reach a value that is not inside an object.
#
# It carries the same three hardenings as wt_json_get, for the same measured reasons: `--`
# so an option-like path stays data, `--slurp` plus a length check so trailing junk and
# concatenated documents fail on jq exactly as they already did on python, and an empty
# path argument rejected rather than silently meaning "the whole document" on jq.
#
# Iterate it like this — note the trailing WT_RS on every record, including the last,
# which is what stops `read -d` dropping the final element:
#
#   while IFS=$WT_US read -r -d "$WT_RS" dir lock strategy; do
#     ...
#   done < <(wt_json_records deps dir lock strategy <"$profile")
#
# RETURN CONTRACT, and it matters: returns 1 only for a CALLER error — no arguments, or
# no JSON backend on PATH. Returns 0 for every DATA outcome, including "the array is
# absent", "it is not an array", and "the document does not parse at all", all of which
# produce no records. That is deliberate: jq exits non-zero on a parse error while python
# exits 0, so propagating the backend's status would make the two distinguishable, and
# every caller would then behave differently depending on which tool the machine has.
# The consequence for callers is explicit: ESTABLISH THAT THE DOCUMENT PARSES FIRST
# (wt_load_profile and wt_validate_profile both read a scalar with wt_json_get before
# they read records), because an empty record stream on its own cannot tell you whether
# the profile has no dependencies or is corrupt.
wt_json_records() {  # $1 = dotted path to the array, $@ = dotted paths within each element
  [ "$#" -ge 2 ] || return 1
  wt_has_json || return 1
  local _p
  for _p in "$@"; do [ -n "$_p" ] || return 1; done
  if wt_use_jq; then
    jq -rj --args --slurp '
      def val:
        if . == null then ""
        elif type == "string" then .
        elif type == "boolean" or type == "number" then tostring
        else tojson end;
      def desep: gsub("[]"; "") | gsub("[\r\n]+"; " ");
      if length != 1 then empty
      else
        .[0] as $doc
        | ($ARGS.positional[0] | split(".")) as $ap
        | ($ARGS.positional[1:] | map(if . == "." then null else split(".") end)) as $fps
        | (try ($doc | getpath($ap)) catch null) as $arr
        | if ($arr | type) != "array" then empty
          else
            $arr[] as $el
            | ([ $fps[] as $fp
                 | (if $fp == null then $el else (try ($el | getpath($fp)) catch null) end)
                 | val | desep ]
               | join("")) + ""
          end
      end' -- "$@" 2>/dev/null || true
  else
    python3 -c "${WT_PY_LF}"'import json,re,sys
try:
    doc = json.load(sys.stdin)
except Exception:
    sys.exit(0)

# Absent and explicitly-null both render as the empty string, exactly as wt_json_get
# does, so walk() returns None for a missing path rather than a distinct sentinel. A
# sentinel would draw a distinction nothing here can observe — mutation-testing it
# changed no assertion — and no field in the schema treats "" as meaningful.
def desep(s):
    # Newlines as well as the two separators: the bash side reads these with a
    # LINE-delimited read, so an embedded newline truncates the record and silently
    # blanks every field after it. (No backticks in this comment -- shellcheck reads
    # them as command substitution even inside the single-quoted python program.)
    return re.sub(r"[\r\n]+", " ", s.replace("\x1f", "").replace("\x1e", ""))

def walk(node, segs):
    # segs is None for the "." field, which means the element itself — needed for an array
    # of bare strings such as copy[], where no field path can reach the value.
    if segs is None:
        return node
    v = node
    for seg in segs:
        if isinstance(v, dict) and seg in v:
            v = v[seg]
        else:
            return None
    return v

def val(v):
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return desep(v)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return desep(json.dumps(v, separators=(",", ":"), ensure_ascii=False))

arr = walk(doc, sys.argv[1].split("."))
if not isinstance(arr, list):
    sys.exit(0)
# Split each field path ONCE, not once per element: deps[] has ~6 fields, so re-splitting
# inside the loop is 6N string operations for no gain.
fields = [None if f == "." else f.split(".") for f in sys.argv[2:]]
out = []
for el in arr:
    out.append("\x1f".join(val(walk(el, f)) for f in fields) + "\x1e")
sys.stdout.write("".join(out))' "$@" 2>/dev/null || true
  fi
  return 0
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

# Collect the `{token}` placeholders in $1 that wt_expand does NOT substitute, one per
# line. Returns 1 if any were found, 0 if none.
#
# This is a WARNING-level check, and the reason is worth stating because the obvious
# stricter version is wrong. wt_expand deliberately passes an unknown brace through
# verbatim so that a shell snippet containing `${FOO}` or an awk program like
# `{print $1}` survives expansion untouched — profile values are command strings, so
# those are legitimate, not mistakes. Rejecting unknown braces outright would refuse
# valid profiles, and a wrong rejection silently downgrades a working repo to bare
# defaults, which is harder to notice than a wrong acceptance is to debug.
#
# So the heuristic reports only braces that LOOK like a failed placeholder attempt: the
# token is a bare identifier, and it is not preceded by `$`. `{slugg}` and `{PORT}` are
# reported (a typo and a wrong case, both of which would otherwise put the literal text
# `demo_{slugg}` into a database name); `${FOO}` and `{print $1}` are not.
#
# The scanner mirrors wt_expand's, including its treatment of an unbalanced brace AND its
# case-dependent advance, so the two agree about what counts as a placeholder.
wt_unknown_placeholders() {  # $1 = template
  local rest=${1-} tok found='' prev=''
  while [ "${rest#*\{}" != "$rest" ]; do
    prev=${rest%%\{*}
    rest=${rest#*\{}
    # An unbalanced `{` is emitted literally by wt_expand; nothing to report.
    [ "${rest#*\}}" = "$rest" ] && break
    tok=${rest%%\}*}
    case $tok in
      name | slug | port | worktree | root) ;;
      # `${FOO}` is a shell expansion the profile author meant to keep.
      *) case $prev in
           *'$') ;;
           *) case $tok in
                # A bare identifier only. Anything with a space, a dot, a quote or a
                # sigil is a program fragment, not a botched placeholder.
                '' | *[!A-Za-z0-9_]*) ;;
                *) found="$found$tok
" ;;
              esac ;;
         esac ;;
    esac
    # Advance EXACTLY as wt_expand does, which differs by case: for a name it recognises it
    # consumes through the `}`, but for anything else it emits the brace and keeps scanning
    # from just after it. Consuming to the `}` unconditionally is NOT equivalent, and the
    # difference is observable: in `demo_{X{slugg}` wt_expand leaves `{slugg}` literal,
    # while a scanner that skipped to the first `}` saw only the fragment `X{slugg` and
    # reported nothing — missing the typo in precisely the inputs that mix a placeholder
    # with shell or awk braces.
    case $tok in
      name | slug | port | worktree | root) rest=${rest#*\}} ;;
    esac
  done
  [ -n "$found" ] || return 0
  printf '%s' "$found"
  return 1
}

# True if $1 is safe to use as a repo-relative path. Prints nothing.
#
# Rejected: an empty path, `.`, an absolute path, anything containing a `..` SEGMENT, and
# anything with a leading `~`. Note the check is on segments, not substrings — a directory
# legitimately named `..cache` or `foo..bar` is fine, and a substring test would refuse it.
#
# This runs BEFORE any existence check, and that order is the point. The profile is
# committed (ADR-008), so these paths arrive with any branch anyone pushes, and consumers
# act on them with `cp -al`, file writes and teardown deletion. Resolving first and hoping
# the result looks reasonable is how a `dir` of `../../..` ends up naming the home
# directory; refusing the shape outright cannot be talked round.
wt_is_safe_relpath() {  # $1 = candidate
  local p=${1-} seg rest
  case $p in
    '' | '.' | /* | '~'* ) return 1 ;;
  esac
  # Split on / without a subshell or bash-4 features.
  rest=$p
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    [ "$seg" = '..' ] && return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Profile
# ---------------------------------------------------------------------------

# The only schemaVersion this build understands. A profile written by a newer plugin
# warns and falls back to defaults rather than acting on fields it may misread.
WT_SCHEMA_VERSION=1

# Default for both timeouts, in seconds.
WT_DEFAULT_TIMEOUT=600

# The timeout hooks/hooks.json declares for the bootstrap hook. bootstrapSeconds and
# seedSeconds both run inside ONE invocation of it, so it is their SUM that must fit.
WT_HOOK_TIMEOUT=600

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

# The allowed values for deps[].strategy. "store" is accepted because it is a valid schema
# value, but no phase has built it — see wt_validate_profile, which warns on it.
WT_STRATEGIES='install hardlink store skip'

# Validate a profile file. Prints EVERY violation it finds, one per line, to stdout in the
# form `key: what is wrong`, and returns 1 if there were any. Warnings — things worth
# telling the developer that must not invalidate the profile — go to stderr via wt_log.
#
# TWO CALLERS, TWO SEVERITIES, ONE FUNCTION AND ONE MESSAGE TEXT:
#   the hook path (wt_load_profile) logs the violations and falls back to defaults;
#   /worktree-calibrate prints the same lines and refuses to write.
# The wording is therefore written once and never re-authored for a second audience.
#
# EVERY violation is collected before returning, not just the first. A hand-broken profile
# is usually broken in more than one place, and one-at-a-time reporting means a developer
# (or the skill) round-trips once per mistake.
#
# THE ASYMMETRY THAT SHAPES WHAT IS A VIOLATION AND WHAT IS A WARNING. Wrongly accepting
# gives a broken worktree, or feeds an unvetted command string to a hook that runs it
# unprompted. Wrongly rejecting silently downgrades a WORKING repo to bare defaults, on a
# profile that arrived with a colleague's branch, and that is harder to notice. So:
# THE RULE: a field with a safe per-field fallback WARNS. A field without one is FATAL.
#   violation — structurally wrong, or unsafe, with no way to carry on sensibly: unknown
#               schemaVersion, a strategy outside the set, a path that escapes the
#               repository, a missing lockfile a hardlink decision is keyed on, deps or
#               runtime of the wrong JSON type.
#   warning   — recoverable or merely suspicious: a bad timeout (the default is substituted
#               instead, which is safe and is already wt_load_profile's tested behaviour), a
#               `store` strategy nothing implements yet, a seed script named but absent, a
#               brace that looks like a botched placeholder.
#
# Getting that boundary wrong in either direction is expensive, and it is easy to get wrong
# by being too strict: discarding a whole profile — every dependency, the toolchain shell —
# because one timeout is mistyped degrades a WORKING repo invisibly, which is harder to
# notice than the thing it was protecting against.
#
# Costs two backend invocations (scalars, then deps records). See the note in
# docs/phases/phase-3-bootstrap.md about collapsing that to one once a real consumer exists.
#
# Never calls `exit` — it is library code, and its caller's contract is to survive
# everything (ADR-003).
wt_validate_profile() {  # $1 = profile path, $2 = repo root (for path existence)
  local file=${1-} root=${2-} raw version shell shellargs deps runtime boot seedt
  local evdet evmark n=0 bad=0 dir lock strategy install verify cksum sum recs
  local slug envvars copy cpath
  local seedp downp envfile unk tok

  [ -n "$file" ] || { printf 'profile: no path given\n'; return 1; }
  if [ ! -f "$file" ]; then
    printf 'profile: %s is not a regular file\n' "$file"
    return 1
  fi
  if [ ! -r "$file" ]; then
    printf 'profile: %s is not readable\n' "$file"
    return 1
  fi
  if ! wt_has_json; then
    # Not the profile's fault, and not something the caller can fix by editing it. Say so
    # on stderr and report no violations, so a toolless machine does not look like a repo
    # with a broken profile.
    wt_log "neither jq nor python3 is on PATH — cannot validate $file"
    return 0
  fi

  raw=$(wt_json_get schemaVersion shell shellArgs deps runtime \
        timeouts.bootstrapSeconds timeouts.seedSeconds \
        evidence.detectionVersion evidence.markers \
        runtime.seed runtime.teardown runtime.env.file \
        runtime.slug runtime.env.vars copy <"$file") || true
  if [ -z "$raw" ]; then
    # Empty output means the document did not parse as exactly one JSON value. This is the
    # check that lets the deps read below trust an empty record stream — see wt_json_records.
    printf 'profile: %s is not parseable as a single JSON document\n' "$file"
    return 1
  fi
  IFS=$WT_US read -r version shell shellargs deps runtime boot seedt \
    evdet evmark seedp downp envfile slug envvars copy <<<"$raw" || true

  # --- schemaVersion --------------------------------------------------------
  if [ -z "$version" ]; then
    printf 'schemaVersion: missing (it is mandatory)\n'
    bad=1
  elif [ "$version" != "$WT_SCHEMA_VERSION" ]; then
    printf 'schemaVersion: %s is not %s, which is the only version this plugin understands\n' \
      "$version" "$WT_SCHEMA_VERSION"
    bad=1
  fi

  # --- shell / shellArgs ----------------------------------------------------
  case $shellargs in
    '' | argv | string) ;;
    *) printf 'shellArgs: "%s" is not "argv" or "string"\n' "$shellargs"; bad=1 ;;
  esac

  # --- deps -----------------------------------------------------------------
  # `deps` renders as compact JSON, so its first byte distinguishes an array from an
  # object or a scalar. Absent is fine: a repo may genuinely have no dependencies.
  if [ -n "$deps" ]; then
    # Both ends, not just the first byte: a JSON *string* of "[not-an-array" renders as
    # `[not-an-array`, which a leading-bracket test accepts as an array. Measured.
    case $deps in
      '['*']') ;;
      *) printf 'deps: must be an array, got %s\n' "$deps"; bad=1; deps='' ;;
    esac
  fi
  if [ -n "$deps" ] && [ "$deps" != '[]' ]; then
    # Capture the records BEFORE iterating, so their absence can be distinguished from an
    # array that is genuinely empty. wt_json_records reports every data outcome as success
    # and swallows a backend failure, which is right for its own contract but wrong here:
    # if the second interpreter invocation dies after `deps` was already seen as a non-empty
    # array, an uncaptured loop simply never runs, `bad` stays 0, and every per-dep check —
    # path escapes, unknown strategies, missing install commands — is silently skipped while
    # the profile is pronounced clean. Measured with a stub that failed only the second call.
    recs=$(wt_json_records deps dir lock strategy install verify lockChecksum <"$file")
    if [ -z "$recs" ]; then
      printf 'deps: is a non-empty array but could not be read — refusing to treat it as empty\n'
      bad=1
    fi
    while IFS=$WT_US read -r -d "$WT_RS" dir lock strategy install verify cksum; do
      # Index in the SAME numbering the file uses, so a message can be acted on directly.
      case $strategy in
        '') printf 'deps[%d].strategy: missing\n' "$n"; bad=1 ;;
        install | hardlink | skip) ;;
        store)
          wt_log "deps[$n].strategy is \"store\", which is a reserved schema value that no phase implements yet — it will be treated as \"install\""
          ;;
        *)
          printf 'deps[%d].strategy: "%s" is not one of %s\n' "$n" "$strategy" \
            "$(printf '%s' "$WT_STRATEGIES" | tr ' ' '|')"
          bad=1
          ;;
      esac

      # `lock` is shape-checked for EVERY strategy, including skip. wt_profile_drifted reads
      # lock for every dep with no strategy filter and runs `cksum` on it, so a skip entry
      # with a lock of ../../../etc/passwd would turn a valid profile into a
      # file-existence-and-content oracle for paths outside the worktree — and a lock
      # pointing at /dev/zero would make that read never return, hanging the hook.
      if [ -n "$lock" ] && ! wt_is_safe_relpath "$lock"; then
        printf 'deps[%d].lock: "%s" must be a relative path inside the repository\n' "$n" "$lock"
        bad=1
        lock=''
      fi

      # A skipped dependency is not acted on, so only its path SHAPE matters.
      case $strategy in
        skip)
          if [ -n "$dir" ] && ! wt_is_safe_relpath "$dir"; then
            printf 'deps[%d].dir: "%s" must be a relative path inside the repository\n' "$n" "$dir"
            bad=1
          fi
          ;;
        *)
          if [ -z "$install" ]; then
            printf 'deps[%d].install: missing, but strategy "%s" needs a command to run\n' \
              "$n" "${strategy:-?}"
            bad=1
          fi
          if [ -z "$dir" ]; then
            printf 'deps[%d].dir: missing, but strategy "%s" needs a directory to populate\n' \
              "$n" "${strategy:-?}"
            bad=1
          elif ! wt_is_safe_relpath "$dir"; then
            printf 'deps[%d].dir: "%s" must be a relative path inside the repository\n' "$n" "$dir"
            bad=1
          fi
          if [ -z "$lock" ]; then
            printf 'deps[%d].lock: missing, but hardlink validity and drift detection are keyed on it\n' "$n"
            bad=1
          elif [ -n "$root" ] && [ ! -e "${root%/}/$lock" ]; then
            printf 'deps[%d].lock: "%s" does not exist in %s\n' "$n" "$lock" "${root%/}"
            bad=1
          fi
          ;;
      esac

      # A checksum that is present must look like `cksum` output, or drift detection would
      # compare a number against a typo and warn on every single session.
      if [ -n "$cksum" ]; then
        case $cksum in
          *[!0-9\ ]* | '') printf 'deps[%d].lockChecksum: "%s" is not cksum output\n' "$n" "$cksum"; bad=1 ;;
        esac
      fi

      for tok in "$install" "$verify" "$dir" "$lock"; do
        [ -n "$tok" ] || continue
        unk=$(wt_unknown_placeholders "$tok") || wt_log "deps[$n]: \"$tok\" contains {$(printf '%s' "$unk" | tr '\n' ' ' | sed 's/ $//')}, which is not a placeholder this plugin expands"
      done

      n=$((n + 1))
    done < <(printf '%s' "$recs")
  fi

  # --- copy[] ---------------------------------------------------------------
  # A list of repo-relative paths a later phase acts on with file operations, arriving in a
  # committed file from anyone's branch — the same threat as deps[].dir, so the same check.
  # It needs the "." identity field because its elements are bare strings, not objects.
  if [ -n "$copy" ]; then
    case $copy in
      '['*']') ;;
      *) printf 'copy: must be an array, got %s\n' "$copy"; bad=1; copy='' ;;
    esac
  fi
  if [ -n "$copy" ] && [ "$copy" != '[]' ]; then
    n=0
    while IFS=$WT_US read -r -d "$WT_RS" cpath; do
      if [ -n "$cpath" ] && ! wt_is_safe_relpath "$cpath"; then
        printf 'copy[%d]: "%s" must be a relative path inside the repository\n' "$n" "$cpath"
        bad=1
      fi
      n=$((n + 1))
    done < <(wt_json_records copy . <"$file")
    n=0
  fi

  # --- timeouts -------------------------------------------------------------
  # WARNINGS, NOT VIOLATIONS, and the distinction is the whole asymmetry in miniature.
  # `timeout 0` means NO timeout, which would turn the one guard against a hanging
  # bootstrap into an unbounded hang — so it must never be honoured. But there is a SAFE
  # per-field fallback (wt_load_profile substitutes WT_DEFAULT_TIMEOUT and says so), and it
  # is already the tested behaviour. Escalating this to a violation would discard an
  # otherwise perfect profile — losing every dependency and the toolchain shell — because
  # one number is wrong. That is the wrong-rejection failure: it degrades a WORKING repo,
  # invisibly, on a profile that arrived with someone else's branch.
  #
  # The rule this encodes: a field with a safe fallback warns; a field without one is fatal.
  if [ -n "$boot" ] && ! wt_is_seconds "$boot"; then
    wt_log "timeouts.bootstrapSeconds: \"$boot\" is not a positive whole number of seconds — the default will be used instead"
  fi
  if [ -n "$seedt" ] && ! wt_is_seconds "$seedt"; then
    wt_log "timeouts.seedSeconds: \"$seedt\" is not a positive whole number of seconds — the default will be used instead"
  fi
  # Both run inside ONE hook invocation, so it is their SUM that has to fit under the
  # hook's own timeout. Setting each to the full budget means the platform kills the hook
  # before either internal guard fires, and the warn-and-continue path never runs.
  # 10# forces base 10. wt_is_seconds accepts "08" (it strips leading zeros only for its own
  # emptiness test), and bash reads a leading zero as OCTAL: `$((08 + 120))` is a fatal
  # "value too great for base" expansion error, which under `set -e` kills the caller
  # outright — measured, and exactly what a sourced library must never do (ADR-003).
  if wt_is_seconds "$boot" && wt_is_seconds "$seedt"; then
    sum=$((10#$boot + 10#$seedt))
    if [ "$sum" -gt "$WT_HOOK_TIMEOUT" ]; then
      wt_log "timeouts.bootstrapSeconds + timeouts.seedSeconds is ${sum}s, over the ${WT_HOOK_TIMEOUT}s hook timeout in hooks/hooks.json — the platform would kill the hook before either guard fires"
    fi
  fi

  # --- runtime --------------------------------------------------------------
  # Absent means touch nothing (ADR-006) and is entirely valid, so only a PRESENT block
  # is checked.
  case $runtime in
    '' | 'false' | 'null' | '{}') ;;
    '{'*'}')
      # Repo-owned escape hatches: named by the profile, owned by the target repo. A
      # missing one is a warning, not a violation — the script may be added on a later
      # commit, and refusing the whole profile over it would take the dependencies down
      # with it.
      if [ -n "$seedp" ]; then
        if ! wt_is_safe_relpath "$seedp"; then
          printf 'runtime.seed: "%s" must be a relative path inside the repository\n' "$seedp"
          bad=1
        elif [ -n "$root" ] && [ ! -e "${root%/}/$seedp" ]; then
          wt_log "runtime.seed names $seedp, which does not exist in ${root%/} — the seed step will do nothing"
        fi
      fi
      if [ -n "$downp" ]; then
        if ! wt_is_safe_relpath "$downp"; then
          printf 'runtime.teardown: "%s" must be a relative path inside the repository\n' "$downp"
          bad=1
        elif [ -n "$root" ] && [ ! -e "${root%/}/$downp" ]; then
          wt_log "runtime.teardown names $downp, which does not exist in ${root%/} — teardown will do nothing"
        fi
      fi
      if [ -n "$envfile" ] && ! wt_is_safe_relpath "$envfile"; then
        printf 'runtime.env.file: "%s" must be a relative path inside the repository\n' "$envfile"
        bad=1
      fi
      # The runtime templates are where a botched placeholder does the most damage, and they
      # are the docstring's own motivating example: `demo_{slugg}` reaching a database name
      # writes the literal text `demo_{slugg}` instead of isolating anything. env.vars is
      # scanned as its raw compact JSON, which is enough to find a brace in any of its values.
      for tok in "$slug" "$envvars"; do
        [ -n "$tok" ] || continue
        unk=$(wt_unknown_placeholders "$tok") \
          || wt_log "runtime: \"$tok\" contains {$(printf '%s' "$unk" | tr '\n' ' ' | sed 's/ $//')}, which is not a placeholder this plugin expands"
      done
      ;;
    *) printf 'runtime: must be an object (or omitted to mean "touch nothing"), got %s\n' "$runtime"; bad=1 ;;
  esac

  # --- evidence -------------------------------------------------------------
  # Optional. It is only ever compared, never acted on, so a malformed block costs a
  # missing warning rather than a broken worktree — but say so, because silently losing
  # drift detection is exactly the kind of quiet degradation this repo dislikes.
  if [ -n "$evdet" ]; then
    case $evdet in
      *[!0-9]* | '') printf 'evidence.detectionVersion: "%s" is not a whole number\n' "$evdet"; bad=1 ;;
    esac
  fi
  if [ -n "$evmark" ]; then
    case $evmark in
      '['*) ;;
      *) printf 'evidence.markers: must be an array, got %s\n' "$evmark"; bad=1 ;;
    esac
  fi

  [ "$bad" -eq 0 ] || return 1
  return 0
}

# Report how the profile's recorded evidence differs from the checkout in front of it, one
# line per difference, returning 1 if anything drifted.
#
# NO CALL SITE IN THIS PHASE — deliberately. Phase 2 ships the evidence block, this
# comparator and its tests; docs/phases/phase-3-bootstrap.md owns wiring it into
# bootstrap.sh, where it must WARN AND NEVER BLOCK (ADR-003).
#
# It is a checksum and a string compare, never a re-detection. That is what keeps it legal
# inside a hook at all (ADR-002 forbids a hook doing discovery), and it is also the honest
# limit of the feature: reference/detection.md records that a lockfile can churn without
# anything meaningful changing, and — worse — that a hazard can appear in composer.json's
# scripts section without touching any lockfile, producing no warning exactly where one
# would matter most. It is a net for the common case, not a guarantee.
wt_profile_drifted() {  # $1 = profile path, $2 = repo root
  local file=${1-} root=${2-} n=0 drift=0 lock cksum now
  [ -f "$file" ] && [ -r "$file" ] || return 0
  [ -n "$root" ] || return 0
  wt_has_json || return 0

  while IFS=$WT_US read -r -d "$WT_RS" lock cksum; do
    n=$((n + 1))
    [ -n "$lock" ] && [ -n "$cksum" ] || continue
    # This is a PUBLIC entry point, so it re-checks the path shape rather than assuming a
    # caller validated first — otherwise a lock of ../../../etc/passwd makes this an
    # existence-and-content oracle for files outside the worktree. `-f` rather than `-e`
    # for the same reason in the other direction: a lock naming /dev/zero or a FIFO would
    # make the read below never return, hanging the session-start hook.
    if ! wt_is_safe_relpath "$lock"; then
      printf 'deps[%d].lock: "%s" is not a repo-relative path — refusing to check it\n' $((n - 1)) "$lock"
      drift=1
      continue
    fi
    if [ ! -f "${root%/}/$lock" ]; then
      printf 'deps[%d].lock: %s no longer exists, but the profile was calibrated against it\n' $((n - 1)) "$lock"
      drift=1
      continue
    fi
    now=$(cksum <"${root%/}/$lock" 2>/dev/null) || continue
    if [ "$now" != "$cksum" ]; then
      printf 'deps[%d].lock: %s has changed since calibration — the recorded install command may be for a different dependency set\n' $((n - 1)) "$lock"
      drift=1
    fi
  done < <(wt_json_records deps lock lockChecksum <"$file")

  [ "$drift" -eq 0 ] || return 1
  return 0
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
  local root=${1:-$PWD} raw version shell runtime boot seed problems

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

  # NO PARTIAL TRUST. A profile that fails validation is not used at all, even for the
  # fields that happen to be fine. Accepting four valid deps entries and silently dropping
  # a fifth broken one is the wrongly-accepts failure wearing a disguise: the worktree
  # comes up looking bootstrapped and is missing something. Bare defaults are visibly
  # incomplete, which is recoverable in five seconds; a half-bootstrapped worktree is not.
  #
  # Set WT_SKIP_VALIDATION=1 to bypass. That exists for the calibrate skill, which
  # validates explicitly with its own severity, and for a caller that has already done it —
  # not as a way to run on a profile known to be broken.
  # Say so when the gate is off. It is read from the ambient environment, and hooks launch
  # from the user's host shell — a stray `export` in a .envrc or a wrapper would otherwise
  # disable validation for every session silently.
  if [ -n "${WT_SKIP_VALIDATION:-}" ]; then
    wt_log "WT_SKIP_VALIDATION is set — $PROFILE_PATH is being used without validation"
  fi
  if [ -z "${WT_SKIP_VALIDATION:-}" ]; then
    problems=$(wt_validate_profile "$PROFILE_PATH" "$root") || {
      wt_log "$PROFILE_PATH is not valid — using defaults. Run /worktree-calibrate to rewrite it:"
      wt_log "$problems"
      return 0
    }
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
