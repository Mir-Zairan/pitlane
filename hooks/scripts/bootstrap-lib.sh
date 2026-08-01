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
# COPY-IF-MISSING, NEVER OVERWRITE. A worktree's own edited `.env` is the developer's.
#
# The self-healing this enables is real but NARROWER than it first looks, so state it precisely:
# it covers the profile's `copy[]` only. That list is re-applied on every entry, so a worktree
# that lost one of those files gets it back next session — something native cannot do, since
# `.worktreeinclude` is honoured at creation and never again. `.worktreeinclude` itself is
# re-applied only on the WorktreeCreate path, where native never ran; on SessionStart it is
# deliberately left alone, because redoing what native already did could only ever disagree
# with it.

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
  # See wt_state_path: the cache only helps once wt_prime_paths has filled it in the caller's
  # own shell, because this function is always called in a command substitution.
  if [ "${WT_LOCKDIR_FOR:-}" = "$root" ] && [ -n "${WT_LOCKDIR_IS:-}" ]; then
    printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
    return 0
  fi
  common=$(wt_git "$root" rev-parse --git-common-dir 2>/dev/null) || common=''
  if [ -n "$common" ]; then
    case $common in
      /*) ;;
      *) common=$root/$common ;;
    esac
    if [ -d "$common" ]; then
      WT_LOCKDIR_FOR=$root
      WT_LOCKDIR_IS="${common%/}/worktree-locks"
      printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
      return 0
    fi
  fi
  WT_LOCKDIR_FOR=$root
  WT_LOCKDIR_IS="$root/.claude/worktree-locks"
  printf '%s/%s.lock' "$WT_LOCKDIR_IS" "$slug"
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

# Bumped when the RECORD FORMAT changes in a way an older parser would MISREAD. Appending a field
# at the end is not such a change — a reader that names fewer variables simply ignores it — so the
# timestamp added later did not need a bump. Reordering or repurposing a field would. Deliberately not the plugin's own version: a new release does not invalidate a
# correct install, and reading plugin.json would cost the interpreter start this file exists to
# avoid — so every worktree on the machine would pay a full reinstall on the day of an upgrade.
WT_STATE_VERSION=1

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
  WT_STATE_PATH_IS="$wt/.claude/worktree-bootstrap-state"
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
wt_state_rewrite() {  # $1 = worktree, $2 = kind to replace, $3 = its first field or empty, $4 = the replacement record
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
    printf '%s%s' "$newrec" "$WT_RS"
  } >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Record the outcome for one dependency. Rewrites the whole file atomically: it holds a handful of
# entries, and a partial write is the one thing a reader must never see.
wt_state_set() {  # $1 = worktree, $2 = dir, $3 = strategy, $4 = lock cksum, $5 = install cksum, $6 = status
  local wt=${1%/} dir=${2-} strategy=${3-} lck=${4-} ick=${5-} status=${6-} when rec

  # Recorded but never compared: it answers "when did this last happen" for a developer looking at
  # a worktree that seems stale, and gives Phase 5 something to age entries by. It is deliberately
  # NOT part of the freshness decision — a timestamp cannot tell you whether a tree is correct, and
  # comparing one would make re-entry depend on the clock.
  when=$(date +%s 2>/dev/null) || when=0

  wt_state_join dep "$dir" "$strategy" "$lck" "$ick" "$status" "$when"
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

# ---------------------------------------------------------------------------
# Per-worktree RUNTIME state — layer 3's half of the same file
# ---------------------------------------------------------------------------
#
# ONE record, kind `rt`, in the SAME state file the dependency records live in. One file rather
# than two because it is one worktree's state, it dies with the worktree the same way, and Phase 5
# then has one place to look rather than two that can disagree about whether a worktree was ever
# set up. The two writers each recognise their own kind and carry every other kind through
# verbatim, so neither needs to understand the other's fields.
#
# Field order, after the kind:
#   1 slug         the FINAL slug, after runtime.slug was expanded and re-slugified. What the
#                  database is actually named after, not the template it came from.
#   2 port         the allocated port, or empty when none was derived
#   3 portsource   `derived` or `probed` — whether the port is the one the slug hashes to, or one
#                  found by stepping past a sibling's claim. Phase 5 wants to know which.
#   4 envfile      the override file's path relative to THE WORKTREE, resolving as
#                  <worktree>/<envfile> — stated exactly because the consumer of this field
#                  deletes it, and `wt_copy_paths` already uses "repo-relative" for paths resolved
#                  against the MAIN CHECKOUT. Recorded so teardown removes the file by name rather
#                  than by re-expanding a template that may have changed underneath it.
#   5 envstate     `ours` or `theirs` — whether this plugin wrote that file or a developer owns it.
#                  Recorded so the warning fires ONCE rather than on every session.
#   6 seedstatus   `none` | `done` | `failed` | `timeout` | `skipped`
#   7 seedcksum    cksum of the seed SCRIPT'S CONTENT at the last attempt, which is what lets an
#                  edited script retry automatically while an unedited failing one does not re-pay
#                  its timeout every session
#   8 when         epoch seconds, recorded and never compared (see wt_state_set)
#
# WHAT THIS RECORD CANNOT DO, stated rather than left for Phase 5 to discover. It is a single
# slot describing the CURRENT allocation, so it cannot describe a superseded one. `runtime.slug`
# and `runtime.env.file` are profile templates, and ADR-008 lets a worktree's own committed profile
# win — so editing either on a branch re-points a live worktree, and the previous slug's database
# becomes referenced by nothing: the only record of it was overwritten. Teardown would then not
# remove it and `/worktree-prune` would not find it.
#
# Deliberately NOT solved here. Reclaiming an orphaned database needs the inverse of a repo-owned
# seed script, which only the repo knows how to write, and unreferenced-state sweeping is
# explicitly Phase 5's `/worktree-prune`. It is recorded in the Phase 4 handoff so that phase
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
  local sstatus=${7-} scksum=${8-} when rec

  when=$(date +%s 2>/dev/null) || when=0

  # An empty key: `rt` is a single slot, so whichever record is there is the one replaced.
  wt_state_join rt "$slug" "$port" "$psrc" "$envfile" "$envstate" "$sstatus" "$scksum" "$when"
  wt_state_rewrite "$wt" rt '' "$WT_STATE_REC"
}

# Read one field of this worktree's `rt` record, by NAME. Prints nothing and returns 1 when there
# is no usable record.
#
# A named accessor rather than "go and parse the state file" is the contract Phase 5 consumes: its
# teardown must not re-derive a slug or re-expand an env path to find out what this phase created,
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

# Read back the recorded status for one dependency: `done`, `doing`, `dirty`, or empty when there
# is no usable record. Needed as well as wt_state_is_done because "we were interrupted" and "we
# have never run" call for different handling — only the first justifies deleting anything.
wt_state_status() {  # $1 = worktree, $2 = dir
  local wt=${1%/} dir=${2-} file rec kind rest ver rdir rstrategy rlck rick rstatus rwhen seen=0
  file=$(wt_state_path "$wt")
  [ -r "$file" ] || { printf ''; return 0; }
  while IFS= read -r -d "$WT_RS" rec; do
    kind=${rec%%"$WT_US"*}
    rest=${rec#*"$WT_US"}
    case $kind in
      wtstate)
        ver=${rest%%"$WT_US"*}
        [ "$ver" = "$WT_STATE_VERSION" ] || { printf ''; return 0; }
        seen=1
        ;;
      dep)
        [ "$seen" = 1 ] || { printf ''; return 0; }
        rdir=${rest%%"$WT_US"*}
        [ "$rdir" = "$dir" ] || continue
        # Read POSITIONALLY, not as "the last field": a trailing timestamp now follows the status,
        # and `${rest##*US}` would return that instead.
        # shellcheck disable=SC2034
        IFS=$WT_US read -r rdir rstrategy rlck rick rstatus rwhen <<<"$rest" || true
        printf '%s' "$rstatus"
        return 0
        ;;
    esac
  done <"$file"
  printf ''
  return 0
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
# THIS DISCHARGES THE OBLIGATION lib.sh's wt_expand states and assigns to this phase:
# "SUBSTITUTION IS NOT QUOTING ... a caller placing an unconstrained placeholder in command
# position must quote it itself." An install command is exactly that position. {slug} and {port}
# are safe by construction ([a-z0-9_] and digits); {name}, {worktree} and {root} are raw text, and
# {name} in particular comes from a DIFFERENT AND LESS TRUSTED PARTY than the profile does — the
# profile is committed and reviewed, while a worktree name can be chosen by whoever opens a PR or
# by a mid-session EnterWorktree call. A profile line as ordinary as `pnpm install --filter {name}`
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
# session that will not start is lost work (ADR-003). Nothing below returns non-zero to the
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
# Returns 0 on success, 1 to say "fall back to a real install". A hardlink copy of a 397 MB
# vendor/ is near-instant and costs almost no disk (ADR-004), but it is only VALID when the two
# checkouts want the same dependencies — which is what comparing the lockfiles establishes — and
# it is not always possible: a worktree on another filesystem cannot hardlink at all.
#   0 = linked, 1 = fall back to a real install, 2 = already present, nothing done.
wt_hardlink_dep() {  # $1 = root, $2 = worktree, $3 = dir, $4 = lock
  # No initialisers built from $1/$3 here: with fewer arguments than expected that is a fatal
  # unbound-variable error under `set -u`, which is precisely the crash this layer must not cause.
  local root=${1%/} worktree=${2%/} dir=${3-} lock=${4-} src dest

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

  # `cp -al` fails on a cross-filesystem copy and on filesystems without hardlinks. Both are
  # ordinary situations, not errors: fall back rather than dying (ADR-003). Any partial tree is
  # removed first, or the install that follows would run on top of debris.
  if cp -al "$src" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -rf "$dest" 2>/dev/null
  wt_log "  $dir: could not hardlink (a different filesystem, or one without hardlinks) — installing instead"
  return 1
}

# Bootstrap every entry in deps[]. $3 is the epoch second the whole bootstrap must be finished by.
wt_bootstrap_deps() {  # $1 = root, $2 = worktree, $3 = deadline
  local root=${1%/} worktree=${2%/} deadline=${3-}
  local rec body dir lock strategy install verify _cksum n=-1
  local lckhash ickhash status left rc lockpath held effective started elapsed bad

  [ -n "${PROFILE_RAW:-}" ] || return 0

  while IFS= read -r -d "$WT_RS" rec; do
    case $rec in
      1"$WT_US"*) ;;
      *) continue ;;
    esac
    n=$((n + 1))
    body=${rec#*"$WT_US"}
    IFS=$WT_US read -r dir lock strategy install verify _cksum <<<"$body" || true

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
        # A valid schema value that no phase has built (Phase 7). Treated as install, which is
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
    fi

    rc=0
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
      wt_log "  $dir: installing (${left}s of the budget left)"
      case ${PROFILE_SHELL:-} in
        nix*) wt_log "  $dir: evaluating the nix environment first, which can take a minute on a cold worktree" ;;
      esac
      started=$(date +%s 2>/dev/null) || started=''
      wt_run_in_shell "$install" "$worktree" "$left"
      rc=$?
      elapsed=''
      [ -n "$started" ] && elapsed=$(( $(date +%s) - started ))
      case $rc in
        0) wt_log "  $dir: installed${elapsed:+ in ${elapsed}s}" ;;
        124) wt_log "  $dir: the install ran past the ${left}s left in the budget and was stopped — the worktree may be incomplete" ;;
        *) wt_log "  $dir: the install command failed (exit $rc) — the worktree may be incomplete" ;;
      esac
    elif [ "$effective" = hardlink ]; then
      wt_log "  $dir: hardlinked from the main checkout"
    fi

    # The optional cheap sanity check. It decides `done` versus `dirty`, and `dirty` is what makes
    # the next entry try again rather than trust this one.
    if [ "$rc" -eq 0 ] && [ -n "$verify" ]; then
      left=$(wt_budget_left "$deadline")
      if [ "$left" -le 0 ]; then
        wt_log "  $dir: no budget left to verify — recording it as needing another look"
        rc=1
      else
        wt_run_in_shell "$verify" "$worktree" "$left"
        rc=$?
        [ "$rc" -eq 0 ] || wt_log "  $dir: the verify command failed (exit $rc) — it will be retried next session"
      fi
    fi

    if [ "$rc" -eq 0 ]; then
      wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" "done" || true
    else
      wt_state_set "$worktree" "$dir" "$strategy" "$lckhash" "$ickhash" dirty || true
    fi

    [ "$held" -eq 1 ] && wt_lock_release 9
  done < <(printf '%s' "$PROFILE_RAW")
  return 0
}

# ---------------------------------------------------------------------------
# Drift: has the checkout moved away from what the profile was calibrated on?
# ---------------------------------------------------------------------------
#
# Phase 2 shipped the `evidence` block and a comparator for its checksums but deliberately no call
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
# a hook at all (ADR-002 forbids a hook doing discovery), and it WARNS WITHOUT EVER BLOCKING
# (ADR-003). Its honest limits are recorded in reference/detection.md: a lockfile can churn with
# nothing meaningful changing, and — worse — a hazard can appear in composer.json's `scripts`
# without touching any lockfile, so the case where a warning matters most produces none.
#
# The detection table is READ, not copied into this file. reference/detection.json is ground truth
# and Phase 2's rule is that adding an ecosystem is one entry there and nothing else; a duplicated
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

wt_report_drift() {  # $1 = checkout, $2 = detectionVersion, $3 = markers, $4 = shellMarker, $5 = profile path (only needed when no profile is loaded)
  local tree=${1%/} evdet=${2-} evmark=${3-} evshell=${4-} profile=${5-}
  local table=${WT_DETECTION_JSON:-$WT_DETECTION_JSON_DEFAULT}
  local raw rec body curdet m rdir gained='' lost='' curshell='' seen='' problems
  local lock cksum now n=0

  # THE LOCKFILE CHECKSUMS FIRST, and OUTSIDE every guard below. They live in deps[], not in
  # `evidence`, and they need neither the evidence block nor the detection table — so gating them
  # on either meant a profile carrying checksums but no evidence (a hand-written one, or any
  # install where the table cannot be found) silently got no drift warning at all, leaving the one
  # comparator Phase 2 actually shipped unwired for exactly those profiles.
  #
  # TWO ROUTES TO ONE ANSWER, and the reason is measured rather than stylistic. With a profile
  # loaded, the checksums are already in PROFILE_RAW, so comparing them here costs nothing —
  # calling lib.sh's wt_profile_drifted would re-read the file and spend an interpreter start on
  # the very path this phase cut from four to one. Without one (a caller checking a profile it is
  # not about to use), that function is the only way to get them, and it is delegated to rather
  # than reimplemented. tests/test_bootstrap_lib.sh asserts the two agree on the same profile,
  # because two routes to one answer is exactly the shape that drifts apart.
  if [ -z "${PROFILE_RAW:-}" ] && [ -n "$profile" ]; then
    problems=$(wt_profile_drifted "$profile" "$tree") || {
      wt_log "$problems"
      wt_log "run /worktree-calibrate if the dependency set really changed"
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
      if [ ! -f "$tree/$lock" ]; then
        wt_log "$lock no longer exists, but the profile was calibrated against it — run /worktree-calibrate"
        continue
      fi
      now=$(cksum <"$tree/$lock" 2>/dev/null) || continue
      if [ "$now" != "$cksum" ]; then
        wt_log "$lock has changed since calibration — the recorded install command may be for a different dependency set; run /worktree-calibrate if so"
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
    wt_log "the profile was calibrated before this checkout had:$gained — run /worktree-calibrate so those are set up too"
  fi
  if [ -n "$lost" ]; then
    wt_log "the profile expects these, which this checkout no longer has:$lost — run /worktree-calibrate"
  fi
  if [ "$evshell" != "$curshell" ]; then
    wt_log "the toolchain marker changed since calibration (${evshell:-none} -> ${curshell:-none}) — installs may be running on the wrong toolchain; run /worktree-calibrate"
  fi
  if [ -n "$evdet" ] && [ -n "$curdet" ] && [ "$evdet" != "$curdet" ]; then
    wt_log "this plugin's detection table is now version $curdet, the profile was written against $evdet — /worktree-calibrate may propose better answers"
  fi
  return 0
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
  common=$(wt_git "$root" rev-parse --git-common-dir 2>/dev/null) || return 0
  [ -n "$common" ] || return 0
  case $common in
    /*) ;;
    *) common=$root/$common ;;
  esac
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
    [ "$wtpath" = "$mine" ] && continue              # ourselves
    # The orphan check: the admin directory outlives an `rm -rf` of the checkout.
    [ -n "$wtpath" ] && [ -d "$wtpath" ] || continue
    [ -r "$admin/worktree-bootstrap-state" ] || continue
    slug=$(wt_runtime_state_read "$admin/worktree-bootstrap-state" slug) || continue
    port=$(wt_runtime_state_read "$admin/worktree-bootstrap-state" port) || continue
    [ -n "$port" ] || continue
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
        # A sibling on the SAME slug is not a collision — it is this worktree seen through a stale
        # record, and stepping around it would move a port that is rightfully ours.
        [ "$sport" = "$cand" ] && [ "$sslug" != "$slug" ] && { skip=1; break; }
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
# exactly the repo-specific judgement ADR-006 forbids inferring and which calibration never
# gathered. A repo that needs another format already has the escape hatch: `runtime.seed` receives
# WT_ENV_FILE and every derived value, and can translate.
#
# VALUES ARE NOT QUOTED. dotenv dialects disagree about quoting — some strip quotes, some keep them
# literally — so the profile author's own text is written verbatim and the author owns it, the same
# trust boundary `deps[].install` already has. What is NOT left to the author is the KEY: it is
# shape-checked, because a key of `A=1` writes a line setting a variable the profile never names,
# and no care on the value side can defend against damage done before the `=`.

# The first line of every file this writes. Its presence is the whole ownership protocol.
WT_ENV_MARKER='# managed by the worktree plugin — delete this line to take ownership of this file'

# Who owns the override file at $1/$2: `absent`, `ours`, or `theirs`.
#
# THE MARKER IS MATCHED AS A PREFIX so a later version can append to that line — a version stamp,
# say — without every previously written file suddenly reading as developer-owned and freezing
# itself. An existing file with no first line at all counts as `theirs`: it is not one we wrote, and
# the rule for anything we did not write is the same.
#
# Read with a plain `read` and no subprocess: this runs on the session-start path, and the answer is
# one line of one small file.
wt_runtime_env_state() {  # $1 = worktree, $2 = relative path
  local worktree=${1%/} rel=${2-} f line
  f=$worktree/$rel
  # A dangling symlink is not `absent` — something is there, and it is not ours.
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    printf 'absent'
    return 0
  fi
  if [ -L "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf 'theirs'
    return 0
  fi
  line=''
  IFS= read -r line <"$f" 2>/dev/null || line=''
  case $line in
    "$WT_ENV_MARKER"*) printf 'ours' ;;
    *) printf 'theirs' ;;
  esac
  return 0
}

# Write the override file. Sets WT_ENV_WROTE to `written`, `developer`, or `skipped`.
#
# NEVER OVERWRITES A FILE THIS PLUGIN DID NOT WRITE. Editing that file is the SUPPORTED way to point
# a worktree somewhere else — a shared database, a colleague's, a restored snapshot — so a
# developer-managed file is left exactly as it is. The caller records that in the state file so the
# warning is said once rather than on every session, which is the difference between a useful
# notice and one people learn to scroll past.
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
wt_runtime_env_write() {  # $1 = worktree, $2 = rel path, $3 = port var, $4 = port, $5 = pairs stream
  local worktree=${1%/} rel=${2-} pvar=${3-} port=${4-} pairs=${5-}
  local dest tmp parent state rec body key val out n=0 irc

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
  if [ "$state" = theirs ]; then
    # SILENT HERE, deliberately. The caller says this once, from the state record — saying it from
    # inside a function that runs every session is how a useful notice becomes noise people scroll
    # past, and this is the escape hatch the design most wants a developer to keep trusting.
    # shellcheck disable=SC2034
    WT_ENV_WROTE=developer
    return 0
  fi

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

  # THE CONTENT IS BUILT FIRST, IN MEMORY, AND WRITTEN BY ONE COMMAND. The obvious shape —
  # `{ printf; printf; while ...; } >"$tmp" || cleanup` — cannot detect a failed write: a brace
  # group reports the status of its LAST command, which here is the loop, so a printf that failed
  # on a full disk was invisible and the truncated file was promoted into place anyway. Worse, if
  # the line lost was the MARKER, every later session reads the file as developer-owned and never
  # touches it again. Building the text first makes the write one checkable command, and shrinks
  # the window in which a killed hook can leave a temp file behind to almost nothing.
  out=$WT_ENV_MARKER$WT_NL
  out=$out"# Regenerated on every session while the line above is present. worktree=${WT_NAME-} slug=${WT_SLUG-}$WT_NL"

  # THE PORT VARIABLE IS SHAPE-CHECKED LIKE ANY OTHER KEY, and it was not at first. It becomes the
  # left-hand side of a `KEY=value` line exactly as an env.vars key does, and it is only WARNED
  # about by validation (which WT_SKIP_VALIDATION removes entirely), so a committed profile naming
  # `"var": "A=1"` would emit `A=1=3812` — setting a variable the profile never names, which is
  # precisely the damage checking the other keys exists to prevent.
  if [ -n "$pvar" ] && [ -n "$port" ]; then
    if wt_is_safe_envkey "$pvar"; then
      out=$out"$pvar=$port$WT_NL"
    else
      wt_log "  runtime: skipping the port line — \"$pvar\" is not a legal environment variable name"
      pvar=''
    fi
  else
    pvar=''
  fi

  while IFS= read -r -d "$WT_RS" rec; do
    # Group 3 of the profile scan is runtime.env.vars.
    case $rec in
      3"$WT_US"*) ;;
      *) continue ;;
    esac
    body=${rec#*"$WT_US"}
    key=${body%%"$WT_US"*}
    val=${body#*"$WT_US"}
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
    val=$(wt_expand "$val")
    val=${val//"$WT_CR"/ }
    val=${val//"$WT_NL"/ }
    out=$out"$key=$val$WT_NL"
    n=$((n + 1))
  done < <(printf '%s' "$pairs")

  # Atomic, and in the same directory so `mv` is a rename rather than a copy. A half-written
  # override file is worse than none: the app reads it and points at half a configuration.
  tmp=$(mktemp "${parent}/.wtenv.XXXXXX" 2>/dev/null) || {
    wt_log "  runtime: could not create a temporary file beside $rel — not writing it"
    return 0
  }
  # 0600 before anything is in it. These files hold the names of databases and, in a repo that puts
  # one there, a connection string.
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s' "$out" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    wt_log "  runtime: could not write $rel"
    return 0
  fi

  if mv -f "$tmp" "$dest" 2>/dev/null; then
    # shellcheck disable=SC2034
    WT_ENV_WROTE=written
    wt_log "  runtime: wrote $rel${pvar:+ ($pvar=$port)}, $n variable(s)"
  else
    rm -f "$tmp"
    wt_log "  runtime: could not put $rel in place"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The hand-off to Phase 4
# ---------------------------------------------------------------------------
#
# An in-process call at the point runtime isolation has to happen: inside the SAME SessionStart
# invocation, before the hook returns, because env overrides must exist before the session starts.
# There is no cross-process boundary here to justify serialising the hand-off through a file — the
# artifact pattern belongs to teardown (Phase 5), which is a genuinely separate event.
#
# SILENT when the profile has no runtime block, because absent means TOUCH NOTHING (ADR-006) and a
# plugin that comments on every session start is one people uninstall. Phase 4 replaces the body.
wt_runtime_handoff() {  # $1 = root, $2 = worktree
  [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] || return 0
  wt_log "runtime isolation (ports, env overrides, seed) is not implemented yet — Phase 4 owns it; this worktree shares the app's ports and databases"
  return 0
}
