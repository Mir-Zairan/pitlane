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

# ---------------------------------------------------------------------------
# Config copying
# ---------------------------------------------------------------------------
#
# TWO SOURCES, ONE RULE. `.worktreeinclude` is authoritative and stays native wherever native
# creation runs (ADR-007); the profile's `copy[]` is a supplement native knows nothing about.
# Both end up in the same copier so they cannot drift apart in what they consider safe.
#
# THE RULE, from ADR-007: a path is copied only if it MATCHES and is ALSO gitignored. Verified on
# git 2.34 while building this: `git ls-files -o -i --exclude-from=F` uses ONLY F as its ignore
# source — the flags are not unioned with .gitignore — so matching and being-gitignored really are
# two questions, and the second needs its own `git check-ignore` pass. A tracked file listed in
# `.worktreeinclude` is therefore skipped, which is native's behaviour too.
#
# COPY-IF-MISSING, NEVER OVERWRITE. A worktree's own edited `.env` is the developer's, and this
# runs on EVERY entry rather than only at creation — which is the one thing native cannot do, and
# is what lets a worktree that lost a config file heal itself on the next session.

# Emit, NUL-separated, the paths `.worktreeinclude` selects: untracked files matching its patterns.
# The gitignored half of the rule is applied later, by the copier, in one batched call.
#
# Only for the WorktreeCreate path. Registering that hook disables native `.worktreeinclude`
# handling, so the plugin owes the behaviour there; on SessionStart native has already done it and
# repeating it could only ever disagree with what it did.
wt_worktreeinclude_paths() {  # $1 = main checkout
  local root=${1%/}
  [ -f "$root/.worktreeinclude" ] || return 0
  # -z because a path may contain a newline, and this feeds a NUL-delimited reader.
  wt_git "$root" ls-files -z -o -i --exclude-from="$root/.worktreeinclude" 2>/dev/null || true
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

  # ONE call for every candidate. check-ignore answers the "and is gitignored" half of ADR-007's
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
wt_copy_config() {  # $1 = main checkout, $2 = worktree, $3 = 1 to also honour .worktreeinclude
  local root=${1%/} worktree=${2%/} own_include=${3:-0} rec body

  {
    [ "$own_include" = 1 ] && wt_worktreeinclude_paths "$root"
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
        [ -n "$body" ] && printf '%s\0' "$body"
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
# ON FAILURE TO ACQUIRE, PROCEED UNLOCKED WITH A WARNING. That is ADR-003 applied to locking
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
  common=$(wt_git "$root" rev-parse --git-common-dir 2>/dev/null) || common=''
  if [ -n "$common" ]; then
    case $common in
      /*) ;;
      *) common=$root/$common ;;
    esac
    if [ -d "$common" ]; then
      printf '%s/worktree-locks/%s.lock' "${common%/}" "$slug"
      return 0
    fi
  fi
  printf '%s/.claude/worktree-locks/%s.lock' "$root" "$slug"
}

# Acquire the lock at $1 on file descriptor $3, waiting at most $2 seconds.
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
  wt_is_seconds "$secs" || secs=$WT_LOCK_WAIT

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
  if flock -w "$secs" "$fd" 2>/dev/null; then
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
# phase document says "inside the worktree — it dies with the worktree", and this satisfies that
# (git removes it with the worktree) while avoiding what a file in the checkout would cost: an
# untracked entry in every `git status`, in a repo whose .gitignore knows nothing about us, which
# a developer could commit by accident. A checkout that cannot report a private git dir falls
# back to the worktree's own .claude/.
#
# STATUS IS WRITTEN BEFORE THE WORK, NOT AFTER. An entry goes to `doing` before the install starts
# and only becomes `done` once the command AND its verify have succeeded. That is what separates
# "installed" from "killed halfway by the timeout", which a populated directory cannot tell you —
# and the phase's own acceptance list requires a hung install to leave a usable session.
#
# NO PARTIAL TRUST, the same rule the profile has: unreadable, wrong version, unparseable, or an
# entry left at `doing` all mean THE SAME THING — not done, do it again. Redoing safe work is
# cheap; skipping real work leaves a worktree that looks finished and is not.

# Bumped when the RECORD FORMAT changes, which is the only thing that can make an existing file
# unreadable. Deliberately not the plugin's own version: a new release does not invalidate a
# correct install, and reading plugin.json would cost the interpreter start this file exists to
# avoid — so every worktree on the machine would pay a full reinstall on the day of an upgrade.
WT_STATE_VERSION=1

wt_state_path() {  # $1 = worktree
  local wt=${1%/} gitdir
  gitdir=$(wt_git "$wt" rev-parse --git-dir 2>/dev/null) || gitdir=''
  if [ -n "$gitdir" ]; then
    case $gitdir in
      /*) ;;
      *) gitdir=$wt/$gitdir ;;
    esac
    if [ -d "$gitdir" ]; then
      printf '%s/worktree-bootstrap-state' "${gitdir%/}"
      return 0
    fi
  fi
  printf '%s/.claude/worktree-bootstrap-state' "$wt"
}

# Record the outcome for one dependency. Rewrites the whole file atomically: it holds a handful of
# entries, and a partial write is the one thing a reader must never see.
wt_state_set() {  # $1 = worktree, $2 = dir, $3 = strategy, $4 = lock cksum, $5 = install cksum, $6 = status
  local wt=${1%/} dir=${2-} strategy=${3-} lck=${4-} ick=${5-} status=${6-}
  local file tmp rec kind rdir rest kept='' hdrok=0

  file=$(wt_state_path "$wt")
  [ -n "$file" ] || return 1
  local parent=${file%/*}
  [ "$parent" = "$file" ] || [ -d "$parent" ] || mkdir -p "$parent" 2>/dev/null || return 1

  # Existing records are carried over ONLY if the file is one this format can read. Without the
  # header check, the first write after a WT_STATE_VERSION bump would copy every stale record
  # into a file freshly stamped with the NEW version — laundering exactly the records the reader
  # had correctly refused to trust, so a dependency never installed under the new format would
  # then read as done. Same rule as the profile: wrong version means ignore the file whole.
  if [ -r "$file" ]; then
    hdrok=0
    while IFS= read -r -d "$WT_RS" rec; do
      kind=${rec%%"$WT_US"*}
      rest=${rec#*"$WT_US"}
      case $kind in
        wtstate)
          [ "${rest%%"$WT_US"*}" = "$WT_STATE_VERSION" ] || { kept=''; break; }
          hdrok=1
          ;;
        dep)
          [ "$hdrok" = 1 ] || { kept=''; break; }   # records before any header: not our file
          rdir=${rest%%"$WT_US"*}
          [ "$rdir" = "$dir" ] && continue          # replaced below
          kept="$kept$rec$WT_RS"
          ;;
      esac
    done <"$file"
  fi

  tmp=$(mktemp "${parent}/.wtstate.XXXXXX" 2>/dev/null) || return 1
  {
    printf 'wtstate%s%s%s' "$WT_US" "$WT_STATE_VERSION" "$WT_RS"
    printf '%s' "$kept"
    printf 'dep%s%s%s%s%s%s%s%s%s%s%s' \
      "$WT_US" "$dir" "$WT_US" "$strategy" "$WT_US" "$lck" \
      "$WT_US" "$ick" "$WT_US" "$status" "$WT_RS"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  # Atomic: a reader sees the old file or the new one, never a half-written one.
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# True when this dependency is recorded as finished AND the evidence still matches.
#
# The lock checksum compared is the WORKTREE's own lockfile, not the main checkout's and not the
# profile's calibration-time value: they answer different questions, and a worktree on its own
# branch can legitimately differ from both. The install command is fingerprinted too, so editing
# it in the profile re-runs the dependency rather than trusting a tree built by the old one.
wt_state_is_done() {  # $1 = worktree, $2 = dir, $3 = lock cksum, $4 = install cksum, $5 = strategy
  local wt=${1%/} dir=${2-} lck=${3-} ick=${4-} want=${5-}
  local file rec kind rest ver rdir rstrategy rlck rick rstatus seen=0

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
        IFS=$WT_US read -r rdir rstrategy rlck rick rstatus <<<"$rest" || true
        [ "$rdir" = "$dir" ] || continue
        # Quoted: bare `done` is the loop keyword to the parser.
        [ "$rstatus" = "done" ] || return 1   # `doing` means killed mid-write: redo it
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
