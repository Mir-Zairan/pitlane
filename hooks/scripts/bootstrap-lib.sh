#!/usr/bin/env bash
# shellcheck shell=bash
#
# The bootstrap ENGINE. Sourced by bootstrap.sh, and by teardown-lib.sh for the state, ledger and
# profile readers teardown shares with it.
#
# WHY THIS IS NOT IN lib.sh. lib.sh is the primitive layer — JSON access, repository geometry,
# slugs and placeholders, the profile — and every hook this plugin will ever ship sources it on
# the session-start path. The calibrate skill's helpers need all of that and none of what is in
# here: dependency strategies, locking, per-worktree state. Teardown needs the state and ledger
# readers too, which is why it sources this file rather than lib.sh alone. Keeping the
# engine separate is the same split `detect.sh` already uses — a large consumer sitting on top of
# lib.sh, with its own test file — and it keeps a whole feature out of the diff of the file
# whose byte-for-byte dual-backend behaviour 700-odd assertions pin.
#
# Everything here inherits lib.sh's three rules:
#   1. No model, no network, no prompting.
#   2. NOTHING here calls `exit`. Functions return a code; the entrypoint decides what to skip.
#      Its contract is to always exit 0 and still print the worktree path.
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
# Which worktree, which profile
# ---------------------------------------------------------------------------
#
# Here rather than in the entrypoint because teardown and prune must answer both questions exactly
# as bootstrap did: a second copy that drifted would tear a worktree down under a different profile,
# or a different name, from the one it was set up with.

# Where Claude Code puts worktrees. Used to tell "this session is in a worktree" from
# "this session is in the main checkout", which is how the SessionStart path stays inert
# for ordinary sessions.
# SC2034: read by the entrypoints that source this file.
# shellcheck disable=SC2034
WT_SUBPATH='/.claude/worktrees/'

# The name of the worktree at $1, for a worktree whose name arrived with no payload: SessionStart
# carries none, and teardown or prune may have no ledger entry recording it.
#
# NOT the basename. A nested name lands at `.claude/worktrees/alice/fix-99/`, so the basename of
# `alice/fix-99` and of `bob/fix-99` is `fix-99` for both: one slug, one derived port, and — the
# part that matters — ONE DATABASE for two worktrees that each believe they are isolated. That is
# exactly the data loss the runtime layer exists to prevent, arriving through the name it is keyed
# on.
#
# The path RELATIVE to the worktrees directory is right for both layouts: nested gives
# `alice/fix-99`, and the flattened form the WorktreeCreate branch produces gives `alice-fix-99`.
# wt_slugify maps both to `alice_fix_99`, so a worktree keeps one identity however it was created.
# A path not under the worktrees directory at all falls back to its basename rather than using the
# whole absolute path as a name. (A worktree DIRECTLY in the worktrees directory strips fine.)
wt_name_from_path() {  # $1 = worktree path
  local wt=${1-} name
  name=${wt##*"$WT_SUBPATH"}
  [ "$name" != "$wt" ] || name=${wt##*/}
  printf '%s' "$name"
}

# The profile is committed, so a branch that adds a dependency also updates it.
# The worktree's own checked-out copy therefore wins over the main checkout's — otherwise
# a worktree gets bootstrapped from whatever main happens to have, while bootstrap reads its
# *lockfiles* from the worktree, and the two disagree.
#
# WHICH copy is loaded is NOT what makes its commands safe to run — the branch wrote it, and the
# branch may be a stranger's pull request. That is the approval gate's job, below: whatever this
# loads, nothing it names is executed until the developer has approved that exact content.
wt_load_profile_for() {  # $1 = worktree, $2 = main checkout
  local which=$1
  [ -f "$1/.claude/worktree-profile.json" ] || which=$2
  wt_load_profile "$which"
  # Not decided yet: wt_approval_check decides once the files it fingerprints are in place.
  WT_APPROVAL=''
  WT_APPROVAL_FP=''
}

# ---------------------------------------------------------------------------
# Approval: nothing the profile names runs until the developer approves that content
# ---------------------------------------------------------------------------
#
# THE THREAT. A worktree's profile and its seed and teardown scripts come from the branch checked
# out in it, and a hook runs them unprompted. For `claude -w "#1234"` that branch is a pull request:
# anyone who can open one would otherwise choose a command that runs as the reviewer, before the
# reviewer has read a line of the diff. Preferring the main checkout's profile does not close it —
# the scripts the profile names are still the branch's files.
#
# THE RULE, the one `direnv allow` uses: the profile's commands run only when its CONTENT — the
# profile itself plus the seed and teardown scripts it names, as they are in the directory they
# would run in — matches a fingerprint the developer approved. Any edit to any of them, by anyone,
# needs approving again. Approval is by content, not by path or branch, so approving a profile once
# covers every worktree that carries the same bytes, and a branch that changes nothing executable
# never asks.
#
# THE RECORD lives in the repository's shared git directory, which no branch can write: a commit
# carries files, never `.git/`. One SHA-256 per line. `cksum` will not do here, as it does for drift:
# CRC is not collision-resistant, and the whole point is that a stranger cannot forge a match.
#
# WHAT THIS DOES NOT COVER, stated so nobody reads more into it: an approved install command still
# runs whatever the branch's own manifests tell the package manager to (composer and npm lifecycle
# scripts), and an approved `shell` still evaluates the branch's toolchain definition (a flake's
# shellHook, a compose file). Installing a branch's dependencies is running its code; the gate only
# guarantees that the commands Pitlane itself starts are ones the developer saw. That is why a
# pull-request worktree's approval also covers its commit (wt_is_pr_worktree): the developer approves
# a stranger's push knowingly, rather than inheriting the approval of their own profile. A PR reached
# some other way — a same-repository branch a colleague pushed, checked out under any other name — is
# treated as the developer's own branch.
#
# PITLANE_TRUST_PROFILES=1 turns the gate off, for a developer who only ever opens their own
# branches. It is read from the environment, which no branch controls.

WT_APPROVALS_FILENAME=pitlane-approved
WT_APPROVAL_FORMAT='pitlane-approval 1'
# yes | no | '' (not decided). Only `no` stops anything: callers that never load a profile
# (the unit tests, the calibrate helpers) are not gated, and every hook path decides before it runs.
WT_APPROVAL=''
WT_APPROVAL_FP=''
# The status wt_run_in_shell returns when the gate stops a command. 126 is the shell's own "found
# but cannot execute", which every caller already treats as a failure that is not a timeout.
WT_UNAPPROVED=126

# SHA-256, as 64 lowercase hex characters, of the file $1 — or of stdin with no argument. Whichever
# tool the host has: coreutils, the BSD/macOS `shasum`, openssl, or python3. None is POSIX, so each is
# tried in turn until one gives a well-formed digest; a tool that is present but broken (a shim, a
# perl without Digest::SHA) falls through to the next rather than failing the gate closed. stdin is
# spooled to a temporary file first, since only a file can be read once per attempt. Fails, printing
# nothing, when none works.
wt_sha256() {  # $1 = file (default: stdin)
  local file=${1-} tmp='' out='' tool
  if [ -z "$file" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/pitlane-sha.XXXXXX" 2>/dev/null) || return 1
    cat >"$tmp" || { rm -f "$tmp"; return 1; }
    file=$tmp
  fi
  for tool in sha256sum shasum openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || continue
    case $tool in
      sha256sum) out=$(sha256sum <"$file" 2>/dev/null) || out='' ;;
      shasum) out=$(shasum -a 256 <"$file" 2>/dev/null) || out='' ;;
      openssl) out=$(openssl dgst -sha256 -r <"$file" 2>/dev/null) || out='' ;;
      python3) out=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' <"$file" 2>/dev/null) || out='' ;;
    esac
    out=${out%%[!0-9a-fA-F]*}
    [ "${#out}" -eq 64 ] && break
    out=''
  done
  [ -n "$tmp" ] && rm -f "$tmp"
  [ -n "$out" ] || return 1
  printf '%s' "$out" | tr 'A-F' 'a-f'
}

# $1 with every byte outside printable ASCII shown as `?`. For text a branch wrote that is about to
# be shown to a human or a model: a carriage return or an escape sequence in an install command could
# make the review screen show one command while another runs, and a newline could forge a line of
# the record. NOT just [:cntrl:]: that misses the Unicode bidi overrides and zero-width characters a
# UTF-8 terminal renders (the Trojan Source reordering), and C1 controls some terminals act on.
wt_visible() {  # $1 = text
  printf '%s' "${1-}" | LC_ALL=C tr -c ' -~' '?'
}

# True when $1 is a pull-request worktree: named `pr-<digits>`, the kind `claude -w "#1234"` makes, or
# on a branch whose upstream is a pull-request ref — what `gh pr checkout` records for a fork's PR, in
# the shared git config no branch can write. For those, the approval is bound to the commit as well as
# the content. An approved install runs
# the branch's own manifests (package lifecycle scripts) and an approved `shell` evaluates its
# toolchain files, so a stranger's PR that leaves the profile alone would otherwise inherit the
# approval the developer gave their own profile, and run its code anyway.
wt_is_pr_worktree() {  # $1 = run directory
  local name digits
  local branch merge
  case "${1%/}/" in
    *"$WT_SUBPATH"*) ;;
    *) return 1 ;;
  esac
  name=$(wt_name_from_path "${1%/}")
  case $name in
    pr-*)
      digits=${name#pr-}
      case $digits in
        '' | *[!0-9]*) ;;
        *) return 0 ;;
      esac
      ;;
  esac
  branch=$(wt_git "$1" symbolic-ref -q --short HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] || return 1
  merge=$(wt_git "$1" config --get "branch.$branch.merge" 2>/dev/null) || return 1
  case $merge in
    refs/pull/*) return 0 ;;
  esac
  return 1
}

# One line of the fingerprint's manifest for a script the profile names, as it is in $1.
wt_approval_script_line() {  # $1 = run directory, $2 = label, $3 = relative path or empty
  local dir=${1%/} label=$2 rel=${3-} sum
  if [ -z "$rel" ]; then
    printf '%s -\n' "$label"
  elif [ -f "$dir/$rel" ] && [ -r "$dir/$rel" ]; then
    sum=$(wt_sha256 "$dir/$rel") || return 1
    printf '%s %s %s\n' "$label" "$rel" "$sum"
  else
    printf '%s %s absent\n' "$label" "$rel"
  fi
}

# The fingerprint of everything executable the loaded profile names, as it would run in $1.
# The profile counts by content alone — the main checkout's copy and a worktree's identical one are
# one approval — and each script by its path and content. A script that is not there yet is
# recorded as absent, so the approval does not silently extend to whatever arrives later. A
# pull-request worktree's fingerprint also carries its commit (wt_is_pr_worktree says why), so each
# push to the PR is approved on its own.
wt_approval_fingerprint() {  # $1 = run directory
  local dir=${1%/} manifest psum head
  psum=$(wt_sha256 "$PROFILE_PATH") || return 1
  manifest="$WT_APPROVAL_FORMAT${WT_NL}profile $psum$WT_NL"
  manifest=$manifest$(wt_approval_script_line "$dir" seed "${PROFILE_RT_SEED:-}") || return 1
  manifest=$manifest$WT_NL$(wt_approval_script_line "$dir" teardown "${PROFILE_RT_TEARDOWN:-}") || return 1
  if wt_is_pr_worktree "$dir"; then
    head=$(wt_git "$dir" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
    [ -n "$head" ] || return 1
    manifest="$manifest${WT_NL}commit $head"
  fi
  printf '%s\n' "$manifest" | wt_sha256
}

# True when what WT_APPROVAL_FP approved is still what is on disk in $1. For the scripts, which are
# read from disk when they run: a background run fingerprints before its installs and seeds minutes
# later, and a `git pull` in the live session meanwhile must not run an unapproved script on a stale
# answer. Nothing to compare (the gate is off, or the profile runs nothing) is still approved.
wt_approval_still() {  # $1 = run directory
  local now
  [ "${WT_APPROVAL:-}" = no ] && return 1
  [ -n "${WT_APPROVAL_FP:-}" ] || return 0
  now=$(wt_approval_fingerprint "$1") || return 1
  [ "$now" = "$WT_APPROVAL_FP" ]
}

# True when the loaded profile names anything that would be executed: an install or verify
# command, a seed or a teardown script, a serve or stop command. `shell` alone runs nothing — it only
# wraps those. A profile that runs nothing (config copies, hardlinks, ports, env overrides, a URL)
# needs no approval.
wt_profile_runs_commands() {
  local rec body dir lock strategy install verify _cksum
  [ "${PROFILE_PRESENT:-0}" = 1 ] || return 1
  if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && { [ -n "${PROFILE_RT_SEED:-}" ] || [ -n "${PROFILE_RT_TEARDOWN:-}" ] \
    || [ -n "${PROFILE_RT_SERVE:-}" ] || [ -n "${PROFILE_RT_STOP:-}" ]; }; then
    return 0
  fi
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    IFS=$WT_US read -r dir lock strategy install verify _cksum <<<"$body" || true
    [ "$strategy" = skip ] && continue
    { [ -n "$install" ] || [ -n "$verify" ]; } && return 0
  done < <(printf '%s' "${PROFILE_RAW:-}")
  return 1
}

# Where the approved fingerprints are kept: the shared git directory, as seen from $1.
wt_approvals_path() {  # $1 = any directory inside the repository
  local common
  common=$(wt_git_common_dir "${1:-$PWD}") || return 1
  printf '%s/%s' "$common" "$WT_APPROVALS_FILENAME"
}

# True when the record $2 lists fingerprint $1. The first field of a line is the fingerprint; the
# rest (when, and which profile) is for a human reading the file.
wt_approval_known() {  # $1 = fingerprint, $2 = record file
  [ -n "${1-}" ] && [ -f "${2-}" ] || return 1
  awk -v f="$1" '$1 == f { found = 1 } END { exit !found }' "$2" 2>/dev/null
}

# Decide whether the loaded profile's commands may run in $1, into WT_APPROVAL (yes/no) and
# WT_APPROVAL_FP. Called once the files it fingerprints are in place — after the config copy, which
# is what brings a personal profile's scripts into a worktree. Says why on stderr when the answer is
# no; never fails.
wt_approval_check() {  # $1 = directory the profile's commands run in
  local dir=${1%/} store
  WT_APPROVAL=yes
  WT_APPROVAL_FP=''
  wt_profile_runs_commands || return 0
  case ${PITLANE_TRUST_PROFILES:-} in
    1 | yes | on | true) return 0 ;;
  esac
  if ! WT_APPROVAL_FP=$(wt_approval_fingerprint "$dir"); then
    WT_APPROVAL=no
    WT_APPROVAL_FP=''
    wt_log "approval: cannot fingerprint $PROFILE_PATH (no sha256sum, shasum, openssl or python3 worked) — none of its commands will run"
    return 0
  fi
  if store=$(wt_approvals_path "$dir") && wt_approval_known "$WT_APPROVAL_FP" "$store"; then
    return 0
  fi
  WT_APPROVAL=no
  wt_log "approval: the commands in $PROFILE_PATH (and the seed and teardown scripts it names) are not approved in this form — none of them will run. To see what they are, run \`bash \"${WT_BOOTSTRAP_SCRIPT:-bootstrap.sh}\" --review\` in $dir"
  return 0
}

# Record $1 as approved for the repository $2 is in. Idempotent.
wt_approval_record() {  # $1 = fingerprint, $2 = any directory inside the repository
  local fp=${1-} store when
  case $fp in
    *[!0-9a-f]* | '') return 1 ;;
  esac
  [ "${#fp}" -eq 64 ] || return 1
  store=$(wt_approvals_path "${2:-$PWD}") || return 1
  wt_approval_known "$fp" "$store" && return 0
  when=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || when=''
  printf '%s %s %s\n' "$fp" "$when" "$(wt_visible "$PROFILE_PATH")" >>"$store" 2>/dev/null
}

# What the loaded profile would run in $1, for a human to read before approving it. stdout: this is
# printed by `bootstrap.sh --review`, run by hand or by /pitlane-finish, never by a hook.
wt_approval_describe() {  # $1 = run directory
  local dir=${1%/} rec body ddir lock strategy install verify _cksum
  printf 'Profile: %s\n' "$(wt_visible "$PROFILE_PATH")"
  printf 'Everything below is text from the branch, shown with control characters as ?:\n'
  [ -n "${PROFILE_SHELL:-}" ] && printf '  toolchain wrapper (shell): %s\n' "$(wt_visible "$PROFILE_SHELL")"
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    IFS=$WT_US read -r ddir lock strategy install verify _cksum <<<"$body" || true
    [ "$strategy" = skip ] && continue
    [ -n "$install" ] && printf '  %s (%s): install: %s\n' "$(wt_visible "${ddir:-?}")" "$(wt_visible "$strategy")" "$(wt_visible "$install")"
    [ -n "$verify" ] && printf '  %s (%s): verify: %s\n' "$(wt_visible "${ddir:-?}")" "$(wt_visible "$strategy")" "$(wt_visible "$verify")"
  done < <(printf '%s' "${PROFILE_RAW:-}")
  if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ]; then
    [ -n "${PROFILE_RT_SEED:-}" ] && printf '  seed script: %s\n' "$(wt_visible "$dir/$PROFILE_RT_SEED")"
    [ -n "${PROFILE_RT_TEARDOWN:-}" ] && printf '  teardown script: %s\n' "$(wt_visible "$dir/$PROFILE_RT_TEARDOWN")"
    [ -n "${PROFILE_RT_SERVE:-}" ] && printf '  serve (run by /pitlane-serve): %s\n' "$(wt_visible "$PROFILE_RT_SERVE")"
    [ -n "${PROFILE_RT_STOP:-}" ] && printf '  stop (run by teardown): %s\n' "$(wt_visible "$PROFILE_RT_STOP")"
  fi
  if wt_is_pr_worktree "$dir"; then
    printf 'This is a pull-request worktree: approving covers this commit only. An approved install runs the PR'"'"'s own package scripts and toolchain files too, so read the diff of those (package.json, composer.json, flake.nix, …) before approving.\n'
  fi
  return 0
}

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
# the `shell` string. That field exists precisely because string-matching only covers
# wrappers already on the list: a hand-written `shell` such as `docker compose run --rm app`, an
# `sh -c` wrapper, or a repo's own `./dev` script has no entry to match. The string-match below is
# the FALLBACK for a profile that omits the field, not the primary path.
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
# or a package.json `scripts` entry has; two would let the WORKTREE NAME, which comes
# from a different and less trusted party than the profile, start a second command.
#
# Note there is no `cd` here: the caller runs this with the worktree as its working directory.
# That is why `nix develop` needs no explicit path argument, which an earlier sketch
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
  # failure this layer exists to prevent. Treat it as no wrapper at all.
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

# ---------------------------------------------------------------------------
# The resource guard — a setup step must never take the desktop down with it
# ---------------------------------------------------------------------------
#
# MEASURED, the reason this exists: a session resume started `nix develop` for a new lockfile while
# the machine was already short of memory. The memory guard of the desktop (systemd-oomd) found the
# user session over its pressure limit and killed the browser and then the session bus, which logs
# the user out. The hook had done nothing wrong but start a tool; ANY tool can do this — a toolchain
# evaluating, a container image pulling, an install resolving a large tree, a seed restoring a dump.
#
# So every command the bootstrap runs goes through three generic protections, applied here once:
#   1. LOW PRIORITY. `nice` (and `ionice -c3` where present), so the step yields to what the user is
#      doing instead of competing with it.
#   2. A MEMORY CAP. Where a user systemd can make a transient scope (Linux with cgroup v2), the step
#      runs in one with MemoryMax and no swap, so a step that grows too large is the one that is
#      killed — reported, and retried later — instead of the desktop around it.
#   3. A PRE-FLIGHT REFUSAL. When too little memory is free to start a step at all, it is not
#      started; it is left for /pitlane-finish or the next session, like a step that ran out of time.
#
# The cap is min(half of RAM, free memory minus a reserve for the desktop). PITLANE_MEMORY_MAX
# overrides it: a size systemd accepts (`6G`, `40%`), or `off` to switch the cap and the refusal off.
# Where none of the mechanisms exist (macOS, no user systemd) the step runs as before, only niced.
# Builds a nix daemon performs run in the daemon's own cgroup and are outside any cap set here.
#
# WT_MEMINFO and WT_SYSTEMD_RUN exist for the tests: a fake /proc/meminfo, and a forced answer to
# "can this host make a capped scope" ('' = no).
WT_GUARD_REFUSED=199          # the status a refused step returns; callers report it as low memory
WT_GUARD_MIN_KB=$((1024 * 1024))   # never start a heavy step with less than 1 GiB to give it
WT_GUARD_REFUSE=${WT_GUARD_REFUSE:-1}
WT_GUARD_SCOPE=${WT_GUARD_SCOPE-}  # cached probe: '' (not probed), yes, no
WT_GUARD_CAP=''               # the cap the last guarded run used, for the caller's message

wt_meminfo_kb() {  # $1 = field (MemTotal, MemAvailable); prints kB or fails
  local file=${WT_MEMINFO:-/proc/meminfo} v
  [ -r "$file" ] || return 1
  v=$(awk -v k="$1:" '$1 == k { print $2; exit }' "$file" 2>/dev/null) || return 1
  wt_is_posint "$v" || return 1
  printf '%s\n' "$v"
}

wt_guard_can_scope() {
  if [ -z "$WT_GUARD_SCOPE" ]; then
    WT_GUARD_SCOPE=no
    if [ -n "${WT_SYSTEMD_RUN+set}" ]; then
      [ -n "$WT_SYSTEMD_RUN" ] && WT_GUARD_SCOPE=yes
    elif command -v systemd-run >/dev/null 2>&1 &&
         systemd-run --user --scope --quiet --collect -p MemoryMax=64M true </dev/null >/dev/null 2>&1; then
      WT_GUARD_SCOPE=yes
    fi
  fi
  [ "$WT_GUARD_SCOPE" = yes ]
}

# Prefix WT_CMD_ARGV with the guard. Returns WT_GUARD_REFUSED (and logs why) when the step must not
# start. Never fails otherwise: a missing mechanism only means a weaker guard.
wt_guard_argv() {  # $1 = the command, for the message
  local total avail reserve cap pre=()
  WT_GUARD_CAP=''
  command -v nice >/dev/null 2>&1 && pre=(nice -n 10)
  command -v ionice >/dev/null 2>&1 && ionice -c3 true >/dev/null 2>&1 && pre=("${pre[@]}" ionice -c3)

  case ${PITLANE_MEMORY_MAX:-} in
    off | OFF | 0) ;;
    ?*)
      wt_guard_can_scope && WT_GUARD_CAP=$PITLANE_MEMORY_MAX
      ;;
    *)
      if total=$(wt_meminfo_kb MemTotal) && avail=$(wt_meminfo_kb MemAvailable); then
        reserve=$((total / 16))
        [ "$reserve" -ge $((1024 * 1024)) ] || reserve=$((1024 * 1024))
        cap=$((avail - reserve))
        [ "$cap" -le $((total / 2)) ] || cap=$((total / 2))
        if [ "$WT_GUARD_REFUSE" = 1 ] && [ "$cap" -lt "$WT_GUARD_MIN_KB" ]; then
          wt_log "  only $((avail / 1024)) MiB of memory is free — not starting \"$1\" now, so it cannot crowd out the desktop; close something heavy and run /pitlane-finish (PITLANE_MEMORY_MAX=off skips this check)"
          return "$WT_GUARD_REFUSED"
        fi
        [ "$cap" -ge "$WT_GUARD_MIN_KB" ] || cap=$WT_GUARD_MIN_KB
        wt_guard_can_scope && WT_GUARD_CAP="$((cap / 1024))M"
      fi
      ;;
  esac

  if [ -n "$WT_GUARD_CAP" ]; then
    pre=("${WT_SYSTEMD_RUN:-systemd-run}" --user --scope --quiet --collect
         -p "MemoryMax=$WT_GUARD_CAP" -p MemorySwapMax=0 "${pre[@]}")
  fi
  [ "${#pre[@]}" -eq 0 ] || WT_CMD_ARGV=("${pre[@]}" "${WT_CMD_ARGV[@]}")
  return 0
}

# Copy what is written to $1 onto stderr while it is written, until wt_capture_unfollow: the live
# view of a captured install. A poller in the background rather than `tail -f`, because it has to
# stop only once it has copied everything the finished command wrote, and `tail -f` cannot be told
# that. It also stops if the hook itself has gone, so it never outlives the run it reports on.
wt_capture_follow() {  # $1 = capture file; sets WT_CAPTURE_FOLLOWER
  local file=$1 hook=$$
  rm -f "$file.ended" 2>/dev/null
  (
    exec 3<"$file" || exit 0
    while :; do
      if [ -e "$file.ended" ] || ! kill -0 "$hook" 2>/dev/null; then
        cat <&3 >&2
        exit 0
      fi
      cat <&3 >&2
      sleep 0.2 2>/dev/null || sleep 1
    done
  ) </dev/null >/dev/null &
  WT_CAPTURE_FOLLOWER=$!
}

wt_capture_unfollow() {  # $1 = capture file
  : >"$1.ended" 2>/dev/null || kill "${WT_CAPTURE_FOLLOWER:-}" 2>/dev/null
  wait "${WT_CAPTURE_FOLLOWER:-}" 2>/dev/null || true
  rm -f "$1.ended" 2>/dev/null
  return 0
}

# Run $1 inside the profile's toolchain, in directory $2, with a timeout of $3 seconds.
#
# Returns the command's own exit status, or 124 when `timeout` killed it — which the caller must
# distinguish, because a killed install leaves a half-written directory and a failed one usually
# does not.
#
# It NEVER lets a failure escape as a shell error: the caller is a hook that must exit 0 whatever
# happens, so every path here returns a status rather than tripping `set -e`.
wt_run_in_shell() {  # $1 = command, $2 = directory, $3 = timeout seconds
  local cmd=${1-} dir=${2-} secs=${3-} rc=0 host=0 capture=${WT_RUN_CAPTURE:-}

  [ -n "$cmd" ] || return 0
  # THE BACKSTOP. Every caller that runs a profile's command checks the approval first and records
  # what it skipped; this catches the one that someday forgets.
  if [ "${WT_APPROVAL:-}" = no ]; then
    wt_log "not running \"$cmd\": the profile's commands are not approved"
    return "$WT_UNAPPROVED"
  fi
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
  if [ "${WT_GUARD:-on}" != off ]; then
    wt_guard_argv "$cmd" || return "$WT_GUARD_REFUSED"
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
  #
  # WT_RUN_CAPTURE names a file to take the command's output instead, so the caller can read the
  # error line back; wt_capture_follow copies it to stderr as it grows. A file rather than a `tee`
  # pipe: a daemon the install leaves behind would hold a pipe open and hang the hook past its
  # budget; it cannot hold up a file.
  if [ -n "$capture" ]; then
    if : >"$capture" 2>/dev/null; then
      wt_capture_follow "$capture"
    else
      capture=''
    fi
  fi
  if command -v timeout >/dev/null 2>&1; then
    if [ -n "$capture" ]; then
      ( cd "$dir" && exec timeout "$secs" "${WT_CMD_ARGV[@]}" ) </dev/null >"$capture" 2>&1 || rc=$?
    else
      ( cd "$dir" && exec timeout "$secs" "${WT_CMD_ARGV[@]}" ) </dev/null >&2 || rc=$?
    fi
  else
    # No coreutils `timeout` (a stock macOS host). Run unbounded rather than not at all, and say
    # so once: an unbounded install is a risk, but refusing to install is a certainty.
    wt_log "coreutils timeout is not on PATH — running \"$cmd\" without a time limit"
    if [ -n "$capture" ]; then
      ( cd "$dir" && exec "${WT_CMD_ARGV[@]}" ) </dev/null >"$capture" 2>&1 || rc=$?
    else
      ( cd "$dir" && exec "${WT_CMD_ARGV[@]}" ) </dev/null >&2 || rc=$?
    fi
  fi
  [ -z "$capture" ] || wt_capture_unfollow "$capture"
  # A step the cap stopped dies of SIGKILL: 137 through `timeout`. Say what happened, because "exit
  # 137" reads like a crash in the tool rather than the guard doing its job.
  if [ "$rc" -eq 137 ] && [ -n "$WT_GUARD_CAP" ]; then
    wt_log "  \"$cmd\" was stopped at its ${WT_GUARD_CAP} memory cap, so it could not crowd out the desktop — it is left for /pitlane-finish or the next session (PITLANE_MEMORY_MAX raises the cap)"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Config copying
# ---------------------------------------------------------------------------
#
# TWO SOURCES, ONE RULE. `.worktreeinclude` is authoritative and stays native wherever native
# creation runs; the profile's `copy[]` is a supplement native knows nothing about.
# Both end up in the same copier so they cannot drift apart in what they consider safe.
#
# THE RULE: a path is copied only if it MATCHES and is ALSO gitignored. Verified on
# git 2.34 while building this: `git ls-files -o -i --exclude-from=F` uses ONLY F as its ignore
# source — the flags are not unioned with .gitignore — so matching and being-gitignored really are
# two questions, and the second needs its own `git check-ignore` pass. A tracked file listed in
# `.worktreeinclude` is therefore skipped, which is native's behaviour too.
#
# COPY-IF-MISSING, NEVER OVERWRITE. A worktree's own edited `.env` is the developer's.
#
# The self-healing this enables is real but NARROWER than it first looks, so state it precisely:
# it covers the profile's `copy[]` only. That list is re-applied on every entry, so a worktree
# that lost one of those files gets it back next session — something native cannot do, since
# `.worktreeinclude` is honoured at creation and never again. `.worktreeinclude` itself is applied
# on the WorktreeCreate path, where native never ran, and on a worktree's FIRST SessionStart, which
# covers one made with plain `git worktree add` (bootstrap.sh says why). Both are copy-if-missing.

# Emit, NUL-separated, the paths `.worktreeinclude` selects: untracked files matching its patterns.
# The gitignored half of the rule is applied later, by the copier, in one batched call.
#
# THE PATTERNS ARE THE WORKTREE'S OWN when it has a `.worktreeinclude`, the main checkout's
# otherwise — the rule the profile follows, for the same reason: the branch checked out in
# the worktree is what says what it needs, and a branch that adds the file must not wait for the main
# checkout to catch up (measured: a review branch adding it bootstrapped with nothing copied, because
# the main checkout was on a branch without one). The FILES are always the main checkout's: that is
# where the gitignored originals live.
wt_worktreeinclude_paths() {  # $1 = main checkout, $2 = worktree (optional)
  local root=${1%/} worktree=${2-} patterns
  patterns=$root/.worktreeinclude
  if [ -n "$worktree" ] && [ -f "${worktree%/}/.worktreeinclude" ] && [ ! -L "${worktree%/}/.worktreeinclude" ]; then
    patterns=${worktree%/}/.worktreeinclude
  fi
  [ -f "$patterns" ] || return 0
  # -z because a path may contain a newline, and this feeds a NUL-delimited reader.
  wt_git "$root" ls-files -z -o -i --exclude-from="$patterns" 2>/dev/null || true
}

# True if any PARENT component of the relative path $2, resolved under $1, is a symlink.
#
# THE LEAF CHECK IS NOT ENOUGH, and this is the same class of threat Claude Code refuses worktree
# creation over. For a path like `config/app.env`, testing only `config/app.env` misses a
# committed symlinked `config/` — and then `mkdir -p` and `cp` both FOLLOW it, writing the file
# wherever it points: another worktree, the main checkout's .git, or the home directory. The mode
# is preserved too, so a committed source file with the executable bit becomes an executable file
# outside the repository. A branch is untrusted input and this is a file write, so every
# component is checked, not just the last.
wt_has_symlinked_parent() {  # $1 = base directory, $2 = relative path
  local base=${1%/} rel=${2-} acc='' seg rest
  rest=${rel%/*}
  [ "$rest" = "$rel" ] && return 1      # no parent components at all
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    [ -n "$seg" ] || continue
    acc="${acc:+$acc/}$seg"
    [ -L "$base/$acc" ] && return 0
  done
  return 1
}

# Copy NUL-separated repo-relative paths, read from stdin, from $1 into $2.
#
# ORDER OF THE CHECKS IS A PERFORMANCE DECISION, not just correctness. The cheap local tests —
# path shape, and "is it already in the worktree" — run FIRST, and only what is still missing is
# batched into a single `git check-ignore`. On the re-entry path, where everything is already
# present, that is N stats and ZERO subprocesses, which is what "well under a second" needs.
wt_copy_paths() {  # $1 = main checkout, $2 = worktree
  local root=${1%/} worktree=${2%/} p q n=0 present=0 copied=0 cand=() ignored=() is_ignored
  local dest src parent irc ictmp

  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    n=$((n + 1))
    # The profile and .worktreeinclude both arrive with anyone's branch, and what follows is a
    # file write: refuse the shape before resolving anything (see wt_is_safe_relpath).
    if ! wt_is_safe_relpath "$p"; then
      wt_log "refusing to copy \"$p\": not a relative path inside the repository"
      continue
    fi
    # Already there — including as a directory, a symlink, or an empty file. Never overwrite.
    # `-e` is false for a DANGLING symlink, so `-L` is tested too: a broken link is still the
    # worktree's own state and replacing it would be an overwrite.
    if [ -e "$worktree/$p" ] || [ -L "$worktree/$p" ]; then
      present=$((present + 1))
      continue
    fi
    [ -e "$root/$p" ] || continue
    cand[${#cand[@]}]=$p
  done

  # Report only what was actually already there. Counting refusals here too produced a summary
  # that contradicted the warnings printed immediately above it.
  if [ "${#cand[@]}" -eq 0 ]; then
    [ "$present" -eq 0 ] || wt_log "config: nothing to copy, $present path(s) already present"
    return 0
  fi

  # ONE call for every candidate. check-ignore answers the "and is gitignored" half of the
  # rule, using the repository's real ignore rules rather than a hand-rolled matcher.
  #
  # The result is read into an array and compared EXACTLY. Two traps here, both avoided
  # deliberately: command substitution silently DISCARDS NUL bytes, so `$(... -z ...)` would
  # return the paths run together with no separator at all; and a substring test against such a
  # blob would then match `a` inside `bar/a.txt` and copy a file git never said was ignored.
  ignored=()
  irc=0
  # A real temp file rather than a process substitution: the status of the command inside `< <(…)`
  # is not the loop's status, and this needs check-ignore's OWN exit code. mktemp honours TMPDIR,
  # so nothing is written into the worktree or the checkout.
  ictmp=$(mktemp 2>/dev/null) || ictmp=''
  if [ -z "$ictmp" ]; then
    wt_log "could not create a temporary file to check gitignore status — copying nothing this run"
    return 0
  fi
  printf '%s\0' "${cand[@]}" | wt_git "$root" check-ignore -z --stdin >"$ictmp" 2>/dev/null
  irc=$?
  # git exits 0 when at least one path is ignored and 1 when none are; ANYTHING else is a real
  # failure (git absent, a corrupt index, not a work tree). Without this, such a failure looks
  # exactly like "nothing is ignored", and every path would be refused with the wrong reason.
  case $irc in
    0 | 1)
      while IFS= read -r -d '' q; do
        ignored[${#ignored[@]}]=$q
      done <"$ictmp"
      ;;
    *)
      rm -f "$ictmp"
      wt_log "could not ask git which paths are gitignored (it exited $irc) — copying nothing this run"
      return 0
      ;;
  esac
  rm -f "$ictmp"

  for p in "${cand[@]}"; do
    is_ignored=0
    for q in ${ignored[@]+"${ignored[@]}"}; do
      if [ "$q" = "$p" ]; then is_ignored=1; break; fi
    done
    case $is_ignored in
      1) ;;
      *)
        # A tracked or otherwise non-ignored file. Native skips these, so this does too — but say
        # so, because a developer who listed one is expecting it to appear.
        wt_log "not copying \"$p\": it is not gitignored, and only gitignored files are copied"
        continue
        ;;
    esac
    src=$root/$p
    dest=$worktree/$p
    # Re-test presence: the candidate list was built before ANY copy happened, so an earlier
    # entry in this same run may have created this path. Without this, a copy[] naming a
    # directory whose child was copied first would `cp -Rp` INTO the existing directory and
    # produce nested/nested.
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      continue
    fi
    if wt_has_symlinked_parent "$worktree" "$p" || wt_has_symlinked_parent "$root" "$p"; then
      wt_log "not copying \"$p\": one of its parent directories is a symlink, which would write outside the worktree"
      continue
    fi
    # A symlink is REFUSED rather than reproduced. Copying the link would leave the worktree's
    # config pointing at a path outside it — usually the main checkout's own file — so edits in
    # one worktree would appear in another, which is the exact isolation this plugin exists to
    # provide. Copying what it points AT would silently turn a link into a file. Neither is
    # obviously right, so it is the developer's call.
    if [ -L "$src" ]; then
      wt_log "not copying \"$p\": it is a symlink, and copying it would share state between worktrees"
      continue
    fi
    # `${dest%/*}` rather than `$(dirname ...)`: this runs per file on a hook that blocks session
    # start, and a subshell plus an exec is a real cost for a value parameter expansion already
    # has. The `-d` test skips the mkdir entirely in the common case.
    parent=${dest%/*}
    if [ "$parent" != "$dest" ] && [ ! -d "$parent" ]; then
      mkdir -p "$parent" 2>/dev/null || {
        wt_log "could not create a parent directory for \"$p\" — skipping it"
        continue
      }
    fi
    # -p preserves the mode, which matters for a private key or a 600 .env.
    if [ -d "$src" ]; then
      # `cp -Rp` reproduces symlinks INSIDE the tree verbatim, which would smuggle past the leaf
      # refusal above the very thing it exists to stop. Refuse the whole directory rather than
      # copy some of it.
      if [ -n "$(find "$src" -type l -print -quit 2>/dev/null)" ]; then
        wt_log "not copying the directory \"$p\": it contains a symlink, which would share state between worktrees"
        continue
      fi
      cp -Rp "$src" "$dest" 2>/dev/null || { wt_log "could not copy the directory \"$p\""; continue; }
    else
      cp -p "$src" "$dest" 2>/dev/null || { wt_log "could not copy \"$p\""; continue; }
    fi
    copied=$((copied + 1))
  done

  [ "$copied" -eq 0 ] || wt_log "config: copied $copied file(s) the worktree was missing"
  return 0
}

# The whole config step: `.worktreeinclude` (only where native did not already do it) merged with
# the profile's copy[], through one copier.
#
# AN OVERRIDE FILE IS COPIED LIKE ANY OTHER, and that is deliberate. The file an app
# loads is usually the one holding the developer's real configuration, so it SHOULD arrive first;
# layer 3 then appends its managed block to that copy. This used to skip the override file, because
# a copied file without the plugin's marker read as developer-owned forever — but that skip only
# ever covered this path, never native `claude -w`, where Claude Code copies `.worktreeinclude`
# before any hook runs. Ownership now belongs to a block inside the file, so both paths agree.
wt_copy_config() {  # $1 = main checkout, $2 = worktree, $3 = 1 to also honour .worktreeinclude
  local root=${1%/} worktree=${2%/} own_include=${3:-0} rec body

  {
    [ "$own_include" = 1 ] && wt_worktreeinclude_paths "$root" "$worktree"
    # copy[] comes out of the scan wt_load_profile already made — group 2 — so honouring it costs
    # no interpreter start at all. PROFILE_RAW is empty unless the profile validated, so an
    # unusable profile contributes nothing here rather than contributing half its list.
    if [ -n "${PROFILE_RAW:-}" ]; then
      while IFS= read -r -d "$WT_RS" rec; do
        case $rec in
          2"$WT_US"*) ;;
          *) continue ;;
        esac
        body=${rec#*"$WT_US"}
        [ -n "$body" ] || continue
        printf '%s\0' "$body"
      done < <(printf '%s' "$PROFILE_RAW")
    fi
  } | wt_copy_paths "$root" "$worktree"
}

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------
#
# WHAT IS SHARED, AND THEREFORE WHAT IS LOCKED. Two worktrees bootstrapping at once contend over
# two things: the main checkout's dependency directory, which is the hardlink SOURCE, and the
# package manager's own cache. Both are keyed by the dependency, so the lock is too. This is the
# race the source conversation's scripts got wrong — its completeness marker was checked outside
# any lock, so two worktrees on one lockfile both installed into the same place.
#
# The lock files live in the MAIN checkout, because that is the only directory every worktree of
# a repository can agree on. They are empty and are never removed: an unlink would race with the
# next acquirer opening the same path, and an empty file per dependency is not worth that.
#
# ON FAILURE TO ACQUIRE, PROCEED UNLOCKED WITH A WARNING. That is the warn-and-continue rule applied to locking
# itself: a session that hangs waiting for another worktree's 90-second install is exactly the
# cost the user must never pay. It is an HONEST weakening — the race becomes rarer, not
# impossible — and the alternative, blocking, is worse for the failure it prevents.
#
# WHAT THIS DOES NOT PROTECT, stated plainly because a lock invites over-trust:
#   * a developer running `composer install` BY HAND in the main checkout while a worktree
#     hardlinks from it. Nothing here can take a lock on that, and no hook can.
#   * two DIFFERENT dependency directories that happen to share one external cache outside the
#     repository. The lock is per directory, so it cannot serialise those.

# Seconds to wait for a lock before giving up and proceeding unlocked. Short on purpose: long
# enough that two worktrees started together serialise properly, short enough that nobody waits.
WT_LOCK_WAIT=10

# The repository's SHARED git directory as an absolute path, as seen from $1. Every worktree of one
# repository gets the same answer, which is what makes it the place for anything the worktrees
# must agree on — the dependency locks and the runtime ledger. git reports it relative to $1 in
# the main checkout, so it is anchored there — except that git before 2.13 reported it relative to
# the top of the checkout even from a subdirectory. Only when the anchored answer is not a
# directory is the top asked for, so a caller passing the top (every session-start caller) pays no
# second git. Prints nothing and returns 1 when git cannot say.
wt_git_common_dir() {  # $1 = any directory inside the repository
  local dir=${1%/} common top
  common=$(wt_git "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$common" ] || return 1
  case $common in
    /*) ;;
    *)
      if [ -d "$dir/$common" ]; then
        common=$dir/$common
      elif top=$(wt_git "$dir" rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] \
        && [ -d "$top/$common" ]; then
        common=$top/$common
      else
        common=$dir/$common
      fi
      ;;
  esac
  printf '%s' "${common%/}"
}

# Where a dependency's lock file lives. The directory name is slugified because it may contain
# `/` — `assets/node_modules` is a real case. Two different directories CAN slug to one name,
# which costs a little concurrency and no correctness: the worst outcome is that two unrelated
# installs serialise. A dir that slugifies to nothing at all still gets a usable name.
#
# It goes in the repository's SHARED git directory, not the working tree. Shared is the
# requirement — every worktree of this repo must agree on the same file, and `--git-common-dir`
# is the same for all of them — and being outside the checkout means these never appear as
# untracked entries in the main checkout's `git status`, in a repo whose .gitignore knows nothing
# about this plugin. A layout git cannot report falls back to `.claude/worktree-locks/`.
wt_lock_path() {  # $1 = main checkout, $2 = dependency dir
  local root=${1%/} slug common
  slug=$(wt_slugify "${2-}") || slug=dep
  [ -n "$slug" ] || slug=dep
  # See wt_state_path: the cache only helps once wt_prime_paths has filled it in the caller's
  # own shell, because this function is always called in a command substitution.
  if [ "${WT_LOCKDIR_FOR:-}" = "$root" ] && [ -n "${WT_LOCKDIR_IS:-}" ]; then
    printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
    return 0
  fi
  common=$(wt_git_common_dir "$root") || common=''
  if [ -n "$common" ] && [ -d "$common" ]; then
    WT_LOCKDIR_FOR=$root
    WT_LOCKDIR_IS="$common/worktree-locks"
    printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
    return 0
  fi
  WT_LOCKDIR_FOR=$root
  WT_LOCKDIR_IS="$root/.claude/worktree-locks"
  printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
}

# Acquire the lock at $1 on file descriptor $3, waiting at most $2 seconds (0: not at all).
#   0 = held, 1 = not held (caller proceeds unlocked), 2 = could not even try.
#
# The fd is a parameter and applied with `eval` because bash 3.2 — the portability floor — has no
# automatic descriptor allocation (`exec {fd}>` is 4.1+), and the engine nests two locks.
wt_lock_acquire() {  # $1 = lock path, $2 = wait seconds, $3 = fd number
  local lock=${1-} secs=${2-} fd=${3-} dir base rel
  # Descriptors 0, 1 and 2 are refused as well as non-numeric ones: `exec 1>"$lock"` would
  # redirect the hook's STDOUT — the channel carrying the worktree path — into the lock file.
  case $fd in '' | *[!0-9]* | 0 | 1 | 2) return 2 ;; esac
  [ -n "$lock" ] || return 2
  [ "$secs" = 0 ] || wt_is_seconds "$secs" || secs=$WT_LOCK_WAIT

  if ! command -v flock >/dev/null 2>&1; then
    # Stock macOS has no flock(1). Say so ONCE per run and carry on: an unserialised install is a
    # risk, refusing to install is a certainty. A mkdir-with-a-TTL substitute was considered and
    # rejected — a TTL is a guess, and one too short lets a second worktree barge into a running
    # install, which is silent corruption rather than a warning.
    if [ -z "${WT_FLOCK_WARNED:-}" ]; then
      WT_FLOCK_WARNED=1
      wt_log "flock is not on PATH — dependency work will not be serialised against other worktrees"
    fi
    return 1
  fi

  dir=${lock%/*}
  # THE OPEN BELOW TRUNCATES. `exec 9>path` is create-or-truncate, so if the lock path or any
  # component of it is a symlink, whatever it points at is zeroed on session start — and these
  # paths are fixed and their names guessable (`vendor`, `node_modules`). This is the same hole
  # wt_copy_paths defends against, and it has to be closed here too rather than assumed away
  # because the path is "ours": the directories it sits under can be committed by anyone.
  if [ -L "$lock" ]; then
    wt_log "refusing to use the lock file $lock: it is a symlink, and opening it would truncate whatever it points at"
    return 2
  fi
  base=${dir%/*}
  rel=${lock##*/}
  if [ -n "$base" ] && [ "$base" != "$dir" ] && wt_has_symlinked_parent "$base" "${dir##*/}/$rel"; then
    wt_log "refusing to use the lock file $lock: one of its parent directories is a symlink"
    return 2
  fi
  [ "$dir" = "$lock" ] || [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 2
  eval "exec $fd>\"\$lock\"" 2>/dev/null || return 2
  if [ "$secs" = 0 ]; then
    flock -n "$fd" 2>/dev/null && return 0
  elif flock -w "$secs" "$fd" 2>/dev/null; then
    return 0
  fi
  wt_lock_release "$fd"
  return 1
}

wt_lock_release() {  # $1 = fd number
  case ${1-} in '' | *[!0-9]*) return 0 ;; esac
  eval "exec $1>&-" 2>/dev/null || true
  return 0
}

# ---------------------------------------------------------------------------
# Per-worktree bootstrap state
# ---------------------------------------------------------------------------
#
# WHY THIS EXISTS: re-entering an already-bootstrapped worktree must cost milliseconds. Without a
# record, "is this done" can only be guessed from the directory's contents, and a directory that
# exists is not the same as an install that FINISHED — the difference being exactly the case a
# timeout produces.
#
# NOT JSON, deliberately. Reading JSON costs a cold interpreter start, on the one path whose
# entire purpose is to be fast. This is US/RS-delimited text read with bash's own `read`, which
# costs no process at all. The same separators as the JSON layer, for the same reason: a command
# string may contain anything except these, which the readers strip.
#
# WHERE IT LIVES: the worktree's own private git directory, `<root>/.git/worktrees/<name>`. The
# requirement is "inside the worktree — it dies with the worktree", and this satisfies that
# (git removes it with the worktree) while avoiding what a file in the checkout would cost: an
# untracked entry in every `git status`, in a repo whose .gitignore knows nothing about us, which
# a developer could commit by accident. A checkout that cannot report a private git dir falls
# back to the worktree's own .claude/.
#
# STATUS IS WRITTEN BEFORE THE WORK, NOT AFTER. An entry goes to `doing` before the install starts
# and only becomes `done` once the command AND its verify have succeeded. That is what separates
# "installed" from "killed halfway by the timeout", which a populated directory cannot tell you —
# and the design requires a hung install to leave a usable session.
#
# THE STATUSES of a `dep` record: `doing` (started, not finished), `done`, `warn` (the install
# exited non-zero but its verify passed: a package manager that installs everything and then fails
# on a policy check has produced a usable tree, so it counts as present), `failed` (exited non-zero
# and nothing said otherwise), `dirty` (not done, for any other reason: out of time, out of memory,
# not approved, a verify that failed after a clean exit). A `failed` install is NOT retried with
# the same lockfile and command (wt_state_failure_stands): it would fail the same way, and each
# attempt can cost minutes. Only `--finish --retry-failed` overrides that. Fields 7 and 8, after `when`, carry a `warn` or `failed` install's
# exit code and its error line.
#
# NO PARTIAL TRUST, the same rule the profile has: unreadable, wrong version, unparseable, or an
# entry left at `doing` all mean THE SAME THING — not done, do it again. Redoing safe work is
# cheap; skipping real work leaves a worktree that looks finished and is not.

# Bumped when the RECORD FORMAT changes in a way an older parser would MISREAD. Appending a field
# at the end is not such a change — a reader that names fewer variables simply ignores it — so the
# timestamp added later did not need a bump. Reordering or repurposing a field would. Deliberately not the plugin's own version: a new release does not invalidate a
# correct install, and reading plugin.json would cost the interpreter start this file exists to
# avoid — so every worktree on the machine would pay a full reinstall on the day of an upgrade.
WT_STATE_VERSION=1

# Where the state goes, relative to the worktree, when git cannot name its git dir. Read by
# wt_state_in_git_dir too, so the two cannot drift apart.
WT_STATE_FALLBACK_REL=.claude/worktree-bootstrap-state

# Memoised — but only usefully if the cache is PRIMED first, by wt_prime_paths below. This
# function returns its answer on stdout, so every call site is a command substitution, i.e. a
# subshell: an assignment made here is discarded the moment it returns. Priming from the
# entrypoint's own shell is what makes the lookup happen once instead of once per call.
wt_state_path() {  # $1 = worktree
  local wt=${1%/} gitdir
  if [ "${WT_STATE_PATH_FOR:-}" = "$wt" ] && [ -n "${WT_STATE_PATH_IS:-}" ]; then
    printf '%s' "$WT_STATE_PATH_IS"
    return 0
  fi
  gitdir=$(wt_git "$wt" rev-parse --git-dir 2>/dev/null) || gitdir=''
  if [ -n "$gitdir" ]; then
    case $gitdir in
      /*) ;;
      *) gitdir=$wt/$gitdir ;;
    esac
    if [ -d "$gitdir" ]; then
      WT_STATE_PATH_FOR=$wt
      WT_STATE_PATH_IS="${gitdir%/}/worktree-bootstrap-state"
      printf '%s' "$WT_STATE_PATH_IS"
      return 0
    fi
  fi
  WT_STATE_PATH_FOR=$wt
  WT_STATE_PATH_IS="$wt/$WT_STATE_FALLBACK_REL"
  printf '%s' "$WT_STATE_PATH_IS"
}

# Join fields into a record body, stripping the bytes the record format cannot carry.
#
# THE FORMAT CANNOT REPRESENT ITS OWN SEPARATORS, so the writer must not pretend otherwise. A US in
# any field forges an extra field and an RS ends the record early; both readers here are
# line-delimited, so a newline truncates the record and blanks EVERY FIELD AFTER IT. That is not a
# cosmetic loss — `seedstatus` and `seedcksum` are late fields, so a stray byte in the slug would
# blank the seed marker and re-run a database clone on every single session, silently.
#
# It mirrors the JSON layer's `desep` exactly (strip US and RS, fold CR and LF to a space) because
# most of these values arrive THROUGH that layer, and a second sanitiser with different rules would
# be a second thing to keep true. This one is the backstop for the values that do not: a caller
# building a record by hand, and a slug or path that reached us another way.
#
# Sets WT_STATE_REC rather than printing, deliberately: this runs per field on the session-start
# path, and a command substitution per field is a fork per field for work that parameter expansion
# already does for free.
wt_state_join() {  # $@ = field values; sets WT_STATE_REC
  local f v out='' first=1
  for f in "$@"; do
    v=$f
    v=${v//"$WT_US"/}
    v=${v//"$WT_RS"/}
    v=${v//"$WT_CR"/ }
    v=${v//"$WT_NL"/ }
    if [ "$first" = 1 ]; then
      out=$v
      first=0
    else
      out="$out$WT_US$v"
    fi
  done
  WT_STATE_REC=$out
}

# Rewrite the state file, replacing one record and carrying every other through untouched.
#
# THE ONE MERGE IMPLEMENTATION, and it is one because the second copy of it had already drifted
# before it was a day old: the copy's own replaced-kind arm was missing the headerless guard the
# original applies to every other arm, so the two writers disagreed about the no-partial-trust
# rule on identical bytes. A merge loop that exists twice is the shape this codebase has now
# un-duplicated three times (the JSON value renderer, the drift comparator, this).
#
# $2 names the kind being replaced and $3 narrows that to a single record by its FIRST field —
# `dep` records are per directory, so only the matching one goes, while `rt` is a single slot and
# passes an empty $3 to replace whichever one is there.
#
# The rules it enforces for every caller at once:
#   * a header of an unrecognised WT_STATE_VERSION discards the whole file rather than merging
#     with it — otherwise the next write restamps stale records as current and the reader trusts
#     records it had correctly refused;
#   * a record appearing BEFORE any header means the file is not ours, same outcome;
#   * a kind this build does not know is preserved verbatim, never parsed and never dropped. That
#     arm is why layer 2 and layer 3 can share one file at all.
#
# Atomic: temp file in the SAME directory (so `mv` is a rename and not a copy), then `mv -f`.
wt_state_rewrite() {  # $1 = worktree, $2 = kind to replace, $3 = its first field or empty, $4 = the replacement record, empty to remove it
  local wt=${1%/} kind=${2-} key=${3-} newrec=${4-}
  local file tmp rec rkind rest kept='' hdrok=0 parent

  file=$(wt_state_path "$wt")
  [ -n "$file" ] || return 1
  parent=${file%/*}
  [ "$parent" = "$file" ] || [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null || return 1

  if [ -r "$file" ]; then
    while IFS= read -r -d "$WT_RS" rec; do
      rkind=${rec%%"$WT_US"*}
      rest=${rec#*"$WT_US"}
      if [ "$rkind" = wtstate ]; then
        [ "${rest%%"$WT_US"*}" = "$WT_STATE_VERSION" ] || { kept=''; break; }
        hdrok=1
        continue
      fi
      # EVERY non-header record is subject to the same headerless rule, including the kind being
      # replaced. Exempting that one is precisely the divergence this function exists to prevent.
      [ "$hdrok" = 1 ] || { kept=''; break; }
      if [ "$rkind" = "$kind" ]; then
        [ -z "$key" ] && continue                      # single-slot kind: this one is replaced
        [ "${rest%%"$WT_US"*}" = "$key" ] && continue  # keyed kind: only the match is replaced
      fi
      kept="$kept$rec$WT_RS"
    done <"$file"
  fi

  tmp=$(mktemp "${parent}/.wtstate.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'wtstate%s%s%s' "$WT_US" "$WT_STATE_VERSION" "$WT_RS"
    printf '%s' "$kept"
    [ -z "$newrec" ] || printf '%s%s' "$newrec" "$WT_RS"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Record the outcome for one dependency. Rewrites the whole file atomically: it holds a handful of
# entries, and a partial write is the one thing a reader must never see.
wt_state_set() {  # $1 = worktree, $2 = dir, $3 = strategy, $4 = lock cksum, $5 = install cksum, $6 = status, $7 = install exit code, $8 = its error line
  local wt=${1%/} dir=${2-} strategy=${3-} lck=${4-} ick=${5-} status=${6-} rc=${7-} reason=${8-} when rec

  # Recorded but never compared: it answers "when did this last happen" for a developer looking at
  # a worktree that seems stale, and gives prune something to age entries by. It is deliberately
  # NOT part of the freshness decision — a timestamp cannot tell you whether a tree is correct, and
  # comparing one would make re-entry depend on the clock.
  when=$(date +%s 2>/dev/null) || when=0

  wt_state_join dep "$dir" "$strategy" "$lck" "$ick" "$status" "$when" "$rc" "$reason"
  rec=$WT_STATE_REC
  # The KEY is cleaned the same way the field was, or a `dir` carrying a stripped byte would never
  # match the record it just wrote and would append a duplicate on every session.
  wt_state_join "$dir"
  wt_state_rewrite "$wt" dep "$WT_STATE_REC" "$rec"
}

# True when this dependency is recorded as finished AND the evidence still matches.
#
# The lock checksum compared is the WORKTREE's own lockfile, not the main checkout's and not the
# profile's calibration-time value: they answer different questions, and a worktree on its own
# branch can legitimately differ from both. The install command is fingerprinted too, so editing
# it in the profile re-runs the dependency rather than trusting a tree built by the old one.
wt_state_is_done() {  # $1 = worktree, $2 = dir, $3 = lock cksum, $4 = install cksum, $5 = strategy
  local wt=${1%/} dir=${2-} lck=${3-} ick=${4-} want=${5-}
  local file rec kind rest ver rdir rstrategy rlck rick rstatus rwhen seen=0

  file=$(wt_state_path "$wt")
  [ -r "$file" ] || return 1

  while IFS= read -r -d "$WT_RS" rec; do
    kind=${rec%%"$WT_US"*}
    rest=${rec#*"$WT_US"}
    case $kind in
      wtstate)
        ver=${rest%%"$WT_US"*}
        # A file written by a different format is not partially trusted, it is ignored whole.
        [ "$ver" = "$WT_STATE_VERSION" ] || return 1
        seen=1
        ;;
      dep)
        # SC2034: rstrategy and rwhen are read POSITIONALLY to consume their fields; dropping
        # either would shift every field after it.
        # shellcheck disable=SC2034
        IFS=$WT_US read -r rdir rstrategy rlck rick rstatus rwhen <<<"$rest" || true
        [ "$rdir" = "$dir" ] || continue
        # Quoted: bare `done` is the loop keyword to the parser. `doing` means killed mid-write.
        case $rstatus in "done" | warn) ;; *) return 1 ;; esac
        [ "$rlck" = "$lck" ] || return 1
        [ "$rick" = "$ick" ] || return 1
        # The recorded STRATEGY is compared too, not merely stored. Flipping a dependency from
        # hardlink to install in the profile changes neither the lockfile nor the install command,
        # so without this the worktree would keep a tree built the way the developer just
        # abandoned and report itself up to date. A caller passing no strategy skips the check.
        [ -z "$want" ] || [ "$rstrategy" = "$want" ] || return 1
        [ "$seen" = 1 ] || return 1           # a dep record before any header: not our file
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

# ---------------------------------------------------------------------------
# Per-worktree RUNTIME state — layer 3's half of the same file
# ---------------------------------------------------------------------------
#
# ONE record, kind `rt`, in the SAME state file the dependency records live in. One file rather
# than two because it is one worktree's state, it dies with the worktree the same way, and teardown
# then has one place to look rather than two that can disagree about whether a worktree was ever
# set up. The two writers each recognise their own kind and carry every other kind through
# verbatim, so neither needs to understand the other's fields.
#
# Field order, after the kind:
#   1 slug         the FINAL slug, after runtime.slug was expanded and re-slugified. What the
#                  database is actually named after, not the template it came from.
#   2 port         the allocated port, or empty when none was derived
#   3 portsource   `derived` or `probed` — whether the port is the one the slug hashes to, or one
#                  found by stepping past a sibling's claim. Teardown wants to know which.
#   4 envfile      every override file, `:`-joined, each relative to THE WORKTREE, resolving as
#                  <worktree>/<envfile> — stated exactly because the consumer of this field
#                  rewrites those files, and `wt_copy_paths` already uses "repo-relative" for paths
#                  resolved against the MAIN CHECKOUT. Recorded so teardown takes the plugin's
#                  block out of the files by name rather than by re-expanding a profile that may
#                  have changed underneath it. A record from an older version holds one.
#   5 envstate     one disposition per file in field 4, `:`-joined and aligned with it: `ours`
#                  (the plugin has written its block there), `theirs` (the developer took the file
#                  over by deleting the block), or EMPTY (never written yet). Recorded so the
#                  warning fires ONCE rather than on every session, and so a file without a block
#                  can be told apart as "taken over" versus "not written yet".
#   6 seedstatus   `none` | `done` | `failed` | `timeout` | `skipped`
#   7 seedcksum    cksum of the seed SCRIPT'S CONTENT at the last attempt, which is what lets an
#                  edited script retry automatically while an unedited failing one does not re-pay
#                  its timeout every session
#   8 when         epoch seconds, recorded and never compared (see wt_state_set)
#
# WHAT THIS RECORD CANNOT DO, stated rather than left for teardown to discover. It is a single
# slot describing the CURRENT allocation, so it cannot describe a superseded one. `runtime.slug`
# and `runtime.env.file` are profile templates, and a worktree's own committed profile
# wins — so editing either on a branch re-points a live worktree, and the previous slug's database
# becomes referenced by nothing: the only record of it was overwritten. Teardown would then not
# remove it and `/pitlane-tidy` would not find it.
#
# Deliberately NOT solved here. Reclaiming an orphaned database needs the inverse of a repo-owned
# seed script, which only the repo knows how to write, and unreferenced-state sweeping is
# explicitly `/pitlane-tidy`'s job. It is stated here so that teardown
# inherits a named problem rather than a surprise.
#
# WT_STATE_VERSION IS NOT BUMPED. A new record KIND is not a change an older parser misreads: the
# readers already skip kinds they do not know, and the writer now carries them through. Bumping
# would force every worktree on the machine to reinstall its dependencies on the day of an
# upgrade, which is a real cost for no correctness gain.

# Write (or replace) this worktree's `rt` record, carrying every other record through untouched.
# Mirrors wt_state_set exactly, including the atomic temp-then-rename and the no-partial-trust
# header rule — a file whose version we do not recognise is not merged with, it is replaced.
wt_runtime_state_set() {  # $1 = worktree, $2 = slug, $3 = port, $4 = portsource, $5 = envfile, $6 = envstate, $7 = seedstatus, $8 = seedcksum
  local wt=${1%/} slug=${2-} port=${3-} psrc=${4-} envfile=${5-} envstate=${6-}
  local sstatus=${7-} scksum=${8-} when rec rc

  when=$(date +%s 2>/dev/null) || when=0

  # An empty key: `rt` is a single slot, so whichever record is there is the one replaced.
  wt_state_join rt "$slug" "$port" "$psrc" "$envfile" "$envstate" "$sstatus" "$scksum" "$when"
  rec=$WT_STATE_REC
  wt_state_rewrite "$wt" rt '' "$rec"
  rc=$?
  # Whatever the state write's outcome: the allocation is real either way, and the ledger is the
  # record of it that has to survive the worktree. It never changes this function's status.
  wt_ledger_write "$wt" "$rec"
  return "$rc"
}

# Read one field of this worktree's `rt` record, by NAME. Prints nothing and returns 1 when there
# is no usable record.
#
# A named accessor rather than "go and parse the state file" is the contract teardown consumes: its
# teardown must not re-derive a slug or re-expand an env path to find out what bootstrap created,
# because a profile edited in between would send it looking in the wrong place — or, worse, let it
# delete something it never made.
#
# STATUS, and the two failures are deliberately DIFFERENT numbers:
#   0  the field was read; its value is on stdout (possibly empty, which is a legitimate value)
#   1  there is no usable record — no file, a foreign format version, or layer 3 has not run here
#   2  the FIELD NAME is not one this record has, which is a bug in the caller
# They were both 1 in the first draft, which made `v=$(... seedstatuss) || v=none` turn a typo into
# a silent default — the caller cannot tell "not set up yet" from "you asked for nothing".
wt_runtime_state_get() {  # $1 = worktree, $2 = field name
  local file
  file=$(wt_state_path "${1%/}")
  wt_runtime_state_read "$file" "${2-}"
}

# The same read, given the state FILE rather than the worktree that owns it.
#
# Sibling enumeration needs this: resolving a path with wt_state_path costs a `git rev-parse` fork,
# and doing that per sibling would undo the reason the admin directories are read directly at all.
# It also makes the liveness check in wt_runtime_siblings load-bearing rather than incidental —
# reading through the worktree path happens to fail for a deleted checkout, which is not the same
# as refusing it.
wt_runtime_state_read() {  # $1 = state file, $2 = field name
  local file=${1-} want=${2-} rec kind rest seen=0
  local rslug rport rpsrc renvfile renvstate rsstatus rscksum rwhen

  [ -r "$file" ] || return 1

  while IFS= read -r -d "$WT_RS" rec; do
    kind=${rec%%"$WT_US"*}
    rest=${rec#*"$WT_US"}
    case $kind in
      wtstate)
        [ "${rest%%"$WT_US"*}" = "$WT_STATE_VERSION" ] || return 1
        seen=1
        ;;
      rt)
        [ "$seen" = 1 ] || return 1       # a record before any header: not our file
        IFS=$WT_US read -r rslug rport rpsrc renvfile renvstate rsstatus rscksum rwhen \
          <<<"$rest" || true
        case $want in
          slug)       printf '%s' "$rslug" ;;
          port)       printf '%s' "$rport" ;;
          portsource) printf '%s' "$rpsrc" ;;
          envfile)    printf '%s' "$renvfile" ;;
          envstate)   printf '%s' "$renvstate" ;;
          seedstatus) printf '%s' "$rsstatus" ;;
          seedcksum)  printf '%s' "$rscksum" ;;
          when)       printf '%s' "$rwhen" ;;
          *)          return 2 ;;          # a CALLER error, and distinct from "no record" (1)
        esac
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

# ---------------------------------------------------------------------------
# The runtime LEDGER — a record of each allocation that outlives its worktree
# ---------------------------------------------------------------------------
#
# The `rt` record lives in the worktree's admin directory, and git deletes that directory with the
# worktree: on `git worktree remove`, on Claude Code's own removal of a launch-time worktree, and on
# `git worktree prune` after a checkout was deleted by hand. Not every one of those runs our
# teardown first, so the one record naming the database a seed created — and the port and env file
# beside it — can vanish while the database itself lives on, and `/pitlane-tidy` cannot find what
# nothing records.
#
# So every `rt` write is copied to `<git-common-dir>/worktree-ledger/<admin id>`: the shared git
# directory, because it outlives every linked worktree and never shows in any `git status`; keyed
# by the admin id, because that is the one name git itself keeps unique among LIVE worktrees.
#
# THE SAME ENCODING AS THE STATE FILE, not a second format: a `wtstate` version header, then one
# `worktree` record (path, admin id, name) and the `rt` record byte-for-byte as the state file got
# it. That makes wt_runtime_state_read work on an entry unchanged, so the rt fields keep exactly
# one reader.
#
# AN ID IS UNIQUE ONLY AMONG LIVE WORKTREES. Once a worktree is gone git hands its id to the next
# one of that name, and a plain overwrite would then erase the only record of the old allocation —
# precisely the one prune exists to find. So an existing entry for another path, or for another
# slug (a branch that edits runtime.slug re-points a live worktree at a new database and orphans
# the old one), is moved aside to `<id>.<its when>` before the new entry is written.
#
# ALWAYS ADVISORY. A ledger that cannot be written costs a later sweep its evidence, never this
# session: the writer warns and returns 0, and nothing it does touches stdout.

WT_LEDGER_DIRNAME='worktree-ledger'
# The prefix of an entry still being written. Enumeration skips it, so a reader never sees half an
# entry.
WT_LEDGER_TMP_PREFIX=.wtledger.

# Parse one ledger entry into WT_LEDGER_PATH, WT_LEDGER_ADMIN, WT_LEDGER_NAME and WT_LEDGER_RT (the
# `rt` record's fields, still US-joined). Returns 1 for anything not wholly trustworthy — unreadable,
# a foreign version, a record before the header, or either record missing — under the same
# no-partial-trust rule as the state file.
#
# Sets globals rather than printing for the reason wt_state_join does: the writer runs this on the
# session-start path, and a command substitution per field would be a fork per field.
wt_ledger_parse() {  # $1 = entry file
  local file=${1-} rec kind rest seen=0 have_wt=0 have_rt=0

  WT_LEDGER_PATH='' WT_LEDGER_ADMIN='' WT_LEDGER_NAME='' WT_LEDGER_RT=''
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r -d "$WT_RS" rec; do
    kind=${rec%%"$WT_US"*}
    rest=${rec#"$kind"}
    rest=${rest#"$WT_US"}
    if [ "$kind" = wtstate ]; then
      [ "${rest%%"$WT_US"*}" = "$WT_STATE_VERSION" ] || return 1
      seen=1
      continue
    fi
    [ "$seen" = 1 ] || return 1
    case $kind in
      worktree)
        WT_LEDGER_PATH=${rest%%"$WT_US"*}
        rest=${rest#"$WT_LEDGER_PATH"}
        rest=${rest#"$WT_US"}
        WT_LEDGER_ADMIN=${rest%%"$WT_US"*}
        rest=${rest#"$WT_LEDGER_ADMIN"}
        rest=${rest#"$WT_US"}
        WT_LEDGER_NAME=${rest%%"$WT_US"*}
        have_wt=1
        ;;
      rt)
        WT_LEDGER_RT=$rest
        have_rt=1
        ;;
    esac
  done <"$file"
  [ "$have_wt" = 1 ] && [ "$have_rt" = 1 ]
}

# Record this worktree's allocation in the ledger. $2 is the `rt` record exactly as it was written
# to the state file, so the two can never disagree about what was allocated.
#
# THE ADMIN DIRECTORY IS READ OFF THE STATE PATH, not asked of git. wt_state_path has already
# resolved it — primed in the entrypoint's own shell — and a linked worktree's git dir is always
# `<common>/worktrees/<id>`, so the id and the common dir are parameter expansions away. A
# `git rev-parse` here would be a fork on every session for an answer already in hand. Anything
# that is not that shape — the main checkout, the `.claude/` fallback — has no admin id to key on
# and is not a worktree prune would sweep, so it is skipped rather than guessed at. The `gitdir`
# file is required as well: git writes one into every linked worktree's admin directory, and it
# is what stops a checkout that merely sits in a directory called `worktrees` passing for one.
#
# THE SET-ASIDE NEVER OVERWRITES. Two sessions in one worktree can both find the old entry and
# pick the same `<id>.<when>`; a clobbering move would let the second replace the first's preserved
# copy with the first's new entry, losing the old allocation. A hard link fails rather than
# replace an existing name, so each session claims a free name or tries the next. The link is not
# undone if the write after it fails: the copy under the id may meanwhile be another session's,
# and a duplicate of an old entry costs prune nothing, where a lost one costs it a database.
#
# THE NAME IS THE FIRST ONE RECORDED for this path and slug: it is what teardown hands the teardown
# script as WT_NAME, and it must be the name the seed saw. A seed that first ran in a later session
# than the one that wrote the entry (a WorktreeCreate seed that failed, retried at SessionStart)
# saw the later name; the entry still holds the first. The rt record has no name field, so a
# teardown with no ledger entry derives the name from the path (wt_read_allocation).
wt_ledger_write() {  # $1 = worktree, $2 = the rt record
  local wt=${1%/} rtrec=${2-} state admin id common ledger entry kept tmp when n slug recorded_wt name

  wt_state_path "$wt" >/dev/null
  state=${WT_STATE_PATH_IS-}
  [ "${WT_STATE_PATH_FOR-}" = "$wt" ] && [ -n "$state" ] || return 0
  admin=${state%/*}
  [ "$admin" != "$wt/.claude" ] && [ -f "$admin/gitdir" ] || return 0
  id=${admin##*/}
  common=${admin%/*}
  [ "${common##*/}" = worktrees ] && [ -n "$id" ] || return 0
  common=${common%/*}
  ledger=$common/$WT_LEDGER_DIRNAME
  entry=$ledger/$id
  if ! wt_ledger_is_entry_name "$id"; then
    wt_log "runtime: worktree id \"$id\" cannot name a ledger entry — /pitlane-tidy will not know about this worktree's allocation"
    return 0
  fi

  if [ ! -d "$ledger" ] && ! mkdir -p "$ledger" 2>/dev/null; then
    wt_log "runtime: could not create the ledger at $ledger — /pitlane-tidy will not know about this worktree's allocation"
    return 0
  fi

  # An entry that does not parse is set aside too: it cannot be shown to be this worktree's, so it
  # is not this worktree's to erase.
  # The path is compared as the record holds it: folded by wt_state_join, or a path with a newline
  # would never match its own entry and be set aside again every session.
  wt_state_join "$wt"
  recorded_wt=$WT_STATE_REC
  name=${WT_NAME-}
  if [ -e "$entry" ]; then
    slug=${rtrec#rt"$WT_US"}
    slug=${slug%%"$WT_US"*}
    if ! wt_ledger_parse "$entry" || [ "$WT_LEDGER_PATH" != "$recorded_wt" ] \
      || [ "${WT_LEDGER_RT%%"$WT_US"*}" != "$slug" ]; then
      when=$(wt_runtime_state_read "$entry" when 2>/dev/null) || when=''
      wt_is_posint "$when" || when=$(date +%s 2>/dev/null) || when=0
      kept=$entry.$when
      n=0
      until ln "$entry" "$kept" 2>/dev/null; do
        if [ ! -e "$kept" ] || [ "$n" -ge 100 ]; then
          wt_log "runtime: could not set aside the earlier ledger entry $entry — keeping it, and not recording this worktree's allocation over it"
          return 0
        fi
        n=$((n + 1))
        kept=$entry.$when.$n
      done
    elif [ -n "$WT_LEDGER_NAME" ]; then
      # The same worktree and allocation: keep the name first recorded. A worktree WorktreeCreate
      # made from `alice/fix-99` lives in `alice-fix-99/`, so a later SessionStart derives a
      # different name from the path — and the seed, run on creation, saw the payload's.
      name=$WT_LEDGER_NAME
    fi
  fi

  wt_state_join worktree "$wt" "$id" "$name"
  if ! tmp=$(mktemp "$ledger/${WT_LEDGER_TMP_PREFIX}XXXXXX" 2>/dev/null); then
    wt_log "runtime: could not write to the ledger at $ledger — /pitlane-tidy will not know about this worktree's allocation"
    return 0
  fi
  if ! {
    printf 'wtstate%s%s%s' "$WT_US" "$WT_STATE_VERSION" "$WT_RS"
    printf '%s%s' "$WT_STATE_REC" "$WT_RS"
    printf '%s%s' "$rtrec" "$WT_RS"
  } >"$tmp" 2>/dev/null || ! mv -f "$tmp" "$entry" 2>/dev/null; then
    rm -f "${tmp:?}"
    wt_log "runtime: could not write the ledger entry $entry — /pitlane-tidy will not know about this worktree's allocation"
  fi
  return 0
}

# The ledger directory for the repository containing $1, which need not exist yet. The readers
# are not on the session-start path, so they ask git; the writer derives the same directory from
# the state path it already holds.
wt_ledger_dir() {  # $1 = any directory inside the repository
  local common
  common=$(wt_git_common_dir "${1:-$PWD}") || return 1
  printf '%s/%s' "$common" "$WT_LEDGER_DIRNAME"
}

# True if $1 may name a ledger entry. The readers join it onto the ledger directory and
# wt_ledger_forget deletes the result, so a `/`, `.` or `..` would let a caller reach outside it or
# at the directory itself. `..` INSIDE a name is no traversal and must stay legal: older git kept a
# basename's dots as they were, so `v1..2` is a real admin id, and refusing it would record an
# entry that no reader could then name. The writer applies this same test to the id.
wt_ledger_is_entry_name() {  # $1 = candidate
  case ${1-} in
    '' | . | .. | */* | "$WT_LEDGER_TMP_PREFIX"*) return 1 ;;
  esac
  return 0
}

# Every readable ledger entry of the repository containing $1, one WT_RS-terminated record each,
# fields joined by WT_US — the shape wt_json_records emits:
#
#   entry  path  admin  name  slug  port  portsource  envfile  envstate  seedstatus  seedcksum  when
#
# `entry` is the file name, which is what wt_ledger_field and wt_ledger_forget take; the rest are
# the recorded values in the order the records hold them. An entry that does not parse is left out
# of the stream but not deleted: it may be an allocation a newer build wrote.
#
# Returns 1 only when the repository cannot be resolved; an absent ledger is simply no entries.
wt_ledger_entries() {  # $1 = any directory inside the repository
  local ledger file entry
  ledger=$(wt_ledger_dir "${1:-$PWD}") || return 1
  [ -d "$ledger" ] || return 0
  for file in "$ledger"/*; do
    entry=${file##*/}
    wt_ledger_is_entry_name "$entry" || continue
    wt_ledger_parse "$file" || continue
    printf '%s%s%s%s%s%s%s%s%s%s' "$entry" "$WT_US" "$WT_LEDGER_PATH" "$WT_US" \
      "$WT_LEDGER_ADMIN" "$WT_US" "$WT_LEDGER_NAME" "$WT_US" "$WT_LEDGER_RT" "$WT_RS"
  done
  return 0
}

# Read one field of one ledger entry, by NAME: `path`, `admin`, `name`, or any field of the `rt`
# record. The status contract is wt_runtime_state_get's, so a consumer handles both alike:
#   0  read; the value is on stdout (possibly empty)
#   1  no usable entry by that name
#   2  a caller error — a field name no entry has, or a string that is not an entry name
wt_ledger_field() {  # $1 = any directory inside the repository, $2 = entry, $3 = field name
  local ledger entry=${2-} want=${3-}
  wt_ledger_is_entry_name "$entry" || return 2
  ledger=$(wt_ledger_dir "${1:-$PWD}") || return 1
  wt_ledger_parse "$ledger/$entry" || return 1
  case $want in
    path)  printf '%s' "$WT_LEDGER_PATH" ;;
    admin) printf '%s' "$WT_LEDGER_ADMIN" ;;
    name)  printf '%s' "$WT_LEDGER_NAME" ;;
    *)     wt_runtime_state_read "$ledger/$entry" "$want" ;;
  esac
}

# Remove exactly one ledger entry. Only once its allocation has been torn down: afterwards nothing
# records it. Returns 2 for a string that is not an entry name, 1 when there is no such entry or it
# could not be removed.
wt_ledger_forget() {  # $1 = any directory inside the repository, $2 = entry
  local ledger entry=${2-}
  if ! wt_ledger_is_entry_name "$entry"; then
    wt_log "refusing to forget ledger entry \"$entry\": not an entry name"
    return 2
  fi
  ledger=$(wt_ledger_dir "${1:-$PWD}") || return 1
  [ -f "$ledger/$entry" ] || return 1
  rm -f "${ledger:?}/${entry:?}" 2>/dev/null && [ ! -e "$ledger/$entry" ]
}

# `cksum` of a string, for fingerprinting an install command. Empty for empty input, so a missing
# command never compares equal to a present one by accident.
wt_cksum_string() {  # $1 = text
  local out
  [ -n "${1-}" ] || { printf ''; return 0; }
  out=$(printf '%s' "$1" | cksum 2>/dev/null) || { printf ''; return 1; }
  printf '%s' "$out"
}

# `cksum` of a file, or empty when it is absent or unreadable.
wt_cksum_file() {  # $1 = path
  local out
  [ -f "${1-}" ] && [ -r "$1" ] || { printf ''; return 0; }
  out=$(cksum <"$1" 2>/dev/null) || { printf ''; return 1; }
  printf '%s' "$out"
}

# Read one dependency's record into WT_DEP_STRATEGY, WT_DEP_LCK, WT_DEP_ICK, WT_DEP_STATUS,
# WT_DEP_RC and WT_DEP_REASON. Returns 1, with them all empty, when there is no usable record.
# Globals rather than output so a caller in its own shell gets every field from one read.
wt_state_dep_read() {  # $1 = worktree, $2 = dir
  local wt=${1%/} dir=${2-} file rec kind rest rdir rwhen seen=0
  WT_DEP_STRATEGY='' WT_DEP_LCK='' WT_DEP_ICK='' WT_DEP_STATUS='' WT_DEP_RC='' WT_DEP_REASON=''
  file=$(wt_state_path "$wt")
  [ -r "$file" ] || return 1
  while IFS= read -r -d "$WT_RS" rec; do
    kind=${rec%%"$WT_US"*}
    rest=${rec#*"$WT_US"}
    case $kind in
      wtstate)
        [ "${rest%%"$WT_US"*}" = "$WT_STATE_VERSION" ] || return 1
        seen=1
        ;;
      dep)
        [ "$seen" = 1 ] || return 1
        [ "${rest%%"$WT_US"*}" = "$dir" ] || continue
        # SC2034: rdir and rwhen are read POSITIONALLY to consume their fields.
        # shellcheck disable=SC2034
        IFS=$WT_US read -r rdir WT_DEP_STRATEGY WT_DEP_LCK WT_DEP_ICK WT_DEP_STATUS rwhen \
          WT_DEP_RC WT_DEP_REASON <<<"$rest" || true
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

# Read back the recorded status for one dependency: `done`, `warn`, `failed`, `doing`, `dirty`, or
# empty when there is no usable record. Needed as well as wt_state_is_done because "we were
# interrupted" and "we have never run" call for different handling — only the first justifies
# deleting anything.
wt_state_status() {  # $1 = worktree, $2 = dir
  wt_state_dep_read "$1" "${2-}" || true
  printf '%s' "$WT_DEP_STATUS"
}

# True when this dependency's install FAILED with the same lockfile, install command and strategy as
# now: running it again would fail the same way. Leaves the recorded exit code and error line in
# WT_DEP_RC and WT_DEP_REASON for the caller's message.
wt_state_failure_stands() {  # $1 = worktree, $2 = dir, $3 = lock cksum, $4 = install cksum, $5 = strategy
  wt_state_dep_read "$1" "${2-}" || return 1
  [ "$WT_DEP_STATUS" = failed ] && [ "$WT_DEP_LCK" = "${3-}" ] && [ "$WT_DEP_ICK" = "${4-}" ] \
    && [ "$WT_DEP_STRATEGY" = "${5-}" ]
}

# The line an install's output ends on that best says why it failed: the last one that looks like an
# error, else the last non-empty one. Made safe to record and to show: escape sequences removed,
# then everything outside printable ASCII (the record's separators included), capped at 160.
wt_install_error_line() {  # $1 = file holding the install's output
  [ -r "${1-}" ] || return 0
  # One awk for what was a six-stage pipeline. Only the last 400 lines count, as `tail -n 400`
  # counted them: a match is kept with its line number and dropped at the end if it fell outside.
  LC_ALL=C awk '
    {
      n = split($0, part, "\r")
      for (i = 1; i <= n; i++) {
        s = part[i]
        gsub(/\033\[[0-9;?]*[A-Za-z]/, "", s)
        gsub(/[^ -~]/, "", s)
        sub(/^ +/, "", s)
        sub(/ +$/, "", s)
        if (s == "") continue
        last = s; lastnr = NR
        if (tolower(s) ~ /err|fail|fatal/) { hit = s; hitnr = NR }
      }
    }
    END {
      first = NR - 399
      out = ""
      if (hit != "" && hitnr >= first) out = hit
      else if (lastnr >= first) out = last
      print substr(out, 1, 160)
    }' "$1" 2>/dev/null
}

# True if $1 contains a character that lets it stop being a value and start being syntax.
#
# Tested one character at a time rather than with a single bracket glob: a bracket expression
# containing `[` and `]` is a well-known way to write a pattern that silently matches nothing,
# which is exactly what a security check must not do. (It did, in the first version of this: the
# malformed glob never fired and an injected command ran.)
#
# A SPACE IS DELIBERATELY ALLOWED. It can split a word, which is the profile author's problem and
# is visible, but it cannot begin a second command — and {worktree}/{root} are absolute paths that
# may legitimately contain one.
wt_value_has_shell_syntax() {  # $1 = value
  local v=${1-} c
  case $v in
    *"$WT_NL"* | *"$WT_CR"*) return 0 ;;
  esac
  # SC1003: '\' is a literal backslash, which is one of the characters being looked for.
  # shellcheck disable=SC1003
  for c in ';' '&' '|' '<' '>' '(' ')' '`' '$' '\' '"' "'" '*' '?' '[' ']' '{' '}' '!'; do
    case $v in
      *"$c"*) return 0 ;;
    esac
  done
  return 1
}

# Name the first placeholder in $1 whose value is unsafe to put in command position, or nothing.
#
# THIS DISCHARGES THE OBLIGATION lib.sh's wt_expand states and assigns to bootstrap:
# "SUBSTITUTION IS NOT QUOTING ... a caller placing an unconstrained placeholder in command
# position must quote it itself." An install command is exactly that position. {slug} and {port}
# are safe by construction ([a-z0-9_] and digits); {name}, {worktree} and {root} are raw text, and
# {name} in particular comes from a DIFFERENT AND LESS TRUSTED PARTY than the profile does — the
# profile's commands run only once the developer has approved them (wt_approval_check), while a
# worktree name can be chosen by whoever opens a PR or by a mid-session EnterWorktree call. A profile line as ordinary as `pnpm install --filter {name}`
# plus a branch called `q; rm -rf ~` would otherwise run the second command at session start.
#
# Refusing is chosen over auto-quoting because quoting cannot be done safely without knowing the
# author's own quoting: wrapping the value in single quotes breaks `"{worktree}/bin/console"`,
# where the inserted quotes would become literal characters. Refusing costs one dependency and
# says exactly why; guessing costs correctness silently.
wt_unsafe_command_placeholder() {  # $1 = the UNEXPANDED template
  local tpl=${1-} tok val
  for tok in name worktree root; do
    case $tpl in
      *"{$tok}"*) ;;
      *) continue ;;
    esac
    case $tok in
      name)     val=${WT_NAME-} ;;
      worktree) val=${WT_PATH-} ;;
      root)     val=${WT_ROOT-} ;;
    esac
    if wt_value_has_shell_syntax "$val"; then
      printf '%s' "$tok"
      return 0
    fi
  done
  printf ''
  return 0
}

# Expand the runtime command template $1 (`runtime.serve` or `runtime.stop`) for this worktree, by
# the install command's rule: printed when every placeholder in it is safe here; refused — the
# reason printed, return 1 — when one would carry shell syntax into command position. Runs nothing.
wt_runtime_command() {  # $1 = the UNEXPANDED template
  local tpl=${1-} bad
  [ -n "$tpl" ] || { printf 'the profile has no such command'; return 1; }
  bad=$(wt_unsafe_command_placeholder "$tpl")
  if [ -n "$bad" ]; then
    printf 'it interpolates {%s}, whose value here contains shell metacharacters' "$bad"
    return 1
  fi
  wt_expand "$tpl"
}

# Resolve the two git-directory lookups ONCE, in the caller's own shell, so the memos inside
# wt_state_path and wt_lock_path are actually populated when those run inside a command
# substitution. Without this the caches are dead code: each of the ~4 calls per dependency forks
# `git rev-parse` again, on the re-entry path whose entire purpose is to cost milliseconds.
wt_prime_paths() {  # $1 = main checkout, $2 = worktree
  wt_state_path "${2%/}" >/dev/null
  wt_lock_path "${1%/}" _prime >/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
#
# One entry in deps[] at a time: decide, do, verify, record — the whole of it inside that
# dependency's lock, because the decision and the action must not be separated by another
# worktree's install.
#
# EVERY FAILURE WARNS AND CONTINUES. A worktree missing its vendor/ is a five-second fix; a
# session that will not start is lost work. Nothing below returns non-zero to the
# entrypoint, and no step's failure prevents the next dependency being attempted.

# Seconds left of the bootstrap budget, floor 0.
wt_budget_left() {  # $1 = deadline, epoch seconds
  local now
  now=$(date +%s 2>/dev/null) || { printf '%s' "$WT_DEFAULT_TIMEOUT"; return 0; }
  case ${1-} in '' | *[!0-9]*) printf '%s' "$WT_DEFAULT_TIMEOUT"; return 0 ;; esac
  if [ "$1" -le "$now" ]; then printf '0'; else printf '%s' $(($1 - now)); fi
}

# Populate one dependency directory by copying the main checkout's with hardlinks.
#
# Returns 0 on success, 1 to say "fall back to a real install". A hardlink copy of a 400 MB
# vendor/ is near-instant and costs almost no disk, but it is only VALID when the two
# checkouts want the same dependencies — which is what comparing the lockfiles establishes — and
# it is not always possible: a worktree on another filesystem cannot hardlink at all.
#   0 = linked, 1 = fall back to a real install, 2 = already present, nothing done.
wt_hardlink_dep() {  # $1 = root, $2 = worktree, $3 = dir, $4 = lock
  # No initialisers built from $1/$3 here: with fewer arguments than expected that is a fatal
  # unbound-variable error under `set -u`, which is precisely the crash this layer must not cause.
  local root=${1%/} worktree=${2%/} dir=${3-} lock=${4-} src dest err

  src=$root/$dir
  dest=$worktree/$dir

  if [ ! -d "$src" ]; then
    wt_log "  $dir: the main checkout has no $dir to link from — installing instead"
    return 1
  fi
  # An empty source would "succeed" and leave an empty dependency directory that then looks
  # installed to everything downstream.
  if [ -z "$(ls -A "$src" 2>/dev/null)" ]; then
    wt_log "  $dir: the main checkout's $dir is empty — installing instead"
    return 1
  fi
  # THE VALIDITY TEST. Hardlinking a tree built for a different lockfile gives a worktree
  # dependencies its own branch never asked for, which is worse than a slow install because it
  # looks like it worked. `cmp -s` rather than two checksums: it is exact and stops at the first
  # differing byte.
  if [ -z "$lock" ] || [ ! -f "$root/$lock" ] || [ ! -f "$worktree/$lock" ]; then
    wt_log "  $dir: cannot compare $lock between the checkouts — installing instead"
    return 1
  fi
  if ! cmp -s "$root/$lock" "$worktree/$lock"; then
    wt_log "  $dir: $lock differs from the main checkout — installing instead"
    return 1
  fi
  if [ -e "$dest" ]; then
    # A distinct code, not success: the caller must not report a link it did not make.
    wt_log "  $dir: already present in the worktree — leaving it alone"
    return 2
  fi

  # A nested dir (vendor/bundle) has a parent the worktree may not have yet, and `cp -al` does not
  # make one. Re-checked here because this is a write: the caller refused unsafe shapes and
  # symlinked ancestors, so the parent can only land inside the worktree.
  if [ "${dir%/*}" != "$dir" ]; then
    if ! wt_is_safe_relpath "$dir" || wt_has_symlinked_parent "$worktree" "$dir"; then
      wt_log "  $dir: not a plain path inside the worktree — installing instead"
      return 1
    fi
    if ! err=$(mkdir -p -- "${dest%/*}" 2>&1); then
      wt_log "  $dir: could not create its parent directory (${err:-mkdir failed}) — installing instead"
      return 1
    fi
  fi

  # `cp -al` fails on a cross-filesystem copy and on filesystems without hardlinks. Both are
  # ordinary situations, not errors: fall back rather than dying. Any partial tree is
  # removed first, or the install that follows would run on top of debris. cp's own first line is
  # what gets logged: guessing a cause blamed the filesystem for what was a missing directory.
  if err=$(cp -al "$src" "$dest" 2>&1); then
    return 0
  fi
  rm -rf "$dest" 2>/dev/null
  wt_log "  $dir: could not hardlink (${err%%"$WT_NL"*}) — installing instead"
  return 1
}

# ---------------------------------------------------------------------------
# The toolchain, started once and on demand
# ---------------------------------------------------------------------------
#
# The profile's `shell` is entered by every install and by the seed, and the FIRST entry in a new
# worktree can take any amount of time: a toolchain download after its lockfile changed (measured:
# 2 GB, five minutes, for one nixpkgs bump), an image pull, a runtime install. Paid inside the first
# install, it ate the whole budget and nothing said why. So it is paid once, as its own step, timed and
# reported, right before the first command that needs it — never on a session where nothing does, so
# a re-entry stays at its sub-second cost.
#
# WT_TOOLCHAIN: '' (not tried), ready, slow (timed out — a download is probably still going; a later
# step with time of its own may try again, and the download resumes), broken (exited non-zero),
# lowmem (the resource guard refused it or stopped it at its cap — retried by the next run).
WT_TOOLCHAIN=''

wt_toolchain_warm() {  # $1 = worktree, $2 = deadline (epoch seconds); returns 0 when the shell is usable
  local worktree=${1%/} deadline=${2-} left started rc elapsed
  [ -n "${PROFILE_SHELL:-}" ] || return 0
  case $WT_TOOLCHAIN in
    ready) return 0 ;;
    broken | lowmem) return 1 ;;
  esac
  left=$(wt_budget_left "$deadline")
  if [ "$left" -le 0 ]; then
    return 1
  fi
  wt_log "  toolchain: starting ${PROFILE_SHELL} (${left}s of the budget left) — the first time in a new worktree, or after its lockfile changes, this may download it"
  started=$(date +%s 2>/dev/null) || started=''
  wt_run_in_shell "true" "$worktree" "$left"
  rc=$?
  elapsed=''
  [ -n "$started" ] && elapsed=$(( $(date +%s) - started ))
  case $rc in
    0)
      WT_TOOLCHAIN=ready
      wt_log "  toolchain: ready${elapsed:+ in ${elapsed}s}"
      return 0
      ;;
    124)
      WT_TOOLCHAIN=slow
      wt_log "  toolchain: still not ready after ${elapsed:-$left}s — it is probably downloading; the steps that need it are left for /pitlane-finish or the next session"
      return 1
      ;;
    137 | "$WT_GUARD_REFUSED")
      # The guard's doing, not the toolchain's: retried by the next run, which may have more memory.
      WT_TOOLCHAIN=lowmem
      return 1
      ;;
    *)
      WT_TOOLCHAIN=broken
      wt_log "  toolchain: \"${PROFILE_SHELL}\" failed to start (exit $rc) — the steps that need it are skipped; run it by hand in the worktree to see why"
      return 1
      ;;
  esac
}

# True when the state file lives in the worktree's git dir, not the `.claude/` fallback inside the
# working tree that wt_state_path uses when git cannot name one.
wt_state_in_git_dir() {  # $1 = worktree
  [ "$(wt_state_path "$1")" != "${1%/}/$WT_STATE_FALLBACK_REL" ]
}

# Where one dependency's install output is captured: beside the state file, so it goes when the
# worktree goes, and overwritten by the next install of the same directory. Returns 1, printing
# nothing, when the state is in the working-tree fallback: a log there would be a file the
# developer could commit, so the install's output goes straight to stderr instead.
wt_install_capture_path() {  # $1 = worktree, $2 = dependency dir
  local p
  wt_state_in_git_dir "$1" || return 1
  p=$(wt_state_path "$1")
  printf '%s/worktree-bootstrap.install.%s.log' "${p%/*}" "${2//[!A-Za-z0-9._-]/_}"
}

# How long a status run for a caller with no deadline of its own (--finish, --changed) may take.
WT_STATUS_SECONDS=30
# '' until probed, then yes/no: whether this git takes --no-optional-locks (2.15 and later).
WT_GIT_OPTIONAL_LOCKS=''
WT_TRACKING_SKIP_LOGGED=''

# Said once per run: an install's changes to tracked files going unchecked must not be silent.
wt_log_tracking_skipped() {  # $1 = why
  [ -z "$WT_TRACKING_SKIP_LOGGED" ] || return 0
  WT_TRACKING_SKIP_LOGGED=1
  wt_log "  not checking which tracked files the installs change: $1"
}

# The worktree's tracked paths that differ from HEAD, staged or not, one per line in
# WT_TRACKED_CHANGES. Returns 1 when git cannot say, and the caller then records nothing rather
# than guess.
#
# --no-optional-locks: the live session may run git at the same moment, and a status that refreshes
# the index would take index.lock from under it. A git without the flag is not asked at all, for
# the same reason. Bounded by $2's budget, because it runs on the session-start path and a large
# repo's status takes seconds. --ignore-submodules=dirty: a submodule's own working tree is not
# this worktree's tracked content, and walking it is the slow part. Untracked and ignored files are
# left out: they are what an install is meant to write. Renames are parsed, not turned off
# (--no-renames needs 2.18): a staged rename names both its paths. A newline in a name becomes a
# US byte, which the state cannot hold either, so wt_install_note_changes can tell it was folded.
wt_tracked_changes() {  # $1 = worktree, $2 = deadline (epoch seconds; empty = WT_STATUS_SECONDS)
  local left listing rc=0
  WT_TRACKED_CHANGES=''
  if [ -n "${2-}" ]; then left=$(wt_budget_left "$2"); else left=$WT_STATUS_SECONDS; fi
  if [ "$left" -le 0 ]; then
    wt_log_tracking_skipped "no budget left to ask git"
    return 1
  fi
  if [ -z "$WT_GIT_OPTIONAL_LOCKS" ]; then
    wt_git "$1" --no-optional-locks version >/dev/null 2>&1 || rc=$?
    case $rc in
      0) WT_GIT_OPTIONAL_LOCKS=yes ;;
      127) return 1 ;;
      *) WT_GIT_OPTIONAL_LOCKS=no ;;
    esac
  fi
  if [ "$WT_GIT_OPTIONAL_LOCKS" = no ]; then
    wt_log_tracking_skipped "this git is older than 2.15, and its status would take the index lock the session may need"
    return 1
  fi
  listing=$(set -o pipefail
    wt_git_within "$left" "$1" --no-optional-locks status --porcelain -z --untracked-files=no \
      --ignore-submodules=dirty 2>/dev/null \
      | tr '\n\000' '\037\n' \
      | LC_ALL=C awk 'from { from = 0; print; next }
          { print substr($0, 4); x = substr($0, 1, 2) }
          x ~ /[RC]/ { from = 1 }') || rc=$?
  case $rc in
    0) ;;
    124)
      wt_log_tracking_skipped "git status took longer than the ${left}s it had"
      return 1
      ;;
    *) return 1 ;;
  esac
  WT_TRACKED_CHANGES=$listing
  return 0
}

# Each non-empty line of $2 that is (wt_lines_in) or is not (wt_lines_not_in) a line of $1, in
# order. Whole lines compared as bytes: a path holding `*` or `[` is not a pattern here. One awk
# each, linear in both sets: a checkout with thousands of dirty paths is ordinary.
wt_lines_in() {  # $1 = set, $2 = lines
  LC_ALL=C awk 'FNR == NR { set[$0] = 1; next } $0 != "" && ($0 in set)' \
    <(printf '%s\n' "${1-}") <(printf '%s\n' "${2-}")
}

wt_lines_not_in() {  # $1 = set, $2 = lines
  LC_ALL=C awk 'FNR == NR { set[$0] = 1; next } $0 != "" && !($0 in set)' \
    <(printf '%s\n' "${1-}") <(printf '%s\n' "${2-}")
}

# Lines of $1 joined by $2 (default ", "), for a human or the model to read. A name holding a
# control byte is shown in bash's $'…' quoting: names are branch content, and a raw ESC would drive
# the terminal it is printed on. A US byte is shown as the newline wt_tracked_changes folded.
wt_paths_display() {  # $1 = paths, one per line, $2 = separator
  local path out='' sep=${2-, }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case $path in
      *[[:cntrl:]]*) printf -v path '%q' "${path//"$WT_US"/$WT_NL}" ;;
    esac
    out+=${out:+$sep}$path
  done <<<"${1-}"
  printf '%s' "$out"
}

# The paths recorded for one dependency's installs ($2), or for every dependency's ($2 omitted),
# one per line. A `changed` record is `changed <dir> <path>...`: a variable number of fields, which
# the format carries because a path cannot hold a US byte (wt_state_join strips it). A new record
# KIND, so no version bump (see the runtime record above for why that is safe).
wt_install_changed_recorded() {  # $1 = worktree, $2 = dir (optional)
  local file rec rest seen=0
  file=$(wt_state_path "$1")
  [ -r "$file" ] || return 0
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      "wtstate$WT_US"*)
        [ "${rec#wtstate"$WT_US"}" = "$WT_STATE_VERSION" ] || return 0
        seen=1
        ;;
      "changed$WT_US"*)
        [ "$seen" = 1 ] || return 0
        rest=${rec#changed"$WT_US"}
        [ -z "${2+set}" ] || [ "${rest%%"$WT_US"*}" = "$2" ] || continue
        case $rest in *"$WT_US"*) printf '%s\n' "${rest#*"$WT_US"}" | tr "$WT_US" '\n' ;; esac
        ;;
    esac
  done <"$file"
  return 0
}

# Record and report the tracked paths one install changed. $3 is wt_tracked_changes from just
# before the install; the after-snapshot is taken here, first thing, so that an edit the session
# makes once the install is over is never counted as the install's.
#
# THE RACE THAT STAYS OPEN: the session runs alongside a background install (ADR-019), and an edit
# it makes to a clean tracked file DURING the install looks exactly like the install's. That is
# why nothing is ever restored automatically, and /pitlane-finish restores path by path on the
# user's word. A path already changed before the install is never attributed to it, even if the
# install changed it further: the session's edit there must not be offered for a restore.
#
# A path recorded by an earlier install of this dir is kept while it is still changed, so a
# re-install that finds it already dirty does not forget who dirtied it.
#
# A name the state cannot hold (a newline, CR, US or RS in it) is named in the log but not recorded:
# stored, it would be folded into a name that may be a different file, and offered for a restore.
wt_install_note_changes() {  # $1 = worktree, $2 = dir, $3 = tracked changes before, $4 = deadline
  local worktree=$1 dir=$2 before=${3-} after changed prior kept rec paths=() unheld='' path
  wt_tracked_changes "$worktree" "${4-}" || return 0
  after=$WT_TRACKED_CHANGES
  changed=$(wt_lines_not_in "$before" "$after")
  prior=$(wt_install_changed_recorded "$worktree" "$dir")
  [ -n "$changed" ] || [ -n "$prior" ] || return 0
  kept=$(wt_lines_in "$after" "$prior")
  while IFS= read -r path; do
    case $path in
      '') ;;
      *["$WT_US$WT_RS$WT_CR"]*) unheld+=$path$WT_NL ;;
      *) paths+=("$path") ;;
    esac
  done <<<"$kept$WT_NL$(wt_lines_not_in "$kept" "$changed")"
  # No paths left: the record goes, so a clean worktree has none for the status line to look into.
  rec=''
  if [ "${#paths[@]}" -gt 0 ]; then
    wt_state_join changed "$dir" "${paths[@]}"
    rec=$WT_STATE_REC
  fi
  wt_state_join "$dir"
  wt_state_rewrite "$worktree" changed "$WT_STATE_REC" "$rec" || true
  [ -n "$changed" ] || return 0
  wt_log "  $dir: the install changed tracked files: $(wt_paths_display "$changed") — left as they are (the session may be editing them too); /pitlane-finish shows the diff and restores a path only on your word"
  [ -z "$unheld" ] || wt_log "  $dir: $(wt_paths_display "$unheld") cannot be recorded by name, so /pitlane-finish will not offer it — look at it with git status"
}

# Every tracked path an install changed that is still changed now, one per line, each once, raw, in
# WT_INSTALL_CHANGED: wt_paths_display before printing one. If git cannot say, or $2's budget is
# spent, it is the record as is. A path the developer restored, or committed, drops out — of the
# record too, so a worktree whose changes are all gone stops paying for the git status that found it.
#
# FREE WHEN THERE IS NO RECORD, which is every clean worktree on every session start: the state file
# is read with bash's own `read`, and nothing forks until a `changed` record holding a path is found.
wt_install_changed_collect() {  # $1 = worktree, $2 = deadline (epoch seconds; empty = WT_STATUS_SECONDS)
  local worktree=${1%/} file rec records='' recorded left deadline=${2-} seen=0
  WT_INSTALL_CHANGED=''
  # The memo read directly: wt_state_path answers through a command substitution, i.e. a fork.
  if [ "${WT_STATE_PATH_FOR:-}" = "$worktree" ] && [ -n "${WT_STATE_PATH_IS:-}" ]; then
    file=$WT_STATE_PATH_IS
  else
    file=$(wt_state_path "$worktree")
  fi
  [ -r "$file" ] || return 0
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      "wtstate$WT_US"*)
        [ "${rec#wtstate"$WT_US"}" = "$WT_STATE_VERSION" ] || return 0
        seen=1
        ;;
      "changed$WT_US"*"$WT_US"*)
        [ "$seen" = 1 ] || return 0
        records+=${rec#changed"$WT_US"}$WT_NL
        ;;
    esac
  done <"$file"
  [ -n "$records" ] || return 0
  recorded=$(printf '%s' "$records" | cut -d "$WT_US" -f 2- | tr "$WT_US" '\n' | LC_ALL=C awk '$0 != "" && !seen[$0]++')
  # Capped at WT_STATUS_SECONDS: this is a status read, and a profile's budget can run to minutes.
  if [ -n "$deadline" ]; then
    left=$(wt_budget_left "$deadline")
    if [ "$left" -le 0 ]; then
      WT_INSTALL_CHANGED=$recorded
      return 0
    fi
    [ "$left" -lt "$WT_STATUS_SECONDS" ] || deadline=''
  fi
  if ! wt_tracked_changes "$worktree" "$deadline"; then
    WT_INSTALL_CHANGED=$recorded
    return 0
  fi
  WT_INSTALL_CHANGED=$(wt_lines_in "$WT_TRACKED_CHANGES" "$recorded")
  [ "$WT_INSTALL_CHANGED" = "$recorded" ] || wt_install_changed_prune "$worktree" "$records" "$WT_TRACKED_CHANGES"
  return 0
}

# Drop from each `changed` record ($2: `dir US path…` per line, as read) the paths no longer changed
# ($3: wt_tracked_changes), and a record left with none. Only under the worktree's lock, re-reading
# each record there: a run holding it may be writing the state, and a rewrite from what was read
# before would put back what that run just changed. Busy, it is skipped; the next read tries again.
# With no flock at all nothing is serialised anyway (wt_lock_acquire), so it goes ahead unlocked.
wt_install_changed_prune() {  # $1 = worktree, $2 = records, $3 = tracked changes now
  local worktree=${1%/} line dir paths kept rec held=0 path
  local -a keep
  if command -v flock >/dev/null 2>&1; then
    wt_lock_acquire "$(wt_state_path "$worktree").lock" 0 8 || return 0
    held=1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    dir=${line%%"$WT_US"*}
    paths=$(wt_install_changed_recorded "$worktree" "$dir")
    kept=$(wt_lines_in "${3-}" "$paths")
    [ "$kept" != "$paths" ] || continue
    keep=()
    while IFS= read -r path; do
      [ -z "$path" ] || keep+=("$path")
    done <<<"$kept"
    rec=''
    if [ "${#keep[@]}" -gt 0 ]; then
      wt_state_join changed "$dir" "${keep[@]}"
      rec=$WT_STATE_REC
    fi
    wt_state_join "$dir"
    wt_state_rewrite "$worktree" changed "$WT_STATE_REC" "$rec" || true
  done <<<"${2-}"
  [ "$held" -eq 0 ] || wt_lock_release 8
  return 0
}

# wt_install_changed_collect's list, printed: one path per line.
wt_install_changed_paths() {  # $1 = worktree, $2 = deadline (optional)
  wt_install_changed_collect "$1" "${2-}"
  [ -z "$WT_INSTALL_CHANGED" ] || printf '%s\n' "$WT_INSTALL_CHANGED"
}

# Put one path an install changed back to its committed content, index and working tree, printing
# one line. Returns 1, restoring nothing, for a path wt_install_changed_paths does not name — the
# only paths this is for — or one holding a control byte, which a person should look at first.
# --literal-pathspecs: a tracked file named `*` or `:/` must restore that one file, not every file
# the pattern matches (`--` alone does not stop pathspec magic). `checkout HEAD` rather than
# `restore`: it is on every git, and it resets the index too, so a staged change goes as well.
wt_install_restore() {  # $1 = worktree, $2 = path, relative to the worktree's root
  local worktree=${1%/} path=${2-} err shown
  case $path in
    '')
      printf 'Pitlane: no path given to restore.\n'
      return 1
      ;;
    *[[:cntrl:]]*)
      printf -v shown '%q' "$path"
      printf 'Pitlane: not restoring %s — its name holds control characters; look at it with git status and restore it by hand if you are sure.\n' "$shown"
      return 1
      ;;
  esac
  if [ -z "$(wt_lines_in "$(wt_install_changed_paths "$worktree")" "$path")" ]; then
    printf 'Pitlane: not restoring %s — it is not a tracked file an install changed (see --changed).\n' "$path"
    return 1
  fi
  if ! err=$(wt_git "$worktree" --literal-pathspecs checkout HEAD -- "$path" 2>&1); then
    printf 'Pitlane: could not restore %s: %s\n' "$path" "$(wt_paths_display "${err%%"$WT_NL"*}")"
    return 1
  fi
  printf 'Pitlane: restored %s to its committed content.\n' "$path"
}

wt_dep_log_failure_stands() {  # $1 = dir, $2 = lock, $3 = recorded exit code, $4 = recorded error line
  local why="exit ${3:-?}${4:+: $4}"
  wt_log "  $1: the recorded failure stands ($why) — not retrying an install that would fail the same way; it is retried once ${2:-its lockfile} or the install command changes, or now by: bash \"${WT_BOOTSTRAP_SCRIPT:-bootstrap.sh}\" --finish --retry-failed"
}

# Bootstrap every entry in deps[]. $3 is the epoch second the whole bootstrap must be finished by.
#
# TWO PASSES, cheapest first: hardlinked entries (a second or so each, and no toolchain needed), then
# installed ones. Profile order used to decide, so one slow install early in the list left every
# hardlink after it undone when the budget ran out.
wt_bootstrap_deps() {  # $1 = root, $2 = worktree, $3 = deadline
  local root=${1%/} worktree=${2%/} deadline=${3-}
  local rec body dir lock strategy install verify _cksum n=-1
  local lckhash ickhash status left rc lockpath held effective started elapsed bad
  local stands stood_rc stood_reason capture reason outcome vrc tracked_before tracking

  [ -n "${PROFILE_RAW:-}" ] || return 0

  local pass
  for pass in cheap slow; do
  n=-1
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    n=$((n + 1))
    body=${rec#*"$WT_US"}
    IFS=$WT_US read -r dir lock strategy install verify _cksum <<<"$body" || true
    case $pass:$strategy in
      cheap:hardlink | cheap:skip | slow:install | slow:store) ;;
      slow:hardlink | slow:skip | cheap:*) continue ;;
      *) ;;
    esac

    # Public entry point, so the shapes are re-checked rather than assumed validated. A `dir` of
    # ../../.. reaches `rm -rf` and `cp -al` further down.
    if [ -n "$dir" ] && ! wt_is_safe_relpath "$dir"; then
      wt_log "deps[$n]: refusing \"$dir\" — not a relative path inside the repository"
      continue
    fi
    if [ -n "$lock" ] && ! wt_is_safe_relpath "$lock"; then
      wt_log "deps[$n]: refusing lock \"$lock\" — not a relative path inside the repository"
      continue
    fi
    # The shape check is not enough on THIS path, because what follows is `rm -rf` and `cp -al`.
    # Both follow symlinked ancestors, so a profile naming `sub/vendor` plus a committed
    # `sub -> /home/alice/.ssh` would delete and write outside the worktree entirely. Same guard
    # the copier and the locking already apply; this is the one path that DELETES trees.
    if [ -n "$dir" ] && { wt_has_symlinked_parent "$worktree" "$dir" || wt_has_symlinked_parent "$root" "$dir"; }; then
      wt_log "deps[$n]: refusing \"$dir\" — one of its parent directories is a symlink"
      continue
    fi

    case $strategy in
      skip)
        wt_log "  ${dir:-deps[$n]}: strategy is skip — not touched"
        continue
        ;;
      store)
        # A valid schema value that nothing implements yet. Treated as install, which is
        # always correct if slower, and said out loud so nobody assumes a store exists.
        wt_log "  ${dir:-deps[$n]}: strategy \"store\" is not implemented yet — installing instead"
        strategy=install
        ;;
      install | hardlink) ;;
      *)
        # Reachable only with WT_SKIP_VALIDATION, but this function re-checks rather than assumes.
        # Falling through would reach the else branch below and record the dependency `done`
        # having done nothing at all.
        wt_log "  ${dir:-deps[$n]}: unknown strategy \"$strategy\" — skipping it"
        continue
        ;;
    esac
    if [ -z "$dir" ]; then
      wt_log "deps[$n]: no directory to populate — skipping"
      continue
    fi

    # A command that interpolates an unconstrained placeholder is refused when that placeholder's
    # value would be shell syntax rather than a value. See wt_unsafe_command_placeholder.
    bad=$(wt_unsafe_command_placeholder "$install")
    [ -n "$bad" ] || bad=$(wt_unsafe_command_placeholder "$verify")
    if [ -n "$bad" ]; then
      wt_log "  ${dir:-deps[$n]}: refusing to run its commands — they interpolate {$bad}, whose value contains shell metacharacters"
      continue
    fi

    # Placeholders expand HERE, not at read time, so the checksum recorded in the state file is
    # of the command that actually ran.
    install=$(wt_expand "$install")
    verify=$(wt_expand "$verify")

    lckhash=$(wt_cksum_file "$worktree/$lock")
    ickhash=$(wt_cksum_string "$install")

    if wt_state_is_done "$worktree" "$dir" "$lckhash" "$ickhash" "$strategy"; then
      wt_log "  $dir: already up to date"
      continue
    fi
    # Settled before the lock and the deferral, so a standing failure neither waits for a lock nor
    # starts a background run that would only say this again. A hardlink is still tried below: its
    # failure was the fallback install's, and the link may work now. WT_RETRY_FAILED (`--finish
    # --retry-failed`, run on the user's word) is how a failure that was the network's, not the
    # lockfile's, gets another go: nothing automatic can tell the two apart.
    if [ "$strategy" = install ] && [ "${WT_RETRY_FAILED:-}" != 1 ] && wt_state_failure_stands "$worktree" "$dir" "$lckhash" "$ickhash" "$strategy"; then
      wt_dep_log_failure_stands "$dir" "$lock" "$WT_DEP_RC" "$WT_DEP_REASON"
      continue
    fi

    # Not approved: an install is left undone, before any lock is taken or anything cleared. Not
    # recorded either — the state still says "not done", which is what the session is told.
    if [ "${WT_APPROVAL:-}" = no ] && [ "$strategy" = install ]; then
      wt_log "  $dir: not installed — the profile's commands are not approved"
      continue
    fi

    # Deferred: an install is the slow part, and the background run that follows does it.
    if [ "${WT_DEFER:-0}" = 1 ] && [ "$strategy" = install ]; then
      wt_log "  $dir: to be installed in the background"
      continue
    fi

    left=$(wt_budget_left "$deadline")
    if [ "$left" -le 0 ]; then
      wt_log "  $dir: out of time before starting — leaving it for the next session"
      continue
    fi

    # ONE lock around decide-and-do. Splitting them would let another worktree's install land
    # between "the lockfiles match" and the `cp -al` that relies on it.
    lockpath=$(wt_lock_path "$root" "$dir")
    held=0
    wt_lock_acquire "$lockpath" "$WT_LOCK_WAIT" 9
    case $? in
      0) held=1 ;;
      1) wt_log "  $dir: another worktree is working on it — continuing without the lock" ;;
    esac

    # RE-CHECK UNDER THE LOCK. Two sessions entering the same worktree both decide "not done"
    # outside it; without this the second waits out the lock and then repeats an install the
    # first just finished. Checking the marker outside the lock and acting on it inside is the
    # source conversation's bug 1 in a different costume.
    if [ "$held" -eq 1 ] && wt_state_is_done "$worktree" "$dir" "$lckhash" "$ickhash" "$strategy"; then
      wt_log "  $dir: another session finished it while we waited"
      wt_lock_release 9
      continue
    fi

    # Read before `doing` overwrites it: a hardlink only learns below whether it needs the install.
    stands=0 stood_rc='' stood_reason=''
    if [ "$strategy" = hardlink ] && [ "${WT_RETRY_FAILED:-}" != 1 ] && wt_state_failure_stands "$worktree" "$dir" "$lckhash" "$ickhash" "$strategy"; then
      stands=1 stood_rc=$WT_DEP_RC stood_reason=$WT_DEP_REASON
    fi

    # Only a dependency we KNOW was interrupted is cleared. A directory with no record at all may
    # be a perfectly good tree from before this plugin, or from a state-format change, and
    # deleting it would turn an upgrade into a mass reinstall.
    #
    # ONLY WHEN THE LOCK IS HELD. Without the lock, another worktree may be mid-install into this
    # very directory — deleting under it destroys its work and leaves both sessions believing
    # they succeeded.
    status=$(wt_state_status "$worktree" "$dir")
    if [ "$status" = doing ] && [ -e "$worktree/$dir" ]; then
      if [ "$held" -eq 1 ]; then
        wt_log "  $dir: a previous run was interrupted — clearing the partial directory"
        rm -rf "${worktree:?}/${dir:?}" 2>/dev/null || wt_log "  $dir: could not clear the partial directory"
      else
        wt_log "  $dir: a previous run was interrupted, but another process holds the lock — leaving the directory alone"
      fi
    fi

    # The budget may have gone while waiting for the lock and clearing the tree. Without this
    # re-test a spent budget reaches wt_run_in_shell as 0, which wt_is_seconds rejects, and the
    # DEFAULT of ten minutes is substituted — turning a spent budget into the longest wait of all.
    left=$(wt_budget_left "$deadline")
    if [ "$left" -le 0 ]; then
      wt_log "  $dir: the budget ran out while waiting — leaving it for the next session"
      wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
      [ "$held" -eq 1 ] && wt_lock_release 9
      continue
    fi

    wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" doing || true

    # `effective` is what actually HAPPENED, used only for the log line. The state records the
    # profile's `strategy`, because that is what the next run compares against: a hardlink that
    # fell back to install must still match `hardlink` next time, or every such dependency
    # reinstalls in full on every single session — silently, and exactly in the common case of a
    # branch that touched its lockfile.
    effective=$strategy
    if [ "$strategy" = hardlink ]; then
      wt_hardlink_dep "$root" "$worktree" "$dir" "$lock"
      case $? in
        0) effective=hardlink ;;
        2) effective=present ;;
        *) effective=install ;;
      esac
      if [ "$effective" = install ] && [ "$stands" -eq 1 ]; then
        wt_dep_log_failure_stands "$dir" "$lock" "$stood_rc" "$stood_reason"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" failed "$stood_rc" "$stood_reason" || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
      # A hardlink that has to fall back to an install is as slow as any install, so it is deferred
      # too. `dirty`, not `doing`: nothing was started that a later run should clear away.
      if [ "$effective" = install ] && [ "${WT_DEFER:-0}" = 1 ]; then
        wt_log "  $dir: to be installed in the background"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
    fi

    rc=0 reason=''
    # A hardlink that fell back to an install runs the install command like any other.
    if [ "$effective" = install ] && [ "${WT_APPROVAL:-}" = no ]; then
      wt_log "  $dir: not installed — the profile's commands are not approved"
      wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
      [ "$held" -eq 1 ] && wt_lock_release 9
      continue
    fi
    if [ "$effective" = install ]; then
      if [ -z "$install" ]; then
        wt_log "  $dir: no install command to run — leaving it empty"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
      # Recomputed and re-tested IMMEDIATELY before the run. An earlier check is not enough:
      # the lock wait and clearing a partial tree both take time, and a `left` of 0 reaching
      # wt_run_in_shell is rejected by wt_is_seconds and replaced with the ten-minute DEFAULT —
      # turning an exhausted budget into the longest wait of the whole session.
      left=$(wt_budget_left "$deadline")
      if [ "$left" -le 0 ]; then
        wt_log "  $dir: the budget ran out before the install could start — leaving it for the next session"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
      if ! wt_toolchain_warm "$worktree" "$deadline"; then
        wt_log "  $dir: needs the toolchain, which is not ready — leaving it for /pitlane-finish or the next session"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
      capture=$(wt_install_capture_path "$worktree" "$dir") || capture=''
      # Taken last before the run and first after it (wt_install_note_changes): the narrower the
      # window, the fewer of the session's own edits can be mistaken for the install's. It spends
      # budget, so the budget is tested again after it, for the reason given above.
      tracked_before='' tracking=0
      if wt_tracked_changes "$worktree" "$deadline"; then
        tracked_before=$WT_TRACKED_CHANGES tracking=1
      fi
      left=$(wt_budget_left "$deadline")
      if [ "$left" -le 0 ]; then
        wt_log "  $dir: the budget ran out before the install could start — leaving it for the next session"
        wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
        [ "$held" -eq 1 ] && wt_lock_release 9
        continue
      fi
      wt_log "  $dir: installing (${left}s of the budget left)"
      started=$(date +%s 2>/dev/null) || started=''
      WT_RUN_CAPTURE=$capture wt_run_in_shell "$install" "$worktree" "$left"
      rc=$?
      [ "$tracking" -eq 0 ] || wt_install_note_changes "$worktree" "$dir" "$tracked_before" "$deadline"
      reason=''
      [ "$rc" -eq 0 ] || reason=$(wt_install_error_line "$capture")
      elapsed=''
      [ -n "$started" ] && elapsed=$(( $(date +%s) - started ))
      case $rc in
        0) wt_log "  $dir: installed${elapsed:+ in ${elapsed}s}" ;;
        124) wt_log "  $dir: the install ran past the ${left}s left in the budget and was stopped — the worktree may be incomplete" ;;
        137 | "$WT_GUARD_REFUSED") wt_log "  $dir: not installed for lack of memory — left for /pitlane-finish or the next session" ;;
        *) wt_log "  $dir: the install command failed (exit $rc) — the worktree may be incomplete" ;;
      esac
    elif [ "$effective" = hardlink ]; then
      wt_log "  $dir: hardlinked from the main checkout"
    fi

    # The optional cheap sanity check. It decides the recorded outcome, and `dirty` is what makes
    # the next entry try again rather than trust this one.
    #
    # IT RUNS IN THE HOST SHELL, NOT THE TOOLCHAIN WRAPPER. A verify is a cheap check by contract —
    # every one the detection table proposes is a plain file test — while the wrapper is not cheap:
    # measured on a real repository, one `nix develop --command true` costs 14s warm in the main
    # checkout and 25–38s in a fresh worktree, and a repo with nine dependency entries paid that nine
    # times on its first bootstrap, for nine `test -r` calls. The time bound is unchanged.
    #
    # IT RUNS AFTER A NON-ZERO INSTALL TOO, because the exit code is not the last word: a package
    # manager can install every package and then exit 1 on a policy check (pnpm's ignored build
    # scripts). A pass then records `warn`; a fail, or no verify to ask, records `failed`. An install
    # that was STOPPED (budget, memory cap, guard) stays `dirty` whatever verify says: it did not
    # finish, and a verify that tests one file can pass on a half-written tree.
    outcome=dirty
    case $rc in
      0) outcome="done" ;;
      124 | 137 | "$WT_GUARD_REFUSED") ;;
      *) outcome=failed ;;
    esac
    if [ -n "$verify" ]; then
      left=$(wt_budget_left "$deadline")
      if [ "${WT_APPROVAL:-}" = no ]; then
        wt_log "  $dir: its verify command is not approved, so it was not run — recording it as needing another look"
        outcome=dirty
      elif [ "$left" -le 0 ]; then
        wt_log "  $dir: no budget left to verify — recording it as needing another look"
        outcome=dirty
      else
        WT_GUARD=off PROFILE_SHELL='' PROFILE_SHELLARGS='' wt_run_in_shell "$verify" "$worktree" "$left"
        vrc=$?
        if [ "$vrc" -eq 0 ] && [ "$outcome" = failed ]; then
          outcome=warn
          wt_log "  $dir: installed with warnings — the install exited $rc${reason:+ (\"$reason\")}, but its verify passed, so it counts as installed"
        elif [ "$vrc" -ne 0 ] && [ "$outcome" = "done" ]; then
          outcome=dirty
          wt_log "  $dir: the verify command failed (exit $vrc) — it will be retried next session"
        elif [ "$vrc" -ne 0 ]; then
          wt_log "  $dir: the verify command failed (exit $vrc) as well"
        fi
      fi
    fi

    # AN INSTALL MAY REWRITE ITS OWN LOCKFILE (npm updating package-lock.json, a tool normalising
    # one). The checksum taken before it would then never match again: pending forever, reinstalled
    # every run. So a finished install records the lockfile as it left it. A tracked one it rewrote
    # is in the `changed` record (wt_install_note_changes), so the user is still told.
    if [ "$effective" = install ]; then
      case $outcome in "done" | warn) lckhash=$(wt_cksum_file "$worktree/$lock") ;; esac
    fi
    case $outcome in
      warn | failed) wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" "$outcome" "$rc" "$reason" || true ;;
      *) wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" "$outcome" || true ;;
    esac

    [ "$held" -eq 1 ] && wt_lock_release 9
  done < <(printf '%s' "$PROFILE_RAW")
  done
  return 0
}

# What this worktree's bootstrap has NOT finished, one item per line, in WT_PENDING: each dependency
# directory not recorded done (or warn) for its current lockfile and install command, then
# `databases (seed: <status>)` when the profile has a seed that has not run to done. Empty means the
# worktree is complete. It is what the session is told, so it reads the state the steps recorded
# rather than guessing. WT_PENDING_ATTEMPTABLE is the same list less each dependency whose failure
# stands: what a run would actually try, which decides whether one is worth starting.
# WT_STATUS_ITEMS is every imperfect item with what the state says about it, for
# wt_bootstrap_status_line: one `<kind> US <name> US <detail>` per line, kind being `standing` (a
# failure that stands; detail its reason), `missing` (detail the recorded status), `seed` (detail the
# seed's status) or `warn` (present, installed with warnings; detail its reason). Globals, not
# output, so one walk answers all three: each item costs an expand and two checksums.
wt_bootstrap_pending() {  # $1 = worktree
  local worktree=${1%/} rec body dir lock strategy install verify _cksum lckhash ickhash seed current
  WT_PENDING='' WT_PENDING_ATTEMPTABLE='' WT_STATUS_ITEMS=''
  [ "${PROFILE_PRESENT:-0}" = 1 ] || return 0
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    IFS=$WT_US read -r dir lock strategy install verify _cksum <<<"$body" || true
    case $strategy in hardlink | install | store) ;; *) continue ;; esac
    { [ -n "$dir" ] && wt_is_safe_relpath "$dir"; } || continue
    [ "$strategy" = store ] && strategy=install
    install=$(wt_expand "$install")
    lckhash=$(wt_cksum_file "$worktree/$lock")
    ickhash=$(wt_cksum_string "$install")
    # ONE read of the record decides done, warn and a failure that stands, by the rules of
    # wt_state_is_done and wt_state_failure_stands: the record is for this lockfile, command and
    # strategy (never empty here), and then its status says which.
    current=0
    if wt_state_dep_read "$worktree" "$dir" && [ "$WT_DEP_LCK" = "$lckhash" ] \
      && [ "$WT_DEP_ICK" = "$ickhash" ] && [ "$WT_DEP_STRATEGY" = "$strategy" ]; then
      current=1
    fi
    if [ "$current" = 1 ]; then
      case $WT_DEP_STATUS in
        "done") continue ;;
        warn)
          wt_dep_recorded_reason
          WT_STATUS_ITEMS+=warn$WT_US$dir$WT_US$WT_DEP_SHOWN_REASON$WT_NL
          continue
          ;;
      esac
    fi
    WT_PENDING+=${WT_PENDING:+$'\n'}$dir
    if [ "$current" = 1 ] && [ "$WT_DEP_STATUS" = failed ]; then
      wt_dep_recorded_reason
      WT_STATUS_ITEMS+=standing$WT_US$dir$WT_US$WT_DEP_SHOWN_REASON$WT_NL
      continue
    fi
    WT_STATUS_ITEMS+=missing$WT_US$dir$WT_US$WT_DEP_STATUS$WT_NL
    WT_PENDING_ATTEMPTABLE+=${WT_PENDING_ATTEMPTABLE:+$'\n'}$dir
  done < <(printf '%s' "${PROFILE_RAW:-}")
  if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_SEED:-}" ] \
    && [ ! -e "$worktree/$WT_NO_RUNTIME_MARKER" ]; then
    seed=$(wt_runtime_state_get "$worktree" seedstatus) || seed=none
    if [ "$seed" != "done" ]; then
      WT_STATUS_ITEMS+=seed${WT_US}databases$WT_US${seed:-none}$WT_NL
      seed="databases (seed: ${seed:-none})"
      WT_PENDING+=${WT_PENDING:+$'\n'}$seed
      WT_PENDING_ATTEMPTABLE+=${WT_PENDING_ATTEMPTABLE:+$'\n'}$seed
    fi
  fi
  return 0
}

# The reason recorded for the dependency wt_state_dep_read last read, in WT_DEP_SHOWN_REASON: its
# error line, else its exit code. Capped well below the record's 160: it shares one status line with
# everything else.
wt_dep_recorded_reason() {
  WT_DEP_SHOWN_REASON=${WT_DEP_REASON:-exit ${WT_DEP_RC:-?}}
  [ "${#WT_DEP_SHOWN_REASON}" -le 80 ] || WT_DEP_SHOWN_REASON="${WT_DEP_SHOWN_REASON:0:77}..."
}

# How many imperfect items the status line names before it says "and N more".
WT_STATUS_SHOWN=3

# THE ONE LINE on stdout that tells the session (SessionStart) or /pitlane-finish (--finish) the
# worktree's state, from the globals wt_bootstrap_pending has just set. Every ending goes through
# here so that all of them name states alike: each imperfect item as `<name> missing (<why>)` or
# `<name> ready with warnings (<why>)`, and the count of tracked files an install changed — a count,
# not the names, which are branch content; /pitlane-finish shows them. Still one line (ADR-017), and
# at start-up a complete worktree with nothing to report prints NOTHING: stdout there is model
# context — unless the profile has runtime.serve, when it prints one line naming /pitlane-serve and
# the URL (ADR-021), a clause every other start-up line carries too. A worktree whose only gaps are
# failures that stand is not sent to /pitlane-finish as if that would fix them: it would not retry
# them, and retrying is the user's call.
wt_bootstrap_status_line() {  # $1 = worktree, $2 = start | finish, $3 = background | approval | empty, $4 = deadline for asking git which changed files remain (empty = WT_STATUS_SECONDS)
  local worktree=${1%/} when=${2-} how=${3-} deadline=${4-} kind name detail why path n=0 nchanged=0 standing=0
  local script=${WT_BOOTSTRAP_SCRIPT:-bootstrap.sh} list='' changed='' summary app=''
  local -a absent_items=() warned_items=()
  while IFS=$WT_US read -r kind name detail; do
    case $kind in
      standing)
        standing=$((standing + 1))
        absent_items+=("$name missing (install failed: $detail)")
        ;;
      missing)
        case $how:$when in
          approval:*) why='held back' ;;
          background:*) why='still installing' ;;
          *:finish) why='not installed; stderr says why' ;;
          *) why='not installed yet' ;;
        esac
        absent_items+=("$name missing ($why)")
        ;;
      seed)
        case $how in
          approval) why='held back' ;;
          background) why='seeding' ;;
          *) why="seed: $detail" ;;
        esac
        absent_items+=("$name missing ($why)")
        ;;
      warn) warned_items+=("$name ready with warnings ($detail)") ;;
    esac
  done <<<"${WT_STATUS_ITEMS:-}"
  for summary in ${absent_items[@]+"${absent_items[@]}"} ${warned_items[@]+"${warned_items[@]}"}; do
    n=$((n + 1))
    [ "$n" -le "$WT_STATUS_SHOWN" ] && list+=${list:+, }$summary
  done
  [ "$n" -le "$WT_STATUS_SHOWN" ] || list+=" and $((n - WT_STATUS_SHOWN)) more"
  list=$(wt_visible "$list")
  wt_install_changed_collect "$worktree" "$deadline"
  if [ -n "$WT_INSTALL_CHANGED" ]; then
    while IFS= read -r path; do
      [ -z "$path" ] || nchanged=$((nchanged + 1))
    done <<<"$WT_INSTALL_CHANGED"
  fi
  if [ "$nchanged" -gt 0 ]; then
    changed="an install changed $nchanged tracked file$([ "$nchanged" -eq 1 ] || echo s)"
    if [ "$when" = finish ]; then
      changed+=" (bash \"$script\" --changed lists them)"
    else
      changed+=" (/pitlane-finish lists them, and restores one only on the user's word)"
    fi
  fi
  summary=$list${list:+${changed:+; }}$changed

  if [ "$when" = finish ]; then
    if [ -z "$summary" ]; then
      printf 'Pitlane: this worktree is fully set up.\n'
    elif [ -z "${WT_PENDING:-}" ]; then
      printf 'Pitlane: this worktree is set up, with warnings — %s.\n' "$summary"
    elif [ "$how" = approval ]; then
      # shellcheck disable=SC2016  # the backticks are text for the reader, not a substitution.
      printf 'Pitlane: not run — the profile'"'"'s commands are not approved in their current form — %s. Run `bash "%s" --review` here, show the user what it would run, and approve only on their explicit word.\n' \
        "$summary" "$script"
    elif [ "$standing" -gt 0 ]; then
      # shellcheck disable=SC2016
      printf 'Pitlane: still not complete — %s. A failed install is not retried while its lockfile and install command are unchanged; retry it with `bash "%s" --finish --retry-failed` only on the user'"'"'s word.\n' \
        "$summary" "$script"
    else
      printf 'Pitlane: still not complete — %s.\n' "$summary"
    fi
    return 0
  fi

  # The app clause, so a session never reaches for the repo's own start command, which knows nothing
  # of this worktree's port. The held-back line does not carry it: /pitlane-serve would refuse there too.
  if [ "${PROFILE_PRESENT:-0}" = 1 ] && [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_SERVE:-}" ]; then
    app=" To run the app, use /pitlane-serve${WT_RUNTIME_URL:+ (it serves at $WT_RUNTIME_URL)}, not the repo's own start command."
  fi
  if [ -z "$summary" ]; then
    [ -z "$app" ] || printf 'Pitlane: this worktree is set up.%s\n' "$app"
    return 0
  fi
  if [ -z "${WT_PENDING:-}" ]; then
    printf 'Pitlane: this worktree is set up, with warnings — %s. It is usable; tell the user if it matters for the task.%s\n' "$summary" "$app"
  # Written for a model that may be reading a stranger's branch: it must neither approve on its own
  # nor do the held-back steps by hand, which would run exactly what the gate held back.
  elif [ "$how" = approval ]; then
    printf 'Pitlane: this worktree'"'"'s setup commands were NOT run — %s. Its profile, or a seed or teardown script it names, is not approved in its current form, and this branch may not be the developer'"'"'s own. Do not approve it, run those commands, or install dependencies or create databases by hand. Tell the user; if they want it set up, run /pitlane-finish, which shows what it would run and needs their explicit approval.\n' "$summary"
  elif [ "$how" = background ]; then
    printf 'Pitlane: this worktree is still being set up in the background — %s. It usually takes a few minutes. Work that needs none of those can start now. Before running anything that does (tests, builds, the app, database queries), run /pitlane-finish: it waits for the background setup and reports what is ready. Do not install dependencies or create databases by hand meanwhile; the background setup is doing it.%s\n' "$summary" "$app"
  elif [ -z "${WT_PENDING_ATTEMPTABLE:-}" ]; then
    printf 'Pitlane: this worktree is not fully set up — %s. An install that failed is not retried while its lockfile and install command are unchanged, so running /pitlane-finish will not fix this. Tell the user why it failed; if they say the cause is fixed, /pitlane-finish can retry on their word. Do not install dependencies by hand.%s\n' "$summary" "$app"
  else
    printf 'Pitlane: this worktree is not fully set up yet — %s. Run /pitlane-finish to complete it now (it has no time limit), or start a new session here. Until then, do not install dependencies or create databases by hand; those steps belong to the setup.%s\n' "$summary" "$app"
  fi
}

# ---------------------------------------------------------------------------
# The background run: the slow steps, after the session has started
# ---------------------------------------------------------------------------
#
# Claude Code holds a session's first prompt until every SessionStart hook has returned. So the
# start-up run defers installs and the seed (WT_DEFER) and starts `bootstrap.sh --finish
# --background` detached — its own session (setsid), every descriptor on a file, so the hook's pipes
# close when the hook exits and the platform has nothing to wait for. It is the /pitlane-finish run
# exactly, guard, locks and state included; it holds the worktree's bootstrap lock while it works,
# which is also what makes teardown keep a worktree that is still being set up.
#
# Its pid and log sit beside the state file, in the worktree's private git dir, for the same reason
# the lock does: nothing in the checkout, nothing in `git status`.

wt_background_enabled() {
  case ${PITLANE_BACKGROUND:-on} in
    off | OFF | 0 | no | false) return 1 ;;
  esac
  command -v setsid >/dev/null 2>&1 || return 1
  [ -n "${WT_BOOTSTRAP_SCRIPT:-}" ] && [ -f "$WT_BOOTSTRAP_SCRIPT" ]
}

wt_background_pidfile() {  # $1 = worktree
  local p
  p=$(wt_state_path "$1")
  printf '%s/worktree-bootstrap.pid' "${p%/*}"
}

wt_background_againfile() {  # $1 = worktree
  local p
  p=$(wt_state_path "$1")
  printf '%s/worktree-bootstrap.again' "${p%/*}"
}

# Run by the background run after its sequence: true (and the request consumed) when a session
# asked for another round while it worked.
wt_background_take_again() {  # $1 = worktree
  local f
  f=$(wt_background_againfile "$1")
  [ -e "$f" ] || return 1
  rm -f "$f" 2>/dev/null
  return 0
}

wt_background_logfile() {  # $1 = worktree
  local p
  p=$(wt_state_path "$1")
  printf '%s/worktree-bootstrap.log' "${p%/*}"
}

# Prints the pid of this worktree's running background setup, or returns 1 when none is running.
# A pid that is alive but no longer a bootstrap is a recycled one, and does not count.
wt_background_pid() {  # $1 = worktree
  local f pid
  f=$(wt_background_pidfile "$1")
  [ -f "$f" ] || return 1
  pid=$(head -c 24 "$f" 2>/dev/null | tr -cd '0-9')
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  if [ -r "/proc/$pid/cmdline" ] && ! tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -q 'bootstrap\.sh --finish --background'; then
    return 1
  fi
  printf '%s' "$pid"
}

# Start the background run, unless one is already going. Returns 1 when it could not be started,
# and the caller falls back to the ordinary "not finished" notice.
wt_background_start() {  # $1 = worktree
  local wt=${1%/} log pidf
  if wt_background_pid "$wt" >/dev/null; then
    # The running one may be past the step this session needs: ask it to go round again.
    : >"$(wt_background_againfile "$wt")" 2>/dev/null || true
    return 0
  fi
  log=$(wt_background_logfile "$wt")
  pidf=$(wt_background_pidfile "$wt")
  {
    printf '%s background setup of %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$wt"
  } >"$log" 2>/dev/null || return 1
  ( cd "$wt" 2>/dev/null || exit 0
    exec setsid bash "$WT_BOOTSTRAP_SCRIPT" --finish --background ) </dev/null >>"$log" 2>&1 &
  printf '%s\n' "$!" >"$pidf" 2>/dev/null || return 1
  return 0
}

# Run by the background run itself: record its own pid (setsid may have forked, so the one the hook
# wrote can be its parent's), and clear the record on the way out, only if it is still its own.
wt_background_claim() {  # $1 = worktree
  WT_BG_PIDFILE=$(wt_background_pidfile "$1")
  printf '%s\n' "$$" >"$WT_BG_PIDFILE" 2>/dev/null || true
  rm -f "$(wt_background_againfile "$1")" 2>/dev/null
  trap 'wt_background_release' EXIT
}

wt_background_release() {
  [ -n "${WT_BG_PIDFILE:-}" ] || return 0
  [ "$(tr -cd '0-9' <"$WT_BG_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WT_BG_PIDFILE"
  return 0
}

# /pitlane-finish while a background run is going: wait for it, bounded, saying so once.
wt_background_wait() {  # $1 = worktree
  local wt=${1%/} pid limit=${WT_FINISH_LIMIT:-3600} waited=0
  pid=$(wt_background_pid "$wt") || return 0
  wt_log "the background setup (pid $pid) is still running — waiting for it; progress in $(wt_background_logfile "$wt")"
  while wt_background_pid "$wt" >/dev/null; do
    [ "$waited" -lt "$limit" ] || { wt_log "still running after ${limit}s — going on without it"; return 0; }
    sleep 2
    waited=$((waited + 2))
  done
  wt_log "the background setup finished after ${waited}s more"
  return 0
}

# ---------------------------------------------------------------------------
# Drift: has the checkout moved away from what the profile was calibrated on?
# ---------------------------------------------------------------------------
#
# The profile gained the `evidence` block and a comparator for its checksums but deliberately no call
# site. This is that call site, and it covers ALL of the evidence, not just the checksums — until
# now `evidence.markers`, `evidence.shellMarker` and `evidence.detectionVersion` were written and
# validated with no reader at all, which is the inert-field smell this repo dislikes.
#
# Each answers a different question a checksum cannot:
#   markers           the repo has GAINED (or lost) an ecosystem the profile knows nothing about
#   shellMarker       a flake.nix has appeared, so installs are running on the wrong toolchain
#   detectionVersion  a newer shipped table might propose better answers
#
# IT IS A STRING COMPARE AND A FILE TEST, NEVER A RE-DETECTION. That is what keeps it legal inside
# a hook at all (a hook must never do discovery), and it WARNS WITHOUT EVER BLOCKING.
# Its honest limits are recorded in reference/detection.md: a lockfile can churn with
# nothing meaningful changing, and — worse — a hazard can appear in composer.json's `scripts`
# without touching any lockfile, so the case where a warning matters most produces none.
#
# The detection table is READ, not copied into this file. reference/detection.json is ground truth
# and the rule is that adding an ecosystem is one entry there and nothing else; a duplicated
# marker list here would be a second copy to rot. It costs one interpreter start, and only for a
# profile that actually carries evidence — a profile without it cannot report drift anyway.
# Resolved to an ABSOLUTE path at source time. A bare `dirname "${BASH_SOURCE[0]}"` is relative
# when the library is sourced by a relative path, and a hook runs from wherever the user launched
# their session — so the table simply would not be found, and drift would silently never report.
# (Measured: it did exactly that until this was fixed.)
# Located the same way detect.sh locates it: the platform's own CLAUDE_PLUGIN_ROOT first, since
# that is what a hook actually receives, and a path derived from this file only as a fallback.
#
# The fallback climbs with parameter expansion rather than `cd ..`. A `..` left in the path is not
# merely untidy: it is resolved by whoever opens the file, and some sandboxes refuse a traversal
# that points at a directory they would otherwise allow. Measured while building this — both
# `<root>/hooks/scripts/../reference/detection.json` and a `cd` through it failed, while the plain
# `<root>/reference/detection.json` worked — and the symptom was drift silently never reporting.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/reference/detection.json" ]; then
  WT_DETECTION_JSON_DEFAULT="${CLAUDE_PLUGIN_ROOT}/reference/detection.json"
else
  WT_BLIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || WT_BLIB_DIR=''
  WT_BLIB_DIR=${WT_BLIB_DIR%/*}          # .../hooks
  WT_BLIB_DIR=${WT_BLIB_DIR%/*}          # the plugin root
  WT_DETECTION_JSON_DEFAULT=${WT_BLIB_DIR:+$WT_BLIB_DIR/reference/detection.json}
fi

wt_report_drift() {  # $1 = checkout, $2 = detectionVersion, $3 = markers, $4 = shellMarker, $5 = profile path (only needed when no profile is loaded), $6 = main checkout (found from $1 when empty)
  local tree=${1%/} evdet=${2-} evmark=${3-} evshell=${4-} profile=${5-} main=${6-}
  local table=${WT_DETECTION_JSON:-$WT_DETECTION_JSON_DEFAULT}
  local raw rec body curdet m rdir gained='' lost='' curshell='' seen='' problems
  local lock cksum now n=0 locks where=''

  # WHOSE LOCKFILE: THE MAIN CHECKOUT'S. lockChecksum is what calibration saw there, so main's
  # lockfile moving on is the case where the recorded install command may be out of date. A
  # worktree's own lockfile differing is just a branch that touches dependencies — every such branch
  # was told to re-run setup, for nothing (wt_bootstrap_deps already installs for the worktree's own
  # lockfile). Only when there is no main checkout to find is the checkout itself compared.
  [ -n "$main" ] || main=$(wt_main_root "$tree" 2>/dev/null) || main=''
  locks=${main%/}
  if [ -n "$locks" ]; then
    where=' in the main checkout'
  else
    locks=$tree
  fi

  # THE LOCKFILE CHECKSUMS FIRST, and OUTSIDE every guard below. They live in deps[], not in
  # `evidence`, and they need neither the evidence block nor the detection table — so gating them
  # on either meant a profile carrying checksums but no evidence (a hand-written one, or any
  # install where the table cannot be found) silently got no drift warning at all, leaving the one
  # comparator that actually shipped unwired for exactly those profiles.
  #
  # TWO ROUTES TO ONE ANSWER, and the reason is measured rather than stylistic. With a profile
  # loaded, the checksums are already in PROFILE_RAW, so comparing them here costs nothing —
  # calling lib.sh's wt_profile_drifted would re-read the file and spend an interpreter start on
  # the very path bootstrap cut from four to one. Without one (a caller checking a profile it is
  # not about to use), that function is the only way to get them, and it is delegated to rather
  # than reimplemented. tests/test_bootstrap_lib.sh asserts the two agree on the same profile,
  # because two routes to one answer is exactly the shape that drifts apart.
  if [ -z "${PROFILE_RAW:-}" ] && [ -n "$profile" ]; then
    problems=$(wt_profile_drifted "$profile" "$locks") || {
      wt_log "$problems"
      wt_log "run /pitlane-setup if the dependency set really changed"
    }
  elif [ -n "${PROFILE_RAW:-}" ]; then
    while IFS= read -r -d "$WT_RS" rec; do
      case $rec in
        1"$WT_US"*) ;;
        *) continue ;;
      esac
      body=${rec#*"$WT_US"}
      IFS=$WT_US read -r rdir lock _st _in _ve cksum <<<"$body" || true
      n=$((n + 1))
      [ -n "$lock" ] && [ -n "$cksum" ] || continue
      wt_is_safe_relpath "$lock" || continue
      if [ ! -f "$locks/$lock" ]; then
        wt_log "$lock no longer exists$where, but the profile was calibrated against it — run /pitlane-setup"
        continue
      fi
      now=$(cksum <"$locks/$lock" 2>/dev/null) || continue
      if [ "$now" != "$cksum" ]; then
        wt_log "$lock$where has changed since calibration — the recorded install command may be out of date; run /pitlane-setup if so"
      fi
    done < <(printf '%s' "$PROFILE_RAW")
  fi

  # The three `evidence` comparisons need the block and the table; without either there is simply
  # nothing to compare, which is not a problem to report.
  if [ -z "$evdet" ] && [ -z "$evmark" ] && [ -z "$evshell" ]; then
    return 0
  fi
  [ -r "$table" ] || return 0
  wt_has_json || return 0

  # One read of the table: its version, each rule's markers AND the directory that rule populates,
  # and every shell marker.
  raw=$(wt_json_scan detectionVersion -- deps markers dir -- shells marker <"$table") || return 0
  [ -n "$raw" ] || return 0

  while IFS= read -r -d "$WT_RS" rec; do
    body=${rec#*"$WT_US"}
    case $rec in
      0"$WT_US"*)
        curdet=$body
        ;;
      1"$WT_US"*)
        IFS=$WT_US read -r body rdir <<<"$body" || true
        # A RULE AT A TIME, not a marker at a time, and this matters. `evidence.markers` records
        # only the marker each rule actually MATCHED, so a rule with several (bun.lock and
        # bun.lockb) would otherwise report its unmatched sibling as newly gained on every single
        # session — a warning that fires for a repo that has not drifted, whose suggested fix
        # produces the identical profile, which is how people learn to ignore warnings.
        if wt_rule_is_recorded "$body" "$rdir" "$evmark"; then
          continue
        fi
        while IFS= read -r m; do
          [ -n "$m" ] || continue
          [ -e "$tree/$m" ] || continue
          case " $seen " in
            *" $m "*) continue ;;
          esac
          seen="$seen $m"
          gained="$gained $m"
        done < <(printf '%s\n' "$body" | tr -d '[]"' | tr ',' '\n')
        ;;
      2"$WT_US"*)
        # First match wins, exactly as the table is ordered for detection.
        [ -n "$curshell" ] && continue
        [ -n "$body" ] || continue
        [ -e "$tree/$body" ] && curshell=$body
        ;;
    esac
  done < <(printf '%s' "$raw")

  # Anything recorded that is no longer on disk.
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ -e "$tree/$m" ] || lost="$lost $m"
  done < <(printf '%s\n' "$evmark" | tr -d '[]"' | tr ',' '\n')

  if [ -n "$gained" ]; then
    wt_log "the profile was calibrated before this checkout had:$gained — run /pitlane-setup so those are set up too"
  fi
  if [ -n "$lost" ]; then
    wt_log "the profile expects these, which this checkout no longer has:$lost — run /pitlane-setup"
  fi
  if [ "$evshell" != "$curshell" ]; then
    wt_log "the toolchain marker changed since calibration (${evshell:-none} -> ${curshell:-none}) — installs may be running on the wrong toolchain; run /pitlane-setup"
  fi
  if [ -n "$evdet" ] && [ -n "$curdet" ] && [ "$evdet" != "$curdet" ]; then
    wt_log "this plugin's detection table is now version $curdet, the profile was written against $evdet — /pitlane-setup may propose better answers"
  fi
  return 0
}

# A Python virtualenv must never be hardlinked: its scripts' shebangs, `activate` and an editable
# install's path mapping all name the main checkout, so pip in the worktree installs into the main
# checkout's venv and imports load the main checkout's source. Detection no longer proposes it, but a
# profile calibrated before may still say so. Only warned about, since the profile is the
# developer's; once per run, however many rounds a background run goes.
WT_VENV_HARDLINK_WARNED=''
wt_warn_hardlinked_venvs() {  # $1 = main checkout
  local root=${1%/} rec body dir strategy venvs=''
  [ -z "$WT_VENV_HARDLINK_WARNED" ] && [ -n "${PROFILE_RAW:-}" ] || return 0
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    dir=${body%%"$WT_US"*}
    strategy=${body#*"$WT_US"*"$WT_US"}
    strategy=${strategy%%"$WT_US"*}
    [ "$strategy" = hardlink ] && [ -n "$dir" ] || continue
    case /${dir%/} in
      */.venv) ;;
      *) { wt_is_safe_relpath "$dir" && [ -f "$root/$dir/pyvenv.cfg" ]; } || continue ;;
    esac
    venvs+=${venvs:+, }$dir
  done < <(printf '%s' "$PROFILE_RAW")
  [ -n "$venvs" ] || return 0
  WT_VENV_HARDLINK_WARNED=1
  wt_log "$(wt_visible "$venvs"): hardlinked, but a Python virtualenv — its scripts and paths name the main checkout, so installs here go into the main checkout's venv and imports load its source. Run /pitlane-setup to install it per worktree instead."
}

# True when a detection rule is already accounted for by the recorded evidence — either one of its
# markers was recorded, or the directory it populates is already a dependency in the profile.
#
# The second half is what handles detection.json's sameDirPolicy: when two lockfiles claim one
# directory, only one rule is accepted, so a stale `package-lock.json` sitting beside the
# `pnpm-lock.yaml` that won is NOT a newly gained ecosystem and must not be reported as one.
wt_rule_is_recorded() {  # $1 = the rule's markers as compact JSON, $2 = the rule's dir, $3 = evidence.markers
  local markers=${1-} dir=${2-} evmark=${3-} m rec body rdir
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    case $evmark in
      *"\"$m\""*) return 0 ;;
    esac
  done < <(printf '%s\n' "$markers" | tr -d '[]"' | tr ',' '\n')

  [ -n "$dir" ] && [ -n "${PROFILE_RAW:-}" ] || return 1
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    rdir=${body%%"$WT_US"*}
    [ "$rdir" = "$dir" ] && return 0
  done < <(printf '%s' "$PROFILE_RAW")
  return 1
}

# ---------------------------------------------------------------------------
# Layer 3 — port allocation
# ---------------------------------------------------------------------------
#
# TWO DIFFERENT QUESTIONS, kept apart because the right answer to each is opposite:
#
#   "is this port claimed by another WORKTREE?"  -> probe forward past it. We allocated that one,
#                                                   we know it is spoken for, and stepping aside is
#                                                   strictly better than colliding.
#   "is something ELSE listening on it?"         -> warn and keep the derived value. Guessing around
#                                                   a foreign process causes more confusion than it
#                                                   prevents: the process may exit a second later,
#                                                   and moving means a developer's bookmarked URL
#                                                   changes for a reason they cannot see.
#
# PORTS FAIL OPEN. If none of this can be worked out, the derived port is used and a warning is
# printed — a port collision costs one bind error, which is loud, immediate and destroys nothing.
# The SEED does the opposite and fails closed, because a wrong database name destroys work. That
# asymmetry is the whole reason these are separate decisions rather than one "is it safe" flag.

# Collapse `..` segments in an absolute path, textually and without a fork.
#
# A relative `gitdir` pointer (git 2.48 worktree.useRelativePaths) builds a path like
# `<admin>/../../../.claude/worktrees/x`, which names the right directory but never string-equals
# the caller's own path — so a worktree would fail to recognise ITSELF among its siblings, and the
# seed's collision check would then refuse every session, blaming a colleague's worktree that does
# not exist. `pwd -P` would also resolve symlinks and costs a subshell per sibling; this is a
# textual normalisation, which is what a comparison between two paths git itself produced needs.
wt_collapse_dotdot() {  # $1 = path
  local p=${1-} out='' seg rest
  case $p in
    */../*) ;;
    *) printf '%s' "$p"; return 0 ;;      # nothing to do, and no cost for the common case
  esac
  rest=$p
  case $rest in /*) out='' ;; esac
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    case $seg in
      '' | '.') continue ;;
      '..') out=${out%/*} ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# Collect every LIVE sibling worktree of $1 that has a runtime allocation. Sets WT_SIBLINGS to the
# records (`slug US port`, RS-terminated) and WT_SIBLINGS_OK to 1 when the enumeration can be
# trusted, 0 when it cannot.
#
# IT SETS BOTH RATHER THAN PRINTING THE RECORDS. A function that prints is called in a command
# substitution, and a flag assigned inside that subshell is discarded the moment it returns — so a
# caller could have the records or the trust signal but never both. That matters more here than
# anywhere else in this file: the flag is what the SEED reads to decide whether it may run at all,
# and a seed that silently read a stale 1 would clone a database against an enumeration it could
# not see. (wt_runtime_claim_port has the same two-results shape for the same reason.)
#
# It reads the shared git directory's own `worktrees/` administration rather than calling
# `git worktree list` per sibling: everything needed is already on disk, so the whole scan costs
# ONE `git rev-parse` for the common directory and no forks at all per sibling.
#
# LIVENESS NEEDS BOTH HALVES. `git worktree remove` deletes the admin directory, but a developer
# who runs `rm -rf` on the checkout instead leaves it behind — measured — and that stale entry
# still holds the old allocation. Treating it as live would make the name permanently unreusable:
# the next worktree of that name would step around a port nothing is using, forever.
#
# ANY SIBLING IT CANNOT READ DROPS THE FLAG TO 0. A partially blind scan that reported itself
# trustworthy is worse than one that admits it, because the seed's whole fail-closed rule rests on
# this number.
wt_runtime_siblings() {  # $1 = main checkout, $2 = this worktree (excluded)
  local root=${1%/} mine=${2%/} common admin gitdirf wtpath slug port

  # SC2034: these two ARE the function's results — see the header for why they are set
  # rather than printed.
  # shellcheck disable=SC2034
  WT_SIBLINGS=''
  # shellcheck disable=SC2034
  WT_SIBLINGS_OK=0
  common=$(wt_git_common_dir "$root") || return 0
  # No linked worktrees yet is a trustworthy answer of "none", not a failure to look.
  # shellcheck disable=SC2034
  [ -d "$common/worktrees" ] || { WT_SIBLINGS_OK=1; return 0; }

  # shellcheck disable=SC2034
  WT_SIBLINGS_OK=1
  for admin in "$common"/worktrees/*/; do
    admin=${admin%/}
    [ -d "$admin" ] || continue                      # an unmatched glob
    gitdirf=$admin/gitdir
    if [ ! -r "$gitdirf" ]; then
      # shellcheck disable=SC2034
      WT_SIBLINGS_OK=0                               # an entry we cannot classify at all
      continue
    fi
    # shellcheck disable=SC2034
    IFS= read -r wtpath <"$gitdirf" || { WT_SIBLINGS_OK=0; continue; }
    wtpath=${wtpath%/.git}
    # `git worktree add --relative-paths` (and worktree.useRelativePaths, git 2.48+) writes this
    # pointer RELATIVE TO THE ADMIN DIRECTORY. Resolving it against the hook's working directory
    # instead would make every sibling look like a deleted orphan — collision avoidance would stop
    # working silently, while the flag still claimed the scan was trustworthy.
    case $wtpath in
      /*) ;;
      *) wtpath=$admin/$wtpath ;;
    esac
    wtpath=$(wt_collapse_dotdot "$wtpath")
    [ "$wtpath" = "$mine" ] && continue              # ourselves
    # The orphan check: the admin directory outlives an `rm -rf` of the checkout.
    [ -n "$wtpath" ] && [ -d "$wtpath" ] || continue
    [ -r "$admin/worktree-bootstrap-state" ] || continue
    slug=$(wt_runtime_state_read "$admin/worktree-bootstrap-state" slug) || continue
    port=$(wt_runtime_state_read "$admin/worktree-bootstrap-state" port) || continue
    # A RECORD IS EMITTED WHENEVER THERE IS A SLUG, PORT OR NOT. Skipping portless records was a
    # real hole: a sibling that seeded a database but never got a port — a profile with `seed` and
    # no `runtime.port`, or one whose port allocation had not run yet — was invisible to the seed's
    # collision check, which is the one guard standing between a derived name and a colleague's
    # database. The port loop is unaffected: an empty port never equals a candidate.
    [ -n "$slug" ] || continue
    WT_SIBLINGS="$WT_SIBLINGS$slug$WT_US$port$WT_RS"
  done
  return 0
}

# True if something is already listening on 127.0.0.1:$1.
#
# ADVISORY ONLY — its answer never changes which port is allocated, it only decides whether to say
# something. bash's own /dev/tcp is used rather than `ss`, `lsof` or `nc`, because it is a shell
# feature rather than a binary that may not be installed; when it is unavailable the answer is
# "do not know" and nothing is printed, since a warning is all this could ever produce.
#
# The host is the LITERAL 127.0.0.1 and the port has already been through wt_is_posint, so nothing
# from a profile reaches the /dev/tcp path as anything but digits.
#
# Bounded by `timeout` where there is one: a connect to a filtered port can hang, and this runs on
# the path that blocks session start. Without `timeout` the probe is skipped rather than risked.
wt_port_in_use() {  # $1 = port
  local port=${1-}
  wt_is_posint "$port" || return 1
  command -v timeout >/dev/null 2>&1 || return 1
  # A subshell so a failed redirection cannot disturb the caller's descriptors.
  ( timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" ) >/dev/null 2>&1
}

# Decide this worktree's port AND record the claim. Sets WT_PORT (empty when there is no usable
# port configuration) and WT_PORT_SOURCE (`derived` or `probed`); returns 0 either way.
#
# IT SETS RATHER THAN PRINTS, for the reason wt_runtime_siblings gives: two results cannot both
# survive a command substitution.
#
# THE WRITE IS INSIDE THE LOCK, and that is the entire point of the lock. A first version took the
# lock, enumerated siblings, chose a port, released, and left the recording to its caller — which
# serialises nothing at all: two sessions starting together each take the lock in turn, each see a
# sibling that has not recorded anything yet, and each choose the same port. A lock around a
# read-only computation is decoration. What has to be atomic is decide-AND-claim, so the next
# holder's enumeration can see this one.
#
# ORDER OF PREFERENCE, and the first rule is what the acceptance criteria rest on:
#   1. THE PORT ALREADY RECORDED FOR THIS SLUG WINS. That is what makes reopening a worktree land
#      where it was — a developer bookmarks the URL — and it must beat re-derivation, because a
#      sibling created in between could otherwise push this worktree off the port it has been using
#      all week. It is still range-checked: a recorded value outside the port space is no more
#      usable than a derived one would be.
#   2. Otherwise derive from the slug, then step forward past ports live siblings have claimed.
#   3. If every candidate is claimed, keep the derived one and warn.
wt_runtime_claim_port() {  # $1 = root, $2 = worktree, $3 = slug, $4 = base, $5 = span
  local root=${1%/} worktree=${2%/} slug=${3-} base=${4-} span=${5-}
  local recslug recport recsource chosen derived source='derived' lockpath held=0
  local cand skip sslug sport oenvfile oenvstate oseed ocksum

  # SC2034: the function's two results; wt_runtime_handoff reads them.
  # shellcheck disable=SC2034
  WT_PORT=''
  # shellcheck disable=SC2034
  WT_PORT_SOURCE=derived
  wt_is_posint "$base" && wt_is_posint "$span" || return 0
  derived=$(wt_derive_port "$slug" "$base" "$span") || return 0
  [ -n "$derived" ] || return 0

  # The recorded port depends on nothing another worktree can change, so it is read before the lock.
  recslug=$(wt_runtime_state_get "$worktree" slug) || recslug=''
  recport=$(wt_runtime_state_get "$worktree" port) || recport=''
  if [ -n "$recport" ] && [ "$recslug" = "$slug" ] && wt_is_posint "$recport" &&
     [ "$((10#$recport))" -ge "$WT_PORT_MIN" ] && [ "$((10#$recport))" -le "$WT_PORT_MAX" ]; then
    recsource=$(wt_runtime_state_get "$worktree" portsource) || recsource=derived
    # shellcheck disable=SC2034
    WT_PORT=$recport
    # shellcheck disable=SC2034
    WT_PORT_SOURCE=${recsource:-derived}
    return 0
  fi

  lockpath=$(wt_lock_path "$root" _runtime-ports)
  wt_lock_acquire "$lockpath" "$WT_LOCK_WAIT" 7
  case $? in
    0) held=1 ;;
    # wt_lock_acquire returns 1 both for contention and for flock being absent, and it has already
    # said which. Claiming "another worktree is allocating" on a machine with no flock(1) — stock
    # macOS — would be a confident lie on every single session.
    1) wt_log "  runtime: allocating a port without the lock" ;;
  esac

  wt_runtime_siblings "$root" "$worktree"
  chosen=''
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    skip=0
    if [ -n "$WT_SIBLINGS" ]; then
      while IFS=$WT_US read -r -d "$WT_RS" sslug sport; do
        # NO SAME-SLUG EXEMPTION. An earlier version skipped a sibling sharing our slug, on the
        # theory that it was this worktree seen through a stale record — but self is already
        # excluded by path and a dead worktree by the liveness test, so the only thing that
        # exemption could ever match is a DIFFERENT LIVE worktree whose name slugifies the same.
        # That is the collision, not an exception to it: both would derive the same database name
        # too, which wt_runtime_handoff warns about separately because moving the port does not
        # fix it.
        if [ "$sport" = "$cand" ]; then skip=1; break; fi
      done <<EOF
$WT_SIBLINGS
EOF
    fi
    [ "$skip" = 1 ] && continue
    chosen=$cand
    break
  done <<EOF
$(wt_port_candidates "$slug" "$base" "$span")
EOF

  if [ -z "$chosen" ]; then
    chosen=$derived
    wt_log "  runtime: every port in ${base}-$((10#$base + 10#$span - 1)) is claimed by another worktree — using $chosen anyway, which may fail to bind"
  elif [ "$chosen" != "$derived" ]; then
    source=probed
    wt_log "  runtime: port $derived is taken by another worktree — using $chosen instead"
  fi

  # THE CLAIM, written before the lock is released so the next holder can see it. The other rt
  # fields are carried forward rather than blanked — but ONLY for the same slug: a changed slug is
  # a different logical allocation whose env file and seed have not happened yet, and inheriting a
  # `done` seed marker across that boundary would skip seeding the new database entirely.
  if [ "$recslug" = "$slug" ]; then
    oenvfile=$(wt_runtime_state_get "$worktree" envfile) || oenvfile=''
    oenvstate=$(wt_runtime_state_get "$worktree" envstate) || oenvstate=''
    oseed=$(wt_runtime_state_get "$worktree" seedstatus) || oseed=''
    ocksum=$(wt_runtime_state_get "$worktree" seedcksum) || ocksum=''
  else
    oenvfile=''; oenvstate=''; oseed=''; ocksum=''
  fi
  wt_runtime_state_set "$worktree" "$slug" "$chosen" "$source" \
    "$oenvfile" "$oenvstate" "${oseed:-none}" "$ocksum" || \
    wt_log "  runtime: could not record the port allocation — it may be re-derived next session"

  [ "$held" -eq 1 ] && wt_lock_release 7

  # Advisory only, and deliberately AFTER both the decision and the lock release: a foreign
  # listener never moves the port, and the probe can take a second — which is a second no other
  # worktree should spend waiting on this lock. Running it here also keeps the probe's child from
  # inheriting the lock descriptor and holding the flock past the release.
  if wt_port_in_use "$chosen"; then
    wt_log "  runtime: something is already listening on port $chosen that is not one of this repository's worktrees — leaving the port as it is; the app may fail to bind"
  fi

  # shellcheck disable=SC2034
  WT_PORT=$chosen
  # shellcheck disable=SC2034
  WT_PORT_SOURCE=$source
  return 0
}

# ---------------------------------------------------------------------------
# Layer 3 — the env override file
# ---------------------------------------------------------------------------
#
# WHAT THIS WRITES IS DOTENV, `KEY=value` a line at a time, and deliberately nothing cleverer. A
# renderer that could also produce YAML or PHP config would have to know that target format's
# nesting and typing conventions — is a boolean quoted, is a key dotted or nested — which is
# exactly the repo-specific judgement the plugin must never infer and which calibration never
# gathered. A repo that needs another format already has the escape hatch: `runtime.seed` receives
# WT_ENV_FILE and every derived value, and can translate.
#
# VALUES ARE NOT QUOTED. dotenv dialects disagree about quoting — some strip quotes, some keep them
# literally — so the profile author's own text is written verbatim and the author owns it, the same
# trust boundary `deps[].install` already has. What is NOT left to the author is the KEY: it is
# shape-checked, because a key of `A=1` writes a line setting a variable the profile never names,
# and no care on the value side can defend against damage done before the `=`.

# THE PLUGIN OWNS A BLOCK, NOT A FILE. Frameworks load env files by fixed name, and the
# file an app loads is usually the one holding the developer's real configuration — copied in by
# `.worktreeinclude` before any hook runs. So the overrides go into THAT file, between two marker
# lines, appended after the developer's own assignments so that dotenv's last-assignment-wins
# resolves them in the plugin's favour. Everything outside the block is the developer's and is
# carried through byte for byte.
#
# WT_ENV_MARKER is the begin line's PREFIX, and the ownership check matches it as a prefix so a
# later version can extend the line. A file written by an older version began with a longer line that
# has this same prefix and had no end line; it reads as a block running to end of file, which is
# exactly the whole file it was.
WT_ENV_MARKER='# managed by the worktree plugin'
WT_ENV_BEGIN="$WT_ENV_MARKER — begin. Rewritten every session: to override a value, set it below the end line; to take this file over, delete the whole block."
WT_ENV_END='# end of the block managed by the worktree plugin'

# Split the file at $1 around its managed block(s). Sets WT_ENV_BEFORE (every line before the first
# block), WT_ENV_AFTER (every line after it that is not itself inside a block) and WT_ENV_HAS_BLOCK.
# Every line is kept newline-terminated, including a last line that had none, so the pieces can be
# concatenated with a block between them. A second block — two sessions' worth, pasted by hand — is
# dropped rather than kept, so a rewrite always leaves exactly one. Returns 1 if the file cannot be
# read, which callers treat as "not ours".
#
# Read with bash's own `read`, not a subprocess: this runs on the session-start path, and the files
# it reads are a few dozen lines.
wt_runtime_env_split() {  # $1 = file
  local f=${1-} line inblock=0
  WT_ENV_BEFORE='' WT_ENV_AFTER='' WT_ENV_HAS_BLOCK=0
  [ -f "$f" ] && [ -r "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$inblock" = 1 ]; then
      case $line in
        "$WT_ENV_END"*) inblock=0 ;;
      esac
      continue
    fi
    case $line in
      "$WT_ENV_MARKER"*)
        inblock=1
        WT_ENV_HAS_BLOCK=1
        continue
        ;;
    esac
    if [ "$WT_ENV_HAS_BLOCK" = 1 ]; then
      WT_ENV_AFTER=$WT_ENV_AFTER$line$WT_NL
    else
      WT_ENV_BEFORE=$WT_ENV_BEFORE$line$WT_NL
    fi
  done <"$f"
  return 0
}

# What is at $1/$2, as far as the override protocol is concerned:
#   absent    nothing there
#   ours      a regular, readable file that contains a managed block
#   unmarked  a regular, readable file with no block — the developer's, or a copy of the main
#             checkout's; whether the plugin may append to it is the WRITER's call, from state
#   theirs    something the plugin must never write through: a symlink (dangling or not), a
#             directory, an unreadable file
wt_runtime_env_state() {  # $1 = worktree, $2 = relative path
  local worktree=${1%/} rel=${2-} f
  f=$worktree/$rel
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    printf 'absent'
    return 0
  fi
  if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf 'theirs'
    return 0
  fi
  if ! wt_runtime_env_split "$f"; then
    printf 'theirs'
    return 0
  fi
  if [ "$WT_ENV_HAS_BLOCK" = 1 ]; then
    printf 'ours'
  else
    printf 'unmarked'
  fi
  return 0
}

# Put $2 in place at $1, atomically: a temp file in the same directory, so `mv` is a rename rather
# than a copy, and one write command, so a failed write is visible. A half-written env file is worse
# than none: the app reads it and points at half a configuration.
#
# THE MODE: a file the plugin creates is 0600 before anything is in it — these files hold database
# names and, in a repo that puts one there, a connection string. A file that ALREADY EXISTS is the
# developer's, and keeps its own mode: `cp -p` puts it on the temp file first, so a container whose
# user differs from the host's (a web server reading a bind-mounted env file) does not lose read
# access because a hook rewrote the file. Its mode is not the plugin's to tighten or loosen.
wt_runtime_env_put() {  # $1 = destination, $2 = content
  local dest=${1-} content=${2-} parent tmp
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || parent=.
  tmp=$(mktemp "${parent}/.wtenv.XXXXXX" 2>/dev/null) || return 1
  if [ -f "$dest" ] && [ ! -L "$dest" ]; then
    cp -p -- "$dest" "$tmp" 2>/dev/null || chmod 600 "$tmp" 2>/dev/null || true
  else
    chmod 600 "$tmp" 2>/dev/null || true
  fi
  if ! printf '%s' "$content" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dest" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  return 0
}

# Write the managed block into one override file. Sets WT_ENV_WROTE to `written`, `developer`, or
# `skipped`.
#
# $6 is what the state file recorded for THIS file last time — `ours`, `theirs`, or empty — and it
# is what separates the two kinds of file without a block. One the plugin has never written is
# appended to: it is the developer's configuration, copied in, and the block goes after it. One the
# plugin HAS written, whose block is now gone, is one the developer took over by deleting the block
# — the supported way to point a worktree at a shared database, a colleague's, a restored snapshot —
# and it is left exactly as it is. Putting the begin line back hands it back.
#
# It refuses rather than follows a symlink, at the leaf and at every parent. `runtime.env.file`
# comes out of a committed profile, so it arrives with anyone's branch, and the write below would
# otherwise land wherever the link points — another worktree, the main checkout, a home directory.
# The leaf check alone is not enough: `mkdir -p` and a redirect both follow a symlinked PARENT.
#
# It refuses a path that is not gitignored, and asks git rather than matching patterns itself. An
# override file that shows up as an untracked change is a bug — a developer commits it by accident
# and every teammate's worktree then points at one database. The question is asked IN THE WORKTREE,
# because that is the .gitignore that governs the file and a branch can legitimately differ.
wt_runtime_env_write() {  # $1 = worktree, $2 = rel path, $3 = port var, $4 = port, $5 = pairs stream, $6 = recorded disposition, $7 = expanded runtime.url or empty
  local worktree=${1%/} rel=${2-} pvar=${3-} port=${4-} pairs=${5-} recorded=${6-} url=${7-}
  local dest parent state rec body key val block before='' after='' n=0 irc verb unsafe wtname scoped

  # SC2034: WT_ENV_WROTE is this function's result — the caller records it in the state file so
  # the developer-managed warning is said once rather than on every session.
  # shellcheck disable=SC2034
  WT_ENV_WROTE=skipped
  [ -n "$rel" ] || return 0
  # A TRAILING SLASH names a directory, and `mv` into one moves the temp file INSIDE it under its
  # own random name — reporting success while creating no override file at all, so the next session
  # finds it absent and does it again, accumulating debris. wt_is_safe_relpath accepts the shape,
  # so it has to be caught here.
  case $rel in
    */) wt_log "  runtime: refusing to write \"$rel\" — it names a directory, not a file"; return 0 ;;
  esac
  if ! wt_is_safe_relpath "$rel"; then
    wt_log "  runtime: refusing to write \"$rel\" — not a relative path inside the worktree"
    return 0
  fi

  dest=$worktree/$rel
  if [ -L "$dest" ]; then
    wt_log "  runtime: refusing to write $rel — it is a symlink, and writing through it would land outside the worktree"
    return 0
  fi
  if wt_has_symlinked_parent "$worktree" "$rel"; then
    wt_log "  runtime: refusing to write $rel — one of its parent directories is a symlink"
    return 0
  fi

  state=$(wt_runtime_env_state "$worktree" "$rel")
  # A TAKEN-OVER FILE IS SILENT HERE, deliberately. The caller says it once, from the state record —
  # saying it from inside a function that runs every session is how a useful notice becomes noise
  # people scroll past, and this is the escape hatch the design most wants a developer to trust.
  case $state in
    theirs)
      # Not a regular, readable file — a directory, or one this user cannot read. Nothing can be
      # written there and no developer "took it over", so it is reported as a refusal: the seed
      # then refuses too, and the recorded disposition carries through unchanged.
      wt_log "  runtime: refusing to write $rel — it is not a regular file this user can read"
      return 0
      ;;
    unmarked)
      case $recorded in
        ours | theirs)
          # shellcheck disable=SC2034
          WT_ENV_WROTE=developer
          return 0
          ;;
      esac
      ;;
  esac

  # GITIGNORED OR NOTHING. Asked before the write, and a git that cannot answer is treated as a
  # refusal rather than as a yes: exit 0 means ignored, 1 means not, anything else is a real
  # failure (no git, a corrupt index, a path beyond a symlink) that must not be read as permission.
  wt_git "$worktree" check-ignore -q -- "$rel" >/dev/null 2>&1
  irc=$?
  case $irc in
    0) ;;
    1)
      wt_log "  runtime: refusing to write $rel — it is not gitignored, and an override file that shows up as an untracked change gets committed by accident"
      return 0
      ;;
    *)
      wt_log "  runtime: could not ask git whether $rel is ignored (it exited $irc) — not writing it"
      return 0
      ;;
  esac

  parent=${dest%/*}
  if [ "$parent" != "$dest" ] && [ ! -d "$parent" ]; then
    mkdir -p "$parent" 2>/dev/null || {
      wt_log "  runtime: could not create a parent directory for $rel — not writing it"
      return 0
    }
  fi

  # The developer's lines, read BEFORE the block is built so that a file which cannot be read is
  # never replaced by one holding only the block — that would delete their configuration.
  verb=wrote
  case $state in
    ours | unmarked)
      if ! wt_runtime_env_split "$dest"; then
        wt_log "  runtime: could not read $rel — not writing it"
        return 0
      fi
      before=$WT_ENV_BEFORE
      after=$WT_ENV_AFTER
      [ "$state" = unmarked ] && verb='added the block to'
      ;;
  esac

  # THE BLOCK IS BUILT FIRST, IN MEMORY, AND WRITTEN BY ONE COMMAND. The obvious shape —
  # `{ printf; printf; while ...; } >"$tmp" || cleanup` — cannot detect a failed write: a brace
  # group reports the status of its LAST command, which here is the loop, so a printf that failed
  # on a full disk was invisible and the truncated file was promoted into place anyway. Worse, if
  # the line lost was the MARKER, every later session would read the file as the developer's.
  block=$WT_ENV_BEGIN$WT_NL
  # WT_NAME is folded like a value: a directory name can hold a line break, and one here would end
  # the comment and start an assignment the profile never named.
  wtname=${WT_NAME-}
  wtname=${wtname//"$WT_CR"/ }
  wtname=${wtname//"$WT_NL"/ }
  block=$block"# worktree=$wtname slug=${WT_SLUG-}$WT_NL"

  # THE PORT VARIABLE IS SHAPE-CHECKED LIKE ANY OTHER KEY, and it was not at first. It becomes the
  # left-hand side of a `KEY=value` line exactly as an env.vars key does, and it is only WARNED
  # about by validation (which WT_SKIP_VALIDATION removes entirely), so a committed profile naming
  # `"var": "A=1"` would emit `A=1=3812` — setting a variable the profile never names, which is
  # precisely the damage checking the other keys exists to prevent.
  if [ -n "$pvar" ] && [ -n "$port" ]; then
    if wt_is_safe_envkey "$pvar"; then
      block=$block"$pvar=$port$WT_NL"
    else
      wt_log "  runtime: skipping the port line — \"$pvar\" is not a legal environment variable name"
      pvar=''
    fi
  else
    pvar=''
  fi
  # Re-checked, not trusted: this line is unquoted in a file a dotenv parser reads.
  if [ -n "$url" ]; then
    if wt_is_safe_url "$url"; then
      block=$block"WORKTREE_URL=$url$WT_NL"
    else
      wt_log "  runtime: skipping WORKTREE_URL — \"$url\" is not a plain http(s) URL"
    fi
  fi

  # SCOPED KEYS: `<file>:<VAR>` sets VAR in that one file only, in place of the shared VAR there. So
  # the pass below first collects which VARs this file scopes, then writes each shared VAR this
  # file does not scope, then this file's scoped ones — every VAR once, with the right value.
  scoped=' '
  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      3"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    key=${body%%"$WT_US"*}
    case $key in
      "$rel":*) scoped="$scoped${key#"$rel":} " ;;
    esac
  done < <(printf '%s' "$pairs")

  while IFS= read -r -d "$WT_RS" rec; do
    # Group 3 of the profile scan is runtime.env.vars.
    case $rec in
      3"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    key=${body%%"$WT_US"*}
    val=${body#*"$WT_US"}
    case $key in
      "$rel":*) key=${key#"$rel":} ;;
      *:*) continue ;;
      *)
        case $scoped in
          *" $key "*) continue ;;
        esac
        ;;
    esac
    # Re-checked here rather than trusted from validation: this is a public entry point, and the
    # validator can be bypassed with WT_SKIP_VALIDATION. A bad key is skipped, not fatal — the
    # other variables are still worth writing.
    if ! wt_is_safe_envkey "$key"; then
      wt_log "  runtime: skipping \"$key\" — not a legal environment variable name"
      continue
    fi
    # A NEWLINE IN A VALUE WOULD FORGE A SECOND ASSIGNMENT, naming a variable the profile does not
    # — the same damage as a bad key, arriving from the other side of the `=`. dotenv is
    # line-oriented, so the writer folds line breaks rather than trusting its input not to have
    # any. The JSON layer folds these already; this is the backstop for a stream built another way.
    # AN UNCONSTRAINED PLACEHOLDER MUST NOT CARRY SHELL SYNTAX INTO A FILE THE APP PARSES. Since
    # the block now goes into the file the framework really loads, and several dotenv dialects
    # (Symfony's, Ruby's) run `$(...)` in an unquoted value — so `DB=app_{name}` plus a colleague's
    # branch named `x$(cmd)` would run `cmd` on every boot of the app. {name}, {worktree} and {root}
    # are raw text from a less trusted party than the committed profile; the same refusal the
    # install commands get applies here, and for the same reason quoting is not attempted instead.
    unsafe=$(wt_unsafe_command_placeholder "$val")
    if [ -n "$unsafe" ]; then
      wt_log "  runtime: skipping \"$key\" — its {$unsafe} expands to text with shell syntax in it, which a dotenv parser may execute"
      continue
    fi
    val=$(wt_expand "$val")
    val=${val//"$WT_CR"/ }
    val=${val//"$WT_NL"/ }
    block=$block"$key=$val$WT_NL"
    n=$((n + 1))
  done < <(printf '%s' "$pairs")
  block=$block$WT_ENV_END$WT_NL

  if wt_runtime_env_put "$dest" "$before$block$after"; then
    # shellcheck disable=SC2034
    WT_ENV_WROTE=written
    wt_log "  runtime: $verb $rel${pvar:+ ($pvar=$port)}, $n variable(s)"
  else
    wt_log "  runtime: could not write $rel"
  fi
  return 0
}

# Take the managed block back out of one override file — teardown's half of the protocol. The
# developer's lines stay; a file left holding nothing but blank lines was only ever the block, so
# it goes. A file without a block, or one this refuses to write through, is not touched. Returns 1
# only when there was a block and it could not be removed.
wt_runtime_env_release() {  # $1 = worktree, $2 = relative path
  local worktree=${1%/} rel=${2-} dest rest
  [ -n "$rel" ] && wt_is_safe_relpath "$rel" || return 0
  case $rel in */) return 0 ;; esac
  wt_has_symlinked_parent "$worktree" "$rel" && return 0
  [ "$(wt_runtime_env_state "$worktree" "$rel")" = ours ] || return 0
  dest=$worktree/$rel
  wt_runtime_env_split "$dest" || return 1
  rest=$WT_ENV_BEFORE$WT_ENV_AFTER
  case $rest in
    *[![:space:]]*) wt_runtime_env_put "$dest" "$rest" ;;
    *) rm -f -- "$dest" 2>/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# Layer 3 — the seed contract
# ---------------------------------------------------------------------------
#
# THE CONTRACT, which the reference template and the calibrate skill both describe and which a
# repo-owned script is written against:
#
#   * it runs INSIDE the profile's `shell`, with the WORKTREE as its working directory;
#   * it receives WT_NAME, WT_SLUG, WT_PORT, WT_PATH, WT_ROOT, WT_ENV_FILE (the first override file)
#     and WT_ENV_FILES (all of them, one per line) in the environment —
#     never as arguments and never interpolated into a command line;
#   * a non-zero exit warns and the session continues; the state file records the
#     failure so a re-entry can retry;
#   * it is time-boxed, out of what is LEFT of the bootstrap budget rather than out of a fresh
#     allowance, because both run inside one hook invocation and their SUM has to fit.
#
# WHY VALUES ARRIVE AS ENVIRONMENT AND NOT AS ARGUMENTS. `runtime.seed` is a PATH, not a command
# template, so nothing expands into command position and the whole injection class bootstrap had to
# defend against with wt_unsafe_command_placeholder does not arise here. The path itself is the one
# thing that does reach a command string, so it is invoked as `./'<path>'` relative to the working
# directory the runner already sets — which keeps $WT_PATH, and therefore the untrusted worktree
# name embedded in it, out of the command entirely.
#
# THE SEED IS THE ONE STEP THAT FAILS CLOSED. Everything else in layer 3 fails open, because a
# missing port costs a bind error and a missing env file costs a misconfigured app — both loud,
# both recoverable. A seed clones or creates a DATABASE from a name this plugin derived, so acting
# on a name it cannot vouch for destroys a colleague's work. It therefore refuses unless it can
# prove three things, and says which one it could not.

# Run the seed. Sets WT_SEED_STATUS to one of: done, failed, timeout, skipped, refused, none.
wt_runtime_seed() {  # $1=root $2=worktree $3=slug $4=port $5=env files $6=env state $7=seed rel $8=deadline
  # $5 is every override file, `:`-joined. $6 carries their COMBINED disposition — `ours`,
  # `theirs` if any file is the developer's, or `unwritten` if the profile asked for a file this
  # session could not write. The per-file dispositions live in the state record, which this
  # function carries through rather than overwriting with the combined one.
  local root=${1%/} worktree=${2%/} slug=${3-} port=${4-} envrel=${5-} envstate=${6-}
  local rel=${7-} deadline=${8-} abs esc cksum prev prevck prevslug left secs full rc started elapsed
  local sibslug sibport

  # SC2034: WT_SEED_STATUS is this function's result — wt_runtime_handoff reports on it.
  # shellcheck disable=SC2034
  WT_SEED_STATUS=none
  [ -n "$rel" ] || return 0

  if ! wt_is_safe_relpath "$rel"; then
    wt_log "  runtime: refusing to run the seed \"$rel\" — not a relative path inside the worktree"
    WT_SEED_STATUS=refused
    return 0
  fi
  abs=$worktree/$rel
  if wt_has_symlinked_parent "$worktree" "$rel" || [ -L "$abs" ]; then
    wt_log "  runtime: refusing to run the seed $rel — it or one of its parents is a symlink, so it is not the script this branch committed"
    WT_SEED_STATUS=refused
    return 0
  fi
  if [ ! -f "$abs" ]; then
    # Not an error: the profile may name a script a later commit adds, and calibration deliberately
    # scaffolds one before it is written.
    wt_log "  runtime: the seed script $rel is not in this worktree — skipping the seed step"
    WT_SEED_STATUS=skipped
    return 0
  fi

  # --- SKIP FIRST: already done, and nothing has changed -------------------------------------
  # BEFORE the refusals, deliberately. If nothing is going to run, none of the three questions need
  # asking — and asking them anyway means a worktree that seeded successfully weeks ago starts
  # reporting `refused` and printing a warning on every session the moment its developer takes
  # ownership of the env file, which is a supported thing to do and already recorded.
  #
  # Fingerprinted on the SCRIPT'S CONTENT and the slug, exactly as a dependency is fingerprinted on
  # its lockfile and install command. Editing the script re-runs it; nothing else does.
  cksum=$(wt_cksum_file "$abs")
  prev=$(wt_runtime_state_get "$worktree" seedstatus) || prev=''
  prevck=$(wt_runtime_state_get "$worktree" seedcksum) || prevck=''
  prevslug=$(wt_runtime_state_get "$worktree" slug) || prevslug=''
  # Quoted: bare `done` is the loop keyword to the parser (the same trap wt_state_is_done notes).
  if [ "$prev" = "done" ] && [ "$prevck" = "$cksum" ] && [ "$prevslug" = "$slug" ]; then
    WT_SEED_STATUS="done"
    return 0
  fi

  # NOT EXECUTABLE is a skip, not a failure. `chmod +x` does not change a file's CONTENT, so
  # recording a failure here would fingerprint the script and then refuse to retry it — leaving
  # "edit it to try again" as the only escape from a problem editing does not fix.
  if [ ! -x "$abs" ]; then
    wt_log "  runtime: the seed script $rel is not executable — run chmod +x on it; skipping the seed step"
    WT_SEED_STATUS=skipped
    return 0
  fi

  # --- REFUSAL 1: the app is not pointed where this seed thinks it is ------------------------
  # A developer-managed env file means the worktree deliberately points somewhere else — a shared
  # database, a colleague's, a restored snapshot. Seeding WT_SLUG then creates or clones something
  # the app will never read, and in the worst case does it to a name someone else is using.
  if [ "$envstate" = theirs ]; then
    wt_log "  runtime: not seeding — ${envrel//:/ or } is managed by you, so this worktree is pointed somewhere the seed's WT_SLUG=$slug does not describe. Put the plugin's block back to hand it back."
    WT_SEED_STATUS=refused
    return 0
  fi
  # THE SAME CONDITION ARRIVED AT A DIFFERENT WAY. If the profile asked for an override file and
  # this session could not write it — the path was not gitignored, a parent was a symlink, the disk
  # was full — then the app in this worktree is still reading whatever it read before, usually the
  # shared database. Seeding would then create a database named after WT_SLUG that nothing points
  # at, while the session quietly works against the shared one. Refusal 1 exists for exactly this
  # state; it just could not see it until the outcome was passed in.
  if [ "$envstate" = unwritten ]; then
    wt_log "  runtime: not seeding — ${envrel//:/ or } could not be written, so this worktree is not pointed at anything named $slug yet"
    WT_SEED_STATUS=refused
    return 0
  fi

  # --- REFUSAL 2: we cannot see the other worktrees ------------------------------------------
  # THE SCAN IS RUN HERE, not inherited. Reading whatever a previous caller left in the globals was
  # a real defect: wt_runtime_claim_port returns EARLY — before scanning — whenever a port is
  # already recorded for this slug, and it never runs at all for a profile with a seed but no
  # `runtime.port`. So the flag was stale or unset in the ordinary case, and the seed refused
  # forever after its first session, blaming an enumeration nobody had attempted. The scan is
  # fork-free per sibling, so running it again costs one `rev-parse`.
  wt_runtime_siblings "$root" "$worktree"
  # The sibling scan is what proves no live worktree already owns this slug. If it could not run,
  # the honest answer is that we do not know — and for the one irreversible step, not knowing has
  # to mean not doing. Ports fail open on the same signal; the seed must not.
  if [ "${WT_SIBLINGS_OK:-0}" != 1 ]; then
    wt_log "  runtime: not seeding — could not enumerate this repository's other worktrees, so it cannot be established that no other worktree already owns the name \"$slug\""
    WT_SEED_STATUS=refused
    return 0
  fi

  # --- REFUSAL 3: another live worktree already owns this slug -------------------------------
  # There is no safe "probe forward" for a database name the way there is for a port: inventing an
  # alternative is exactly the inference the plugin must never make. Refuse, name the collision, let the
  # developer rename the worktree or fix the profile.
  # Distinct names: `prev`/`prevck` hold the RECORDED SEED FINGERPRINT read above, and reusing them
  # as this loop's variables clobbered it — so the "do not retry an unchanged failure" rule below
  # silently never fired and a failing stub re-ran on every session, which is the exact cost that
  # rule exists to avoid.
  # shellcheck disable=SC2034  # sibport is read POSITIONALLY to consume its field.
  while IFS=$WT_US read -r -d "$WT_RS" sibslug sibport; do
    if [ "$sibslug" = "$slug" ]; then
      wt_log "  runtime: not seeding — another live worktree already owns the name \"$slug\". Rename this worktree, or give runtime.slug a template that distinguishes them."
      WT_SEED_STATUS=refused
      return 0
    fi
  done <<EOF
${WT_SIBLINGS-}
EOF

  # A PREVIOUS FAILURE IS NOT RE-PAID EVERY SESSION. Calibration deliberately scaffolds a seed stub
  # that exits non-zero until edited, so without this a repo that has not written its seed yet
  # would burn the whole seed timeout on every single session, forever, for a failure it has
  # already been told about. One line instead — and the moment the script or the slug changes, it
  # retries by itself, with no reset step to remember.
  case $prev in
    failed | timeout)
      if [ "$prevck" = "$cksum" ] && [ "$prevslug" = "$slug" ]; then
        wt_log "  runtime: the seed $rel failed last time and has not changed since — not retrying. Edit it to try again."
        WT_SEED_STATUS=$prev
        return 0
      fi
      ;;
  esac

  # --- RUN -----------------------------------------------------------------------------------
  # The budget is what is LEFT, clamped by the profile's own seedSeconds. Both this and the
  # dependency work run inside one hook invocation, so taking a fresh seedSeconds here is how the
  # platform ends up killing the hook before any internal guard fires.
  left=$(wt_budget_left "$deadline")
  secs=${PROFILE_SEED_TIMEOUT:-$WT_DEFAULT_TIMEOUT}
  wt_is_seconds "$secs" || secs=$WT_DEFAULT_TIMEOUT
  full=$secs
  # `left` may legitimately be "0", which wt_is_posint REJECTS — so testing it with that would
  # skip the clamp exactly when the budget is spent and hand the seed the profile's full
  # allowance. Digits, including zero, is the right test here.
  case $left in
    '' | *[!0-9]*) left='' ;;
  esac
  if [ -n "$left" ] && [ "$((10#$left))" -lt "$((10#$secs))" ]; then
    secs=$left
  fi
  if ! wt_is_posint "$secs"; then
    wt_log "  runtime: no time left in the bootstrap budget to run the seed — leaving it for the next session"
    wt_runtime_state_set "$worktree" "$slug" "$port" \
      "$(wt_runtime_state_get "$worktree" portsource || printf derived)" \
      "$(wt_runtime_state_get "$worktree" envfile || printf '%s' "$envrel")" \
      "$(wt_runtime_state_get "$worktree" envstate || printf '%s' "$envstate")" failed "" || true
    WT_SEED_STATUS=failed
    return 0
  fi

  # The seed runs inside the toolchain too, so it is started first — with the seed's own time, which
  # the installs could not spend. A toolchain that still is not ready leaves the seed for later,
  # recorded as not run, so the next session or /pitlane-finish retries it.
  if ! wt_toolchain_warm "$worktree" "$deadline"; then
    wt_log "  runtime: the toolchain is not ready, so the seed has not run — leaving it for /pitlane-finish or the next session"
    wt_runtime_state_set "$worktree" "$slug" "$port" \
      "$(wt_runtime_state_get "$worktree" portsource || printf derived)" \
      "$(wt_runtime_state_get "$worktree" envfile || printf '%s' "$envrel")" \
      "$(wt_runtime_state_get "$worktree" envstate || printf '%s' "$envstate")" failed "" || true
    WT_SEED_STATUS=failed
    return 0
  fi
  left=$(wt_budget_left "$deadline")
  case $left in '' | *[!0-9]*) ;; *) [ "$((10#$left))" -ge "$((10#$secs))" ] || secs=$left ;; esac
  # `timeout 0` would mean no limit at all, so a warm-up that used the seed's time leaves it for later.
  if ! wt_is_posint "$secs"; then
    wt_log "  runtime: starting the toolchain used the seed's time — leaving the seed for /pitlane-finish or the next session"
    wt_runtime_state_set "$worktree" "$slug" "$port" \
      "$(wt_runtime_state_get "$worktree" portsource || printf derived)" \
      "$(wt_runtime_state_get "$worktree" envfile || printf '%s' "$envrel")" \
      "$(wt_runtime_state_get "$worktree" envstate || printf '%s' "$envstate")" failed "" || true
    WT_SEED_STATUS=failed
    return 0
  fi

  # `./'<path>'` keeps $WT_PATH — and the untrusted worktree name inside it — out of the command
  # string. An embedded single quote in the path is escaped rather than assumed absent.
  esc=${rel//\'/\'\\\'\'}
  wt_log "  runtime: seeding with $rel (${secs}s of the budget left)"
  started=$(date +%s 2>/dev/null) || started=''
  # SC2030/SC2031: the assignments below are DELIBERATELY confined to this subshell. The contract
  # values belong to the seed child and must not leak back into the hook, whose own WT_SLUG/WT_PORT
  # describe the same worktree but are set by the handoff, not by this function.
  (
    export WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT WT_ENV_FILE WT_ENV_FILES
    # shellcheck disable=SC2030
    WT_SLUG=$slug
    # shellcheck disable=SC2030
    WT_PORT=$port
    WT_PATH=$worktree
    WT_ROOT=$root
    WT_ENV_FILE=${envrel%%:*}
    WT_ENV_FILES=${envrel//:/$WT_NL}
    wt_run_in_shell "./'$esc'" "$worktree" "$secs"
  )
  rc=$?
  elapsed=''
  [ -n "$started" ] && elapsed=$(( $(date +%s) - started ))

  case $rc in
    0)
      wt_log "  runtime: seeded${elapsed:+ in ${elapsed}s}"
      WT_SEED_STATUS="done"
      ;;
    124)
      # A TIMEOUT CAUSED BY A SHORT BUDGET MUST STAY RETRYABLE. If the seed got less than the
      # profile allows — a slow dependency install ate the budget — then the script was never the
      # problem, and fingerprinting it here would wedge seeding permanently: no later session would
      # retry however much time it had, and "edit the script" is advice about a script that is
      # fine. Clearing the fingerprint makes the next session try again.
      if [ "$((10#$secs))" -lt "$((10#$full))" ]; then
        wt_log "  runtime: the seed only had ${secs}s of the ${full}s it asks for, because the rest of the bootstrap used the budget — it was stopped, and will be tried again next session"
        cksum=''
      else
        wt_log "  runtime: the seed ran past the ${secs}s it had and was stopped — the database may be half-made; it will be retried when the script changes"
      fi
      WT_SEED_STATUS=timeout
      ;;
    137 | "$WT_GUARD_REFUSED")
      # Memory, not the script: never fingerprinted, so the next session retries it.
      wt_log "  runtime: the seed was not completed for lack of memory — it will be tried again by /pitlane-finish or the next session"
      WT_SEED_STATUS=failed
      cksum=''
      ;;
    *)
      wt_log "  runtime: the seed failed (exit $rc) — the worktree has its own port and env file, but its database may not be ready"
      WT_SEED_STATUS=failed
      ;;
  esac

  wt_runtime_state_set "$worktree" "$slug" "$port" \
    "$(wt_runtime_state_get "$worktree" portsource || printf derived)" \
    "$(wt_runtime_state_get "$worktree" envfile || printf '%s' "$envrel")" \
    "$(wt_runtime_state_get "$worktree" envstate || printf '%s' "$envstate")" \
    "$WT_SEED_STATUS" "$cksum" || \
    wt_log "  runtime: could not record the seed outcome — it will run again next session"
  return 0
}

# ---------------------------------------------------------------------------
# Layer 3 — the whole step
# ---------------------------------------------------------------------------
#
# An in-process call at the point runtime isolation has to happen: inside the SAME SessionStart
# invocation, before the hook returns, because env overrides must exist before the session starts.
# There is no cross-process boundary here to justify serialising the hand-off through a file — the
# artifact pattern belongs to teardown, which is a genuinely separate event.
#
# SILENT when the profile has no runtime block, because absent means TOUCH NOTHING and a
# plugin that comments on every session start is one people uninstall.

# The marker a developer drops in a worktree to opt that ONE worktree out of layer 3 entirely.
#
# It exists because editing the env override file — the other escape hatch — only redirects the
# state; it does not stop a port being derived or a seed running. This is for the case where the
# derived database is the LAST thing someone wants: a worktree opened to reproduce a bug against
# the shared data, or to look at a restored snapshot. Dependencies are untouched, so the worktree
# still works; only isolation is skipped.
WT_NO_RUNTIME_MARKER='.claude/worktree-no-runtime'

# The disposition recorded for env file $3, given the recorded `:`-joined file list $1 and the
# aligned `:`-joined dispositions $2. Prints `ours`, `theirs`, or nothing. A record from an
# older version holds one file and one disposition, which is the same shape with a single element.
wt_runtime_env_recorded() {  # $1 = recorded files, $2 = recorded dispositions, $3 = file
  local files=${1-} states=${2-} want=${3-} f st
  [ -n "$files" ] && [ -n "$want" ] || return 0
  while :; do
    f=${files%%:*}
    st=${states%%:*}
    if [ "$f" = "$want" ]; then
      case $st in ours | theirs) printf '%s' "$st" ;; esac
      return 0
    fi
    [ "$f" != "$files" ] || return 0
    files=${files#*:}
    if [ "$st" = "$states" ]; then states=''; else states=${states#*:}; fi
  done
}

# Layer 3 for one worktree: slug, port, env blocks, seed. Publishes WT_RUNTIME_PORT (the claimed
# port, when runtime.port.var names a variable to carry it) and WT_RUNTIME_URL (runtime.url expanded,
# when it is safe), for the session's environment and status line; both empty when nothing was set.
wt_runtime_handoff() {  # $1 = root, $2 = worktree, $3 = the bootstrap deadline (epoch seconds)
  local root=${1%/} worktree=${2%/} deadline=${3-}
  local slug tpl envfiles envstate oldenv oldstates recenv port psrc oldslug oldseed oldcksum sslug sport
  local rest f prior fstate shown nfiles url

  WT_RUNTIME_PORT=''
  WT_RUNTIME_URL=''
  [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] || return 0

  if [ -e "$worktree/$WT_NO_RUNTIME_MARKER" ]; then
    wt_log "runtime: $WT_NO_RUNTIME_MARKER is present — leaving this worktree's ports, env and database alone"
    return 0
  fi

  # THE SLUG IS RE-SLUGIFIED AFTER EXPANSION, always. `runtime.slug` is a TEMPLATE, and the schema
  # allows it to be `{name}` — raw branch text — while everything downstream trusts a slug to be
  # [a-z0-9_]: a database name and a derived port among them. Running the result back through
  # wt_slugify makes that safe BY CONSTRUCTION rather than by review, and costs nothing, since
  # wt_slugify is idempotent on its own output.
  #
  # A TEMPLATE WITH NO PER-WORKTREE PLACEHOLDER IS IGNORED, and that is not cosmetic. It expands to
  # the same text for every worktree, so every worktree derives one port and one database — and
  # then the same-slug rule in the port claim treats them as one worktree rather than as a
  # collision, so nothing downstream notices. wt_validate_profile already only WARNS about such a
  # template, on the explicit promise that "the worktree's own name will be used instead"; this is
  # where that promise is kept. Without it the warning was a lie in the most expensive direction.
  #
  # The default is built in two plain steps rather than with a `:-` word containing an escaped
  # brace, whose quoting is not portable enough to bet a database name on.
  tpl=${PROFILE_RT_SLUG:-}
  case $tpl in
    *'{slug}'* | *'{name}'*) ;;
    *)
      [ -z "$tpl" ] || wt_log "runtime: runtime.slug is \"$tpl\", which is the same for every worktree — using this worktree's own name instead"
      tpl='{slug}'
      ;;
  esac
  slug=$(wt_expand "$tpl")
  # SC2031: shellcheck is tracking the seed function's subshell from earlier in this file; the
  # WT_SLUG read here is the hook's own, set by the entrypoint before this runs.
  # shellcheck disable=SC2031
  slug=$(wt_slugify "$slug") || slug=${WT_SLUG-}
  # shellcheck disable=SC2031
  [ -n "$slug" ] || slug=${WT_SLUG-}
  if [ -z "$slug" ]; then
    wt_log "runtime: could not derive a slug for this worktree — skipping runtime isolation"
    return 0
  fi

  # Republished, because everything below expands {slug} and the template may have changed it.
  WT_SLUG=$slug
  export WT_SLUG

  # A CHANGED SLUG IS A DIFFERENT DATABASE, so the previous one's seed marker must not carry over.
  # The port claim resets these too, but it returns early — before writing anything — whenever the
  # profile has no usable `runtime.port`, so a profile with `env` and `seed` and no port would
  # otherwise keep a `done` marker across a slug change and never seed the new database at all.
  # Read once, here, where every later write can see it.
  oldslug=$(wt_runtime_state_get "$worktree" slug) || oldslug=''
  if [ -n "$oldslug" ] && [ "$oldslug" != "$slug" ]; then
    oldseed=none
    oldcksum=''
  else
    oldseed=$(wt_runtime_state_get "$worktree" seedstatus) || oldseed=none
    oldcksum=$(wt_runtime_state_get "$worktree" seedcksum) || oldcksum=''
  fi

  # --- the port ------------------------------------------------------------------------------
  wt_runtime_claim_port "$root" "$worktree" "$slug" \
    "${PROFILE_RT_PORTBASE:-}" "${PROFILE_RT_PORTSPAN:-}"
  # shellcheck disable=SC2031  # the seed's subshell is a different function; this is our own.
  port=$WT_PORT
  psrc=$WT_PORT_SOURCE
  # Exported BEFORE the env file is written, because {port} in a value resolves from it.
  WT_PORT=$port
  export WT_PORT
  if [ -n "$port" ] && [ -n "${PROFILE_RT_PORTVAR:-}" ] && wt_is_safe_envkey "$PROFILE_RT_PORTVAR"; then
    WT_RUNTIME_PORT=$port
  fi
  url=''
  if [ -n "${PROFILE_RT_URL:-}" ]; then
    if url=$(wt_expand_url "$PROFILE_RT_URL"); then
      WT_RUNTIME_URL=$url
    else
      wt_log "runtime: runtime.url — $url; WORKTREE_URL is not set"
      url=''
    fi
  fi

  # --- the env override files ------------------------------------------------------------------
  # One managed block per file the app loads, each with its OWN recorded disposition: a
  # developer can take over the test env's file and leave the dev env's to the plugin. The record
  # keeps the list and the dispositions `:`-joined and aligned, and a file's prior disposition is
  # looked up BY NAME, so reordering the list or adding a file cannot hand one file's `ours` to
  # another — which would claim a block was deleted from a file the plugin never wrote.
  envfiles=${PROFILE_RT_ENVFILES:-}
  envstate=''
  shown=''
  if [ -n "$envfiles" ]; then
    oldenv=$(wt_runtime_state_get "$worktree" envfile) || oldenv=''
    oldstates=$(wt_runtime_state_get "$worktree" envstate) || oldstates=''
    envstate=ours
    recenv=''
    nfiles=0
    rest=$envfiles
    while [ -n "$rest" ]; do
      f=${rest%%:*}
      if [ "$f" = "$rest" ]; then rest=''; else rest=${rest#*:}; fi
      prior=$(wt_runtime_env_recorded "$oldenv" "$oldstates" "$f")
      # A FILE NOTHING RECORDS, WITHOUT A BLOCK, THAT DIFFERS FROM THE MAIN CHECKOUT'S was written in
      # this worktree by hand — most often one set up before the plugin was adopted, pointed at a
      # database cloned by hand. Appending the block would silently re-point it. A file
      # native creation or .worktreeinclude just copied in is byte-identical to the main checkout's,
      # which is the one case the block is for. Said once, since the verdict is then recorded.
      if [ -z "$prior" ] && [ "$(wt_runtime_env_state "$worktree" "$f")" = unmarked ] \
        && ! cmp -s -- "$root/$f" "$worktree/$f" 2>/dev/null; then
        prior=theirs
        wt_log "runtime: $f is yours — it differs from the main checkout's copy, so it was set up in this worktree by hand; it will be left alone, and nothing will be seeded. To hand it to the plugin, add this line at its end: $WT_ENV_MARKER"
      fi
      wt_runtime_env_write "$worktree" "$f" "${PROFILE_RT_PORTVAR:-}" "$port" "${PROFILE_RAW:-}" "$prior" "$url"
      case $WT_ENV_WROTE in
        written) fstate=ours ;;
        developer)
          # SAID ONCE, not every session. The state record is what makes that possible: taking a
          # file over is the supported way to point a worktree at a shared database or a
          # colleague's, and a warning repeated on every start is one a developer learns to scroll
          # past — at which point it stops protecting the thing it is about.
          if [ "$prior" != theirs ]; then
            wt_log "runtime: $f is yours — it has no block from the plugin, so it will be left alone from now on. To hand it back, add this line at its end: $WT_ENV_MARKER"
          fi
          fstate=theirs
          ;;
        # The profile asked for a file and we could not write it — a state of its own, because the
        # seed must refuse on it just as it refuses on a developer-managed file.
        *) fstate=unwritten ;;
      esac
      # The seed's view is the WORST file: one environment pointed elsewhere, or not pointed at
      # all, is enough to make a database named after this slug unsafe to create.
      case $fstate in
        unwritten) envstate=unwritten ;;
        theirs) [ "$envstate" = unwritten ] || envstate=theirs ;;
      esac
      case $fstate in
        written | ours | theirs) shown=${shown:+$shown, }$f ;;
      esac
      # `unwritten` is this session's outcome, not a durable fact about the file — so the fact
      # recorded BEFORE it carries through. Recording an empty slot instead would forget that the
      # plugin had written here, and a developer who later deletes the block to take the file over
      # would get it appended again, silently re-pointing a worktree they had pointed elsewhere.
      case $fstate in
        ours | theirs) ;;
        *) fstate=$prior ;;
      esac
      if [ "$nfiles" -eq 0 ]; then recenv=$fstate; else recenv=$recenv:$fstate; fi
      nfiles=$((nfiles + 1))
    done
    wt_runtime_state_set "$worktree" "$slug" "$port" "$psrc" "$envfiles" "$recenv" \
      "${oldseed:-none}" "$oldcksum" || true
  fi

  # ANOTHER LIVE WORKTREE ON THIS SLUG affects the DATABASE, not just the port — both derive the
  # same `demo_{slug}`, and stepping the port forward does not fix that. The seed refuses outright,
  # but a profile with `env.vars` and no seed has nothing to refuse, so the warning belongs here
  # where every profile shape reaches it.
  if [ -n "${WT_SIBLINGS-}" ]; then
    while IFS=$WT_US read -r -d "$WT_RS" sslug sport; do
      if [ "$sslug" = "$slug" ]; then
        wt_log "runtime: another live worktree already uses the name \"$slug\", so both would point at the same database. Rename this worktree, or give runtime.slug a template that distinguishes them."
        break
      fi
    done <<EOF
${WT_SIBLINGS-}
EOF
  fi

  # --- the seed ----------------------------------------------------------------------------------
  # Deferred like the installs: the env overrides above are cheap and are already written, so the
  # session knows its databases' names; making them is the background run's job.
  # Not approved: nothing recorded, so the seed stays "not done" and runs once it is approved.
  if [ -n "${PROFILE_RT_SEED:-}" ] && [ "${WT_APPROVAL:-}" = no ]; then
    wt_log "runtime: the seed ${PROFILE_RT_SEED} is not approved — not run"
  elif [ -n "${PROFILE_RT_SEED:-}" ] && [ "${WT_DEFER:-0}" != 1 ] && ! wt_approval_still "$worktree"; then
    WT_APPROVAL=no
    wt_log "runtime: the profile or a script it names changed since it was approved — the seed is not run"
  elif [ -n "${PROFILE_RT_SEED:-}" ] && [ "${WT_DEFER:-0}" != 1 ]; then
    wt_runtime_seed "$root" "$worktree" "$slug" "$port" "$envfiles" "$envstate" \
      "${PROFILE_RT_SEED}" "$deadline"
  fi

  # ONE honest summary line, naming what this worktree actually got. It is the sentence in which a
  # wrong mapping becomes obvious — and the only feedback a developer sees before the TUI renders.
  # `env=` names only the files that ARE there: wt_runtime_env_write refuses a symlink, a
  # non-gitignored path and a failed write, and naming such a file would report isolation that did
  # not happen.
  wt_log "runtime: slug=$slug${port:+ port=$port}${url:+ url=$url}${shown:+ env=$shown}"
  return 0
}

# Append this worktree's port and URL to the file Claude Code names in CLAUDE_ENV_FILE, as `export`
# lines, so the session's own commands see them in their environment (ADR-021). SessionStart only,
# and only before the hook exits: Claude Code reads the file once, when the hook returns, so a
# background run's write never arrives. Additive — the app still reads its env files. A missing,
# unwritable or non-regular target only warns. The values are constrained by construction (digits; a
# URL wt_is_safe_url passed, which holds no quote), and single-quoted anyway.
wt_session_env_export() {  # $1 = the file CLAUDE_ENV_FILE names (empty: do nothing)
  local f=${1-} lines=''
  [ -n "$f" ] || return 0
  if [ -n "${WT_RUNTIME_PORT:-}" ] && wt_is_safe_envkey "${PROFILE_RT_PORTVAR:-}" \
    && wt_is_posint "$WT_RUNTIME_PORT"; then
    lines+="export $PROFILE_RT_PORTVAR='$WT_RUNTIME_PORT'$WT_NL"
  fi
  if [ -n "${WT_RUNTIME_URL:-}" ] && wt_is_safe_url "$WT_RUNTIME_URL"; then
    lines+="export WORKTREE_URL='$WT_RUNTIME_URL'$WT_NL"
  fi
  [ -n "$lines" ] || return 0
  if [ -d "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
    wt_log "runtime: CLAUDE_ENV_FILE ($f) is not a regular file — the session's environment does not get the port or the URL"
    return 0
  fi
  if ! printf '%s' "$lines" >>"$f" 2>/dev/null; then
    wt_log "runtime: could not append to CLAUDE_ENV_FILE ($f) — the session's environment does not get the port or the URL"
  fi
  return 0
}
