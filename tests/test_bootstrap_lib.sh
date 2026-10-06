#!/usr/bin/env bash
#
# Exercises hooks/scripts/bootstrap-lib.sh — the bootstrap engine.
#
# Unlike tests/test_lib.sh this suite is NOT run once per JSON backend: the engine mostly reads the
# PROFILE_* variables lib.sh already produced, so the cross-backend parity guard belongs to that
# suite and repeating it here would only double the runtime. The few engine readers of the detection
# table match on its rendering, and those assertions loop over the backends themselves.
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)
LIB=$HERE/lib.sh
BLIB=$HERE/bootstrap-lib.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../hooks/scripts/lib.sh
# shellcheck disable=SC1091
. "$LIB"
# shellcheck source=../hooks/scripts/bootstrap-lib.sh
# shellcheck disable=SC1091
. "$BLIB"

# shellcheck source=serve_helpers.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/serve_helpers.sh"

pass=0 fail=0
US_=$WT_US
RS_=$WT_RS
NL_=$WT_NL
CR_=$WT_CR
# SC2034: PROFILE_RAW, PROFILE_SHELL and PROFILE_SHELLARGS are read by the SOURCED
# engine, never by this file, so shellcheck cannot see the use.
# shellcheck disable=SC2034
PROFILE_RAW=''

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      expected: %q\n      actual:   %q\n' "$1" "$2" "$3" >&2
  fi
}

ne() {  # $1 = label, $2, $3 = values that must differ
  if [ "$2" != "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      both were: %q\n' "$1" "$2" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL %s\n      expected to contain: %q\n      actual: %q\n' "$1" "$2" "$3" >&2 ;;
  esac
}

# A derived port must land in [base, base+span). Asserted as a RANGE rather than against a literal:
# pinning the number would pin `cksum`'s output on this machine while saying nothing about whether
# the derivation is still correct.
noflock_port=''; c=''; cp=''; kv=''; bad=''; before=''
in_range_b() {  # $1 = label, $2 = base, $3 = span, $4 = actual
  if [ -n "$4" ] && [ "$4" -ge "$2" ] && [ "$4" -lt $(($2 + $3)) ] 2>/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      %q is not in [%s, %s)\n' "$1" "$4" "$2" $(($2 + $3)) >&2
  fi
}

lacks() {  # $1 = label, $2 = needle that must NOT appear, $3 = haystack
  case $3 in
    *"$2"*) fail=$((fail + 1))
            printf 'FAIL %s\n      must not contain: %q\n      actual: %q\n' "$1" "$2" "$3" >&2 ;;
    *) pass=$((pass + 1)) ;;
  esac
}

# The constructed argv, rendered one element per line so an element containing a space is
# distinguishable from two elements — which is the entire bug class this function exists to avoid.
argv_of() {  # $1 = command; uses the ambient PROFILE_SHELL / PROFILE_SHELLARGS
  wt_build_shell_argv "$1"
  printf '%s\n' "${WT_CMD_ARGV[@]}"
}

# ---------------------------------------------------------------------------
# wt_build_shell_argv
# ---------------------------------------------------------------------------

PROFILE_SHELL='' PROFILE_SHELLARGS=''
eq 'no shell wrapper runs the command on the host login shell' \
  'bash
-lc
composer install' "$(argv_of 'composer install')"

PROFILE_SHELL='nix develop --command' PROFILE_SHELLARGS='argv'
eq 'argv mode appends the command as separate arguments, via bash -lc' \
  'nix
develop
--command
bash
-lc
composer install' "$(argv_of 'composer install')"

PROFILE_SHELL='nix-shell --run' PROFILE_SHELLARGS='string'
eq 'string mode passes ONE argument and does not interpose bash -lc' \
  'nix-shell
--run
composer install' "$(argv_of 'composer install')"

# The profile's field is authoritative. These two are the cases the old string-matching approach
# could not get right, because the wrapper is not on any list.
PROFILE_SHELL='docker compose run --rm app' PROFILE_SHELLARGS='argv'
eq 'a hand-written wrapper is honoured as argv when the profile says so' \
  'docker
compose
run
--rm
app
bash
-lc
pnpm i' "$(argv_of 'pnpm i')"

PROFILE_SHELL='./dev' PROFILE_SHELLARGS='string'
eq "a repo's own script is honoured as string when the profile says so" \
  './dev
pnpm i' "$(argv_of 'pnpm i')"

# The fallback, used ONLY when the profile omits shellArgs.
PROFILE_SHELL='nix-shell --run' PROFILE_SHELLARGS=''
eq 'with no shellArgs, a --run wrapper falls back to string' \
  'nix-shell
--run
composer install' "$(argv_of 'composer install')"

PROFILE_SHELL='sh -c' PROFILE_SHELLARGS=''
eq 'with no shellArgs, a -c wrapper falls back to string' \
  'sh
-c
composer install' "$(argv_of 'composer install')"

PROFILE_SHELL='direnv exec .' PROFILE_SHELLARGS=''
eq 'with no shellArgs, everything else falls back to argv' \
  'direnv
exec
.
bash
-lc
composer install' "$(argv_of 'composer install')"

# The profile must be able to OVERRIDE the fallback, or the field would be decorative.
PROFILE_SHELL='nix-shell --run' PROFILE_SHELLARGS='argv'
eq 'an explicit shellArgs beats what the string-match would have guessed' \
  'nix-shell
--run
bash
-lc
composer install' "$(argv_of 'composer install')"

# The command is ONE argument however many spaces, quotes or metacharacters it has. If it were
# re-split, these would arrive as several arguments and the count would change.
PROFILE_SHELL='nix develop --command' PROFILE_SHELLARGS='argv'
wt_build_shell_argv 'composer install --no-scripts && echo "done | now"'
eq 'a command with spaces, quotes and metacharacters stays exactly one argument' 6 \
  "${#WT_CMD_ARGV[@]}"
eq 'and its text is untouched' 'composer install --no-scripts && echo "done | now"' \
  "${WT_CMD_ARGV[5]}"

# A `shell` containing a glob must not expand against the working directory. The profile is
# committed and arrives with anyone's branch, so a prefix of `foo *` would otherwise turn into
# every filename in the worktree.
( cd "$TMP" && touch aaa.txt bbb.txt
  PROFILE_SHELL='wrap *' PROFILE_SHELLARGS='argv'
  wt_build_shell_argv 'x'
  printf '%s' "${#WT_CMD_ARGV[@]}" ) >"$TMP/globcount"
eq 'a glob in the shell prefix is not expanded against the worktree' 5 "$(cat "$TMP/globcount")"

# ...and the shell option state is left as it was found, or a later glob in the entrypoint breaks.
case $- in *f*) globbing_was=off ;; *) globbing_was=on ;; esac
PROFILE_SHELL='nix develop --command' PROFILE_SHELLARGS='argv'
wt_build_shell_argv 'x'
case $- in *f*) globbing_now=off ;; *) globbing_now=on ;; esac
eq 'building an argv does not leave globbing disabled' "$globbing_was" "$globbing_now"

# A `shell` that is non-empty but all whitespace splits to zero words, leaving WT_CMD_ARGV empty.
#
# HONEST LIMIT OF THIS ASSERTION. The failure being guarded against is that expanding an empty
# array under `set -u` is a fatal unbound-variable error on bash < 4.4 — including bash 3.2, this
# repo's stated floor and the stock macOS shell — which in the hook's own shell would kill the
# entrypoint before it printed the worktree path. That fatality CANNOT be reproduced on a modern
# bash, where the same expansion is simply empty, so a test asserting "it does not crash" passes
# with or without the guard and catches nothing (confirmed by mutation: removing the guard left
# this suite green). What IS observable on every bash is the guard's other half — it says so and
# falls back to the host shell — so that is what is pinned here, and it fails if the guard goes.
PROFILE_SHELL='   ' PROFILE_SHELLARGS='argv'
err=$(wt_build_shell_argv 'x' 2>&1 >/dev/null)
contains 'a whitespace-only shell prefix is reported, not silently treated as a wrapper' \
  'contains no command' "$err"
eq '...and falls back to running on the host shell' \
  'bash
-lc
x' "$(argv_of 'x' 2>/dev/null)"

# ---------------------------------------------------------------------------
# wt_nix_shell_missing
# ---------------------------------------------------------------------------

mkdir -p "$TMP/noflake" "$TMP/withflake" "$TMP/withshellnix" "$TMP/withdefaultnix"
touch "$TMP/withflake/flake.nix" "$TMP/withshellnix/shell.nix" "$TMP/withdefaultnix/default.nix"

PROFILE_SHELL='nix develop --command'
wt_nix_shell_missing "$TMP/noflake"; eq 'nix develop with no flake.nix is reported missing' 0 $?
wt_nix_shell_missing "$TMP/withflake"; eq 'nix develop with a flake.nix is not' 1 $?
PROFILE_SHELL='nix-shell --run'
wt_nix_shell_missing "$TMP/noflake"; eq 'nix-shell with no shell.nix is reported missing' 0 $?
wt_nix_shell_missing "$TMP/withshellnix"; eq 'nix-shell with a shell.nix is not' 1 $?
# A legacy default.nix repo must not be pushed onto the host shell with a scary warning.
wt_nix_shell_missing "$TMP/withdefaultnix"; eq 'nix-shell with a default.nix is not either' 1 $?
PROFILE_SHELL='direnv exec .'
wt_nix_shell_missing "$TMP/noflake"; eq 'a non-nix wrapper is never reported missing' 1 $?

# ---------------------------------------------------------------------------
# wt_run_in_shell
# ---------------------------------------------------------------------------

PROFILE_SHELL='' PROFILE_SHELLARGS=''
mkdir -p "$TMP/run" "$TMP/home"

# `bash -lc` is a LOGIN shell, so it reads /etc/profile and the developer's ~/.bash_profile or
# ~/.profile. A dotfile that prints a banner (nvm, direnv) or cd's would break the assertions
# below for reasons that have nothing to do with this code. Point HOME at an empty directory so
# the suite measures the engine and not the machine it runs on.
HOME=$TMP/home
export HOME

# The command's stdout is redirected to STDERR by the engine, because the hook's stdout is a
# protocol channel. So every assertion here captures stderr; a value arriving on stdout instead
# would mean the protocol guarantee had been lost.
out=$(wt_run_in_shell 'printf ran' "$TMP/run" 10 2>&1 >/dev/null)
eq 'a command actually runs, and its output goes to stderr' 'ran' "$out"
eq 'nothing the command prints reaches stdout, which is the protocol channel' '' \
  "$(wt_run_in_shell 'printf leaked' "$TMP/run" 10 2>/dev/null)"

out=$(wt_run_in_shell 'pwd -P' "$TMP/run" 10 2>&1 >/dev/null)
eq 'it runs with the given directory as its working directory' "$(cd "$TMP/run" && pwd -P)" "$out"

wt_run_in_shell 'exit 3' "$TMP/run" 10 >/dev/null 2>&1
eq "it returns the command's own exit status" 3 $?

wt_run_in_shell 'true' "$TMP/nosuchdir" 10 >/dev/null 2>&1
eq 'a missing directory is a returned failure, not a crash' 1 $?

# The `cd` must not leak: the entrypoint prints a worktree path and runs later steps relative to
# where it started.
before=$PWD
wt_run_in_shell 'true' "$TMP/run" 10 >/dev/null 2>&1
eq 'the working directory of the caller is unchanged afterwards' "$before" "$PWD"

if command -v timeout >/dev/null 2>&1; then
  wt_run_in_shell 'sleep 5' "$TMP/run" 1 >/dev/null 2>&1
  eq 'a command that outruns its timeout is killed and reports 124' 124 $?
  # 124 has to be DISTINGUISHABLE from an ordinary failure, because a killed install leaves a
  # half-written directory and a failed one usually does not.
  wt_run_in_shell 'exit 124' "$TMP/run" 10 >/dev/null 2>&1
  eq '...and an ordinary command may still exit 124 itself' 124 $?
else
  printf 'WARNING: coreutils timeout absent — timeout behaviour NOT verified\n' >&2
fi

# A command is handed to exactly ONE shell. If it were evaluated twice, the inner substitution
# would run again and the file would hold two lines.
: >"$TMP/run/evalcount"
# SC2016: the single quotes are the point — $PWD must be expanded by the shell the command is
# handed to, not by this one. Expanding it here would test nothing.
# shellcheck disable=SC2016
wt_run_in_shell 'printf "x\n" >> "$PWD/evalcount"' "$TMP/run" 10 >/dev/null 2>&1
eq 'the command reaches exactly one shell, so it is evaluated once' 1 \
  "$(wc -l <"$TMP/run/evalcount" | tr -d ' ')"

# A filename with a space survives, which it would not if the command were re-split.
wt_run_in_shell 'touch "a b.txt"' "$TMP/run" 10 >/dev/null 2>&1
eq 'a command creating a path with a space creates ONE file' 1 \
  "$(find "$TMP/run" -maxdepth 1 -name 'a b.txt' | wc -l | tr -d ' ')"

# The nix fallback: warn on stderr and run anyway, rather than failing on a branch that genuinely
# has no flake.
PROFILE_SHELL='nix develop --command' PROFILE_SHELLARGS='argv'
err=$(wt_run_in_shell 'printf ok' "$TMP/noflake" 10 2>&1 >/dev/null)
contains 'a nix wrapper with no flake warns' 'no flake.nix/shell.nix' "$err"
out=$(wt_run_in_shell 'printf ok' "$TMP/noflake" 10 2>&1 >/dev/null)
contains '...and still runs the command on the host' 'ok' "$out"
# SC2034: these are read by the SOURCED library, not by this file — restoring them to the default
# matters because the assertions below must not inherit the nix wrapper set just above.
# shellcheck disable=SC2034
PROFILE_SHELL='' PROFILE_SHELLARGS=''

# An invalid timeout must not become `timeout 0`, which to timeout(1) means NO timeout at all —
# the one guard against a hanging bootstrap turning into a hung session.
#
# The obvious assertion here cannot fail: with the guard the default applies and `sleep 5`
# completes; WITHOUT it the call becomes `timeout 0 sleep 5`, which also completes and also
# returns 0. Shrinking the default to 1s makes the two outcomes different — 124 means the guard
# substituted the default, 0 means the bad value went straight through.
if command -v timeout >/dev/null 2>&1; then
  for bad in 0 000 abc -1 ''; do
    rc=$(WT_DEFAULT_TIMEOUT=1 wt_run_in_shell 'sleep 5' "$TMP/run" "$bad" >/dev/null 2>&1; echo $?)
    eq "an invalid timeout of \"$bad\" is replaced by the default, not treated as unlimited" 124 "$rc"
  done
  rc=$(WT_DEFAULT_TIMEOUT=1 wt_run_in_shell 'sleep 5' "$TMP/run" 30 >/dev/null 2>&1; echo $?)
  eq 'a valid timeout is used as given, not overridden by the default' 0 "$rc"
fi

# The empty-command no-op.
wt_run_in_shell '' "$TMP/run" 10 >/dev/null 2>&1
eq 'an empty command is a no-op success' 0 $?

# A real wrapper, actually executed rather than only constructed. `env` is a harmless stand-in
# for nix/docker: it takes argv exactly the way `nix develop --command` does.
PROFILE_SHELL='env WT_WRAPPED=1' PROFILE_SHELLARGS='argv'
# SC2016: single quotes deliberate -- $WT_WRAPPED must be expanded by the wrapped shell.
# shellcheck disable=SC2016
out=$(wt_run_in_shell 'printf "%s" "$WT_WRAPPED"' "$TMP/run" 10 2>&1 >/dev/null)
eq 'an argv wrapper really does wrap the command' '1' "$out"
# `sh -c` is the shape string mode exists for: it takes the command as ONE argument and runs it
# with a shell itself, which is why the engine must not interpose another `bash -lc`.
PROFILE_SHELL='sh -c' PROFILE_SHELLARGS='string'
out=$(wt_run_in_shell 'printf wrapped' "$TMP/run" 10 2>&1 >/dev/null)
eq 'a string wrapper receives the command as one argument and runs it' 'wrapped' "$out"
out=$(wt_run_in_shell 'printf "a b"; printf c' "$TMP/run" 10 2>&1 >/dev/null)
eq '...and the whole command reaches it, metacharacters and all' 'a bc' "$out"
# shellcheck disable=SC2034
PROFILE_SHELL='' PROFILE_SHELLARGS=''

# No coreutils timeout: run unbounded rather than not at all, and say so.
mkdir -p "$TMP/nobin"
ln -sf "$(command -v bash)" "$TMP/nobin/bash" 2>/dev/null
ln -sf "$(command -v printf)" "$TMP/nobin/printf" 2>/dev/null
err=$(PATH=$TMP/nobin wt_run_in_shell 'printf ok' "$TMP/run" 10 2>&1 >/dev/null)
contains 'with no timeout binary it says so' 'without a time limit' "$err"
contains '...and still runs the command' 'ok' "$err"

# ---------------------------------------------------------------------------
# The resource guard
# ---------------------------------------------------------------------------
# Driven through a fake /proc/meminfo and a fake systemd-run that records its argv and then runs
# the command it wraps, so every assertion is about THIS code, not the host's memory.
PROFILE_SHELL='' PROFILE_SHELLARGS=''
meminfo() {  # $1 = total kB, $2 = available kB
  printf 'MemTotal:       %s kB\nMemFree:        1 kB\nMemAvailable:   %s kB\n' "$1" "$2" > "$TMP/meminfo"
}
cat > "$TMP/fake-systemd-run" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/scope.log"
shift 4
while [ "\${1-}" = -p ]; do shift 2; done
exec "\$@"
SH
chmod +x "$TMP/fake-systemd-run"
guarded() {  # run one command under the guard with a fresh probe; stderr to $TMP/gerr
  : > "$TMP/scope.log"; rm -f "$TMP/run/ran"
  # shellcheck disable=SC2034  # read by the sourced guard
( WT_GUARD_SCOPE=''; WT_MEMINFO=$TMP/meminfo; export WT_MEMINFO
    wt_run_in_shell 'touch ran' "$TMP/run" 10 ) >/dev/null 2>"$TMP/gerr"
}
GiB=$((1024 * 1024))

meminfo $((16 * GiB)) $((8 * GiB))
WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
eq 'with memory to spare the step runs' yes "$([ -e "$TMP/run/ran" ] && echo yes)"
contains '...inside a capped scope: free memory minus the desktop reserve' 'MemoryMax=7168M' "$(cat "$TMP/scope.log")"
contains '...with no swap to thrash' 'MemorySwapMax=0' "$(cat "$TMP/scope.log")"
contains '...and at low priority' 'nice -n 10' "$(cat "$TMP/scope.log")"

meminfo $((16 * GiB)) $((15 * GiB))
WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
contains 'the cap is never more than half the RAM, however much is free' 'MemoryMax=8192M' "$(cat "$TMP/scope.log")"

meminfo $((16 * GiB)) $((3 * GiB / 2))
WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded; rc=$?
eq 'with too little free memory the step is refused' "$WT_GUARD_REFUSED" "$rc"
eq '...and never started' no "$([ -e "$TMP/run/ran" ] && echo yes || echo no)"
contains '...saying why and what to do' 'MiB of memory is free' "$(cat "$TMP/gerr")"
contains '...pointing at /pitlane-finish' '/pitlane-finish' "$(cat "$TMP/gerr")"
WT_GUARD_REFUSE=0 WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
eq 'a caller that must not be refused (teardown) still runs, at the minimum cap' yes \
  "$([ -e "$TMP/run/ran" ] && echo yes)"
contains '...which is 1 GiB' 'MemoryMax=1024M' "$(cat "$TMP/scope.log")"
PITLANE_MEMORY_MAX=off WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
eq 'PITLANE_MEMORY_MAX=off switches the refusal off' yes "$([ -e "$TMP/run/ran" ] && echo yes)"
eq '...and the cap' '' "$(cat "$TMP/scope.log")"
WT_GUARD=off WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
eq 'WT_GUARD=off (the cheap verify) is never refused or capped' yes "$([ -e "$TMP/run/ran" ] && echo yes)"

meminfo $((16 * GiB)) $((8 * GiB))
PITLANE_MEMORY_MAX=3G WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
contains 'PITLANE_MEMORY_MAX sets the cap explicitly' 'MemoryMax=3G' "$(cat "$TMP/scope.log")"
WT_SYSTEMD_RUN='' guarded
eq 'a host that cannot make a scope still runs the step' yes "$([ -e "$TMP/run/ran" ] && echo yes)"
rm -f "$TMP/meminfo"
WT_SYSTEMD_RUN=$TMP/fake-systemd-run guarded
eq 'a host with no /proc/meminfo (macOS) runs the step uncapped' yes "$([ -e "$TMP/run/ran" ] && echo yes)"
eq '...without a scope' '' "$(cat "$TMP/scope.log")"

# THE REAL THING, where this host can make a capped scope: a step that outgrows its cap is the one
# killed, and says so — not the session around it.
WT_GUARD_SCOPE=''
if (unset WT_SYSTEMD_RUN; wt_guard_can_scope) && command -v python3 >/dev/null 2>&1; then
  # SC2034: both are read by the sourced engine inside the subshell.
  # shellcheck disable=SC2034
  rc=$( (WT_GUARD_SCOPE=''; PITLANE_MEMORY_MAX=96M
         wt_run_in_shell 'python3 -c "b = bytearray(512 * 1024 * 1024)"' "$TMP/run" 60) >/dev/null 2>"$TMP/gerr"; echo $?)
  eq 'a step that outgrows a real cap is killed (137)' 137 "$rc"
  contains '...and the message says it was the cap, not a crash' 'memory cap' "$(cat "$TMP/gerr")"
else
  printf 'WARNING: no user systemd scope on this host — the real memory cap was NOT exercised\n' >&2
fi
# shellcheck disable=SC2034  # reset the engine's cached probe for the tests after this block
WT_GUARD_SCOPE=''

# ---------------------------------------------------------------------------
# Config copying
# ---------------------------------------------------------------------------
# These need a REAL git repository: the whole point is that the gitignore semantics are git's
# rather than a matcher of ours, so a fake would test the fake.

# The ignore semantics under test must come from the FIXTURE only. A developer's global
# core.excludesFile, or a system /etc/gitconfig, would otherwise inject ignore rules into this
# scratch repo and make the suite machine-dependent.
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
# These suites assert what a start-up run DID, so it does all of it in the hook; the background
# hand-off has its own tests, which turn it back on.
PITLANE_BACKGROUND=off
export PITLANE_BACKGROUND
unset XDG_CONFIG_HOME

REPO=$TMP/cfgrepo
WT=$TMP/cfgwt
mkdir -p "$REPO" "$WT"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t

printf '%s\n' '.env' 'secrets/' 'nested/deep/' '*.local' '*.hidden' > "$REPO/.gitignore"
printf '%s\n' '# a comment line, which git ignores' '' '.env' 'secrets/**' 'nested/deep/**' \
  'tracked.txt' 'config.local' 'key.pem' 'mode.local' '*.local' '!excluded.local' \
  > "$REPO/.worktreeinclude"
# Matched by the '*.local' glob and then UN-matched by the '!excluded.local' negation that follows
# it. Getting negation right is exactly why the matching is delegated to git rather than written
# here, so it needs an assertion.
printf 'NEGATED\n' > "$REPO/excluded.local"
printf 'ENVVAL\n' > "$REPO/.env"
chmod 600 "$REPO/.env"
mkdir -p "$REPO/secrets" "$REPO/nested/deep"
printf 'KEY\n' > "$REPO/secrets/key.pem"
printf 'DEEP\n' > "$REPO/nested/deep/thing.txt"
printf 'LOCAL\n' > "$REPO/config.local"
printf 'TRACKED\n' > "$REPO/tracked.txt"
printf 'UNLISTED\n' > "$REPO/unlisted.hidden"
# A file whose name is a SUBSTRING of an ignored path (secrets/key.pem). It is UNTRACKED and NOT
# gitignored, so .worktreeinclude selects it as a candidate and check-ignore must then reject it.
# Tracked would not exercise this: `git ls-files -o` drops tracked files before the ignore check
# ever sees them.
printf 'DECOY\n' > "$REPO/key.pem"
# 666 rather than 600 for the mode check: 600 survives `cp` without -p, because the umask only
# clears bits that are already clear, so an assertion on it cannot fail. 666 & ~022 is 644.
# Names that justify the NUL-delimited plumbing: a space, a non-ASCII character, and a newline.
printf 'SPACED\n' > "$REPO/my conf.local"
printf 'UNICODE\n' > "$REPO/café.local"
printf 'NEWLINE\n' > "$REPO/$(printf 'two\nlines').local"
printf 'MODE\n' > "$REPO/mode.local"
chmod 666 "$REPO/mode.local"
touch -t 200001020304.05 "$REPO/mode.local"
git -C "$REPO" add .gitignore .worktreeinclude tracked.txt
git -C "$REPO" commit -qm init

PROFILE_RAW=''
wt_copy_config "$REPO" "$WT" 1 2>/dev/null

eq 'worktreeinclude: a gitignored file it names is copied' 'ENVVAL' "$(cat "$WT/.env" 2>/dev/null)"
eq 'worktreeinclude: a gitignored file in a named directory is copied' 'KEY' \
  "$(cat "$WT/secrets/key.pem" 2>/dev/null)"
eq 'worktreeinclude: parent directories are created as needed' 'DEEP' \
  "$(cat "$WT/nested/deep/thing.txt" 2>/dev/null)"
eq 'worktreeinclude: a glob pattern matches' 'LOCAL' "$(cat "$WT/config.local" 2>/dev/null)"
# .worktreeinclude's other half: matching is not enough, it must ALSO be gitignored.
eq 'worktreeinclude: a TRACKED file it names is NOT copied' '' \
  "$(cat "$WT/tracked.txt" 2>/dev/null)"
# ...and being gitignored is not enough either, it must be named.
eq 'a gitignored file it does NOT name is not copied' '' \
  "$(cat "$WT/unlisted.hidden" 2>/dev/null)"
eq 'the file mode is preserved, which matters for a 600 .env' '600' \
  "$(stat -c '%a' "$WT/.env" 2>/dev/null || stat -f '%Lp' "$WT/.env" 2>/dev/null)"
# The assertion above documents the intent but cannot FAIL: 600 survives a plain `cp`, since the
# umask only clears bits that are already clear. 666 is the mode that actually distinguishes
# `cp -p` from `cp`, and mtime distinguishes it regardless of umask.
eq 'a mode the umask would otherwise strip is preserved too' '666' \
  "$(stat -c '%a' "$WT/mode.local" 2>/dev/null || stat -f '%Lp' "$WT/mode.local" 2>/dev/null)"
eq 'and the modification time is preserved, not reset to now' \
  "$(stat -c '%Y' "$REPO/mode.local" 2>/dev/null || stat -f '%m' "$REPO/mode.local" 2>/dev/null)" \
  "$(stat -c '%Y' "$WT/mode.local" 2>/dev/null || stat -f '%m' "$WT/mode.local" 2>/dev/null)"
# EXACT ignore matching. `key.pem` is tracked and therefore not ignored, but it is a substring of
# the ignored `secrets/key.pem`; a substring test would copy a file git never said was ignored.
eq 'a candidate that is merely a SUBSTRING of an ignored path is not copied' '' \
  "$(cat "$WT/key.pem" 2>/dev/null)"
# The NUL-delimited plumbing exists for these; a line-delimited reader would split the last one
# into two bogus paths and copy neither.
eq 'a filename containing a space is copied' 'SPACED' "$(cat "$WT/my conf.local" 2>/dev/null)"
eq 'a non-ASCII filename is copied' 'UNICODE' "$(cat "$WT/café.local" 2>/dev/null)"
eq 'a filename containing a newline is copied' 'NEWLINE' \
  "$(cat "$WT/$(printf 'two\nlines').local" 2>/dev/null)"
# Comments and blank lines are git's to interpret, and a later negation must win over an earlier
# glob. A hand-rolled matcher is where this goes wrong; delegating to git is why it does not.
eq 'a later negation un-matches an earlier glob, as gitignore syntax requires' '' \
  "$(cat "$WT/excluded.local" 2>/dev/null)"
eq '...while a sibling the same glob matched is still copied' 'LOCAL' \
  "$(cat "$WT/config.local" 2>/dev/null)"

# Never overwrite: the worktree's own edit is the developer's.
printf 'MINE\n' > "$WT/.env"
wt_copy_config "$REPO" "$WT" 1 2>/dev/null
eq 'a file already in the worktree is never overwritten' 'MINE' "$(cat "$WT/.env")"

# Self-healing, which is the thing native cannot do: .worktreeinclude runs only at creation, so a
# worktree that loses a config file only gets it back because this runs on every entry.
rm -f "$WT/.env"
wt_copy_config "$REPO" "$WT" 1 2>/dev/null
eq 'a config file deleted from the worktree is restored on the next entry' 'ENVVAL' \
  "$(cat "$WT/.env" 2>/dev/null)"

# On the SessionStart path native already did .worktreeinclude, so the plugin must not redo it.
WT2=$TMP/cfgwt2
mkdir -p "$WT2"
PROFILE_RAW=''
wt_copy_config "$REPO" "$WT2" 0 2>/dev/null
eq 'with own_include off, .worktreeinclude is left to native and nothing is copied' '' \
  "$(cat "$WT2/.env" 2>/dev/null)"

# The profile's copy[] is honoured on that path instead, straight out of the scan the load made.
PROFILE_RAW="0${US_}${RS_}2${US_}.env${RS_}2${US_}unlisted.hidden${RS_}"
wt_copy_config "$REPO" "$WT2" 0 2>/dev/null
eq 'copy[] is honoured with no second interpreter start' 'ENVVAL' "$(cat "$WT2/.env" 2>/dev/null)"
eq 'copy[] can name a gitignored file .worktreeinclude does not' 'UNLISTED' \
  "$(cat "$WT2/unlisted.hidden" 2>/dev/null)"

# copy[] obeys the same gitignored-only rule.
WT3=$TMP/cfgwt3; mkdir -p "$WT3"
PROFILE_RAW="0${US_}${RS_}2${US_}tracked.txt${RS_}"
err=$(wt_copy_config "$REPO" "$WT3" 0 2>&1)
eq 'a tracked file in copy[] is not copied' '' "$(cat "$WT3/tracked.txt" 2>/dev/null)"
contains '...and the developer is told why' 'not gitignored' "$err"

# Path containment. The profile arrives with anyone's branch and this step writes files.
WT4=$TMP/cfgwt4; mkdir -p "$WT4"
printf 'SECRET\n' > "$TMP/outside.txt"
PROFILE_RAW="0${US_}${RS_}2${US_}../outside.txt${RS_}2${US_}/etc/hostname${RS_}"
err=$(wt_copy_config "$REPO" "$WT4" 0 2>&1)
eq 'a traversing copy[] entry writes nothing' '' "$(find "$WT4" -type f 2>/dev/null)"
contains '...and is refused by shape, before anything is resolved' 'refusing to copy' "$err"

# An unusable profile contributes NO copy entries, rather than half of them.
WT5=$TMP/cfgwt5; mkdir -p "$WT5"
PROFILE_RAW=''
wt_copy_config "$REPO" "$WT5" 0 2>/dev/null
eq 'with no loaded profile, copy[] contributes nothing' '' "$(find "$WT5" -type f 2>/dev/null)"

# A symlink is refused: reproducing it would point the worktree's config at the main checkout,
# so an edit in one worktree would show up in another.
ln -s "$REPO/.env" "$REPO/linked.local"
WT6=$TMP/cfgwt6; mkdir -p "$WT6"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}linked.local${RS_}"
err=$(wt_copy_config "$REPO" "$WT6" 0 2>&1)
eq 'a symlinked config file is not copied' '' "$(find "$WT6" -type f -o -type l 2>/dev/null)"
contains '...and the reason names the shared-state risk' 'share state between worktrees' "$err"

# A symlinked PARENT directory must not be followed. This is the threat Claude Code refuses
# worktree creation over, and the leaf check alone does not see it: `mkdir -p` and `cp` would
# both follow `conf/` and write the file wherever it points — here, outside the worktree.
WT7=$TMP/cfgwt7; mkdir -p "$WT7" "$TMP/elsewhere"
mkdir -p "$REPO/conf"
printf 'INNER\n' > "$REPO/conf/app.local"
ln -s "$TMP/elsewhere" "$WT7/conf"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}conf/app.local${RS_}"
err=$(wt_copy_config "$REPO" "$WT7" 0 2>&1)
eq 'a symlinked parent directory in the worktree is not followed' '' \
  "$(cat "$TMP/elsewhere/app.local" 2>/dev/null)"
contains '...and the reason says so' 'parent directories is a symlink' "$err"

# The same on the SOURCE side: a symlinked parent in the main checkout would read from outside it.
WT8=$TMP/cfgwt8; mkdir -p "$WT8"
ln -s "$TMP/elsewhere" "$REPO/linkdir"
printf 'OUTSIDE\n' > "$TMP/elsewhere/secret.local"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}linkdir/secret.local${RS_}"
wt_copy_config "$REPO" "$WT8" 0 2>/dev/null
eq 'a symlinked parent directory in the checkout is not followed either' '' \
  "$(cat "$WT8/linkdir/secret.local" 2>/dev/null)"
rm -f "$REPO/linkdir"

# A DANGLING symlink in the worktree is still the worktree's own state. `-e` is false for one, so
# without the `-L` half of the guard `cp` would write THROUGH the link, creating the file it
# points at — outside the worktree.
WT9=$TMP/cfgwt9; mkdir -p "$WT9"
ln -s "$TMP/elsewhere/notyet" "$WT9/.env"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}.env${RS_}"
wt_copy_config "$REPO" "$WT9" 0 2>/dev/null
eq 'a dangling symlink in the worktree is left alone, not written through' 'yes' \
  "$([ -L "$WT9/.env" ] && echo yes)"
eq '...and the file it points at is not created' '' \
  "$(cat "$TMP/elsewhere/notyet" 2>/dev/null)"

# A directory whose tree contains a symlink is refused whole, or `cp -Rp` would reproduce the
# link and reintroduce exactly the shared state the leaf refusal prevents.
WT10=$TMP/cfgwt10; mkdir -p "$WT10"
mkdir -p "$REPO/bundle"
printf 'PLAIN\n' > "$REPO/bundle/plain.txt"
ln -s "$TMP/elsewhere" "$REPO/bundle/link"
printf 'bundle/\n' >> "$REPO/.gitignore"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}bundle${RS_}"
err=$(wt_copy_config "$REPO" "$WT10" 0 2>&1)
eq 'a directory containing a symlink is not copied at all' '' \
  "$(cat "$WT10/bundle/plain.txt" 2>/dev/null)"
contains '...and the reason names the shared-state risk' 'contains a symlink' "$err"

# A repository with NO .worktreeinclude is the ordinary case; it must be silent, not a git error.
NOINC=$TMP/noinc; mkdir -p "$NOINC"
git init -q "$NOINC"
git -C "$NOINC" config user.email t@example.com
git -C "$NOINC" config user.name t
printf '*.local\n' > "$NOINC/.gitignore"
printf 'X\n' > "$NOINC/only.local"
git -C "$NOINC" add .gitignore
git -C "$NOINC" commit -qm init
WT11=$TMP/cfgwt11; mkdir -p "$WT11"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}only.local${RS_}"
err=$(wt_copy_config "$NOINC" "$WT11" 1 2>&1)
eq 'a repo with no .worktreeinclude still gets its copy[] entries' 'X' \
  "$(cat "$WT11/only.local" 2>/dev/null)"
eq '...and produces no git error' '' "$(printf '%s' "$err" | grep -i 'fatal\|error' || true)"

# A traversal whose destination is observable, so removing the shape check makes this FAIL rather
# than merely stop logging. `sub/../escaped.local` resolves to a real gitignored file.
WT12=$TMP/cfgwt12; mkdir -p "$WT12"
printf 'ESCAPED\n' > "$REPO/escaped.local"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}sub/../escaped.local${RS_}"
wt_copy_config "$REPO" "$WT12" 0 2>/dev/null
eq 'a copy[] entry containing a .. segment copies nothing, even when it resolves inside' '' \
  "$(find "$WT12" -type f 2>/dev/null)"

# An empty copy[] element is ignored rather than treated as the repository root.
WT13=$TMP/cfgwt13; mkdir -p "$WT13"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}${RS_}"
wt_copy_config "$REPO" "$WT13" 0 2>/dev/null
eq 'an empty copy[] entry copies nothing' '' "$(find "$WT13" -mindepth 1 2>/dev/null)"

# ORDERING: the candidate list is built before any copy happens, so a copy[] naming both a file
# and the directory containing it must not `cp -Rp` into a directory an earlier entry just
# created. Without the re-existence test this produces pack/pack.
WT14=$TMP/cfgwt14; mkdir -p "$WT14"
mkdir -p "$REPO/pack"
printf 'A\n' > "$REPO/pack/a.txt"
printf 'pack/\n' >> "$REPO/.gitignore"
# shellcheck disable=SC2034
PROFILE_RAW="0${US_}${RS_}2${US_}pack/a.txt${RS_}2${US_}pack${RS_}"
wt_copy_config "$REPO" "$WT14" 0 2>/dev/null
eq 'the file inside the named directory is copied' 'A' "$(cat "$WT14/pack/a.txt" 2>/dev/null)"
eq 'and the directory entry does not nest a second copy inside it' '' \
  "$(find "$WT14" -type d -name pack -path '*/pack/pack' 2>/dev/null)"

# A check-ignore that FAILS outright (git absent, corrupt index, not a work tree) must not read as
# "nothing is ignored" — that would blame every path with the wrong reason, and a later change
# that inverted the default would silently copy files git never approved.
WT15=$TMP/cfgwt15; mkdir -p "$WT15"
out=$(
  # shellcheck disable=SC2034
  PROFILE_RAW="0${US_}${RS_}2${US_}.env${RS_}"
  # SC2329: invoked indirectly, by the engine this suite sources.
  # shellcheck disable=SC2329
  wt_git() { return 128; }
  wt_copy_config "$REPO" "$WT15" 0 2>&1
)
contains 'a failing check-ignore is reported as a failure, not as nothing-ignored' \
  'could not ask git which paths are gitignored' "$out"
eq '...and nothing is copied on that run' '' "$(find "$WT15" -type f 2>/dev/null)"

# ---------------------------------------------------------------------------
# Locking
# ---------------------------------------------------------------------------

LKROOT=$TMP/lkroot
mkdir -p "$LKROOT"
git init -q "$LKROOT"
git -C "$LKROOT" config user.email t@example.com
git -C "$LKROOT" config user.name t

# Locks live in the SHARED git directory: every worktree of the repo must agree on the same file,
# and being outside the checkout keeps them out of `git status`.
eq 'a lock path is in the shared git dir, keyed on the dependency' \
  "$LKROOT/.git/worktree-locks/vendor.lock" "$(wt_lock_path "$LKROOT" vendor)"
eq 'a dependency dir containing a slash is slugified into one filename' \
  "$LKROOT/.git/worktree-locks/assets_node_modules.lock" \
  "$(wt_lock_path "$LKROOT" assets/node_modules)"
# A directory outside a git repository still gets a usable path rather than nothing.
eq 'outside a repository it falls back to .claude/worktree-locks' \
  "$TMP/plain/.claude/worktree-locks/vendor.lock" "$(wt_lock_path "$TMP/plain" vendor)"

# Hostile dependency directories arrive in a committed profile. Whatever they are, the lock path
# must stay one file inside the locks directory — never escape it, never be empty.
for bad in '' '..' '/etc/passwd' '../../x' 'a/../../b' 'ünïcode' '///'; do
  lp=$(wt_lock_path "$LKROOT" "$bad")
  case $lp in
    "$LKROOT/.git/worktree-locks/"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); printf 'FAIL lock path escaped for %q: %q\n' "$bad" "$lp" >&2 ;;
  esac
  tail_part=${lp#"$LKROOT/.git/worktree-locks/"}
  case $tail_part in
    */*) fail=$((fail+1)); printf 'FAIL lock name has a separator for %q: %q\n' "$bad" "$tail_part" >&2 ;;
    '') fail=$((fail+1)); printf 'FAIL lock name empty for %q\n' "$bad" >&2 ;;
    *) pass=$((pass+1)) ;;
  esac
done
ne 'two different dependency dirs get different locks' \
  "$(wt_lock_path "$LKROOT" vendor)" "$(wt_lock_path "$LKROOT" node_modules)"

if command -v flock >/dev/null 2>&1; then
  LK=$(wt_lock_path "$LKROOT" vendor)
  wt_lock_acquire "$LK" 5 9
  eq 'a free lock is acquired' 0 $?
  # A SECOND holder must not get it while the first has it. Taken from a child process, because
  # flock is per open-file-description and a second acquire in this same shell would succeed.
  rc=$(flock -w 1 "$LK" -c true >/dev/null 2>&1; echo $?)
  ne 'a held lock genuinely excludes another process' 0 "$rc"
  wt_lock_release 9
  rc=$(flock -w 1 "$LK" -c true >/dev/null 2>&1; echo $?)
  eq 'and releasing it lets the next one in' 0 "$rc"

  # The never-cost-a-session behaviour: contention must never stall a session. Hold the lock from a child,
  # then confirm the acquire gives up quickly and reports "not held" rather than waiting.
  # A readiness marker rather than a bare sleep: on a loaded machine the holder may not have the
  # lock yet, the parent would acquire it, and the two assertions below would fail for reasons
  # that have nothing to do with the code. A flaky suite trains people to ignore red.
  rm -f "$LKROOT/held"
  ( flock 9; : >"$LKROOT/held"; sleep 3 ) 9>"$LK" &
  holder=$!
  waitn=0
  while [ ! -f "$LKROOT/held" ] && [ "$waitn" -lt 100 ]; do
    sleep 0.05
    waitn=$((waitn + 1))
  done
  eq 'the test holder actually took the lock before we tried' yes \
    "$([ -f "$LKROOT/held" ] && echo yes)"
  start=$(date +%s)
  wt_lock_acquire "$LK" 1 8
  rc=$?
  waited=$(( $(date +%s) - start ))
  eq 'a contended lock reports not-held rather than blocking' 1 "$rc"
  eq '...and gives up within its wait, so a session never stalls behind another worktree' yes \
    "$([ "$waited" -le 2 ] && echo yes)"
  wt_lock_release 8
  wait "$holder" 2>/dev/null
else
  printf 'WARNING: flock absent — lock exclusion NOT verified\n' >&2
fi

# The fd guard runs before the flock probe, so it holds on any host.
rc=$(wt_lock_acquire "$LKROOT/x.lock" 1 notanumber >/dev/null 2>&1; echo $?)
eq 'a non-numeric fd is refused rather than eval-ed' 2 "$rc"
# 0, 1 and 2 must be refused too: `exec 1>lock` would redirect the hook's stdout — the channel
# carrying the worktree path — into the lock file.
for badfd in 0 1 2; do
  rc=$(wt_lock_acquire "$LKROOT/x.lock" 1 "$badfd" >/dev/null 2>&1; echo $?)
  eq "fd $badfd is refused, so the protocol channel cannot be clobbered" 2 "$rc"
done

if command -v flock >/dev/null 2>&1; then
  # An unusable lock path is "could not even try", distinct from "not held". Only meaningful
  # where flock exists — without it the probe short-circuits and returns 1 first.
  rc=$(wt_lock_acquire /proc/nonexistent/x.lock 1 7 >/dev/null 2>&1; echo $?)
  eq 'an unusable lock path is reported as could-not-try, not as acquired' 2 "$rc"

  # A symlinked lock path must be refused, not opened: `exec 9>` TRUNCATES, so opening it would
  # zero whatever it points at.
  printf 'PRECIOUS\n' > "$TMP/precious.txt"
  mkdir -p "$LKROOT/.git/worktree-locks"
  ln -sf "$TMP/precious.txt" "$LKROOT/.git/worktree-locks/evil.lock"
  rc=$(wt_lock_acquire "$LKROOT/.git/worktree-locks/evil.lock" 1 7 >/dev/null 2>&1; echo $?)
  eq 'a symlinked lock file is refused rather than opened' 2 "$rc"
  eq '...and the file it pointed at is untouched' 'PRECIOUS' "$(cat "$TMP/precious.txt")"
  # The same for a symlinked parent directory.
  ln -sf "$TMP/elsewhere" "$LKROOT/.git/linkdir"
  mkdir -p "$TMP/elsewhere"
  printf 'ALSO\n' > "$TMP/elsewhere/p.lock"
  rc=$(wt_lock_acquire "$LKROOT/.git/linkdir/p.lock" 1 7 >/dev/null 2>&1; echo $?)
  eq 'a lock under a symlinked directory is refused' 2 "$rc"
  eq '...and that file is untouched too' 'ALSO' "$(cat "$TMP/elsewhere/p.lock")"
fi

# No flock on PATH: warn once and proceed unlocked, never refuse to work.
out=$(
  # SC2123: clobbering PATH is the point — this simulates a host with no flock(1).
  # shellcheck disable=SC2123
  PATH=/nonexistent
  unset WT_FLOCK_WARNED
  wt_lock_acquire "$LKROOT/y.lock" 1 6 2>&1
  printf '|rc=%s' $?
)
contains 'with no flock binary the user is told' 'not be serialised' "$out"
contains '...and the caller is told to proceed unlocked, not that it failed' '|rc=1' "$out"
# "Say so ONCE per run" is the contract; a warning on every dependency would bury the real output.
out=$(
  # shellcheck disable=SC2123
  PATH=/nonexistent
  unset WT_FLOCK_WARNED
  wt_lock_acquire "$LKROOT/y.lock" 1 6 2>&1
  wt_lock_acquire "$LKROOT/z.lock" 1 6 2>&1
)
eq 'the missing-flock warning is printed once per run, not once per dependency' 1 \
  "$(printf '%s\n' "$out" | grep -c 'not be serialised')"
# A non-numeric wait falls back to the default instead of erroring.
rc=$(wt_lock_acquire "$LKROOT/w.lock" abc 7 >/dev/null 2>&1; echo $?)
case $rc in 0|1) pass=$((pass+1)) ;; *) fail=$((fail+1)); printf 'FAIL non-numeric wait: rc=%s\n' "$rc" >&2 ;; esac
wt_lock_release 7

# ---------------------------------------------------------------------------
# Per-worktree bootstrap state
# ---------------------------------------------------------------------------

SREPO=$TMP/srepo
git init -q "$SREPO"
git -C "$SREPO" config user.email t@example.com
git -C "$SREPO" config user.name t
printf 'x\n' > "$SREPO/f.txt"
git -C "$SREPO" add f.txt
git -C "$SREPO" commit -qm init
SWT=$SREPO/.claude/worktrees/one
git -C "$SREPO" worktree add -q "$SWT" -b wt-one 2>/dev/null

# It lives in the worktree's private git directory, so it never shows up in `git status` and a
# developer cannot commit it by accident.
sp=$(wt_state_path "$SWT")
case $sp in
  *"/.git/worktrees/one/worktree-bootstrap-state") pass=$((pass+1)) ;;
  *) fail=$((fail+1)); printf 'FAIL state path is not in the private git dir: %q\n' "$sp" >&2 ;;
esac
eq 'and the worktree checkout itself stays clean' '' \
  "$(git -C "$SWT" status --porcelain 2>/dev/null)"

wt_state_is_done "$SWT" vendor L1 I1 hardlink
eq 'an unbootstrapped worktree reports not done' 1 $?

wt_state_set "$SWT" vendor hardlink L1 I1 doing
eq 'writing an in-progress record succeeds' 0 $?
wt_state_is_done "$SWT" vendor L1 I1 hardlink
eq 'an entry left at "doing" is NOT done — that is a timeout kill, not a finished install' 1 $?

wt_state_set "$SWT" vendor hardlink L1 I1 "done"
wt_state_is_done "$SWT" vendor L1 I1 hardlink
eq 'a completed entry with matching evidence is done' 0 $?
wt_state_is_done "$SWT" vendor L2 I1 hardlink
eq 'a changed lockfile makes it not done' 1 $?
wt_state_is_done "$SWT" vendor L1 I2 hardlink
eq 'a changed install command makes it not done' 1 $?
wt_state_is_done "$SWT" node_modules L1 I1 install
eq 'a different dependency is not covered by this one' 1 $?

# Several dependencies coexist, and rewriting one leaves the others intact.
wt_state_set "$SWT" node_modules install L9 I9 "done"
wt_state_is_done "$SWT" vendor L1 I1 hardlink
eq 'writing a second dependency does not disturb the first' 0 $?
wt_state_is_done "$SWT" node_modules L9 I9 install
eq 'and the second is recorded too' 0 $?
wt_state_set "$SWT" vendor hardlink L3 I3 "done"
wt_state_is_done "$SWT" node_modules L9 I9 install
eq 'rewriting the first still leaves the second intact' 0 $?
eq 'a dependency is stored once, not appended to' 1 \
  "$(tr "$RS_" '\n' < "$(wt_state_path "$SWT")" | grep -c '^dep.*vendor' )"

# No partial trust: anything unreadable, truncated or from another format means "not done".
printf 'garbage' > "$(wt_state_path "$SWT")"
wt_state_is_done "$SWT" vendor L3 I3 hardlink
eq 'an unparseable state file means not done' 1 $?
printf 'wtstate%s99%sdep%svendor%shardlink%sL3%sI3%sdone%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_state_is_done "$SWT" vendor L3 I3 hardlink
eq 'a state file from a different format version means not done' 1 $?
printf 'dep%svendor%shardlink%sL3%sI3%sdone%s' "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" \
  > "$(wt_state_path "$SWT")"
wt_state_is_done "$SWT" vendor L3 I3 hardlink
eq 'a record with no header means not done' 1 $?
rm -f "$(wt_state_path "$SWT")"
wt_state_is_done "$SWT" vendor L3 I3 hardlink
eq 'a missing state file means not done' 1 $?

# Atomicity has a limit worth stating: a `cp`-then-`rm` write produces the same CONTENT, so only
# a racing reader could observe the difference and such a test is inherently flaky. What IS
# deterministic is the precondition atomicity depends on — the temp file must be created in the
# SAME directory as the target, or `mv` crosses a filesystem and stops being a rename — and that
# no temp file survives a write.
wt_state_set "$SWT" vendor hardlink L4 I4 "done"
eq 'a state write leaves no temporary file behind' 0 \
  "$(find "$(dirname "$(wt_state_path "$SWT")")" -maxdepth 1 -name '.wtstate.*' 2>/dev/null | wc -l | tr -d ' ')"
eq 'and the state file itself is intact afterwards' 0 \
  "$(wt_state_is_done "$SWT" vendor L4 I4 hardlink; echo $?)"

# The recorded STRATEGY is evidence too. Flipping hardlink -> install in the profile changes
# neither the lockfile nor the install command, so without comparing it the worktree would keep a
# tree built the way the developer just abandoned and call itself up to date.
wt_state_set "$SWT" vendor hardlink L5 I5 "done"
wt_state_is_done "$SWT" vendor L5 I5 hardlink
eq 'a matching strategy is done' 0 $?
wt_state_is_done "$SWT" vendor L5 I5 install
eq 'the SAME evidence under a different strategy is NOT done' 1 $?
wt_state_is_done "$SWT" vendor L5 I5
eq 'a caller that passes no strategy skips that check' 0 $?

# A file from a different format version must not be LAUNDERED by an unrelated write: without a
# header check in the writer, the first write after a version bump restamps every stale record as
# current, and the reader then trusts records it had correctly refused.
printf 'wtstate%s99%sdep%snode_modules%sinstall%sL9%sI9%sdone%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_state_set "$SWT" vendor hardlink L7 I7 "done"
wt_state_is_done "$SWT" node_modules L9 I9 install
eq 'a foreign-version record is discarded by the next write, not promoted' 1 $?
wt_state_is_done "$SWT" vendor L7 I7 hardlink
eq '...while the record just written is trusted' 0 $?

# Same for a file with no header at all.
printf 'dep%snode_modules%sinstall%sL9%sI9%sdone%s' \
  "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_state_set "$SWT" vendor hardlink L8 I8 "done"
wt_state_is_done "$SWT" node_modules L9 I9 install
eq 'a headerless record is discarded by the next write too' 1 $?

# ---------------------------------------------------------------------------
# The runtime (`rt`) record — layer 3's half of the same file
# ---------------------------------------------------------------------------
#
# THE TWO WRITERS MUST NOT ERASE EACH OTHER, and this is the defect that made a shared file look
# unusable: wt_state_set's carry-over recognised `wtstate` and `dep` only, with no default arm, so
# any other kind was silently dropped by the next dependency write. Since a dependency write
# happens on nearly every session, an `rt` record would have survived for about one session —
# taking the seed's already-done marker with it and re-seeding forever. Both directions are
# asserted, because only one of them was ever broken and a future edit could break the other.
rm -f "$(wt_state_path "$SWT")"
wt_state_set "$SWT" vendor hardlink LR IR "done"
wt_runtime_state_set "$SWT" demo_one 3812 derived .env.worktree.local ours "done" SC1
eq 'writing a runtime record succeeds' 0 $?
eq 'the dependency record survives a runtime write' 0 \
  "$(wt_state_is_done "$SWT" vendor LR IR hardlink; echo $?)"
wt_state_set "$SWT" node_modules install LN IN "done"
eq 'and the runtime record survives a dependency write' 'demo_one' \
  "$(wt_runtime_state_get "$SWT" slug)"
eq '...including its seed status, which is what stops the seed re-running forever' 'done' \
  "$(wt_runtime_state_get "$SWT" seedstatus)"

# Every field round-trips, by NAME. Teardown consumes these rather than re-deriving a slug or
# re-expanding an env path, because a profile edited in between would send it looking elsewhere.
eq 'rt field: slug'       'demo_one'             "$(wt_runtime_state_get "$SWT" slug)"
eq 'rt field: port'       '3812'                 "$(wt_runtime_state_get "$SWT" port)"
eq 'rt field: portsource' 'derived'              "$(wt_runtime_state_get "$SWT" portsource)"
eq 'rt field: envfile'    '.env.worktree.local'  "$(wt_runtime_state_get "$SWT" envfile)"
eq 'rt field: envstate'   'ours'                 "$(wt_runtime_state_get "$SWT" envstate)"
eq 'rt field: seedcksum'  'SC1'                  "$(wt_runtime_state_get "$SWT" seedcksum)"
ne 'rt field: when is recorded' '' "$(wt_runtime_state_get "$SWT" when)"
# THE TWO FAILURES ARE DIFFERENT NUMBERS. Both were 1 at first, which made
# `v=$(... seedstatuss) || v=none` turn a field-name TYPO into a silent default — the caller could
# not tell "layer 3 has not run here" from "you asked for a field that does not exist".
wt_runtime_state_get "$SWT" nosuchfield >/dev/null 2>&1
eq 'an unknown rt field name is a caller error (2)' 2 $?
eq 'and it prints nothing' '' "$(wt_runtime_state_get "$SWT" nosuchfield 2>/dev/null)"
wt_runtime_state_get "$TMP/nowhere-at-all" slug >/dev/null 2>&1
eq 'while a missing record is a different failure (1)' 1 $?

# One record, replaced rather than appended: a second allocation must not leave the first behind
# for a reader to find.
wt_runtime_state_set "$SWT" demo_one 3813 probed .env.worktree.local ours failed SC2
eq 'a runtime record is stored once, not appended to' 1 \
  "$(tr "$RS_" '\n' < "$(wt_state_path "$SWT")" | grep -c '^rt')"
eq 'and the replacement wins' '3813' "$(wt_runtime_state_get "$SWT" port)"
eq 'the dependency records are still there after both runtime writes' 0 \
  "$(wt_state_is_done "$SWT" node_modules LN IN install; echo $?)"

# No partial trust, exactly as for the dependency records.
printf 'garbage' > "$(wt_state_path "$SWT")"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'an unparseable state file yields no runtime record' 1 $?
printf 'wtstate%s99%srt%sdemo%s3812%sderived%s.e%sours%sdone%sSC%s1%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" \
  > "$(wt_state_path "$SWT")"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'a runtime record from another format version is not trusted' 1 $?
printf 'rt%sdemo%s3812%sderived%s.e%sours%sdone%sSC%s1%s' \
  "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'a runtime record before any header is not trusted' 1 $?
rm -f "$(wt_state_path "$SWT")"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'a missing state file yields no runtime record' 1 $?

# ...and a foreign-version file is not LAUNDERED by a runtime write either, which is the same
# trap wt_state_set has: restamping stale records as current makes the reader trust records it
# had correctly refused.
printf 'wtstate%s99%sdep%snode_modules%sinstall%sLZ%sIZ%sdone%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" demo_two 3900 derived .e ours none ''
eq 'a foreign-version dep record is discarded by a runtime write, not promoted' 1 \
  "$(wt_state_is_done "$SWT" node_modules LZ IZ install; echo $?)"
eq '...while the runtime record just written is trusted' 'demo_two' \
  "$(wt_runtime_state_get "$SWT" slug)"

# Empty fields are legal and must round-trip as empty rather than shifting their neighbours — the
# ordinary state before a port is allocated or a seed has ever run.
rm -f "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" demo_three '' '' '' '' none ''
eq 'an empty port round-trips as empty' '' "$(wt_runtime_state_get "$SWT" port)"
eq 'and the fields after it are not shifted' 'none' "$(wt_runtime_state_get "$SWT" seedstatus)"
eq 'and the slug before it is intact' 'demo_three' "$(wt_runtime_state_get "$SWT" slug)"
eq 'an empty envfile round-trips as empty'   '' "$(wt_runtime_state_get "$SWT" envfile)"
eq 'an empty envstate round-trips as empty'  '' "$(wt_runtime_state_get "$SWT" envstate)"
eq 'an empty seedcksum round-trips as empty' '' "$(wt_runtime_state_get "$SWT" seedcksum)"

# A VALID, CURRENT file that simply has no rt record yet — the ordinary state before layer 3 has
# ever run in this worktree. Distinct from every corruption case above and easy to get wrong.
rm -f "$(wt_state_path "$SWT")"
wt_state_set "$SWT" vendor hardlink LQ IQ "done"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'a valid file with dep records but no rt record yields no runtime record' 1 $?

# A dep record positioned AFTER an rt record must still be readable: once layer 3 has run, that is
# the ordinary file layout, so the dependency reader has to skip a leading rt rather than stop at it.
rm -f "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" demo_five 3902 derived .e ours none ''
wt_state_set "$SWT" vendor hardlink LP IP "done"
eq 'a dep record after an rt record is still found' 0 \
  "$(wt_state_is_done "$SWT" vendor LP IP hardlink; echo $?)"
eq 'and wt_state_status skips the rt record too' 'done' "$(wt_state_status "$SWT" vendor)"

# THE HEADERLESS GUARD, from BOTH directions. Neither was pinned: the only headerless test planted
# a dep record and hit the dep arm's own guard, so the shared rule could be deleted and the suite
# would stay green while a headerless file's records were laundered into a header-stamped one.
printf 'rt%sdemo_ghost%s3999%sderived%s.e%sours%sdone%sSCX%s1%s' \
  "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_state_set "$SWT" vendor hardlink LG IG "done"
wt_runtime_state_get "$SWT" slug >/dev/null 2>&1
eq 'a headerless rt record is discarded by a dependency write, not promoted' 1 $?
printf 'dep%snode_modules%sinstall%sLG2%sIG2%sdone%s1%s' \
  "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" demo_six 3903 derived .e ours none ''
eq 'a headerless dep record is discarded by a runtime write, not promoted' 1 \
  "$(wt_state_is_done "$SWT" node_modules LG2 IG2 install; echo $?)"
eq '...while the runtime record just written is trusted' 'demo_six' \
  "$(wt_runtime_state_get "$SWT" slug)"

# HOSTILE FIELD VALUES. A slug is derived from a worktree name and an envfile from a profile
# template, and the record is US/RS-delimited and read with a line-based `read` — so a value
# carrying any of those bytes would truncate the record and blank every field after it, silently.
# The seed status is one of those later fields, so the seed would re-run every session.
rm -f "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" "a${US_}b" "3904" derived "x${RS_}y" ours "done" SCZ
eq 'a separator in an early field does not blank the fields after it' 'done' \
  "$(wt_runtime_state_get "$SWT" seedstatus)"
eq 'and the checksum after that survives too' 'SCZ' "$(wt_runtime_state_get "$SWT" seedcksum)"
eq 'the separator itself is stripped from the value that carried it' 'ab' \
  "$(wt_runtime_state_get "$SWT" slug)"
eq 'and an RS in a later field is stripped too, not treated as a record end' 'xy' \
  "$(wt_runtime_state_get "$SWT" envfile)"
rm -f "$(wt_state_path "$SWT")"
wt_runtime_state_set "$SWT" "a${NL_}b" 3905 derived .e ours "done" SCY
eq 'a newline in an early field does not blank the fields after it' 'done' \
  "$(wt_runtime_state_get "$SWT" seedstatus)"
eq 'and the newline is folded to a space, matching the JSON layer' 'a b' \
  "$(wt_runtime_state_get "$SWT" slug)"
rm -f "$(wt_state_path "$SWT")"
# SC2016: the `$(x)` is LITERAL and is the point — a slug that reached the state file carrying
# shell syntax must be stored and returned as text, never evaluated. Expanding it here would test
# a different string than the one under test.
# shellcheck disable=SC2016
wt_runtime_state_set "$SWT" 'a;b$(x)' 3906 derived '.env-üñî' ours "done" SCW
# shellcheck disable=SC2016
eq 'shell metacharacters in a slug round-trip verbatim' 'a;b$(x)' \
  "$(wt_runtime_state_get "$SWT" slug)"
eq 'and a non-ASCII env path round-trips verbatim' '.env-üñî' \
  "$(wt_runtime_state_get "$SWT" envfile)"

wt_runtime_state_set "$SWT" demo_four 3901 derived .e ours "done" SC9
eq 'a runtime write leaves no temporary file behind' 0 \
  "$(find "$(dirname "$(wt_state_path "$SWT")")" -maxdepth 1 -name '.wtstate.*' 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$(wt_state_path "$SWT")"

# ---------------------------------------------------------------------------
# The runtime ledger — the record of an allocation that outlives its worktree
# ---------------------------------------------------------------------------
#
# A repository of its own: the rt tests above re-point one worktree at several slugs, and each of
# those is correctly preserved as a separate entry, which would make "exactly one" unprovable here.
LREPO=$TMP/lrepo
git init -q "$LREPO"
git -C "$LREPO" config user.email t@example.com
git -C "$LREPO" config user.name t
printf 'x\n' > "$LREPO/f.txt"
git -C "$LREPO" add f.txt
git -C "$LREPO" commit -qm init
LWT=$LREPO/.claude/worktrees/alice/fix-99
git -C "$LREPO" worktree add -q "$LWT" -b wt-fix-99 2>/dev/null
LEDGER=$LREPO/.git/worktree-ledger

ledger_count() {  # every file in the ledger, whatever the readers think of it
  find "$LEDGER" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

WT_NAME=alice/fix-99
out=$(wt_runtime_state_set "$LWT" alice_fix_99 3812 derived .env.worktree.local ours "done" SCL 2>"$TMP/ledger-err")
eq 'an rt write prints nothing, ledger included (stdout is a protocol)' '' "$out"
wt_runtime_state_set "$LWT" alice_fix_99 3812 derived .env.worktree.local ours "done" SCL 2>"$TMP/ledger-err"
eq 'an rt write in a linked worktree creates exactly one ledger entry' 1 "$(ledger_count)"
eq '...named after the admin id git gave the worktree' 'fix-99' \
  "$(find "$LEDGER" -mindepth 1 -maxdepth 1 -exec basename {} \; 2>/dev/null)"
eq '...and it is written quietly' '' "$(cat "$TMP/ledger-err")"
eq 'ledger field: path'       "$LWT"                "$(wt_ledger_field "$LREPO" fix-99 path)"
eq 'ledger field: admin'      'fix-99'              "$(wt_ledger_field "$LREPO" fix-99 admin)"
eq 'ledger field: name, as bootstrap knows it' 'alice/fix-99' "$(wt_ledger_field "$LREPO" fix-99 name)"
eq 'ledger field: slug'       'alice_fix_99'        "$(wt_ledger_field "$LREPO" fix-99 slug)"
eq 'ledger field: port'       '3812'                "$(wt_ledger_field "$LREPO" fix-99 port)"
eq 'ledger field: portsource' 'derived'             "$(wt_ledger_field "$LREPO" fix-99 portsource)"
eq 'ledger field: envfile'    '.env.worktree.local' "$(wt_ledger_field "$LREPO" fix-99 envfile)"
eq 'ledger field: envstate'   'ours'                "$(wt_ledger_field "$LREPO" fix-99 envstate)"
eq 'ledger field: seedstatus' 'done'                "$(wt_ledger_field "$LREPO" fix-99 seedstatus)"
eq 'ledger field: seedcksum'  'SCL'                 "$(wt_ledger_field "$LREPO" fix-99 seedcksum)"
eq 'ledger field: when matches the state record' "$(wt_runtime_state_get "$LWT" when)" \
  "$(wt_ledger_field "$LREPO" fix-99 when)"
eq 'the ledger is found from inside the worktree as well' 'alice_fix_99' \
  "$(wt_ledger_field "$LWT" fix-99 slug)"
wt_ledger_field "$LREPO" fix-99 nosuchfield >/dev/null
eq 'an unknown ledger field is a caller error (2), as for the rt accessor' 2 $?
wt_ledger_field "$LREPO" no-such-entry slug >/dev/null
eq 'a missing entry is a different failure (1)' 1 $?
wt_ledger_field "$LREPO" ../HEAD slug >/dev/null
eq 'a traversal entry name is refused as a caller error (2)' 2 $?

# The enumeration stream: one record per entry, entry name first, then every field in order.
eq 'wt_ledger_entries emits one record per entry, entry name first' \
  "fix-99|$LWT|fix-99|alice/fix-99|alice_fix_99|3812|derived|.env.worktree.local|ours|done|SCL|$(wt_ledger_field "$LREPO" fix-99 when)" \
  "$(wt_ledger_entries "$LREPO" | tr "$US_$RS_" '|\n')"

# Same worktree, same slug, new values: the entry is REPLACED, not set aside.
wt_runtime_state_set "$LWT" alice_fix_99 3813 probed .env.worktree.local ours failed SCM 2>/dev/null
eq 'rewriting the rt record for the same worktree still leaves one entry' 1 "$(ledger_count)"
eq '...carrying the new allocation' '3813' "$(wt_ledger_field "$LREPO" fix-99 port)"
# A later SessionStart derives the flattened name from the path; the seed saw the first one.
WT_NAME=alice-fix-99 wt_runtime_state_set "$LWT" alice_fix_99 3813 probed .env.worktree.local ours failed SCM 2>/dev/null
eq '...keeping the name first recorded for the same path and slug' 'alice/fix-99' \
  "$(wt_ledger_field "$LREPO" fix-99 name)"
eq 'a ledger write leaves no temporary file behind' 0 \
  "$(find "$LEDGER" -maxdepth 1 -name '.wtledger.*' 2>/dev/null | wc -l | tr -d ' ')"

# THE POINT OF IT: git deletes the admin directory, and with it the state file, but not the ledger.
git -C "$LREPO" worktree remove --force "$LWT" 2>/dev/null
eq 'git worktree remove takes the state file with it' 1 "$([ -e "$LREPO/.git/worktrees/fix-99" ] && echo 0 || echo 1)"
eq '...but the ledger entry survives it' '3813' "$(wt_ledger_field "$LREPO" fix-99 port)"

# A REUSED ADMIN ID. git hands `fix-99` to the next worktree whose basename is fix-99, and
# overwriting the entry would erase the only record of the first worktree's database.
LWT2=$LREPO/.claude/worktrees/bob/fix-99
git -C "$LREPO" worktree add -q "$LWT2" -b wt-bob-fix-99 2>/dev/null
eq 'the fixture really does reuse the admin id' 1 "$([ -d "$LREPO/.git/worktrees/fix-99" ] && echo 1 || echo 0)"
WT_NAME=bob/fix-99
wt_runtime_state_set "$LWT2" bob_fix_99 3900 derived .env.worktree.local ours none '' 2>/dev/null
eq 'a reused id with a different path keeps both entries' 2 "$(ledger_count)"
eq '...the new one under the id' "$LWT2" "$(wt_ledger_field "$LREPO" fix-99 path)"
old_entry=$(wt_ledger_entries "$LREPO" | tr "$RS_" '\n' | grep -v '^fix-99'"$US_" | cut -d "$US_" -f1)
case $old_entry in
  fix-99.[0-9]*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL the earlier entry is set aside as <id>.<when>: %q\n' "$old_entry" >&2 ;;
esac
eq '...and the earlier one still says what the first worktree allocated' 'alice_fix_99' \
  "$(wt_ledger_field "$LREPO" "$old_entry" slug)"
eq '...including where it was' "$LWT" "$(wt_ledger_field "$LREPO" "$old_entry" path)"

# Same path, different slug: a branch that edited runtime.slug has orphaned the old database.
WT_NAME=bob-renamed wt_runtime_state_set "$LWT2" bob_renamed 3901 derived .env.worktree.local ours none '' 2>/dev/null
eq 'a changed slug for the same worktree sets the old entry aside too' 3 "$(ledger_count)"
eq '...and the id now records the new slug' 'bob_renamed' "$(wt_ledger_field "$LREPO" fix-99 slug)"
eq '...and records the current name, not the set-aside one' 'bob-renamed' \
  "$(wt_ledger_field "$LREPO" fix-99 name)"

# FORGET removes exactly what it is named, and nothing a traversal name could reach.
wt_ledger_forget "$LREPO" '../HEAD' 2>"$TMP/ledger-err"
eq 'forgetting a traversal name is refused' 2 $?
contains '...and says so' 'not an entry name' "$(cat "$TMP/ledger-err")"
eq '...leaving what it pointed at alone' 1 "$([ -f "$LREPO/.git/HEAD" ] && echo 1 || echo 0)"
wt_ledger_forget "$LREPO" 'a/b' 2>/dev/null
eq 'forgetting a name containing / is refused' 2 $?
wt_ledger_forget "$LREPO" "$old_entry"
eq 'forgetting a named entry succeeds' 0 $?
eq '...and removes only that one' 2 "$(ledger_count)"
wt_ledger_field "$LREPO" "$old_entry" slug >/dev/null
eq '...which no longer reads' 1 $?
eq 'the live entry is untouched' 'bob_renamed' "$(wt_ledger_field "$LREPO" fix-99 slug)"
wt_ledger_forget "$LREPO" "$old_entry" 2>/dev/null
eq 'forgetting an entry that is not there is a failure (1)' 1 $?

# NO PARTIAL TRUST: an entry that is not wholly readable is neither listed nor read — and never
# deleted, since it may be an allocation a newer build wrote.
ledger_put() {  # $1 = entry name, $2... = records, each written RS-terminated
  local name=$1 rec
  shift
  : >"$LEDGER/$name"
  for rec in "$@"; do printf '%s%s' "$rec" "$RS_" >>"$LEDGER/$name"; done
}
ledger_names() {  # the entry names the enumeration emits, one line each, sorted
  wt_ledger_entries "$LREPO" | tr "$RS_" '\n' | cut -d "$US_" -f1 | sort
}
listed=$(ledger_names)
hdr="wtstate${US_}$WT_STATE_VERSION"
wtrec="worktree${US_}/gone/wt${US_}hand${US_}hand/made"
rtrec="rt${US_}hand_slug${US_}4000${US_}derived${US_}.e${US_}ours${US_}none${US_}${US_}1"
ledger_put foreign-version "wtstate${US_}999" "$wtrec" "$rtrec"
ledger_put headerless "$wtrec" "$rtrec"
ledger_put record-before-header "$wtrec" "$hdr" "$rtrec"
ledger_put rt-only "$hdr" "$rtrec"
ledger_put worktree-only "$hdr" "$wtrec"
ledger_put "${WT_LEDGER_TMP_PREFIX}half" "$hdr" "$wtrec" "$rtrec"
before=$(ledger_count)
eq 'enumeration lists only the entries that parse, never a temporary one' "$listed" "$(ledger_names)"
for bad in foreign-version headerless record-before-header rt-only worktree-only; do
  wt_ledger_field "$LREPO" "$bad" slug >/dev/null
  eq "an unparseable entry ($bad) reads as no entry (1)" 1 $?
done
wt_ledger_field "$LREPO" "${WT_LEDGER_TMP_PREFIX}half" slug >/dev/null
eq 'a half-written entry is not an entry name at all (2)' 2 $?
if [ "$(id -u)" != 0 ]; then
  ledger_put unreadable "$hdr" "$wtrec" "$rtrec"
  chmod 000 "$LEDGER/unreadable"
  wt_ledger_field "$LREPO" unreadable slug >/dev/null
  eq 'an unreadable entry reads as no entry (1)' 1 $?
  eq '...and is not enumerated' "$listed" "$(ledger_names)"
  chmod 600 "$LEDGER/unreadable"
  rm -f "$LEDGER/unreadable"
fi
eq 'reading the ledger deletes nothing, however little of it parses' "$before" "$(ledger_count)"
rm -f "$LEDGER"/foreign-version "$LEDGER"/headerless "$LEDGER"/record-before-header \
  "$LEDGER"/rt-only "$LEDGER"/worktree-only "$LEDGER/${WT_LEDGER_TMP_PREFIX}half"

# ENTRY NAMES: what a caller could use to reach outside the ledger is refused; what git can
# legitimately name a worktree is not. `..` INSIDE a name is only a traversal as a whole component.
for bad in '' . .. "${WT_LEDGER_TMP_PREFIX}abc"; do
  wt_ledger_field "$LREPO" "$bad" slug >/dev/null
  eq "reading entry name \"$bad\" is a caller error (2)" 2 $?
  wt_ledger_forget "$LREPO" "$bad" 2>/dev/null
  eq "forgetting entry name \"$bad\" is refused (2)" 2 $?
done
ledger_put 'v1..2' "$hdr" "$wtrec" "$rtrec"
eq 'an entry whose name merely contains .. reads' 'hand_slug' "$(wt_ledger_field "$LREPO" 'v1..2' slug)"
contains '...and is enumerated' "v1..2$US_" "$(wt_ledger_entries "$LREPO")"
wt_ledger_forget "$LREPO" 'v1..2'
eq '...and can be forgotten once torn down' 0 $?
wt_ledger_entries "$TMP" >/dev/null
eq 'enumerating outside any repository is a failure (1), not an empty ledger' 1 $?

# A CORRUPT ENTRY UNDER THIS ID cannot be shown to be this worktree's, so it is set aside, not
# overwritten.
ledger_put fix-99 "wtstate${US_}999" "corrupt${US_}bytes"
corrupt=$(cat "$LEDGER/fix-99")
before=$(ledger_count)
wt_runtime_state_set "$LWT2" bob_renamed 3901 derived .env.worktree.local ours none '' 2>/dev/null
eq 'an rt write over a corrupt entry keeps it' "$((before + 1))" "$(ledger_count)"
kept_corrupt=''
for f in "$LEDGER"/fix-99.*; do
  [ "$(cat "$f")" = "$corrupt" ] && kept_corrupt=$f
done
ne '...set aside byte-for-byte as <id>.<when>' '' "$kept_corrupt"
eq '...while the id records the allocation again' 'bob_renamed' "$(wt_ledger_field "$LREPO" fix-99 slug)"
rm -f "$kept_corrupt"

# A SET-ASIDE NAME ALREADY TAKEN is never overwritten: the next free suffix is used instead.
ledger_put fix-99 "$hdr" "worktree${US_}$LWT2${US_}fix-99${US_}bob/fix-99" \
  "rt${US_}bob_renamed${US_}3901${US_}derived${US_}.e${US_}ours${US_}none${US_}${US_}1234"
printf 'already here' >"$LEDGER/fix-99.1234"
wt_runtime_state_set "$LWT2" bob_suffixed 3903 derived .env.worktree.local ours none '' 2>/dev/null
eq 'a taken set-aside name is left as it was' 'already here' "$(cat "$LEDGER/fix-99.1234")"
eq '...and the earlier entry goes to the next suffix' 'bob_renamed' \
  "$(wt_ledger_field "$LREPO" fix-99.1234.1 slug)"
rm -f "$LEDGER/fix-99.1234" "$LEDGER/fix-99.1234.1"
unset hdr wtrec rtrec before listed bad corrupt kept_corrupt f

# A ledger that cannot be written warns and costs the rt write nothing.
if [ "$(id -u)" != 0 ]; then
  chmod 500 "$LEDGER"
  out=$(wt_runtime_state_set "$LWT2" bob_renamed 3902 derived .env.worktree.local ours none '' 2>"$TMP/ledger-err")
  eq 'an unwritable ledger does not fail the rt write' 0 $?
  eq '...prints nothing on stdout' '' "$out"
  contains '...and warns on stderr' 'ledger' "$(cat "$TMP/ledger-err")"
  eq '...while the state file took the write' '3902' "$(wt_runtime_state_get "$LWT2" port)"
  # A NEW slug needs the old entry set aside first; when that cannot happen the old entry is the
  # one kept, because it is the only record of its database.
  before=$(ledger_count)
  wt_runtime_state_set "$LWT2" carol_new_slug 3904 derived .env.worktree.local ours none '' 2>"$TMP/ledger-err"
  eq 'a set-aside that fails keeps the earlier entry under the id' 'bob_suffixed' \
    "$(wt_ledger_field "$LREPO" fix-99 slug)"
  eq '...writes nothing else' "$before" "$(ledger_count)"
  contains '...and says it could not set it aside' 'set aside' "$(cat "$TMP/ledger-err")"
  chmod 700 "$LEDGER"
fi

# The main checkout has no admin id, so there is nothing to key an entry on.
rm -rf "${LEDGER:?}"
wt_runtime_state_set "$LREPO" main_slug 3999 derived .e ours none '' 2>/dev/null
eq 'an rt write in the main checkout records no ledger entry' 0 "$(ledger_count)"
eq 'an absent ledger enumerates as no entries' '' "$(wt_ledger_entries "$LREPO")"

# ONLY A LINKED WORKTREE IS KEYED. Neither the `.claude/` fallback nor a git dir that merely sits
# in a directory called `worktrees` (no `gitdir` file) has an admin id to key on.
PLAINLWT=$TMP/plainlwt; mkdir -p "$PLAINLWT"
wt_runtime_state_set "$PLAINLWT" plain_slug 3998 derived .e ours none '' 2>/dev/null
eq 'an rt write outside git records no ledger entry' '' \
  "$(find "$PLAINLWT" -name "$WT_LEDGER_DIRNAME" 2>/dev/null)"
FAKECOMMON=$TMP/fakecommon
mkdir -p "$FAKECOMMON/worktrees"
git init -q --separate-git-dir "$FAKECOMMON/worktrees/lookalike" "$TMP/lookalike"
wt_runtime_state_set "$TMP/lookalike" lookalike_slug 3997 derived .e ours none '' 2>/dev/null
eq 'a git dir inside a worktrees directory but with no gitdir file records nothing' 1 \
  "$([ -e "$FAKECOMMON/$WT_LEDGER_DIRNAME" ] && echo 0 || echo 1)"

# An admin id is keyed on as git made it. `..` inside one is legitimate (older git kept a
# basename's dots as they were), so it is recorded; an id the readers could never name is warned
# about rather than written where nothing will look.
git init -q --separate-git-dir "$FAKECOMMON/worktrees/v1..2" "$TMP/dotted"
: >"$FAKECOMMON/worktrees/v1..2/gitdir"
wt_runtime_state_set "$TMP/dotted" dotted_slug 3996 derived .e ours none '' 2>/dev/null
eq 'an admin id containing .. is still recorded' 1 \
  "$([ -f "$FAKECOMMON/$WT_LEDGER_DIRNAME/v1..2" ] && echo 1 || echo 0)"
git init -q --separate-git-dir "$FAKECOMMON/worktrees/${WT_LEDGER_TMP_PREFIX}id" "$TMP/tmpnamed"
: >"$FAKECOMMON/worktrees/${WT_LEDGER_TMP_PREFIX}id/gitdir"
wt_runtime_state_set "$TMP/tmpnamed" tmpnamed_slug 3995 derived .e ours none '' 2>"$TMP/ledger-err"
eq 'an admin id that is not an entry name is not recorded' 1 \
  "$([ -e "$FAKECOMMON/$WT_LEDGER_DIRNAME/${WT_LEDGER_TMP_PREFIX}id" ] && echo 0 || echo 1)"
contains '...and says so' 'ledger' "$(cat "$TMP/ledger-err")"

# A PATH OR NAME THE RECORD FORMAT FOLDS — a space and non-ASCII survive, a newline becomes a
# space. Folding must not make a worktree look like someone else on its next session.
NLWT="$LREPO/.claude/worktrees/sp ace/né${NL_}wx"
git -C "$LREPO" worktree add -q "$NLWT" -b wt-nl 2>/dev/null
nlid=$(basename "$(wt_git "$NLWT" rev-parse --git-dir)")
WT_NAME="sp ace/né${NL_}wx"
wt_runtime_state_set "$NLWT" nl_slug 3994 derived .e ours none '' 2>/dev/null
eq 'a path with a space, non-ASCII and a newline is recorded, the newline folded' \
  "$LREPO/.claude/worktrees/sp ace/né wx" "$(wt_ledger_field "$LREPO" "$nlid" path)"
eq '...and so is the name' 'sp ace/né wx' "$(wt_ledger_field "$LREPO" "$nlid" name)"
wt_runtime_state_set "$NLWT" nl_slug 3993 derived .e ours none '' 2>/dev/null
eq '...and the next session replaces its entry instead of setting it aside' 1 "$(ledger_count)"
eq '...with the new allocation' 3993 "$(wt_ledger_field "$LREPO" "$nlid" port)"
git -C "$LREPO" worktree remove --force "$NLWT" 2>/dev/null
unset nlid

# git before 2.13 reported --git-common-dir relative to the TOP of the checkout even from a
# subdirectory; the ledger must still be found there.
mkdir -p "$LREPO/sub/dir"
eval "real_wt_git() $(declare -f wt_git | tail -n +2)"
wt_git() {
  if [ "${2-}" = rev-parse ] && [ "${3-}" = --git-common-dir ]; then printf '.git\n'; return 0; fi
  real_wt_git "$@"
}
eq 'the ledger is found from a subdirectory under old git too' "$LREPO/.git/$WT_LEDGER_DIRNAME" \
  "$(wt_ledger_dir "$LREPO/sub/dir")"
eval "wt_git() $(declare -f real_wt_git | tail -n +2)"
unset -f real_wt_git
unset WT_NAME old_entry

# The non-git fallback location, and a write that cannot succeed.
PLAINWT=$TMP/plainwt; mkdir -p "$PLAINWT"
case "$(wt_state_path "$PLAINWT")" in
  "$PLAINWT/.claude/worktree-bootstrap-state") pass=$((pass+1)) ;;
  *) fail=$((fail+1)); printf 'FAIL non-git state path: %q\n' "$(wt_state_path "$PLAINWT")" >&2 ;;
esac
wt_state_set "$PLAINWT" vendor install LA IA "done"
eq 'state round-trips outside a git repository too' 0 \
  "$(wt_state_is_done "$PLAINWT" vendor LA IA install; echo $?)"

if [ "$(id -u)" != 0 ]; then
  ROWT=$TMP/rowt; mkdir -p "$ROWT/.claude"
  chmod 500 "$ROWT/.claude"
  wt_state_set "$ROWT" vendor install LB IB "done"
  eq 'an unwritable state directory is a returned failure, not a crash' 1 $?
  eq '...and the dependency then reads as not done, so the work is redone' 1 \
    "$(wt_state_is_done "$ROWT" vendor LB IB install; echo $?)"
  chmod 700 "$ROWT/.claude"
fi

# The timestamp bootstrap records: recorded, and never part of the freshness
# decision — a clock cannot tell you whether a tree is correct.
wt_state_set "$SWT" vendor hardlink L6 I6 "done"
eq 'a state record carries a timestamp' yes \
  "$(tr "$RS_" '\n' < "$(wt_state_path "$SWT")" | grep '^dep' | tail -1 \
     | awk -F"$US_" '{print ($7 ~ /^[0-9]+$/) ? "yes" : "no:" $7}')"
eq '...and the status is still read from its own field, not the last one' 0 \
  "$(wt_state_is_done "$SWT" vendor L6 I6 hardlink; echo $?)"
eq '...including through wt_state_status' 'done' "$(wt_state_status "$SWT" vendor)"

# Checksums
eq 'the checksum of a string is stable' "$(wt_cksum_string 'composer install')" \
  "$(wt_cksum_string 'composer install')"
ne 'and differs when the command differs' "$(wt_cksum_string 'composer install')" \
  "$(wt_cksum_string 'composer install --no-scripts')"
eq 'an empty command has an empty checksum, never matching a present one' '' \
  "$(wt_cksum_string '')"
eq 'a missing file has an empty checksum' '' "$(wt_cksum_file "$TMP/nosuchlock")"
eq 'a file checksum is stable' "$(wt_cksum_file "$SREPO/f.txt")" "$(wt_cksum_file "$SREPO/f.txt")"
printf 'y\n' > "$TMP/other.txt"
ne 'and differs when the contents differ' "$(wt_cksum_file "$SREPO/f.txt")" \
  "$(wt_cksum_file "$TMP/other.txt")"
if [ "$(id -u)" != 0 ]; then
  printf 'z\n' > "$TMP/unreadable.txt"; chmod 000 "$TMP/unreadable.txt"
  eq 'an unreadable file has an empty checksum rather than a spurious match' '' \
    "$(wt_cksum_file "$TMP/unreadable.txt")"
  chmod 600 "$TMP/unreadable.txt"
fi

# ---------------------------------------------------------------------------
# The dependency engine
# ---------------------------------------------------------------------------
# A real repo with a real worktree, and a fake "package manager" that can be told to succeed,
# fail, hang, or record that it ran. Failure injection needs no real toolchain that way.

DREPO=$TMP/drepo
git init -q "$DREPO"
git -C "$DREPO" config user.email t@example.com
git -C "$DREPO" config user.name t
printf 'LOCKV1\n' > "$DREPO/composer.lock"
git -C "$DREPO" add composer.lock
git -C "$DREPO" commit -qm init
DWT=$DREPO/.claude/worktrees/dep1
git -C "$DREPO" worktree add -q "$DWT" -b wt-dep1 2>/dev/null

# shellcheck disable=SC2034
PROFILE_SHELL='' PROFILE_SHELLARGS=''
FAR=$(( $(date +%s) + 600 ))

dep_raw() {  # $1 = dir, $2 = lock, $3 = strategy, $4 = install, $5 = verify, $6 = copy as compact JSON
  printf '0%s%s1%s%s%s%s%s%s%s%s%s%s%s%s%s%s' \
    "$US_" "$RS_" "$US_" "$1" "$US_" "$2" "$US_" "$3" "$US_" "$4" "$US_" "$5" "$US_" "$US_" "${6-}" "$RS_"
}
ino() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }

# --- install ---------------------------------------------------------------
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf ok > vendor/marker' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'install: the command runs and populates the directory' 'ok' \
  "$(cat "$DWT/vendor/marker" 2>/dev/null)"
eq 'install: the dependency is recorded as done' 0 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'mkdir -p vendor && printf ok > vendor/marker')" install; echo $?)"

# Idempotence: a second run must do nothing at all, and say so.
printf 'TOUCHED' > "$DWT/vendor/marker"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'idempotence: a second run reports it is already up to date' 'already up to date' "$out"
eq 'idempotence: and does not re-run the install' 'TOUCHED' "$(cat "$DWT/vendor/marker")"

# Changing the install command invalidates it, even though the lockfile is untouched.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf v2 > vendor/marker' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a changed install command re-runs the dependency' 'v2' "$(cat "$DWT/vendor/marker")"

# --- failure injection: the install exits non-zero -------------------------
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'exit 1' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
rc=$?
eq 'a failing install does NOT fail the bootstrap' 0 "$rc"
contains '...and says what happened' 'install command failed' "$out"
eq '...and is recorded as not done' 1 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'exit 1')" install; echo $?)"
eq '...and, with no verify to say otherwise, as failed' failed "$(wt_state_status "$DWT" vendor)"

# --- verify decides, not the install's exit code ----------------------------
# A package manager that installs everything and then exits non-zero (one build script not yet
# allowed, a peer-dependency complaint) has still produced a usable tree. The counter file proves
# whether a later run re-ran the install.
CNT=$TMP/install-count
pending_all() { wt_bootstrap_pending "$1"; printf '%s' "$WT_PENDING"; }
pending_attemptable() { wt_bootstrap_pending "$1"; printf '%s' "$WT_PENDING_ATTEMPTABLE"; }
dep_line() {  # $1 = dir; the recorded dep record's fields, US shown as |
  local rec
  while IFS= read -r -d "$RS_" rec; do
    case $rec in "dep$US_$1$US_"*) printf '%s' "${rec//"$US_"/|}" ;; esac
  done <"$(wt_state_path "$DWT")"
}
WARNCMD="printf x >> $CNT; mkdir -p vendor && printf x > vendor/autoload.php; printf 'progress 1/2\\n'; printf '\\033[31mERR_FAKE_IGNORED_BUILDS\\033[0m one build \\302\\251 not allowed\\n' >&2; printf 'Done in 1s\\n\\n'; exit 1"
rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$WARNCMD" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'non-zero install, passing verify: recorded as warn' warn "$(wt_state_status "$DWT" vendor)"
eq '...which counts as present' 0 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" "$(wt_cksum_string "$WARNCMD")" install; echo $?)"
contains '...and says so' 'installed with warnings' "$out"
# The install's output is captured in the worktree's git dir, one file per dependency, and shown live.
CAPF=$(wt_install_capture_path "$DWT" vendor)
case $CAPF in "$(git -C "$DWT" rev-parse --absolute-git-dir)"/*) where=gitdir ;; *) where=$CAPF ;; esac
eq "...its output captured in the worktree's git dir" gitdir "$where"
contains '...holding what the install printed' 'progress 1/2' "$(cat "$CAPF" 2>/dev/null)"
contains '...and copied to the log' 'progress 1/2' "$out"
contains '...all of it, to the last line' 'Done in 1s' "$out"
eq '...leaving no follower marker behind' no "$([ -e "$CAPF.ended" ] && echo yes || echo no)"
rec=$(dep_line vendor)
contains '...recorded as warn' '|warn|' "$rec"
contains '...with the exit code and the error line, escapes and non-ASCII stripped' \
  '|1|ERR_FAKE_IGNORED_BUILDS one build  not allowed' "$rec"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...and a second run does not re-run the install' x "$(cat "$CNT")"
contains '...because it is up to date' 'already up to date' "$out"
# shellcheck disable=SC2034
PROFILE_PRESENT=1
eq '...nor is it pending' '' "$(pending_all "$DWT")"
status_items() { wt_bootstrap_pending "$1"; printf '%s' "${WT_STATUS_ITEMS//"$US_"/|}"; }
eq '...but it is a status item, with its recorded reason' \
  'warn|vendor|ERR_FAKE_IGNORED_BUILDS one build  not allowed' "$(status_items "$DWT")"

# --- the status line ------------------------------------------------------
# One helper renders every ending. A directory with no state, so no install changed anything.
SLW=$TMP/statusline
mkdir -p "$SLW"
status_line() {  # $1 = items (kind|name|detail lines), $2 = pending, $3 = attemptable, $4 = when, $5 = how
  WT_STATUS_ITEMS=${1//|/$US_} WT_PENDING=$2 WT_PENDING_ATTEMPTABLE=$3 \
    wt_bootstrap_status_line "$SLW" "$4" "${5-}"
}
ALL='standing|a|exit 1
missing|b|dirty
seed|databases|failed
warn|c|peer warning'
PEND=$'a\nb\ndatabases (seed: failed)'
ATT=$'b\ndatabases (seed: failed)'
out=$(status_line "$ALL" "$PEND" "$ATT" start)
contains 'status: each item named by state, missing before warnings, capped at three' \
  'not fully set up yet — a missing (install failed: exit 1), b missing (not installed yet), databases missing (seed: failed) and 1 more.' "$out"
contains '...and sends the session to /pitlane-finish, which would retry b' 'Run /pitlane-finish to complete it' "$out"
# shellcheck disable=SC2034  # read by wt_bootstrap_status_line
WT_STATUS_SHOWN=4
contains 'status: within the cap, a warning reads "ready with warnings"' \
  ', c ready with warnings (peer warning).' "$(status_line "$ALL" "$PEND" "$ATT" start)"
# shellcheck disable=SC2034  # read by wt_bootstrap_status_line
WT_STATUS_SHOWN=3
out=$(status_line "$ALL" "$PEND" "$ATT" start background)
contains 'status, background: what the run does reads as in progress' \
  'in the background — a missing (install failed: exit 1), b missing (still installing), databases missing (seeding)' "$out"
out=$(status_line "$ALL" "$PEND" "$ATT" start approval)
contains 'status, approval: held back' 'NOT run — a missing (install failed: exit 1), b missing (held back), databases missing (held back)' "$out"
out=$(status_line "$ALL" "$PEND" "$ATT" finish approval)
contains 'status, --finish held back: the approval line, with states' \
  "not run — the profile's commands are not approved in their current form — a missing (install failed: exit 1), b missing (held back)" "$out"
out=$(status_line "$ALL" "$PEND" "$ATT" finish)
contains 'status, --finish: what is left, and where the reason is' \
  'Pitlane: still not complete — a missing (install failed: exit 1), b missing (not installed; stderr says why)' "$out"
contains '...and a standing failure is retried only on the user'"'"'s word' '--retry-failed` only on the user' "$out"
out=$(status_line 'missing|b|dirty' b b finish)
eq 'status, --finish with nothing standing: no retry advice' 'Pitlane: still not complete — b missing (not installed; stderr says why).' "$out"
# Only failures that stand: /pitlane-finish would not retry them, so it is not offered as the fix.
out=$(status_line 'standing|a|error: registry unreachable' a '' start)
contains 'status, only standing failures: named with the reason' 'a missing (install failed: error: registry unreachable).' "$out"
lacks '...not sent to /pitlane-finish as if it would complete it' 'Run /pitlane-finish to complete it' "$out"
contains '...told /pitlane-finish retries only on the user'"'"'s word' '/pitlane-finish can retry on their word' "$out"
contains '...in words that fit one failure or several' 'An install that failed is not retried while its lockfile' "$out"
lacks '...never "that failure", which is wrong for two' 'That failure' "$out"
eq 'status, complete with a warning: not a bare "fully set up"' \
  'Pitlane: this worktree is set up, with warnings — c ready with warnings (peer warning).' \
  "$(status_line 'warn|c|peer warning' '' '' finish)"
contains '...and at start-up it is said, not swallowed' 'set up, with warnings — c ready with warnings' \
  "$(status_line 'warn|c|peer warning' '' '' start)"
eq 'status, complete and clean: silent at start-up' '' "$(status_line '' '' '' start)"
eq '...and "fully set up" from --finish' 'Pitlane: this worktree is fully set up.' "$(status_line '' '' '' finish)"
# A profile with runtime.serve names /pitlane-serve and the URL, so the session never reaches for
# the repo's own start command: the ONE line a complete worktree then prints, and a clause on the
# others — except the held-back line, where /pitlane-serve would refuse too.
serve_line() {  # $1 = items, $2 = pending, $3 = attemptable, $4 = how, $5 = url
  PROFILE_PRESENT=1 PROFILE_HAS_RUNTIME=1 PROFILE_RT_SERVE='bin/server --port={port}' WT_RUNTIME_URL=${5-} \
    status_line "$1" "$2" "$3" start "${4-}"
}
eq 'status, complete with a serve profile: one line naming /pitlane-serve and the URL' \
  "Pitlane: this worktree is set up. To run the app, use /pitlane-serve (it serves at http://localhost:4123), not the repo's own start command." \
  "$(serve_line '' '' '' '' http://localhost:4123)"
eq '...without a URL, the command alone' \
  "Pitlane: this worktree is set up. To run the app, use /pitlane-serve, not the repo's own start command." \
  "$(serve_line '' '' '' '' '')"
contains '...appended to a not-finished line' \
  "Run /pitlane-finish to complete it now (it has no time limit), or start a new session here. Until then, do not install dependencies or create databases by hand; those steps belong to the setup. To run the app, use /pitlane-serve (it serves at http://localhost:4123)" \
  "$(serve_line 'missing|b|dirty' b b '' http://localhost:4123)"
contains '...and to a background line' 'the background setup is doing it. To run the app, use /pitlane-serve' \
  "$(serve_line 'missing|b|dirty' b b background http://localhost:4123)"
contains '...and to a warnings line' 'tell the user if it matters for the task. To run the app' \
  "$(serve_line 'warn|c|peer warning' '' '' '' http://localhost:4123)"
contains '...and to a standing-failure line' 'Do not install dependencies by hand. To run the app' \
  "$(serve_line 'standing|a|exit 1' a '' '' http://localhost:4123)"
lacks '...but not to a held-back line' '/pitlane-serve' "$(serve_line 'missing|b|dirty' b b approval http://localhost:4123)"
eq '...and it stays one line' 1 "$(serve_line 'missing|b|dirty' b b '' http://localhost:4123 | wc -l | tr -d ' ')"
# An unapproved profile gets no app clause on ANY line — serve is a command the branch chose, and
# /pitlane-serve would refuse it — not even the clean one, which then stays silent.
eq 'status, unapproved, complete with a serve profile: silent' '' \
  "$(WT_APPROVAL=no serve_line '' '' '' '' http://localhost:4123)"
for how in '' background approval; do
  lacks "...nor on a not-finished line (how=${how:-none})" '/pitlane-serve' \
    "$(WT_APPROVAL=no serve_line 'missing|b|dirty' b b "$how" http://localhost:4123)"
done
lacks '...nor on a warnings line' '/pitlane-serve' \
  "$(WT_APPROVAL=no serve_line 'warn|c|peer warning' '' '' '' http://localhost:4123)"
lacks '...nor on a standing-failure line' '/pitlane-serve' \
  "$(WT_APPROVAL=no serve_line 'standing|a|exit 1' a '' '' http://localhost:4123)"
contains '...while an approved one keeps it' 'To run the app' \
  "$(WT_APPROVAL=yes serve_line '' '' '' '' http://localhost:4123)"
eq 'status, clean, a runtime-less profile with a stray serve: silent' '' \
  "$(PROFILE_PRESENT=1 PROFILE_HAS_RUNTIME=0 PROFILE_RT_SERVE=x status_line '' '' '' start)"
eq 'status, clean, no profile: silent even with a serve left in the environment' '' \
  "$(PROFILE_PRESENT=0 PROFILE_HAS_RUNTIME=1 PROFILE_RT_SERVE=x status_line '' '' '' start)"
contains 'status: a name the branch wrote is shown printable' 'x?[31m missing' \
  "$(status_line "missing|x"$'\033'"[31m|dirty" x x start)"
WT_STATUS_ITEMS='' WT_PENDING='' WT_PENDING_ATTEMPTABLE=''

# The walk reads each record once and decides from it: a record is current only for this lockfile,
# install command AND strategy, and only then is it done, a warning, or a failure that stands.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
SWCMD='true # status walk'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$SWCMD" '')
SWL=$(wt_cksum_file "$DWT/composer.lock"); SWI=$(wt_cksum_string "$SWCMD")
wt_state_set "$DWT" vendor hardlink "$SWL" "$SWI" "done"
eq 'walk: done, but for another strategy, is pending' vendor "$(pending_all "$DWT")"
eq '...as missing, with its recorded status' 'missing|vendor|done' "$(status_items "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" other-ick "done"
eq 'walk: done, but for another install command, is pending' 'missing|vendor|done' "$(status_items "$DWT")"
wt_state_set "$DWT" vendor install other-lck "$SWI" warn 1 why
eq 'walk: a warning for another lockfile is pending' 'missing|vendor|warn' "$(status_items "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" "$SWI" "done"
eq 'walk: done for this lockfile, command and strategy is no item' '' "$(status_items "$DWT")"
eq '...and not pending' '' "$(pending_all "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" "$SWI" failed 1 boom
eq 'walk: a failure for this lockfile, command and strategy stands' 'standing|vendor|boom' "$(status_items "$DWT")"
eq '...pending' vendor "$(pending_all "$DWT")"
eq '...but not attempted' '' "$(pending_attemptable "$DWT")"
wt_state_set "$DWT" vendor hardlink "$SWL" "$SWI" failed 1 boom
eq 'walk: a failure recorded for another strategy does not stand' 'missing|vendor|failed' "$(status_items "$DWT")"
eq '...so it is attempted' vendor "$(pending_attemptable "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" other-ick failed 1 boom
eq 'walk: nor one for another install command' vendor "$(pending_attemptable "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" "$SWI" failed 2 ''
eq 'walk: a failure with no error line is shown by its exit code' 'standing|vendor|exit 2' "$(status_items "$DWT")"
EIGHTY=$(printf '%080d' 0)
wt_state_set "$DWT" vendor install "$SWL" "$SWI" warn 1 "$EIGHTY"
eq 'walk: a reason of exactly 80 characters is shown whole' "warn|vendor|$EIGHTY" "$(status_items "$DWT")"
wt_state_set "$DWT" vendor install "$SWL" "$SWI" warn 1 "${EIGHTY}1"
item=$(status_items "$DWT"); detail=${item##*|}
eq 'walk: one character longer is cut to exactly 80' 80 "${#detail}"
eq '...its last three an ellipsis' "${EIGHTY:0:77}..." "$detail"
rm -f "$(wt_state_path "$DWT")"

# The reason is one bounded line of printable ASCII: nothing that could break the record.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
LONGCMD="mkdir -p vendor && touch vendor/autoload.php; printf 'error %0400d\\n' 0 >&2; exit 3"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$LONGCMD" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
rec=$(dep_line vendor)
reason=${rec##*|}
eq 'the recorded reason is length-capped' 160 "${#reason}"
contains '...with the exit code beside it' '|3|error 000' "$rec"
# The record's own separators, inside the part of the line that is kept.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install \
  "mkdir -p vendor && touch vendor/autoload.php; printf 'error \\037ab\\036c\\n' >&2; exit 3" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
rec=$(dep_line vendor)
eq 'separators in the error line are stripped, so the record still has its nine fields' 8 \
  "$(printf '%s' "$rec" | tr '|' '\n' | wc -l | tr -d ' ')"
eq '...leaving the text around them' 'error abc' "${rec##*|}"

# The error line is the LAST one that looks like an error...
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "echo 'error: first'; echo 'Error: second'; echo done; exit 1" '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'of two error lines, the last is recorded' 'Error: second' "$(dep_line vendor | sed 's/.*|//')"
# ...else the last non-empty line...
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "printf 'resolving...\\nstopped at step 3\\n\\n'; exit 1" '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'with no error-looking line, the last non-empty one is recorded' 'stopped at step 3' \
  "$(dep_line vendor | sed 's/.*|//')"
# ...and nothing at all when the install printed nothing.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'exit 1' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
rec=$(dep_line vendor)
eq 'a silent install records an empty reason after its exit code' '|failed|W|1|' \
  "$(printf '%s' "$rec" | sed 's/.*|failed|[0-9]*|/|failed|W|/')"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...and the message names only the exit code' 'stands (exit 1) —' "$out"

# Non-zero, and verify fails: failed, exactly as before.
rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"
FAILCMD="printf x >> $CNT; echo 'npm error ENOTFOUND registry' >&2; exit 1"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$FAILCMD" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'non-zero install, failing verify: failed' failed "$(wt_state_status "$DWT" vendor)"
contains '...the verify was run and said no' 'verify command failed' "$out"
contains '...recording what went wrong' '|1|npm error ENOTFOUND registry' "$(dep_line vendor)"
eq '...and it is pending' vendor "$(pending_all "$DWT")"

# The same failure is not paid for again.
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'an identical failure is not retried' x "$(cat "$CNT")"
contains '...and the run says the failure stands' 'the recorded failure stands' "$out"
contains '...and what would make a retry worth it' 'composer.lock or the install command changes' "$out"
contains '...naming it' 'npm error ENOTFOUND registry' "$out"
eq '...and keeps it recorded as failed' failed "$(wt_state_status "$DWT" vendor)"
contains '...with its reason intact' '|1|npm error ENOTFOUND registry' "$(dep_line vendor)"
eq '...still pending' vendor "$(pending_all "$DWT")"
eq '...but not something a run would attempt' '' "$(pending_attemptable "$DWT")"
# A deferred start-up run does not hand it to the background either.
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'a deferred run does not schedule a standing failure' 'to be installed in the background' "$out"

# A changed lockfile is a reason to try again.
printf 'LOCKV3\n' > "$DWT/composer.lock"
eq 'a changed lockfile makes it attemptable again' vendor "$(pending_attemptable "$DWT")"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a changed lockfile retries the install' xx "$(cat "$CNT")"
printf 'LOCKV1\n' > "$DWT/composer.lock"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
# ...and so is a changed command.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$FAILCMD # v2" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a changed install command retries the install' xxxx "$(cat "$CNT")"

# Non-zero with no verify configured: failed, and not retried either.
rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "printf x >> $CNT; mkdir -p vendor; exit 1" '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'non-zero install with no verify: failed even though it created the directory' failed \
  "$(wt_state_status "$DWT" vendor)"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...and not retried' x "$(cat "$CNT")"
out=$(WT_RETRY_FAILED=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...unless the run is told to retry failures' xx "$(cat "$CNT")"
lacks '...which then does not call the failure standing' 'the recorded failure stands' "$out"

# A hardlink that fell back to a failing install: the failure stands for the fallback too.
rm -rf "$DWT/vendor" "$DREPO/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "printf x >> $CNT; exit 2" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a failed fallback install is recorded failed' failed "$(wt_state_status "$DWT" vendor)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...and the fallback is not re-run' x "$(cat "$CNT")"
contains '...saying why' 'the recorded failure stands' "$out"
eq '...still recorded failed, not left at doing' failed "$(wt_state_status "$DWT" vendor)"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks '...nor deferred to the background' 'to be installed in the background' "$out"
eq '...and the deferral leaves it failed' failed "$(wt_state_status "$DWT" vendor)"
WT_RETRY_FAILED=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...though a run told to retry failures re-runs the fallback' xx "$(cat "$CNT")"
# Its failure was the fallback's: once the main checkout has the directory, the link is tried.
mkdir -p "$DREPO/vendor"; printf main > "$DREPO/vendor/autoload.php"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...and once the main checkout has it, the link is made' "done" "$(wt_state_status "$DWT" vendor)"
eq '...without the install' xx "$(cat "$CNT")"
contains '...said as a link' 'hardlinked from the main checkout' "$out"
rm -rf "$DREPO/vendor"

# An install that was STOPPED did not finish: it is retried, never recorded as a failure that
# stands, and verify does not get to call it good.
if command -v timeout >/dev/null 2>&1; then
  rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock install 'sleep 30' '')
  wt_bootstrap_deps "$DREPO" "$DWT" $(( $(date +%s) + 2 )) 2>/dev/null
  eq 'an install stopped by the budget is left to retry, not failed' dirty "$(wt_state_status "$DWT" vendor)"
fi
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
mkdir -p "$DWT/vendor"; : > "$DWT/vendor/autoload.php"
meminfo $((16 * GiB)) $((GiB / 2))
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'true' 'test -r vendor/autoload.php')
# shellcheck disable=SC2034  # read by the sourced guard
( WT_GUARD_SCOPE=''; WT_MEMINFO=$TMP/meminfo; export WT_MEMINFO
  wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" ) 2>/dev/null
eq 'an install the guard refused is not rescued by a verify that passes on an old tree' dirty \
  "$(wt_state_status "$DWT" vendor)"
rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"

# --- an install that changes tracked files ----------------------------------
# A package manager that writes into a tracked file (a placeholder line in a workspace file) leaves
# the worktree dirty. It is recorded and named, and never restored: the session may be editing too.
mkdir -p "$DWT/conf"
printf 'packages: []\n' > "$DWT/conf/work space.yaml"; printf 'a\n' > "$DWT/notes.txt"
printf 'ignored.log\n' > "$DWT/.gitignore"
git -C "$DWT" add conf notes.txt .gitignore && git -C "$DWT" commit -qm tracked
changed_recs() {  # every `changed` record in the state file, US shown as |
  local rec
  while IFS= read -r -d "$RS_" rec; do
    case $rec in "changed$US_"*) printf '%s\n' "${rec//"$US_"/|}" ;; esac
  done <"$(wt_state_path "$DWT")"
}
TOUCHCMD="mkdir -p vendor && touch vendor/autoload.php && printf 'placeholder: 1\\n' >> 'conf/work space.yaml'"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$TOUCHCMD" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'tracked: the install changing a tracked file is logged by name' \
  'the install changed tracked files: conf/work space.yaml' "$out"
eq '...recorded in the state, against its dependency' 'changed|vendor|conf/work space.yaml' "$(changed_recs)"
eq '...and read back by wt_install_changed_paths' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
contains '...and NOT restored' 'placeholder: 1' "$(cat "$DWT/conf/work space.yaml")"
eq '...while the install still counts as done' "done" "$(wt_state_status "$DWT" vendor)"
# An edit the session makes once the install is over is the session's, not the install's.
printf 'b\n' >> "$DWT/notes.txt"
eq '...a later edit by the session is never attributed to it' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
# A re-install that finds the path still dirty does not forget who dirtied it.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$TOUCHCMD # v2" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...a re-install keeps the earlier attribution while the path is still changed' \
  'changed|vendor|conf/work space.yaml' "$(changed_recs)"
lacks '...without claiming it changed it again, or taking the session'"'"'s edit' 'notes.txt' "$(changed_recs)$out"
# Restored by the user: it drops out of what is reported.
git -C "$DWT" checkout -q -- 'conf/work space.yaml' notes.txt
eq '...and a path the user restored is no longer reported' '' "$(wt_install_changed_paths "$DWT")"
eq '...and the read that found it restored drops the record, so git is not asked again' '' "$(changed_recs)"
# An install that finds a recorded path restored drops it too, and writes no empty record.
printf 'placeholder: 1\n' >> "$DWT/conf/work space.yaml"
wt_install_note_changes "$DWT" vendor '' 2>/dev/null
eq '...(a record to drop)' 'changed|vendor|conf/work space.yaml' "$(changed_recs)"
git -C "$DWT" checkout -q -- 'conf/work space.yaml'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && touch vendor/autoload.php # v3' 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...a re-install after the restore drops the record whole' '' "$(changed_recs)"
# A path in two dependencies' records is reported once.
printf 'placeholder: 2\n' >> "$DWT/conf/work space.yaml"
wt_install_note_changes "$DWT" other '' 2>/dev/null
eq '...a path two installs changed is reported once' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
git -C "$DWT" checkout -q -- . ; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# Pruning takes out only what git shows gone: a path still changed keeps its record, a record left
# with none goes, and every other record is carried through.
write_changed() {  # $@ = records, each `dir|path|path...`; a dep record is kept beside them
  local r out
  out=$(printf 'wtstate%s%s%s' "$US_" "$WT_STATE_VERSION" "$RS_")
  for r in "$@"; do out+=changed$US_${r//|/$US_}$RS_; done
  printf '%s' "$out" > "$(wt_state_path "$DWT")"
  wt_state_set "$DWT" vendor install L I "done"
}
printf 'placeholder: 3\n' >> "$DWT/conf/work space.yaml"
write_changed 'vendor|conf/work space.yaml|notes.txt' 'other|notes.txt'
eq 'prune: what is still changed is reported' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
eq '...the restored path leaves its record, and a record left empty goes' \
  'changed|vendor|conf/work space.yaml' "$(changed_recs)"
contains '...the dependency record is untouched' '|install|L|I|done|' "$(dep_line vendor)"
eq '...and a second read finds nothing to prune' 'changed|vendor|conf/work space.yaml' \
  "$(wt_install_changed_paths "$DWT" >/dev/null; changed_recs)"
if command -v flock >/dev/null 2>&1; then
  write_changed 'vendor|notes.txt'
  exec 7>"$(wt_state_path "$DWT").lock"; flock 7
  eq 'prune: while a run holds the worktree lock, the record is not rewritten' 'changed|vendor|notes.txt' \
    "$(wt_install_changed_paths "$DWT" >/dev/null; changed_recs)"
  exec 7>&-
  eq '...and once it is free, it is' '' "$(wt_install_changed_paths "$DWT" >/dev/null; changed_recs)"
fi
# A clean worktree pays nothing: with no `changed` record, not one process outside bash is started.
mkdir -p "$TMP/no-path"
collect_with_no_path() {  # run in a subshell: any process the read starts is "not found"
  # shellcheck disable=SC2123  # emptying the search path is the point
  PATH=$TMP/no-path
  wt_install_changed_collect "$DWT" ''
  printf 'rc=%s[%s]' "$?" "$WT_INSTALL_CHANGED"
}
write_changed
wt_state_path "$DWT" >/dev/null
eq 'no record: answered without starting a process' 'rc=0[]' "$(collect_with_no_path 2>&1)"
write_changed 'vendor'
eq '...nor for a record that names no path' 'rc=0[]' "$(collect_with_no_path 2>&1)"
write_changed 'vendor|notes.txt'
contains '...while one that names a path does start them (so the check above is not vacuous)' 'not found' \
  "$(collect_with_no_path 2>&1)"
# The status line asks git within the budget it is given; with none left it reports the record as
# stored, without asking, and prunes nothing.
SPENT=$(( $(date +%s) - 5 ))
write_changed 'vendor|notes.txt'
out=$( { WT_TRACKING_SKIP_LOGGED=''; wt_install_changed_paths "$DWT" "$SPENT"; } 2>&1 )
eq 'deadline spent: the record as stored, git not asked' notes.txt "$out"
eq '...nothing pruned' 'changed|vendor|notes.txt' "$(changed_recs)"
out=$(WT_STATUS_ITEMS='' WT_PENDING='' WT_PENDING_ATTEMPTABLE='' wt_bootstrap_status_line "$DWT" start '' "$SPENT" 2>&1)
contains 'status line: the start-up deadline reaches the changed-files read' 'an install changed 1 tracked file' "$out"
eq '...and with time to ask, git says it was restored, so a clean worktree starts silent' '' \
  "$(WT_STATUS_ITEMS='' WT_PENDING='' WT_PENDING_ATTEMPTABLE='' wt_bootstrap_status_line "$DWT" start '' "$FAR" 2>&1)"
eq '...and its record is gone' '' "$(changed_recs)"
git -C "$DWT" checkout -q -- . ; rm -f "$(wt_state_path "$DWT")"

# Already changed before the install: the change is the session's, never offered for a restore.
printf 'mine\n' >> "$DWT/conf/work space.yaml"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$TOUCHCMD" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'tracked: a path already changed before the install is not attributed to it' 'changed tracked files' "$out"
eq '...nor recorded' '' "$(changed_recs)"
eq '...nor reported' '' "$(wt_install_changed_paths "$DWT")"
git -C "$DWT" checkout -q -- . ; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# Staged and not in the working tree any more: still a change against HEAD.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "mkdir -p vendor && touch vendor/autoload.php && echo staged >> notes.txt && git add notes.txt" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'tracked: a change the install only staged is recorded' 'changed|vendor|notes.txt' "$(changed_recs)"
wt_install_restore "$DWT" notes.txt >/dev/null
eq '...and restoring it resets the index too, not only the file' '' "$(git -C "$DWT" status --porcelain -- notes.txt)"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# A staged rename names both sides, on a git that cannot turn rename detection off.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "mkdir -p vendor && touch vendor/autoload.php && git mv notes.txt moved.txt" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'tracked: a staged rename records the new path and the old one' "moved.txt${NL_}notes.txt" \
  "$(wt_install_changed_paths "$DWT" | LC_ALL=C sort)"
git -C "$DWT" mv moved.txt notes.txt; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# A newline in a name is folded by the record into a name that may be another file, so it is named
# in the log but never recorded; a control byte is shown quoted, never raw.
NLNAME="conf/nl${NL_}name"
printf 'x\n' > "$DWT/$NLNAME"; printf 'x\n' > "$DWT/conf/nl name"; printf 'x\n' > "$DWT/conf/esc"$'\033'"[31m"
git -C "$DWT" add conf && git -C "$DWT" commit -qm 'odd names'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "mkdir -p vendor && touch vendor/autoload.php && printf y >> 'conf/nl'\"\$(printf '\\nname')\" && printf y >> 'conf/esc'\"\$(printf '\\033')\"'[31m'" 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'tracked: the install did change the file with a newline in its name' "x${NL_}y" "$(cat "$DWT/$NLNAME")"
contains '...it is named in the log, quoted' "\$'conf/nl\\nname' cannot be recorded by name" "$out"
eq '...and never recorded, so never offered as the other file it would fold into' \
  "changed|vendor|conf/esc"$'\033'"[31m" "$(changed_recs)"
lacks '...an ESC never reaches the log raw' $'\033' "$out"
contains '...it is shown quoted instead' "\$'conf/esc\\E[31m'" "$out"
eq '...and quoted by wt_paths_display' "\$'conf/esc\\E[31m'" "$(wt_paths_display "$(wt_install_changed_paths "$DWT")")"
git -C "$DWT" checkout -q -- . ; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# Restoring is one literal path, and only one an install changed.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$TOUCHCMD && echo z >> notes.txt" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
printf 'mine\n' >> "$DWT/.gitignore"
out=$(wt_install_restore "$DWT" .gitignore); rc=$?
eq 'restore: a path no install changed is refused' 1 "$rc"
contains '...saying why' 'not a tracked file an install changed' "$out"
contains '...and left alone' 'mine' "$(cat "$DWT/.gitignore")"
out=$(wt_install_restore "$DWT" "conf/nl${NL_}name"); rc=$?
eq 'restore: a name with a control byte is refused' 1 "$rc"
contains '...shown quoted' "\$'conf/nl\\nname'" "$out"
eq 'restore: an empty path is refused' 1 "$(wt_install_restore "$DWT" '' >/dev/null; echo $?)"
out=$(wt_install_restore "$DWT" notes.txt); rc=$?
eq 'restore: a path an install changed is restored' 0 "$rc"
contains '...said so' 'restored notes.txt' "$out"
eq '...to its committed content' 'a' "$(cat "$DWT/notes.txt")"
eq '...and only that path' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
git -C "$DWT" checkout -q -- . ; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# The set operations compare whole lines as bytes, in the order given.
eq 'lines: in keeps the order of the lines, and treats * literally' "b${NL_}*" \
  "$(wt_lines_in "*${NL_}a${NL_}b" "b${NL_}x${NL_}*${NL_}")"
eq 'lines: not-in drops empty lines and keeps the rest in order' "x${NL_}c" \
  "$(wt_lines_not_in "a${NL_}b" "x${NL_}${NL_}a${NL_}c")"
eq 'lines: an empty set keeps every line' "a${NL_}b" "$(wt_lines_not_in '' "a${NL_}b")"
eq 'lines: nothing is in an empty set' '' "$(wt_lines_in '' "a${NL_}b")"

# Bounded: no budget left is "cannot tell", said once per run, never a status run with no limit.
SPENT=$(( $(date +%s) - 5 ))
out=$( { WT_TRACKING_SKIP_LOGGED=''; wt_tracked_changes "$DWT" "$SPENT"; echo "rc=$?"; wt_tracked_changes "$DWT" "$SPENT"; } 2>&1 )
contains 'status: no budget left means it cannot tell' 'rc=1' "$out"
eq '...said once, not per call' 1 "$(printf '%s\n' "$out" | grep -c 'not checking which tracked files')"
FAKEGIT=$TMP/fakegit
mkdir -p "$FAKEGIT"
REALGIT=$(command -v git)
# A git whose status hangs, and one too old for --no-optional-locks, put where the engine runs git.
printf '#!/bin/sh\ncase " $* " in *" status "*) sleep 5 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$FAKEGIT/slow"
printf '#!/bin/sh\ncase " $* " in *" --no-optional-locks "*) echo "unknown option" >&2; exit 129 ;; esac\nexec "%s" "$@"\n' "$REALGIT" > "$FAKEGIT/old"
chmod +x "$FAKEGIT/slow" "$FAKEGIT/old"
# shellcheck disable=SC2034  # all read by the sourced engine
out=$( { WT_GIT_OPTIONAL_LOCKS='' WT_TRACKING_SKIP_LOGGED='' WT_GIT_CMD=("$FAKEGIT/old")
  wt_tracked_changes "$DWT" "$FAR"; echo "rc=$?"; } 2>&1 )
contains 'status: a git without --no-optional-locks is not asked' 'rc=1' "$out"
contains '...and that is said, not silent' 'older than 2.15' "$out"
if command -v timeout >/dev/null 2>&1; then
  start=$(date +%s)
  # shellcheck disable=SC2034  # read by the sourced engine
  out=$( { WT_TRACKING_SKIP_LOGGED='' WT_GIT_CMD=("$FAKEGIT/slow")
    wt_tracked_changes "$DWT" $(( $(date +%s) + 1 )); echo "rc=$?"; } 2>&1 )
  contains 'status: one that outruns the budget is stopped and cannot tell' 'rc=1' "$out"
  contains '...said' 'git status took longer' "$out"
  eq '...within the budget, not after the slow status' yes "$([ $(( $(date +%s) - start )) -lt 4 ] && echo yes)"
  # The snapshot spent what was left: the install is not started on a budget of nothing.
  rm -f "$CNT"
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock install "printf x >> '$CNT'" '')
  # shellcheck disable=SC2034  # read by the sourced engine
  out=$( { WT_TRACKING_SKIP_LOGGED='' WT_GIT_CMD=("$FAKEGIT/slow")
    wt_bootstrap_deps "$DREPO" "$DWT" $(( $(date +%s) + 2 )); } 2>&1 )
  eq 'status: a snapshot that spent the budget leaves the install unstarted' '' "$(cat "$CNT" 2>/dev/null)"
  contains '...said' 'the budget ran out before the install could start' "$out"
  eq '...and left to retry' dirty "$(wt_state_status "$DWT" vendor)"
  rm -f "$CNT" "$(wt_state_path "$DWT")"
  # The changed-files read is bounded by the deadline it is given, and never past WT_STATUS_SECONDS
  # however far off that deadline is: a git that hangs costs a second here, not the hang.
  write_changed 'vendor|notes.txt'
  start=$(date +%s)
  # shellcheck disable=SC2034  # read by the sourced engine
  out=$( { WT_TRACKING_SKIP_LOGGED='' WT_GIT_CMD=("$FAKEGIT/slow")
    wt_install_changed_paths "$DWT" $(( $(date +%s) + 1 )); } 2>/dev/null )
  eq 'changed read: a git that outruns the deadline leaves the record as stored' notes.txt "$out"
  eq '...within the deadline' yes "$([ $(( $(date +%s) - start )) -lt 4 ] && echo yes)"
  start=$(date +%s)
  # shellcheck disable=SC2034  # read by the sourced engine
  out=$( { WT_TRACKING_SKIP_LOGGED='' WT_STATUS_SECONDS=1 WT_GIT_CMD=("$FAKEGIT/slow")
    wt_install_changed_paths "$DWT" "$FAR"; } 2>/dev/null )
  eq 'changed read: a far deadline is capped at WT_STATUS_SECONDS' notes.txt "$out"
  eq '...so it returns within it' yes "$([ $(( $(date +%s) - start )) -lt 4 ] && echo yes)"
  rm -f "$(wt_state_path "$DWT")"
fi

# Untracked and ignored files are what an install is for.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && touch vendor/autoload.php new.txt && echo x > ignored.log' 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'tracked: an install writing only untracked and ignored files reports nothing' 'changed tracked files' "$out"
eq '...and writes no record' '' "$(changed_recs)"
rm -rf "$DWT/vendor" "$DWT/new.txt" "$DWT/ignored.log"; rm -f "$(wt_state_path "$DWT")"

# An install that rewrites its own lockfile (npm updating package-lock.json): recorded against the
# lockfile as the install left it, so it is done after one run and not re-run on the next. The
# lockfile is tracked, so the rewrite is an install-changed file the user is told about.
rm -f "$CNT"
RWCMD="printf x >> '$CNT'; mkdir -p vendor && touch vendor/autoload.php && printf 'LOCKV1 normalised\\n' > composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$RWCMD" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'lockfile rewritten by its install: the rewrite happened' 'LOCKV1 normalised' "$(cat "$DWT/composer.lock")"
eq '...done after one run' "done" "$(wt_state_status "$DWT" vendor)"
eq '...recorded against the lockfile as the install left it' "$(wt_cksum_file "$DWT/composer.lock")" \
  "$(dep_line vendor | cut -d'|' -f4)"
eq '...so it is not pending' '' "$(pending_all "$DWT")"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...and not re-run' x "$(cat "$CNT")"
eq '...the lockfile listed as a tracked file the install changed' composer.lock "$(wt_install_changed_paths "$DWT")"
eq '...and recorded as it was before, too' "$(git -C "$DWT" show HEAD:composer.lock | cksum)" \
  "$(wt_state_dep_read "$DWT" vendor; printf '%s' "$WT_DEP_LCK_BEFORE")"
# The developer restores the lockfile the install rewrote: still done, not reinstalled (which would
# rewrite it again).
git -C "$DWT" checkout -q -- composer.lock
eq 'lockfile restored after its install rewrote it: still done' '' "$(pending_all "$DWT")"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...up to date' 'vendor: already up to date' "$out"
eq '...not re-run' x "$(cat "$CNT")"
eq '...and the lockfile stays as restored' LOCKV1 "$(cat "$DWT/composer.lock")"
# A genuinely different lockfile is neither: reinstalled.
printf 'LOCKV9\n' > "$DWT/composer.lock"
eq 'a lockfile neither as committed nor as the install left it: pending' vendor "$(pending_all "$DWT")"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...and reinstalled' xx "$(cat "$CNT")"
# A record from before the field existed (nine fields) still reads, and matches only as it says.
wt_state_set "$DWT" vendor install "$(wt_cksum_file "$DWT/composer.lock")" "$(wt_cksum_string "$RWCMD")" "done"
eq 'a record without the before field: done for its own lockfile' '' "$(pending_all "$DWT")"
eq '...read with that field empty' '' "$(wt_state_dep_read "$DWT" vendor; printf '%s' "$WT_DEP_LCK_BEFORE")"
git -C "$DWT" checkout -q -- composer.lock
eq '...and pending for another' vendor "$(pending_all "$DWT")"
# A donor's field is kept apart from it: both in one record.
wt_state_set "$DWT" vendor hardlink LCKAFTER ICK "done" '' '' /elsewhere/donor-a LCKBEFORE
wt_state_dep_read "$DWT" vendor
eq 'a record with a donor and a before field reads both' "/elsewhere/donor-a|LCKAFTER|LCKBEFORE" \
  "$WT_DEP_DONOR|$WT_DEP_LCK|$WT_DEP_LCK_BEFORE"
eq '...and is done for either lockfile' "0|0|1" \
  "$(wt_state_is_done "$DWT" vendor LCKAFTER ICK hardlink; echo $?)|$(wt_state_is_done "$DWT" vendor LCKBEFORE ICK hardlink; echo $?)|$(wt_state_is_done "$DWT" vendor OTHER ICK hardlink; echo $?)"
# Installed with warnings: the same.
git -C "$DWT" checkout -q -- composer.lock; rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "$RWCMD; exit 1" 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'lockfile rewritten by an install with warnings: warn' warn "$(wt_state_status "$DWT" vendor)"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...and not re-run either' x "$(cat "$CNT")"
eq '...recorded as it was before, too' "$(git -C "$DWT" show HEAD:composer.lock | cksum)" \
  "$(wt_state_dep_read "$DWT" vendor; printf '%s' "$WT_DEP_LCK_BEFORE")"
git -C "$DWT" checkout -q -- composer.lock
eq '...so with the lockfile restored nothing is pending' '' "$(pending_all "$DWT")"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...nor re-run' x "$(cat "$CNT")"
git -C "$DWT" checkout -q -- composer.lock; rm -rf "$DWT/vendor"; rm -f "$CNT" "$(wt_state_path "$DWT")"

# Where git cannot say, nothing is recorded, and nothing is captured into the working tree.
NOGIT=$TMP/nogit-wt
mkdir -p "$NOGIT"; printf 'L\n' > "$NOGIT/composer.lock"
# Without pipefail in the caller too: the engine must not depend on its entrypoint's options.
eq 'no git: wt_tracked_changes says it cannot tell' 1 "$(set +o pipefail; wt_tracked_changes "$NOGIT"; echo $?)"
eq '...the state falls back into the working tree' "$NOGIT/.claude/worktree-bootstrap-state" "$(wt_state_path "$NOGIT")"
eq '...so there is no capture path' '1:' "$(p=$(wt_install_capture_path "$NOGIT" vendor); echo "$?:$p")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install "mkdir -p vendor && echo nogit-progress" '')
out=$(wt_bootstrap_deps "$NOGIT" "$NOGIT" "$FAR" 2>&1)
eq '...the install still runs' "done" "$(wt_state_status "$NOGIT" vendor)"
contains '...its output still on stderr' 'nogit-progress' "$out"
eq '...and no install log is written inside the working tree' '' \
  "$(find "$NOGIT" -name 'worktree-bootstrap.install.*' 2>/dev/null)"
# With no git to ask, the record is reported as stored — each path once.
NGSTATE=$(wt_state_path "$NOGIT")
printf 'wtstate%s%s%schanged%svendor%sa%schanged%sother%sa%sb%s' "$US_" "$WT_STATE_VERSION" "$RS_" \
  "$US_" "$US_" "$RS_" "$US_" "$US_" "$US_" "$RS_" > "$NGSTATE"
eq 'no git: the stored record is printed as is, each path once' "a${NL_}b" "$(wt_install_changed_paths "$NOGIT")"
# A record the reader cannot vouch for is no record at all.
printf 'wtstate%s%s%schanged%svendor%sa%s' "$US_" "$((WT_STATE_VERSION + 1))" "$RS_" "$US_" "$US_" "$RS_" > "$NGSTATE"
eq 'changed: a state file of another version yields nothing' '' "$(wt_install_changed_recorded "$NOGIT")"
printf 'changed%svendor%sa%swtstate%s%s%s' "$US_" "$US_" "$RS_" "$US_" "$WT_STATE_VERSION" "$RS_" > "$NGSTATE"
eq 'changed: a record before the header yields nothing' '' "$(wt_install_changed_recorded "$NOGIT")"
printf 'wtstate%s%s%schanged%svendor%sa%s' "$US_" "$WT_STATE_VERSION" "$RS_" "$US_" "$US_" "$RS_" > "$NGSTATE"
eq '...while the same record after it is read' 'a' "$(wt_install_changed_recorded "$NOGIT")"
rm -f "$NGSTATE"
# shellcheck disable=SC2034
PROFILE_RAW=''

# --- failure injection: the install hangs past the budget ------------------
if command -v timeout >/dev/null 2>&1; then
  rm -rf "$DWT/vendor"
  NEAR=$(( $(date +%s) + 3 ))
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock install 'sleep 30' '')
  start=$(date +%s)
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$NEAR" 2>&1)
  rc=$?
  took=$(( $(date +%s) - start ))
  eq 'a hanging install is stopped rather than hanging the session' yes \
    "$([ "$took" -lt 15 ] && echo yes)"
  contains '...and says the budget ran out' 'was stopped' "$out"
  eq '...and leaves the session usable, returning success' 0 "$rc"
fi

# --- failure injection: no budget left at all ------------------------------
PAST=$(( $(date +%s) - 5 ))
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'printf SHOULDNOTRUN > /dev/null' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$PAST" 2>&1)
contains 'with the budget already spent, the dependency is deferred, not started' 'out of time' "$out"

# --- hardlink --------------------------------------------------------------
mkdir -p "$DREPO/vendor/pkg"
printf 'REAL\n' > "$DREPO/vendor/pkg/file.txt"
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'printf INSTALLED > /dev/null' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'hardlink: the tree appears in the worktree' 'REAL' "$(cat "$DWT/vendor/pkg/file.txt" 2>/dev/null)"
contains 'hardlink: and it is reported as a link, not an install' 'hardlinked from the main checkout' "$out"
# The point of hardlinking: the same inode, so 400 MB costs almost nothing.
eq 'hardlink: the file really is the same inode, not a copy' \
  "$(stat -c '%i' "$DREPO/vendor/pkg/file.txt" 2>/dev/null || stat -f '%i' "$DREPO/vendor/pkg/file.txt")" \
  "$(stat -c '%i' "$DWT/vendor/pkg/file.txt" 2>/dev/null || stat -f '%i' "$DWT/vendor/pkg/file.txt")"

# A nested dependency dir: its parent does not exist in a fresh worktree, and must be made for it.
mkdir -p "$DREPO/vendor/bundle/gems"
printf 'GEM\n' > "$DREPO/vendor/bundle/gems/g.rb"
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor/bundle composer.lock hardlink 'printf INSTALLED > /dev/null' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'hardlink: a nested dir is linked though its parent did not exist' 'GEM' \
  "$(cat "$DWT/vendor/bundle/gems/g.rb" 2>/dev/null)"
lacks '...without falling back to an install' 'could not hardlink' "$out"
eq '...the same inode' \
  "$(stat -c '%i' "$DREPO/vendor/bundle/gems/g.rb" 2>/dev/null || stat -f '%i' "$DREPO/vendor/bundle/gems/g.rb")" \
  "$(stat -c '%i' "$DWT/vendor/bundle/gems/g.rb" 2>/dev/null || stat -f '%i' "$DWT/vendor/bundle/gems/g.rb")"
# A copy that fails says why, in cp's words, rather than guessing at the filesystem.
if [ "$(id -u)" != 0 ]; then
  rm -rf "$DWT/vendor"; mkdir -p "$DWT/vendor"; chmod a-w "$DWT/vendor"
  out=$(wt_hardlink_dep "$DREPO" "$DWT" vendor/bundle composer.lock 2>&1)
  rc=$?
  chmod u+w "$DWT/vendor"
  eq 'hardlink: a copy that fails falls back to an install' 1 "$rc"
  contains '...and the log says what cp said' 'Permission denied' "$out"
  lacks '...not a guess at the filesystem' 'different filesystem' "$out"
fi
rm -rf "$DWT/vendor" "$DREPO/vendor/bundle"

# --- deps[].copy: paths a package manager rewrites in place are real copies ---
# composer rewrites vendor/composer/*.php and npm node_modules/.package-lock.json through the inode
# they share with the main checkout, so those paths are copied after the link and the rest stay linked.
mkdir -p "$DREPO/vendor/composer/sub"
printf 'MAIN-INSTALLED\n' > "$DREPO/vendor/composer/installed.json"
printf 'MAIN-SUB\n' > "$DREPO/vendor/composer/sub/map.php"
printf 'MAIN-LOCK\n' > "$DREPO/vendor/.package-lock.json"
main_installed=$(ino "$DREPO/vendor/composer/installed.json")
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'printf COPYLINK > /dev/null' '' '["composer",".package-lock.json","not-there"]')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'copy: the dir is still reported hardlinked' 'hardlinked from the main checkout' "$out"
eq '...the rest of it shares inodes with the main checkout' "$(ino "$DREPO/vendor/pkg/file.txt")" "$(ino "$DWT/vendor/pkg/file.txt")"
ne 'copy: a listed dir is a real copy' "$main_installed" "$(ino "$DWT/vendor/composer/installed.json")"
ne '...all the way down' "$(ino "$DREPO/vendor/composer/sub/map.php")" "$(ino "$DWT/vendor/composer/sub/map.php")"
ne 'copy: a listed file is a real copy' "$(ino "$DREPO/vendor/.package-lock.json")" "$(ino "$DWT/vendor/.package-lock.json")"
eq '...with the same bytes' 'MAIN-INSTALLED|MAIN-SUB|MAIN-LOCK' \
  "$(cat "$DWT/vendor/composer/installed.json")|$(cat "$DWT/vendor/composer/sub/map.php")|$(cat "$DWT/vendor/.package-lock.json")"
lacks 'copy: a listed path the dir does not have is no reason to install' 'installing instead' "$out"
eq '...and nothing is made up for it' no "$([ -e "$DWT/vendor/not-there" ] && echo yes || echo no)"
eq 'copy: no temporary copy is left behind' '' "$(cd "$DWT/vendor" && find . -name '*.wtcopy*')"
# What the experiment measured: an in-place write in the worktree. It must not reach the main checkout.
printf 'WORKTREE-WROTE\n' > "$DWT/vendor/composer/installed.json"
printf 'WORKTREE-WROTE\n' > "$DWT/vendor/.package-lock.json"
eq 'copy: an in-place write in the worktree leaves the main checkout alone' 'MAIN-INSTALLED|MAIN-LOCK' \
  "$(cat "$DREPO/vendor/composer/installed.json")|$(cat "$DREPO/vendor/.package-lock.json")"
eq '...which keeps its own inode' "$main_installed" "$(ino "$DREPO/vendor/composer/installed.json")"

# A listed path reached through a symlink could copy, or replace, something outside the dir: the
# link is dropped and the dir installed instead.
for shape in parent self; do
  rm -rf "$DWT/vendor" "$DREPO/vendor/linked"
  mkdir -p "$DREPO/vendor/real"; printf 'R\n' > "$DREPO/vendor/real/f"
  case $shape in
    parent) ln -s real "$DREPO/vendor/linked"; cpath='["linked/f"]' ;;
    self) ln -s real "$DREPO/vendor/linked"; cpath='["linked"]' ;;
  esac
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "mkdir -p vendor && printf SYMINSTALL > vendor/m # $shape" '' "$cpath")
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains "copy: a path through a symlink ($shape) is refused" 'is reached through a symlink — installing instead' "$out"
  eq '...and the dir is installed, not left half-linked' 'SYMINSTALL|no' \
    "$(cat "$DWT/vendor/m" 2>/dev/null)|$([ -e "$DWT/vendor/pkg" ] && echo yes || echo no)"
  eq '...the main checkout untouched' 'R' "$(cat "$DREPO/vendor/real/f")"
done
rm -rf "$DREPO/vendor/linked" "$DREPO/vendor/real"

# A list the validator would have refused is not acted on half-way either.
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf BADLIST > vendor/m' '' '["../../escape"]')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'copy: an unreadable list falls back to an install' 'not a list of paths inside it — installing instead' "$out"
eq '...which ran' 'BADLIST' "$(cat "$DWT/vendor/m" 2>/dev/null)"

# A copy that fails mid-way (an unreadable file) leaves no half-linked tree behind.
if [ "$(id -u)" != 0 ]; then
  rm -rf "$DWT/vendor"
  printf 'S\n' > "$DREPO/vendor/composer/secret"; chmod 000 "$DREPO/vendor/composer/secret"
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf CPFAIL > vendor/m' '' '["composer"]')
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  chmod 600 "$DREPO/vendor/composer/secret"
  contains 'copy: a copy that fails says so' 'could not copy composer' "$out"
  eq '...and installs over a cleared dir' 'CPFAIL|no' \
    "$(cat "$DWT/vendor/m" 2>/dev/null)|$([ -e "$DWT/vendor/pkg" ] && echo yes || echo no)"
  eq '...the main checkout untouched' 'MAIN-INSTALLED' "$(cat "$DREPO/vendor/composer/installed.json")"
  rm -f "$DREPO/vendor/composer/secret"
fi
# A worktree linked before its profile had a copy list — or by an older plugin — shares every file
# with the main checkout and has a `done` record. Each run repairs it, logging what it copied, and
# leaves the rest linked; once repaired, a run does nothing.
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'printf OLDLINK > /dev/null' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" >/dev/null 2>&1
eq 'repair: the old-style link shares the copy paths, as the fixture needs' yes \
  "$([ "$DWT/vendor/composer/installed.json" -ef "$DREPO/vendor/composer/installed.json" ] && echo yes)"
main_snap=$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json .package-lock.json)
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'printf OLDLINK > /dev/null' '' '["composer",".package-lock.json"]')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'repair: a done dir is still checked' 'already up to date' "$out"
contains '...its shared copy dir is made a real copy, and said so' 'composer shared its files with the main checkout — made a real copy' "$out"
contains '...and its shared copy file' '.package-lock.json shared its files with the main checkout' "$out"
ne '...the dir no longer shares' "$(ino "$DREPO/vendor/composer/installed.json")" "$(ino "$DWT/vendor/composer/installed.json")"
ne '...all the way down' "$(ino "$DREPO/vendor/composer/sub/map.php")" "$(ino "$DWT/vendor/composer/sub/map.php")"
ne '...nor the file' "$(ino "$DREPO/vendor/.package-lock.json")" "$(ino "$DWT/vendor/.package-lock.json")"
eq '...the rest stays linked' "$(ino "$DREPO/vendor/pkg/file.txt")" "$(ino "$DWT/vendor/pkg/file.txt")"
eq '...and the main checkout is untouched' "$main_snap" \
  "$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json .package-lock.json)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'repair: a second run has nothing to repair' 'made a real copy' "$out"
# A tree from before the plugin recorded anything: found present, repaired all the same.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
cp -al "$DREPO/vendor" "$DWT/vendor"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'repair: a present dir with no record is repaired too' 'composer shared its files with the main checkout' "$out"
ne '...really' "$(ino "$DREPO/vendor/composer/installed.json")" "$(ino "$DWT/vendor/composer/installed.json")"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks '...once' 'made a real copy' "$out"
eq '...the main checkout untouched' "$main_snap" \
  "$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json .package-lock.json)"
# A dir whose top level holds only directories is judged by what lies below.
rm -rf "$DWT/vendor"; cp -al "$DREPO/vendor" "$DWT/vendor"
out=$(wt_repair_shared_copy_paths "$DREPO" "$DWT" vendor '["composer/sub"]' 2>&1)
contains 'repair: a dir with only files further down is still found shared' 'composer/sub shared its files' "$out"
eq 'repair: an unshared dir is no reason to copy' '' "$(wt_repair_shared_copy_paths "$DREPO" "$DWT" vendor '["composer/sub"]' 2>&1)"
# A symlinked dir in the worktree is not repaired through: what it points at is not the worktree's.
rm -rf "$DWT/vendor"; ln -s "$DREPO/vendor" "$DWT/vendor"
out=$(wt_repair_shared_copy_paths "$DREPO" "$DWT" vendor '["composer"]' 2>&1)
contains 'repair: a symlinked dir is warned about' 'is a symlink in the worktree' "$out"
eq '...and nothing it points at is replaced' "$main_snap" \
  "$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json .package-lock.json)"
rm -f "$DWT/vendor"

# The main checkout's dir as a symlink: `cp -al` would copy the symlink, and the copy paths would be
# replaced wherever it points. Refused before any link, and installed instead.
SHARED=$TMP/shared-vendor
rm -rf "$SHARED"; mv "$DREPO/vendor" "$SHARED"; ln -s "$SHARED" "$DREPO/vendor"
shared_snap=$(cd "$SHARED" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json)
rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf SYMSRC > vendor/m' '' '["composer"]')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains "copy: a symlinked dir in the main checkout is not linked" "the main checkout's vendor is a symlink — installing instead" "$out"
eq '...the worktree gets a real install' 'SYMSRC|no' "$(cat "$DWT/vendor/m" 2>/dev/null)|$([ -L "$DWT/vendor" ] && echo yes || echo no)"
eq '...and nothing it points at changed' "$shared_snap" \
  "$(cd "$SHARED" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat composer/installed.json)"
rm -rf "$DWT/vendor"; rm -f "$DREPO/vendor"; mv "$SHARED" "$DREPO/vendor"
rm -rf "$DWT/vendor" "$DREPO/vendor/composer" "$DREPO/vendor/.package-lock.json"

# --- hardlink falls back when the lockfiles differ -------------------------
rm -rf "$DWT/vendor"
printf 'LOCKV2-DIFFERENT\n' > "$DWT/composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf FELLBACK > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a worktree whose lockfile differs is NOT given the main checkout tree' 'differs from the main checkout' "$out"
eq '...it gets a real install instead' 'FELLBACK' "$(cat "$DWT/vendor/m" 2>/dev/null)"
printf 'LOCKV1\n' > "$DWT/composer.lock"

# --- hardlink donors: another worktree with the same lockfile ------------------
# When the main checkout cannot give a hardlinked dir (its lockfile differs, it has none), a linked
# worktree whose identical lockfile is recorded `done` can. Every rule a donor must meet has a case
# here that links from the donor once the rule is dropped.
DONORS=$TMP/donors
DINSTALL='mkdir -p vendor && printf DINSTALLED > vendor/m'
DLOCK2=$(printf 'LOCKV2\n' | cksum)
DICK=$(wt_cksum_string "$DINSTALL")
mk_donor() {  # $1 = name; a linked worktree whose lockfile is LOCKV2 and whose vendor is filled
  local w=$DONORS/$1
  git -C "$DREPO" worktree add -q "$w" -b "wt-$1" 2>/dev/null
  printf 'LOCKV2\n' > "$w/composer.lock"
  mkdir -p "$w/vendor/pkg"; printf 'DONOR-%s\n' "$1" > "$w/vendor/pkg/file.txt"
}
donor_rec() {  # $1 = name, $2 = status, $3 = when, $4 = lock cksum, $5 = install cksum, $6 = strategy
  wt_state_join dep vendor "${6:-hardlink}" "${4:-$DLOCK2}" "${5:-$DICK}" "$2" "$3"
  printf 'wtstate%s%s%s%s%s' "$US_" "$WT_STATE_VERSION" "$RS_" "$WT_STATE_REC" "$RS_" \
    > "$(git -C "$DONORS/$1" rev-parse --absolute-git-dir)/worktree-bootstrap-state"
}
# Where the worktree's vendor came from: main, a donor's name, install, or none.
linked_from() {
  local f=$DWT/vendor/pkg/file.txt n
  [ "$(cat "$DWT/vendor/m" 2>/dev/null)" = DINSTALLED ] && { echo install; return; }
  [ -e "$f" ] || { echo none; return; }
  [ "$f" -ef "$DREPO/vendor/pkg/file.txt" ] && { echo main; return; }
  for n in "$DONORS"/*/; do
    n=${n%/}
    [ "$f" -ef "$n/vendor/pkg/file.txt" ] && { echo "${n##*/}"; return; }
  done
  echo copy
}
run_donor() {  # $1 = verify, $2 = copy; sets out
  rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$DINSTALL" "${1-}" "${2-}")
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
}
printf 'LOCKV2\n' > "$DWT/composer.lock"
mkdir -p "$DREPO/vendor/pkg"; printf 'REAL\n' > "$DREPO/vendor/pkg/file.txt"
dmain_snap=$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat pkg/file.txt)
mk_donor donor-a
donor_rec donor-a "done" 100
run_donor
eq 'donor: the lockfile differs from main, so the done sibling with the same one gives the tree' donor-a "$(linked_from)"
contains '...and says so' 'vendor: hardlinked from worktree donor-a (composer.lock differs from the main checkout)' "$out"
lacks '...not an install' 'installing instead' "$out"
eq '...the main checkout untouched' "$dmain_snap" \
  "$(cd "$DREPO/vendor" && find . -type f -exec ls -i {} + | LC_ALL=C sort; cat pkg/file.txt)"
wt_state_dep_read "$DWT" vendor
eq '...recorded done, naming the donor' "done|$DONORS/donor-a" "$WT_DEP_STATUS|$WT_DEP_DONOR"
# In this shell, not a $(...): a subshell's exit would release a lock left held.
rm -rf "$DWT/vendor"
wt_hardlink_dep "$DREPO" "$DWT" vendor composer.lock '' "$DLOCK2" "$DICK" '' "$FAR" 2>/dev/null
eq '...the donor lock is not left held' 0 \
  "$( (exec 5>"$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)/worktree-bootstrap-state.lock"; flock -n 5); echo $?)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...and a second run finds it up to date' 'already up to date' "$out"

for st in warn failed doing dirty; do
  donor_rec donor-a "$st" 100
  run_donor
  eq "donor: a sibling recorded $st is not used" install "$(linked_from)"
done
contains 'donor: with none to use, the old message stands' 'composer.lock differs from the main checkout — installing instead' "$out"

donor_rec donor-a "done" 100 "$(printf 'LOCKV1\n' | cksum)"
run_donor
eq 'donor: a sibling whose lockfile changed since its install is not used' install "$(linked_from)"
# A sibling whose install rewrote its lockfile matches ours by the lockfile as it was before.
donor_rec_before() {  # $1 = lock cksum as the install left it, $2 = as it was before
  wt_state_join dep vendor hardlink "$1" "$DICK" "done" 100 '' '' '' "$2"
  printf 'wtstate%s%s%s%s%s' "$US_" "$WT_STATE_VERSION" "$RS_" "$WT_STATE_REC" "$RS_" \
    > "$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)/worktree-bootstrap-state"
}
donor_rec_before REWRITTEN "$DLOCK2"
run_donor
eq 'donor: a sibling recorded against our lockfile as it was before its install is used' donor-a "$(linked_from)"
donor_rec_before REWRITTEN OTHERBEFORE
run_donor
eq '...one matching neither is not' install "$(linked_from)"
donor_rec donor-a "done" 100
printf 'LOCKV3\n' > "$DONORS/donor-a/composer.lock"
run_donor
eq 'donor: a sibling whose lockfile now differs from ours is not used' install "$(linked_from)"
printf 'LOCKV2\n' > "$DONORS/donor-a/composer.lock"
donor_rec donor-a "done" 100 '' "$(wt_cksum_string 'composer install --no-dev')"
run_donor
eq 'donor: a sibling installed by another command is not used' install "$(linked_from)"
donor_rec donor-a "done" 100 '' '' install
run_donor
eq 'donor: a sibling whose record is of another strategy is not used' install "$(linked_from)"

donor_rec donor-a "done" 100
git -C "$DREPO" config branch.wt-donor-a.merge refs/pull/7/head
run_donor
eq "donor: a sibling on a pull request's ref is not used" install "$(linked_from)"
git -C "$DREPO" config --unset branch.wt-donor-a.merge
mk_donor pr-123
donor_rec pr-123 "done" 200
run_donor
eq 'donor: a pull-request worktree is not used, though it is the most recent' donor-a "$(linked_from)"
git -C "$DREPO" worktree remove --force "$DONORS/pr-123"
# A sibling started from a pull request's worktree (wt_pr_origin_mark) is one, whatever its name and
# branch: it is on that PR's commit, and its install ran that PR's package scripts.
DMARK=$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)/pitlane-pr-origin
wt_pr_origin_mark "$DONORS/donor-a" pr-7 "$(git -C "$DONORS/donor-a" rev-parse HEAD)"
eq 'donor: (fixture) the marker is written' yes "$([ -f "$DMARK" ] && echo yes || echo no)"
run_donor
eq "donor: a sibling started from a pull request's worktree is not used" install "$(linked_from)"
rm -f "$DMARK"
run_donor
eq '...and without the marker it is again' donor-a "$(linked_from)"

mv "$DONORS/donor-a/vendor" "$TMP/donor-real"; ln -s "$TMP/donor-real" "$DONORS/donor-a/vendor"
run_donor
eq 'donor: a symlinked dir is not used' install "$(linked_from)"
lacks '...not even tried' 'is a symlink' "$out"
rm "$DONORS/donor-a/vendor"; mkdir -p "$DONORS/donor-a/vendor"
run_donor
eq 'donor: an empty dir is not used' install "$(linked_from)"
rmdir "$DONORS/donor-a/vendor"; mv "$TMP/donor-real" "$DONORS/donor-a/vendor"
# A nested dir under a symlinked parent: the link would read through it.
mkdir -p "$TMP/donor-parent/bundle/pkg"; printf 'B\n' > "$TMP/donor-parent/bundle/pkg/file.txt"
mv "$DONORS/donor-a/vendor" "$TMP/donor-real"; ln -s "$TMP/donor-parent" "$DONORS/donor-a/vendor"
wt_state_join dep vendor/bundle hardlink "$DLOCK2" "$DICK" "done" 100
printf 'wtstate%s%s%s%s%s' "$US_" "$WT_STATE_VERSION" "$RS_" "$WT_STATE_REC" "$RS_" \
  > "$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)/worktree-bootstrap-state"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor/bundle composer.lock hardlink "$DINSTALL" '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'donor: a dir under a symlinked parent is not used' 'hardlinked from worktree' "$out"
rm "$DONORS/donor-a/vendor"; mv "$TMP/donor-real" "$DONORS/donor-a/vendor"; rm -rf "$TMP/donor-parent"
donor_rec donor-a "done" 100

# Being set up (or torn down) right now: its bootstrap lock is held, so it is skipped, not waited for.
exec 5>"$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)/worktree-bootstrap-state.lock"
flock -n 5
run_donor
exec 5>&-
eq 'donor: a sibling whose bootstrap lock is held is not used' install "$(linked_from)"

mk_donor donor-b
donor_rec donor-b "done" 200
run_donor
eq 'donor: of two, the most recent done is chosen' donor-b "$(linked_from)"
donor_rec donor-a "done" 300
run_donor
eq '...whichever that is' donor-a "$(linked_from)"
donor_rec donor-b "done" 300
run_donor
eq '...ties by path' donor-a "$(linked_from)"
donor_rec donor-a warn 300
WT_DONOR_SCAN_MAX=1 run_donor
eq 'donor: the scan stops at WT_DONOR_SCAN_MAX worktrees' install "$(linked_from)"
WT_DONOR_SCAN_MAX=2 run_donor
eq '...and finds the one within it' donor-b "$(linked_from)"
git -C "$DREPO" worktree remove --force "$DONORS/donor-b"
donor_rec donor-a "done" 100

# The verify is run in the donor, against the donor: {worktree} is the donor's path there.
run_donor 'test -f {worktree}/vendor/pkg/file.txt'
eq 'donor: a sibling passing the verify is used' donor-a "$(linked_from)"
run_donor 'test -f vendor/pkg/absent'
eq 'donor: a sibling failing the verify is not used' install "$(linked_from)"
WT_APPROVAL=no run_donor 'test -f vendor/pkg/file.txt'
eq 'donor: with a verify that may not run, no sibling is used' none "$(linked_from)"
lacks '...and its verify is not tried' 'not running' "$out"
WT_APPROVAL=no run_donor ''
eq '...nor with no verify: an unapproved worktree takes from no other' none "$(linked_from)"
contains '...and says so' "composer.lock differs from the main checkout, and a pull request's or unapproved worktree links from no other worktree — installing instead" "$out"

# Copy paths are unshared from the DONOR: an in-place write in this worktree must not reach it.
mkdir -p "$DONORS/donor-a/vendor/composer"; printf 'DONOR-INSTALLED\n' > "$DONORS/donor-a/vendor/composer/installed.json"
donor_installed=$(ino "$DONORS/donor-a/vendor/composer/installed.json")
run_donor '' '["composer"]'
eq 'donor copy: linked from the donor' donor-a "$(linked_from)"
ne '...its copy path is a real copy, not the donor inode' "$donor_installed" "$(ino "$DWT/vendor/composer/installed.json")"
printf 'WORKTREE-WROTE\n' > "$DWT/vendor/composer/installed.json"
eq '...so a write here leaves the donor alone' "DONOR-INSTALLED|$donor_installed" \
  "$(cat "$DONORS/donor-a/vendor/composer/installed.json")|$(ino "$DONORS/donor-a/vendor/composer/installed.json")"
# A link made before the copy list existed: repaired against the donor its record names.
rm -rf "$DWT/vendor"; cp -al "$DONORS/donor-a/vendor" "$DWT/vendor"
wt_state_set "$DWT" vendor hardlink "$DLOCK2" "$DICK" "done" '' '' "$DONORS/donor-a"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'donor repair: a done dir still sharing with its donor is repaired' 'composer shared its files with worktree donor-a — made a real copy' "$out"
ne '...really' "$donor_installed" "$(ino "$DWT/vendor/composer/installed.json")"
eq '...the rest stays linked' donor-a "$(linked_from)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks '...once' 'made a real copy' "$out"
rm -rf "$DONORS/donor-a/vendor/composer"

# The main checkout, when it can give the tree, is still the source.
printf 'LOCKV1\n' > "$DWT/composer.lock"; printf 'LOCKV1\n' > "$DONORS/donor-a/composer.lock"
donor_rec donor-a "done" 100 "$(printf 'LOCKV1\n' | cksum)"
run_donor
eq 'donor: a lockfile equal to main links from main, a donor or not' main "$(linked_from)"
contains '...and says so' 'hardlinked from the main checkout' "$out"
printf 'LOCKV2\n' > "$DWT/composer.lock"; printf 'LOCKV2\n' > "$DONORS/donor-a/composer.lock"
donor_rec donor-a "done" 100

# The main checkout with no dir at all: a donor gives it.
mv "$DREPO/vendor" "$TMP/main-vendor"
run_donor
eq 'donor: main has no dir, the donor gives it' donor-a "$(linked_from)"
contains '...and says why' '(the main checkout has no vendor to link from)' "$out"
mv "$TMP/main-vendor" "$DREPO/vendor"

# A checkout that no longer points back at its registration is not that worktree.
cp "$DONORS/donor-a/.git" "$TMP/donor-a.git"
printf 'gitdir: %s\n' "$TMP/nowhere" > "$DONORS/donor-a/.git"
run_donor
eq 'donor: a checkout whose .git points elsewhere is not used' install "$(linked_from)"
cp "$TMP/donor-a.git" "$DONORS/donor-a/.git"
# A registration whose checkout was deleted by hand is no donor.
mv "$DONORS/donor-a" "$TMP/donor-a-moved"
run_donor
eq 'donor: a sibling whose checkout is gone is not used' install "$(linked_from)"
mv "$TMP/donor-a-moved" "$DONORS/donor-a"
run_donor
eq '...and is used once it is back' donor-a "$(linked_from)"

# The main checkout with no lockfile, or with its dir a symlink, cannot give the tree: a donor can.
mv "$DREPO/composer.lock" "$TMP/main-lock"
run_donor
eq 'donor: main has no lockfile, the donor gives it' donor-a "$(linked_from)"
contains '...and says why' '(the main checkout has no composer.lock)' "$out"
mv "$TMP/main-lock" "$DREPO/composer.lock"
mv "$DREPO/vendor" "$TMP/main-vendor"; ln -s "$TMP/main-vendor" "$DREPO/vendor"
run_donor
eq "donor: main's dir is a symlink, the donor gives it" donor-a "$(linked_from)"
contains '...and says why' "(the main checkout's vendor is a symlink)" "$out"
rm "$DREPO/vendor"; mv "$TMP/main-vendor" "$DREPO/vendor"

# git 2.48's relative paths: the donor's .git names its admin dir relative to the checkout.
DADMIN=$(git -C "$DONORS/donor-a" rev-parse --absolute-git-dir)
cp "$DONORS/donor-a/.git" "$TMP/donor-a.git"
printf 'gitdir: %s\n' "$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$DADMIN" "$DONORS/donor-a")" \
  > "$DONORS/donor-a/.git"
run_donor
eq 'donor: a .git holding a relative gitdir is still that worktree' donor-a "$(linked_from)"
cp "$TMP/donor-a.git" "$DONORS/donor-a/.git"

# A name that only starts like a pull request's is an ordinary worktree.
mk_donor pr-x
donor_rec pr-x "done" 200
run_donor
eq 'donor: a worktree named pr-x is not a pull request' pr-x "$(linked_from)"
git -C "$DREPO" worktree remove --force "$DONORS/pr-x"

# A detached HEAD cannot be told apart from a pull request's checkout.
git -C "$DONORS/donor-a" checkout -q --detach
run_donor
eq 'donor: a sibling on a detached HEAD is not used' install "$(linked_from)"
git -C "$DONORS/donor-a" checkout -q wt-donor-a

# A pull request's worktree takes from no other: their trees would share inodes both ways.
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/9/head
run_donor
eq "donor: a pull request's worktree links from no sibling" install "$(linked_from)"
contains "...and says it installs its own copy" "vendor: a pull request's worktree installs its own copy" "$out"
# The link step's own refusal stays, behind the one above.
rm -rf "$DWT/vendor"
out=$(wt_hardlink_dep "$DREPO" "$DWT" vendor composer.lock '' "$DLOCK2" "$DICK" '' "$FAR" 2>&1); hl_rc=$?
eq "...and asked to link it directly, it still refuses a donor" "1|none" "$hl_rc|$(linked_from)"
contains '...saying so' "pull request's or unapproved worktree links from no other worktree" "$out"
git -C "$DREPO" config --unset branch.wt-dep1.merge

# The verify needs time to run: with none left the donor is skipped, not trusted unverified.
rm -rf "$DWT/vendor"
hl_rc=0
wt_hardlink_dep "$DREPO" "$DWT" vendor composer.lock '' "$DLOCK2" "$DICK" 'true' "$(( $(date +%s) - 1 ))" \
  2>/dev/null || hl_rc=$?
eq 'donor: with the budget spent, a verify-gated donor is skipped' "1|none" "$hl_rc|$(linked_from)"

# Every path that gives up after a donor was chosen lets go of the donor's lock.
donor_lock_free() {
  ( exec 5>"$DADMIN/worktree-bootstrap-state.lock"; flock -n 5 ) && echo free || echo held
}
hl_run() {  # $1 = dir, $2 = verify; in this shell, so a lock left held stays held
  hl_rc=0
  wt_hardlink_dep "$DREPO" "$DWT" "$1" composer.lock '' "$DLOCK2" "$DICK" "${2-}" "$FAR" 2>"$TMP/hl.log" \
    || hl_rc=$?
  hl_log=$(cat "$TMP/hl.log")
}
# The dir appears while the donor is being verified: left alone, and the lock released.
rm -rf "$DWT/vendor"
hl_run vendor "mkdir -p '$DWT/vendor'"
eq 'donor: a dir that appears after the donor is chosen is left alone' 2 "$hl_rc"
contains '...said so' 'already present in the worktree' "$hl_log"
eq '...and the donor lock is released' free "$(donor_lock_free)"
rm -rf "$DWT/vendor"

# cp -al failing: a shim that refuses -al, so the fallback install can still run.
mkdir -p "$TMP/nocp"
# shellcheck disable=SC2016  # the shim's own "$1" and "$@", expanded when it runs
printf '#!/bin/sh\n[ "$1" = -al ] && { echo "cp: refused" >&2; exit 1; }\nexec %s "$@"\n' "$(command -v cp)" \
  > "$TMP/nocp/cp"
chmod +x "$TMP/nocp/cp"
PATH=$TMP/nocp:$PATH hl_run vendor
eq 'donor: a cp -al that fails falls back to an install' 1 "$hl_rc"
contains '...said so' 'could not hardlink (cp: refused)' "$hl_log"
eq '...and the donor lock is released' free "$(donor_lock_free)"
PATH=$TMP/nocp:$PATH run_donor
eq '...the install runs' install "$(linked_from)"

# A nested dir: its donor record and tree.
mkdir -p "$DONORS/donor-a/vendor/bundle/pkg"; printf 'B\n' > "$DONORS/donor-a/vendor/bundle/pkg/file.txt"
wt_state_join dep vendor/bundle hardlink "$DLOCK2" "$DICK" "done" 100
printf 'wtstate%s%s%s%s%s' "$US_" "$WT_STATE_VERSION" "$RS_" "$WT_STATE_REC" "$RS_" \
  > "$DADMIN/worktree-bootstrap-state"
# Its parent cannot be made: the worktree's vendor is a file.
rm -rf "$DWT/vendor"; printf 'x\n' > "$DWT/vendor"
hl_run vendor/bundle
eq 'donor: a parent that cannot be made falls back to an install' 1 "$hl_rc"
contains '...said so' 'could not create its parent directory' "$hl_log"
eq '...and the donor lock is released' free "$(donor_lock_free)"
# Its parent is a symlink in this worktree: the link would land wherever that points.
rm -f "$DWT/vendor"; mkdir -p "$TMP/donor-elsewhere"; ln -s "$TMP/donor-elsewhere" "$DWT/vendor"
hl_run vendor/bundle
eq 'donor: a parent symlinked in the worktree falls back to an install' 1 "$hl_rc"
contains '...said so' 'not a plain path inside the worktree' "$hl_log"
eq '...nothing landed where it points' '' "$(ls -A "$TMP/donor-elsewhere")"
eq '...and the donor lock is released' free "$(donor_lock_free)"
rm -f "$DWT/vendor"; rm -rf "$TMP/donor-elsewhere" "$DONORS/donor-a/vendor/bundle"
donor_rec donor-a "done" 100

# The repair, when the donor its record names is gone: nothing to compare with, nothing said.
mkdir -p "$DWT/vendor/composer"; printf 'OWN\n' > "$DWT/vendor/composer/installed.json"
wt_state_set "$DWT" vendor hardlink "$DLOCK2" "$DICK" "done" '' '' "$DONORS/vanished"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$DINSTALL" '' '["composer"]')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1); rc=$?
eq 'donor repair: a vanished donor fails nothing' 0 "$rc"
contains '...the dir is up to date' 'already up to date' "$out"
lacks '...and no repair is claimed' 'shared its files' "$out"
lacks '...nor a failure' 'could not' "$out"
# The repair with the main checkout lacking the dir: the donor alone is compared with.
mv "$DREPO/vendor" "$TMP/main-vendor"
mkdir -p "$DONORS/donor-a/vendor/composer"; printf 'DONOR-INSTALLED\n' > "$DONORS/donor-a/vendor/composer/installed.json"
rm -rf "$DWT/vendor"; cp -al "$DONORS/donor-a/vendor" "$DWT/vendor"
wt_state_set "$DWT" vendor hardlink "$DLOCK2" "$DICK" "done" '' '' "$DONORS/donor-a"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'donor repair: with main lacking the dir, the donor is repaired against' 'composer shared its files with worktree donor-a — made a real copy' "$out"
ne '...really' "$(ino "$DONORS/donor-a/vendor/composer/installed.json")" "$(ino "$DWT/vendor/composer/installed.json")"
wt_state_set "$DWT" vendor hardlink "$DLOCK2" "$DICK" "done" '' '' "$DONORS/vanished"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1); rc=$?
eq '...and with the donor gone too, nothing fails' "0|" "$rc|$(printf '%s' "$out" | grep -E 'shared its files|could not')"
mv "$TMP/main-vendor" "$DREPO/vendor"
rm -rf "$DONORS/donor-a/vendor/composer" "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

# --- a linked dir whose lockfile changed is installed fresh, not over the link ------
# The install appends to files the link shares, as a package's own script may write in place: run
# over the linked tree, it would write into the tree the dir was linked from.
RINSTALL='mkdir -p vendor/pkg && printf FRESH >> vendor/pkg/file.txt && { [ ! -f vendor/locked/f ] || printf FRESH >> vendor/locked/f; } && printf DINSTALLED > vendor/m'
relink() {  # $1 = the worktree's lockfile; vendor linked afresh and recorded done; sets out
  rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
  printf '%s\n' "$1" > "$DWT/composer.lock"
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$RINSTALL" '')
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
}
# A PATH holding every command on ours but flock, in $NOFLOCK: stock macOS.
make_noflock_bin() {
  local path_dirs pd exe
  NOFLOCK=$TMP/noflock-bin
  [ ! -d "$NOFLOCK" ] || return 0
  mkdir -p "$NOFLOCK"
  IFS=: read -r -a path_dirs <<<"$PATH"
  for pd in "${path_dirs[@]}"; do
    for exe in "$pd"/*; do
      [ -x "$exe" ] || continue
      case ${exe##*/} in flock) continue ;; esac
      [ -e "$NOFLOCK/${exe##*/}" ] || ln -s "$exe" "$NOFLOCK/${exe##*/}" 2>/dev/null
    done
  done
}
tree_snap() { (cd "$1" || exit 1; find . -type f -exec ls -i {} + | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort); }
present() { [ -e "$1" ] && echo present || echo absent; }
printf 'STALE\n' > "$DREPO/vendor/stale.txt"; printf 'STALE\n' > "$DONORS/donor-a/vendor/stale.txt"

relink LOCKV1
eq 'relink: linked from the main checkout first' main "$(linked_from)"
rmain=$(tree_snap "$DREPO/vendor")
printf 'LOCKV3\n' > "$DWT/composer.lock"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'relink: at start-up with installs deferred, the install waits for the background run' 'vendor: to be installed in the background' "$out"
lacks '...and so does the removal' 'removing the linked copy' "$out"
eq '...the linked dir is left as it is' main "$(linked_from)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'relink: the run that installs removes the linked dir first' \
  'vendor: composer.lock changed since it was linked — removing the linked copy and installing fresh' "$out"
eq '...and installs into a fresh dir' 'FRESH|DINSTALLED|absent' \
  "$(cat "$DWT/vendor/pkg/file.txt")|$(cat "$DWT/vendor/m")|$(present "$DWT/vendor/stale.txt")"
eq '...no file of which is a link any more' '' "$(find "$DWT/vendor" -type f -links +1)"
eq "...while the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
eq '...recorded done' "done" "$(wt_state_status "$DWT" vendor)"

donor_rec donor-a "done" 100 '' "$(wt_cksum_string "$RINSTALL")"
relink LOCKV2
eq 'relink: linked from a donor first' donor-a "$(linked_from)"
rdonor=$(tree_snap "$DONORS/donor-a/vendor")
rmain=$(tree_snap "$DREPO/vendor")
printf 'LOCKV3\n' > "$DWT/composer.lock"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'relink: a donor-linked dir whose lockfile changed is removed first too' \
  'vendor: composer.lock changed since it was linked — removing the linked copy and installing fresh' "$out"
eq '...and installed fresh' 'FRESH|DINSTALLED|absent' \
  "$(cat "$DWT/vendor/pkg/file.txt")|$(cat "$DWT/vendor/m")|$(present "$DWT/vendor/stale.txt")"
eq '...sharing no inode' '' "$(find "$DWT/vendor" -type f -links +1)"
eq "...the donor's tree kept every byte and inode" "$rdonor" "$(tree_snap "$DONORS/donor-a/vendor")"
eq "...and so did the main checkout's" "$rmain" "$(tree_snap "$DREPO/vendor")"

# A dir that was installed shares nothing: the install reconciles it in place, as it always has.
relink LOCKV3
eq 'relink: a dir no tree can give is installed' install "$(linked_from)"
printf 'OWN\n' > "$DWT/vendor/keep.txt"
printf 'LOCKV4\n' > "$DWT/composer.lock"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'relink: an installed dir whose lockfile changed is not removed' 'removing the linked copy' "$out"
eq '...the install runs over it in place' 'OWN|FRESHFRESH' "$(cat "$DWT/vendor/keep.txt")|$(cat "$DWT/vendor/pkg/file.txt")"

# Without the dependency's lock another session may be installing into the dir: left linked.
relink LOCKV1
printf 'LOCKV3\n' > "$DWT/composer.lock"
rmain=$(tree_snap "$DREPO/vendor")
exec 7>"$(wt_lock_path "$DREPO" vendor)"; flock -n 7
out=$(WT_LOCK_WAIT=0 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
exec 7>&-
contains 'relink: without the lock a linked dir is neither removed nor installed over' \
  'another process holds its lock — not installing over files it shares' "$out"
eq '...it stays linked, the install not run' main "$(linked_from)"
eq "...the main checkout's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"
eq '...and it is retried next run' dirty "$(wt_state_status "$DWT" vendor)"
# Without flock nothing is serialised at all: the dir is cleared and installed, or it never would be.
make_noflock_bin
out=$(PATH=$NOFLOCK WT_FLOCK_WARNED=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'relink: with no flock on PATH the linked dir is still removed first' \
  'removing the linked copy and installing fresh' "$out"
eq '...and installed fresh' "done|absent" "$(wt_state_status "$DWT" vendor)|$(present "$DWT/vendor/stale.txt")"
eq "...the main checkout's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"

# The lock could not even be opened (a symlinked lock file): said as such, not as another holder.
relink LOCKV1
printf 'LOCKV3\n' > "$DWT/composer.lock"
rmain=$(tree_snap "$DREPO/vendor")
rlock=$(wt_lock_path "$DREPO" vendor)
mv "$rlock" "$TMP/relink-lock-real"; ln -s "$TMP/relink-lock-real" "$rlock"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
rm -f "$rlock"; mv "$TMP/relink-lock-real" "$rlock"
contains 'relink: a lock that cannot be opened is named as that' \
  'vendor: composer.lock changed since it was linked, but its lock could not be opened' "$out"
lacks '...not as another holder' 'another process holds its lock' "$out"
eq '...the dir stays linked, the install not run' "main|absent" "$(linked_from)|$(present "$DWT/vendor/m")"
eq "...the main checkout's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"
eq '...and it is retried next run' dirty "$(wt_state_status "$DWT" vendor)"

# The main checkout itself, by any path that resolves to it, is never cleared: its tree is the source.
ln -s "$DREPO" "$TMP/main-alias"
out=$(wt_clear_linked_dep "$DREPO" "$TMP/main-alias" vendor composer.lock 0 2>&1); rc=$?
eq 'relink: a worktree that resolves to the main checkout removes nothing' "0|" "$rc|$out"
eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
out=$(wt_clear_linked_dep "$DREPO" "$DREPO/" vendor composer.lock 0 2>&1); rc=$?
eq '...nor does the main checkout named as itself' "0|" "$rc|$out"
eq "...still untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"
rm -f "$TMP/main-alias"

if [ "$(id -u)" != 0 ]; then
  # A walk that cannot see every file fails closed: an installed dir with an unreadable subdir is
  # treated as linked (here the lock is held elsewhere, so it is reported and left alone).
  relink LOCKV3
  eq 'relink: a dir no tree can give is installed (for the walk test)' install "$(linked_from)"
  mkdir -p "$DWT/vendor/sealed"; printf 'S\n' > "$DWT/vendor/sealed/f"; chmod 000 "$DWT/vendor/sealed"
  out=$(wt_clear_linked_dep "$DREPO" "$DWT" vendor composer.lock 1 2>&1); rc=$?
  chmod 755 "$DWT/vendor/sealed"
  eq 'relink: an unreadable subdir counts as linked' 1 "$rc"
  contains '...and the dir is not installed over' 'another process holds its lock' "$out"
  eq '...nor removed' "present|S" "$(present "$DWT/vendor/m")|$(cat "$DWT/vendor/sealed/f")"
  out=$(wt_clear_linked_dep "$DREPO" "$DWT" vendor composer.lock 1 2>&1); rc=$?
  eq '...while the same dir, readable and sharing nothing, is left for the install' "0|" "$rc|$out"

  # The rename aside fails, into the git dir and beside the dir (both read-only): the tree and the
  # record stay whole.
  ADMIN=$(wt_removed_dep_admin_dir "$DWT")
  relink LOCKV1
  printf 'LOCKV3\n' > "$DWT/composer.lock"
  rwt=$(tree_snap "$DWT/vendor")
  mkdir -p "$ADMIN"
  chmod 555 "$DWT" "$ADMIN"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  chmod 755 "$DWT" "$ADMIN"
  contains 'relink: a linked dir that cannot be moved aside says so' 'vendor: could not move the linked copy aside to remove it (' "$out"
  eq '...every file of it is still there, unchanged' "$rwt" "$(tree_snap "$DWT/vendor")"
  eq '...the install does not run' absent "$(present "$DWT/vendor/m")"
  eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
  eq '...and it is not done, so the next run retries' dirty "$(wt_state_status "$DWT" vendor)"
  eq '...nothing was left beside it' '' "$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)"
  eq '...nor in the git dir' '' "$(ls -A "$ADMIN")"

  # The removal of the moved-aside copy fails part-way: no half tree is left at vendor itself, and
  # what is left sits in the worktree's git dir, where git does not list it.
  mkdir -p "$DREPO/vendor/locked"; printf 'L\n' > "$DREPO/vendor/locked/f"
  relink LOCKV1
  chmod 555 "$DWT/vendor/locked"
  rmain=$(tree_snap "$DREPO/vendor")
  printf 'LOCKV3\n' > "$DWT/composer.lock"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains 'relink: a moved-aside copy that cannot be removed says so' \
    "vendor: could not remove the linked copy moved aside to $ADMIN/vendor." "$out"
  eq '...the dir itself is gone, not half there' absent "$(present "$DWT/vendor")"
  leftover=$(cd "$ADMIN" && ls -Ad vendor.* 2>/dev/null)
  ne "...the leftover sits in the worktree's git dir" '' "$leftover"
  eq '...not beside the dir' '' "$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)"
  eq '...so git lists nothing of it' '' "$(git -C "$DWT" status --porcelain --untracked-files=all -- . ':!composer.lock')"
  eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
  eq '...and it is not done, so the next run installs' dirty "$(wt_state_status "$DWT" vendor)"
  chmod 755 "$ADMIN/$leftover/locked"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains '...which removes the leftover' "vendor: removed $ADMIN/$leftover, a tree an earlier run left aside" "$out"
  eq '...and installs into a fresh dir' "done|DINSTALLED|absent|absent" \
    "$(wt_state_status "$DWT" vendor)|$(cat "$DWT/vendor/m")|$(present "$DWT/vendor/locked")|$(present "$ADMIN/$leftover")"
  eq "...main's tree still untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"

  # The git dir cannot take it (read-only here; on another device below): moved aside beside the
  # dir instead, as before, and the next run's sweep finds it there.
  relink LOCKV1
  chmod 555 "$DWT/vendor/locked" "$ADMIN"
  printf 'LOCKV3\n' > "$DWT/composer.lock"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  chmod 755 "$ADMIN"
  contains 'relink: with the git dir read-only the copy is moved aside beside the dir' \
    "vendor: could not remove the linked copy moved aside to $DWT/.vendor.pitlane-removed." "$out"
  eq '...nothing went into the git dir' '' "$(ls -A "$ADMIN")"
  leftover=$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)
  ne '...the leftover sits beside the dir' '' "$leftover"
  chmod 755 "$DWT/$leftover/locked"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains '...and the next run removes it there' "vendor: removed $DWT/$leftover, a tree an earlier run left aside" "$out"
  eq '...and installs' "done|absent" "$(wt_state_status "$DWT" vendor)|$(present "$DWT/$leftover")"

  # A git dir on another device: never `mv`ed into, which would copy the whole tree.
  FAKESTAT=$TMP/fakestat-bin
  mkdir -p "$FAKESTAT"
  # shellcheck disable=SC2016  # the fake's own script, expanded when it runs
  printf '#!/bin/sh\nfor a; do p=$a; done\nprintf "%%s\\n" "$p" | cksum | cut -d" " -f1\n' > "$FAKESTAT/stat"
  chmod +x "$FAKESTAT/stat"
  eq 'relink: (fixture) the fake stat gives two paths two devices' 1 \
    "$(PATH=$FAKESTAT:$PATH wt_same_device "$DWT" "$ADMIN"; echo $?)"
  eq '...while the real one gives the worktree and its git dir one' 0 "$(wt_same_device "$DWT" "$ADMIN"; echo $?)"
  relink LOCKV1
  chmod 555 "$DWT/vendor/locked"
  printf 'LOCKV3\n' > "$DWT/composer.lock"
  out=$(PATH=$FAKESTAT:$PATH wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains 'relink: with the git dir on another device the copy is moved aside beside the dir' \
    "vendor: could not remove the linked copy moved aside to $DWT/.vendor.pitlane-removed." "$out"
  eq '...nothing went into the git dir' '' "$(ls -A "$ADMIN")"
  leftover=$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)
  chmod 755 "$DWT/$leftover/locked"

  # The sweep looks in both places, and takes only names it makes for this dir.
  mkdir -p "$ADMIN/vendor.77.1/pkg" "$ADMIN/node_modules.77.1" "$ADMIN/vendor.77.x"
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains 'relink: the sweep removes a leftover beside the dir' "vendor: removed $DWT/$leftover," "$out"
  contains '...and one in the git dir' "vendor: removed $ADMIN/vendor.77.1," "$out"
  eq "...leaving what is not this dir's" "absent|absent|present|present" \
    "$(present "$DWT/$leftover")|$(present "$ADMIN/vendor.77.1")|$(present "$ADMIN/node_modules.77.1")|$(present "$ADMIN/vendor.77.x")"
  rm -rf "$ADMIN/node_modules.77.1" "$ADMIN/vendor.77.x"
  rm -rf "$DREPO/vendor/locked"

  # A copy left in the git dir is no work of the developer's: teardown removes the worktree, and the
  # copy goes with its git dir.
  TRM=$TMP/trm
  git init -q "$TRM"
  git -C "$TRM" config user.email t@example.com
  git -C "$TRM" config user.name t
  printf 'vendor/\n' > "$TRM/.gitignore"
  printf 'LOCKV1\n' > "$TRM/composer.lock"
  git -C "$TRM" add .gitignore composer.lock
  git -C "$TRM" commit -qm init
  mkdir -p "$TRM/vendor/pkg" "$TRM/vendor/locked"
  printf 'MAIN\n' > "$TRM/vendor/pkg/file.txt"; printf 'L\n' > "$TRM/vendor/locked/f"
  TWT=$TRM/.claude/worktrees/tr1
  git -C "$TRM" worktree add -q "$TWT" -b tr1 2>/dev/null
  # shellcheck disable=SC2034
  PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$RINSTALL" '')
  wt_bootstrap_deps "$TRM" "$TWT" "$FAR" >/dev/null 2>&1
  eq 'teardown: (fixture) vendor is linked from the main checkout' yes \
    "$([ "$TWT/vendor/pkg/file.txt" -ef "$TRM/vendor/pkg/file.txt" ] && echo yes || echo no)"
  printf 'LOCKV2\n' > "$TWT/composer.lock"
  git -C "$TWT" commit -qam lock2
  git -C "$TRM" branch -q tr1-kept tr1
  chmod 555 "$TWT/vendor/locked"
  out=$(wt_bootstrap_deps "$TRM" "$TWT" "$FAR" 2>&1)
  TADMIN=$(git -C "$TWT" rev-parse --absolute-git-dir)
  contains 'teardown: (fixture) the moved-aside copy could not be removed' 'could not remove the linked copy moved aside' "$out"
  ne '...and is left in the git dir' '' "$(ls -A "$TADMIN/pitlane-removed" 2>/dev/null)"
  chmod -R u+w "$TADMIN/pitlane-removed"
  eq '...where git status lists nothing' '' "$(git -C "$TWT" status --porcelain --untracked-files=all)"
  rc=0
  ( cd "$TRM" && printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s","reason":"session_exit","cwd":"%s"}' "$TWT" "$TRM" \
    | bash "$HERE/teardown.sh" >/dev/null 2>"$TMP/trm-err" ) || rc=$?
  eq 'teardown: the worktree is removed, not held for the copy' "0|absent|absent" "$rc|$(present "$TWT")|$(present "$TADMIN")"
  lacks '...and nothing says it holds work' 'holds work' "$(cat "$TMP/trm-err")"
  eq "...the main checkout's tree untouched" 'MAIN|L' "$(cat "$TRM/vendor/pkg/file.txt")|$(cat "$TRM/vendor/locked/f")"

  # The same, with the copy in the git dir still read-only (a Go module cache is): teardown exits 0.
  TWT2=$TRM/.claude/worktrees/tr2
  git -C "$TRM" worktree add -q "$TWT2" -b tr2 2>/dev/null
  wt_bootstrap_deps "$TRM" "$TWT2" "$FAR" >/dev/null 2>&1
  printf 'LOCKV2\n' > "$TWT2/composer.lock"
  git -C "$TWT2" commit -qam lock2
  git -C "$TRM" branch -q tr2-kept tr2
  chmod 555 "$TWT2/vendor/locked"
  wt_bootstrap_deps "$TRM" "$TWT2" "$FAR" >/dev/null 2>&1
  TADMIN2=$(git -C "$TWT2" rev-parse --absolute-git-dir)
  ne 'teardown, read-only leftover: (fixture) it is in the git dir' '' "$(ls -A "$TADMIN2/pitlane-removed" 2>/dev/null)"
  rc=0
  ( cd "$TRM" && printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s","reason":"session_exit","cwd":"%s"}' "$TWT2" "$TRM" \
    | bash "$HERE/teardown.sh" >/dev/null 2>"$TMP/trm-err2" ) || rc=$?
  chmod -R u+w "$TADMIN2" 2>/dev/null
  eq 'teardown, read-only leftover: exits 0' 0 "$rc"
  eq '...the checkout and its git dir are removed' "absent|absent" "$(present "$TWT2")|$(present "$TADMIN2")"
  eq '...so git no longer lists it' '' "$(git -C "$TRM" worktree list --porcelain | grep -F "$TWT2")"
  lacks '...with no failure from git' 'Permission denied' "$(cat "$TMP/trm-err2")"
  lacks '...and nothing says it holds work' 'holds work' "$(cat "$TMP/trm-err2")"
  eq "...the main checkout's tree untouched" 'MAIN|L' "$(cat "$TRM/vendor/pkg/file.txt")|$(cat "$TRM/vendor/locked/f")"
fi
rm -f "$DREPO/vendor/stale.txt" "$DONORS/donor-a/vendor/stale.txt"

# --- a pull request's worktree never links its hardlink deps: it copies main's, or installs -------
# A linked tree shares inodes with main both ways: the PR's own scripts would write into main's files.
# With main's lockfile it takes a real copy of main's tree; with another, it installs.
relink LOCKV1
eq 'pr: (fixture) an ordinary worktree with main'"'"'s lockfile still links from main' main "$(linked_from)"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
rmain=$(tree_snap "$DREPO/vendor")
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq "pr: with main's lockfile, a pull request's worktree copies main's tree" copy "$(linked_from)"
contains '...and says why, once' \
  "vendor: a pull request's worktree copies the main checkout's rather than link it — a linked one would share files with the main checkout both ways" "$out"
eq '...once' 1 "$(printf '%s\n' "$out" | grep -c "rather than link it")"
contains '...and what it cost' 'vendor: copied from the main checkout in ' "$out"
lacks '...not linked from main' 'hardlinked from' "$out"
lacks '...nor installed' 'installing' "$out"
eq '...the install never ran' absent "$(present "$DWT/vendor/m")"
eq '...no file of it shares an inode' '' "$(find "$DWT/vendor" -type f -links +1)"
eq "...every byte of main's" "$(cd "$DREPO/vendor" && find . -type f -exec cksum {} + | LC_ALL=C sort)" \
  "$(cd "$DWT/vendor" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
eq '...no temp left in the git dir or beside the dir' '|' \
  "$(ls -A "$(wt_removed_dep_admin_dir "$DWT")" 2>/dev/null)|$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)"
wt_state_dep_read "$DWT" vendor
eq '...recorded done as its own copy, spelled as an artifact'"'"'s is' "done|own-copy" "$WT_DEP_STATUS|$WT_DEP_STRATEGY"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...which the next run finds up to date' 'vendor: already up to date' "$out"
lacks '...without saying it again' 'rather than link it' "$out"
PROFILE_PRESENT=1 wt_bootstrap_pending "$DWT"
eq '...and nothing is pending' '' "$WT_PENDING"
# A write in the PR's copy goes nowhere else.
printf 'PR EDIT' >> "$DWT/vendor/pkg/file.txt"
eq "...an in-place write in the PR's copy leaves main's file as it was" "$rmain" "$(tree_snap "$DREPO/vendor")"
# With a lockfile of its own it installs, as before.
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
printf 'LOCKV5\n' > "$DWT/composer.lock"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq "pr: with a lockfile of its own, a pull request's worktree installs" install "$(linked_from)"
contains '...and says why' \
  "vendor: a pull request's worktree installs its own copy — a linked one would share files with the main checkout both ways" "$out"
lacks '...nothing copied' 'copied from the main checkout' "$out"
wt_state_dep_read "$DWT" vendor
eq '...recorded done as an install' "done|install" "$WT_DEP_STATUS|$WT_DEP_STRATEGY"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
printf 'LOCKV1\n' > "$DWT/composer.lock"

# Started from a pull request's worktree, on a plain branch with no upstream: the marker alone makes
# it a pull request's, so it takes a copy of main's tree rather than a link.
git -C "$DREPO" config --unset branch.wt-dep1.merge
PMARK=$(git -C "$DWT" rev-parse --absolute-git-dir)/pitlane-pr-origin
eq 'pr-origin: (fixture) an unmarked worktree on its own branch is not a pull request'"'"'s' 1 \
  "$(wt_is_pr_worktree "$DWT"; echo $?)"
wt_pr_origin_mark "$DWT" pr-7 "$(git -C "$DWT" rev-parse HEAD)"
eq 'pr-origin: the marker names the commit and the parent' "$(git -C "$DWT" rev-parse HEAD) pr-7" "$(cat "$PMARK" 2>/dev/null)"
eq "pr-origin: a marked worktree is a pull request's" 0 "$(wt_is_pr_worktree "$DWT"; echo $?)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq "pr-origin: it copies main's tree rather than link it" copy "$(linked_from)"
contains '...saying why' "vendor: a pull request's worktree copies the main checkout's rather than link it" "$out"
eq '...no file of it shares an inode' '' "$(find "$DWT/vendor" -type f -links +1)"
rm -f "$PMARK"
eq 'pr-origin: without the marker it is not' 1 "$(wt_is_pr_worktree "$DWT"; echo $?)"
# Moved out of the worktrees dir, the marker still decides, and the two tests agree.
MOVED=$(mktemp -d)/moved-wt
git -C "$DREPO" worktree add -q -b wt-moved "$DREPO${WT_SUBPATH}moved-wt" HEAD
git -C "$DREPO" worktree move "$DREPO${WT_SUBPATH}moved-wt" "$MOVED"
moved_donor_is_pr() {
  wt_worktree_admin "$MOVED"
  wt_donor_is_pr "$WT_WORKTREE_ADMIN" "$MOVED" "$(git -C "$DREPO" config --get-regexp '^branch\..*\.merge$')"
  echo $?
}
eq 'pr-origin: an unmarked worktree moved out is not a pull request'"'"'s' 1 "$(wt_is_pr_worktree "$MOVED"; echo $?)"
eq '...nor a donor pull request'"'"'s' 1 "$(moved_donor_is_pr)"
wt_pr_origin_mark "$MOVED" pr-7 "$(git -C "$MOVED" rev-parse HEAD)"
eq 'pr-origin: a marked worktree moved out is still a pull request'"'"'s' 0 "$(wt_is_pr_worktree "$MOVED"; echo $?)"
eq '...and a donor pull request'"'"'s' 0 "$(moved_donor_is_pr)"
git -C "$DREPO" worktree remove --force "$MOVED"
git -C "$DREPO" branch -q -D wt-moved
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head

# Linked before this change: the start-up run, installs deferred, moves the linked copy out of the
# worktree into its git dir at once (an instant rename), and the background run removes it there and
# installs fresh.
PADMIN=$(wt_removed_dep_admin_dir "$DWT")
pr_relink() {  # vendor linked from main while not a pull request, then the branch becomes one
  git -C "$DREPO" config --unset branch.wt-dep1.merge 2>/dev/null
  rm -rf "$PADMIN"
  relink LOCKV1
  git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head
}
pr_relink
eq 'pr: (fixture) linked from main while not yet a pull request' main "$(linked_from)"
PROFILE_PRESENT=1 wt_bootstrap_pending "$DWT"
eq 'pr: a linked dir recorded done is pending again' vendor "$WT_PENDING_ATTEMPTABLE"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...at start-up its copy is left for the background run' 'vendor: to be copied from the main checkout in the background' "$out"
lacks '...no copy made at start-up' 'vendor: copied from' "$out"
contains '...saying why' "vendor: a pull request's worktree copies the main checkout's rather than link it" "$out"
contains '...and the linked copy is moved out of the worktree at once' \
  "vendor: it was linked, and a pull request's worktree keeps its own copy — moved the linked copy out of the worktree, into its git dir" "$out"
eq '...so the session has no tree shared with main' absent "$(present "$DWT/vendor")"
ne '...it sits in the git dir' '' "$(ls -A "$PADMIN" 2>/dev/null)"
eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks '...a second start-up has nothing more to move' 'moved the linked copy' "$out"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...the run that copies removes it from the git dir' "vendor: removed $PADMIN/vendor." "$out"
eq "...and copies main's tree into a fresh dir" "copy|absent" "$(linked_from)|$(present "$DWT/vendor/stale.txt")"
eq '...no file of it shares an inode' '' "$(find "$DWT/vendor" -type f -links +1)"
eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
eq '...nothing left in the git dir or beside the dir' '|' \
  "$(ls -A "$PADMIN" 2>/dev/null)|$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)"
eq '...recorded done' "done" "$(wt_state_status "$DWT" vendor)"

# Not deferred, the run that copies clears the linked copy itself, right before the copy; with a
# lockfile of its own, before the install.
pr_relink
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr: a run that copies clears the linked copy first' \
  "vendor: it was linked, and a pull request's worktree keeps its own copy — removing the linked copy and copying the main checkout's" "$out"
eq '...and copies' "copy|" "$(linked_from)|$(find "$DWT/vendor" -type f -links +1)"
eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
pr_relink
printf 'LOCKV9\n' > "$DWT/composer.lock"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr: a run that installs clears the linked copy first' \
  "vendor: it was linked, and a pull request's worktree keeps its own copy — removing the linked copy and installing fresh" "$out"
eq '...and installs' "install|" "$(linked_from)|$(find "$DWT/vendor" -type f -links +1)"

# Every step that leaves it uninstalled still moves the linked copy out of use: a PR worktree never
# keeps a tree shared with main because it could not install.
PASTDUE=$(( $(date +%s) - 5 ))
for pr_exit in approval empty-install budget; do
  pr_relink
  case $pr_exit in
    approval) out=$(WT_APPROVAL=no wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1); why='not installed — the profile'"'"'s commands are not approved' ;;
    empty-install)
      # A lockfile of its own, or main's tree would be copied before the install is looked at.
      printf 'LOCKV9\n' > "$DWT/composer.lock"
      # shellcheck disable=SC2034
      PROFILE_RAW=$(dep_raw vendor composer.lock hardlink '' '')
      out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1); why='no install command to run' ;;
    budget) out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$PASTDUE" 2>&1); why='out of time before starting' ;;
  esac
  contains "pr, $pr_exit: not installed" "vendor: $why" "$out"
  contains '...the linked copy is moved out of the worktree all the same' 'moved the linked copy out of the worktree, into its git dir' "$out"
  eq '...no tree shared with main is left in it' absent "$(present "$DWT/vendor")"
  eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
  eq '...and the dep is recorded not done' dirty "$(wt_state_status "$DWT" vendor)"
done
# Recorded not done, a worktree that stops being a pull request's links the dir again rather than
# calling the missing one current.
pr_relink
WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" >/dev/null 2>&1
git -C "$DREPO" config --unset branch.wt-dep1.merge
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'pr: moved out of use, then no longer a pull request: not called up to date' 'already up to date' "$out"
eq '...linked from main again' main "$(linked_from)"
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head

# The steps past the dep's lock. wt_budget_left is stood in for, counting its calls in a file, so the
# budget runs out at exactly the check under test: the first passes the step before the lock, the
# second the one after the wait, the third the one before the copy or, with a lockfile of its own,
# the install.
PBUDGET=$TMP/pr-budget-calls
budget_out_after() {  # $1 = how many budget checks pass; sets out
  local passes=$1
  rm -f "$PBUDGET"
  out=$(
    # shellcheck disable=SC2329  # called by the engine, in place of its own
    wt_budget_left() {
      local n
      n=$(( $(cat "$PBUDGET" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$PBUDGET"
      if [ "$n" -gt "$passes" ]; then printf 0; else printf 600; fi
    }
    wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1
  )
}
for pr_exit in waiting before-copy before-install toolchain; do
  pr_relink
  # Past the copy, a lockfile of its own: main's would be copied first.
  case $pr_exit in before-install | toolchain) printf 'LOCKV9\n' > "$DWT/composer.lock" ;; esac
  case $pr_exit in
    waiting) budget_out_after 1; why='the budget ran out while waiting' ;;
    before-copy) budget_out_after 2; why='the budget ran out before the copy could start' ;;
    before-install) budget_out_after 2; why='the budget ran out before the install could start' ;;
    toolchain) out=$(PROFILE_SHELL=fake-shell WT_TOOLCHAIN=broken wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
      why='needs the toolchain, which is not ready' ;;
  esac
  contains "pr, $pr_exit: not installed" "vendor: $why" "$out"
  contains '...the linked copy is moved out of the worktree' 'moved the linked copy out of the worktree, into its git dir' "$out"
  eq '...no tree shared with main is left in it' absent "$(present "$DWT/vendor")"
  eq "...the main checkout's tree kept every byte and inode" "$rmain" "$(tree_snap "$DREPO/vendor")"
  eq '...recorded not done' dirty "$(wt_state_status "$DWT" vendor)"
done
# Another process holds the dep's lock, or it cannot be opened: the linked copy is not touched.
pr_relink
exec 7>"$(wt_lock_path "$DREPO" vendor)"; flock -n 7
WT_LOCK_WAIT=0 budget_out_after 1
exec 7>&-
contains 'pr, lock held elsewhere: the run goes on without it' 'another worktree is working on it' "$out"
contains '...and stops at the budget' 'vendor: the budget ran out while waiting' "$out"
lacks '...the linked copy is not moved' 'moved the linked copy' "$out"
eq '...it stays' main "$(linked_from)"
eq "...the main checkout's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"
pr_relink
plock=$(wt_lock_path "$DREPO" vendor)
mv "$plock" "$TMP/pr-lock-real"; ln -s "$TMP/pr-lock-real" "$plock"
budget_out_after 1
rm -f "$plock"; mv "$TMP/pr-lock-real" "$plock"
contains 'pr, lock that cannot be opened: stops at the budget' 'vendor: the budget ran out while waiting' "$out"
lacks '...the linked copy is not moved' 'moved the linked copy' "$out"
eq '...it stays' main "$(linked_from)"
eq "...the main checkout's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"

# The git dir on another device: no instant move, so start-up leaves the linked copy to the run that
# installs, and says so; a step with no later install (unapproved) removes it outright.
PFAKESTAT=$TMP/pr-fakestat-bin
mkdir -p "$PFAKESTAT"
# shellcheck disable=SC2016  # the fake's own script, expanded when it runs
printf '#!/bin/sh\nfor a; do p=$a; done\nprintf "%%s\\n" "$p" | cksum | cut -d" " -f1\n' > "$PFAKESTAT/stat"
chmod +x "$PFAKESTAT/stat"
pr_relink
out=$(PATH=$PFAKESTAT:$PATH WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr, git dir on another device: start-up says the linked copy stays for the install' \
  'vendor: it was linked, and a pull request'"'"'s worktree keeps its own copy — the linked copy stays until the run that installs removes it' "$out"
eq '...and leaves it, rather than copy the tree across devices' main "$(linked_from)"
out=$(PATH=$PFAKESTAT:$PATH WT_APPROVAL=no wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains '...unapproved, nothing will install it, so it is removed outright' \
  "vendor: it was linked, and a pull request's worktree keeps its own copy — removing the linked copy; nothing installs it here" "$out"
lacks '...not said to be installed fresh' 'installing fresh' "$out"
eq '...gone' "absent|$rmain" "$(present "$DWT/vendor")|$(tree_snap "$DREPO/vendor")"
eq '...nothing left beside it or in the git dir' '|' \
  "$(ls -A "$PADMIN" 2>/dev/null)|$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* 2>/dev/null)"

# The toolchain step, with the git dir on another device, only leaves it: no outright removal there.
pr_relink
printf 'LOCKV9\n' > "$DWT/composer.lock"
out=$(PATH=$PFAKESTAT:$PATH PROFILE_SHELL=fake-shell WT_TOOLCHAIN=broken wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr, toolchain, git dir on another device: the linked copy stays for the install' \
  'the linked copy stays until the run that installs removes it' "$out"
lacks '...not removed outright inside the start-up budget' 'removing the linked copy' "$out"
eq '...left in place' main "$(linked_from)"

# A PR worktree whose own tree was never linked is not touched by these steps.
git -C "$DREPO" config --unset branch.wt-dep1.merge
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$RINSTALL" '')
printf 'LOCKV5\n' > "$DWT/composer.lock"
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" >/dev/null 2>&1
printf 'LOCKV7\n' > "$DWT/composer.lock"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'pr: an own install pending again is not moved aside at start-up' 'linked copy' "$out"
eq '...and stays in place' DINSTALLED "$(cat "$DWT/vendor/m" 2>/dev/null)"
printf 'LOCKV1\n' > "$DWT/composer.lock"
git -C "$DREPO" config --unset branch.wt-dep1.merge
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'pr: no longer a pull request, it says nothing of its own copy' 'installs its own copy' "$out"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"


# --- a pull request's copy of main's tree: its symlinks, its failures, its cost ------------------
# The copy is made in a temp and its symlinks checked there, before it is renamed into place: a
# link leaving the folder would still lead the PR's writes out of it, so that tree is installed instead.
git -C "$DREPO" config branch.wt-dep1.merge refs/pull/11/head
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink "$RINSTALL" '')
PCADMIN=$(wt_removed_dep_admin_dir "$DWT")
PCCOPYING=$(wt_copying_dep_admin_dir "$DWT")
pc_reset() {  # no vendor, no record, no leftovers, main's lockfile
  rm -rf "$DWT/vendor" "$PCADMIN" "$PCCOPYING"; rm -f "$(wt_state_path "$DWT")"
  printf 'LOCKV1\n' > "$DWT/composer.lock"
}
pc_leftovers() {
  printf '%s|%s' "$(cd "$PCADMIN" 2>/dev/null && ls -A)$(cd "$PCCOPYING" 2>/dev/null && ls -A)" \
    "$(cd "$DWT" && ls -Ad .vendor.pitlane-removed.* .vendor.pitlane-copying.* 2>/dev/null)"
}

# Package-manager links inside the tree (a bin entry into its package, one through another link that
# stays in, one dangling in place) are kept as they are, and so resolve inside the worktree's copy.
mkdir -p "$DREPO/vendor/bin"
ln -s ../pkg/file.txt "$DREPO/vendor/bin/tool"
ln -s pkg "$DREPO/vendor/lib"
ln -s ../lib/file.txt "$DREPO/vendor/bin/via"
ln -s ../pkg/missing/x "$DREPO/vendor/bin/gone"
pc_reset
rmain=$(tree_snap "$DREPO/vendor")
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'pr copy: links that stay inside the folder do not stop the copy' copy "$(linked_from)"
eq '...the bin link is kept as a link, with its own target' 'link|../pkg/file.txt' \
  "$([ -L "$DWT/vendor/bin/tool" ] && echo link)|$(readlink "$DWT/vendor/bin/tool")"
eq "...and resolves to the worktree's own file, not main's" 'mine|' \
  "$([ "$DWT/vendor/bin/tool" -ef "$DWT/vendor/pkg/file.txt" ] && echo mine)|$([ "$DWT/vendor/bin/tool" -ef "$DREPO/vendor/pkg/file.txt" ] && echo main)"
eq '...one through a link inside resolves to the copy too' mine \
  "$([ "$DWT/vendor/bin/via" -ef "$DWT/vendor/pkg/file.txt" ] && echo mine)"
eq '...a dangling one inside is kept' '../pkg/missing/x' "$(readlink "$DWT/vendor/bin/gone")"
eq "...main's tree untouched" "$rmain" "$(tree_snap "$DREPO/vendor")"
rm -f "$DREPO/vendor/lib" "$DREPO/vendor/bin/via" "$DREPO/vendor/bin/gone"

# Every link leaving the folder is refused, wherever it leads: the tree is installed instead, the
# temp is gone, and the dir never held the copy.
mkdir -p "$TMP/elsewhere"; printf 'X\n' > "$TMP/elsewhere/x"
pc_refused() {  # $1 = label, $2 = link in main's vendor, $3 = its target, $4 = the example the log gives
  ln -s "$3" "$DREPO/vendor/$2"
  pc_reset
  out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
  contains "pr copy: $1 is refused, and says which" "vendor: the main checkout's copy has a link leaving the folder ($4" "$out"
  eq '...installed instead, nothing left behind, the link not in the worktree' "install||absent" \
    "$(linked_from)|$(pc_leftovers | tr -d '|')|$( [ -L "$DWT/vendor/$2" ] && echo present || echo absent)"
  rm -f "$DREPO/vendor/$2"
}
pc_refused 'an absolute link elsewhere' bin/sys "$TMP/elsewhere/x" "bin/sys -> $TMP/elsewhere/x) — installing instead"
wt_state_dep_read "$DWT" vendor
eq '...recorded as an install' "done|install" "$WT_DEP_STATUS|$WT_DEP_STRATEGY"
pc_refused "an absolute link into main" bin/back "$DREPO/composer.lock" "bin/back -> $DREPO/composer.lock"
pc_refused "a relative link to the worktree's own lockfile" lockref ../composer.lock 'lockref -> ../composer.lock'
pc_refused 'a target ending in ..' bin/up ../.. 'bin/up -> ../..'
mkdir -p "$DREPO/vendor/a/b"
ln -s .. "$DREPO/vendor/a/b/up"
pc_refused 'a link whose text stays in but climbs through another' u2 a/b/up/../.. 'u2 -> a/b/up/../..'
rm -f "$DREPO/vendor/a/b/up"
ln -s loop2 "$DREPO/vendor/loop1"
pc_refused 'a loop' loop2 loop1 'loop'
rm -f "$DREPO/vendor/loop1"
rm -rf "$DREPO/vendor/a"

# The check runs on the temp, before the dir exists; the dir appears only once it has passed.
eval "pc_orig_$(declare -f wt_copy_link_leaves)"
pc_checked() {  # runs the rest with the check recording what it was given and whether the dir was there
  # shellcheck disable=SC2329  # stands in for the check inside the copy
  wt_copy_link_leaves() { printf '%s|%s\n' "$1" "$(present "$DWT/vendor")" > "$TMP/pc-checked"; pc_orig_wt_copy_link_leaves "$@"; }
  "$@"
}
pc_reset; rm -f "$TMP/pc-checked"
out=$(pc_checked wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
pc_seen=$(cat "$TMP/pc-checked" 2>/dev/null)
eq 'pr copy: the links are checked in the temp, the dir not yet there' "$PCCOPYING/|absent" \
  "$(case ${pc_seen%|*} in "$PCCOPYING"/*) printf '%s/' "$PCCOPYING" ;; *) printf '%s' "${pc_seen%|*}" ;; esac)|${pc_seen##*|}"
eq '...then moved into place' copy "$(linked_from)"
ln -s "$DREPO/composer.lock" "$DREPO/vendor/bin/back"
pc_reset; rm -f "$TMP/pc-checked"
out=$(pc_checked wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
pc_seen=$(cat "$TMP/pc-checked" 2>/dev/null)
eq 'pr copy: refused, the dir was not there when it was judged' absent "${pc_seen##*|}"
eq '...and never took the copy: what is there is the install' 'install|absent' \
  "$(linked_from)|$([ -L "$DWT/vendor/bin/back" ] && echo present || echo absent)"
rm -f "$DREPO/vendor/bin/back" "$TMP/pc-checked"

# The check's arms, on its own, over a scratch tree: what stays in, what leaves, and a listing that
# fails is a refusal.
PCS=$TMP/pc-scan/tree
mkdir -p "$PCS/a/b"
pc_scan() { wt_copy_link_leaves "$PCS"; printf '%s:%s' "$?" "$WT_COPY_ESCAPE"; }
pc_scan_one() {  # $1 = link in the tree, $2 = target; the scan with only it
  ln -s "$2" "$PCS/$1"; pc_scan; rm -f "$PCS/$1"
}
eq 'scan: no symlinks, nothing found' '1:' "$(pc_scan)"
eq 'scan: a bin link into its package stays in' '1:' "$(pc_scan_one a/x ../b/x)"
eq 'scan: a link to the top of the tree stays in' '1:' "$(pc_scan_one a/top ..)"
eq 'scan: a name starting with dots is not a climb' '1:' "$(pc_scan_one a/dots ..lookalike)"
eq 'scan: a dangling link inside is kept' '1:' "$(pc_scan_one a/d missing/../../a/b/x)"
eq 'scan: a dangling link whose text leaves is refused' '0:a/d -> missing/../../../x' "$(pc_scan_one a/d missing/../../../x)"
eq 'scan: an absolute link into the tree itself is refused' "0:a/abs -> $PCS/a/b" "$(pc_scan_one a/abs "$PCS/a/b")"
eq 'scan: a relative climb out is refused' '0:a/out -> ../../x' "$(pc_scan_one a/out ../../x)"
ln -s ../a/b "$PCS/a/lib"
eq 'scan: through a link that stays in, it stays in' '1:' "$(pc_scan_one a/via lib/../b/x)"
rm -f "$PCS/a/lib"
ln -s .. "$PCS/u1"
eq 'scan: u1 -> .. alone leaves' '0:u1 -> ..' "$(pc_scan)"
rm -f "$PCS/u1"
# Judged one link at a time, the chain's second link is caught on its own walk too.
ln -s .. "$PCS/a/b/up"
eq 'scan, one link: .. after a link climbs from its target' 1 \
  "$(wt_link_target_is_contained "$PCS" u2 a/b/up/../..; echo $?)"
eq '...the same text without the link stays in' 0 \
  "$(wt_link_target_is_contained "$PCS" u2 a/b/../..; echo $?)"
rm -f "$PCS/a/b/up"
ln -s "$TMP" "$PCS/a/abs"
eq 'scan, one link: through an absolute link is a leaving' 1 \
  "$(wt_link_target_is_contained "$PCS" via a/abs/x; echo $?)"
rm -f "$PCS/a/abs"
ln -s l2 "$PCS/l1"
ln -s l1 "$PCS/l2"
eq 'scan: a loop is a leaving at the hop limit' 0 "$(wt_copy_link_leaves "$PCS"; echo $?)"
rm -f "$PCS/l1" "$PCS/l2"
eq 'scan: control characters in the example are replaced' "0:a/n?l -> /x" "$(pc_scan_one "a/n${WT_NL}l" /x)"
# shellcheck disable=SC2329  # stands in for find inside the scan
eq 'scan: a find that fails is a refusal' '2:' "$(find() { return 1; }; pc_scan)"
eq 'scan: a dir that is not there is a refusal' '2:' \
  "$(wt_copy_link_leaves "$TMP/pc-scan/not-there"; printf '%s:%s' "$?" "$WT_COPY_ESCAPE")"
# Without GNU find's -printf: one readlink per link, the same answer.
ln -s ../../x "$PCS/a/climb"
# shellcheck disable=SC2329  # stands in for find inside the scan
eq 'scan, plain find: a climb out is found' "0:a/climb -> ../../x" \
  "$(find() { case " $* " in *' -printf '*) return 1 ;; esac; command find "$@"; }; pc_scan)"
rm -rf "$TMP/pc-scan"

# cp stood in for: one that fails part-way, one that hangs, one without --reflink, one that logs.
REALCP=$(command -v cp)
PCBIN=$TMP/pc-bin
mkdir -p "$PCBIN"
# shellcheck disable=SC2016  # the stand-ins' own scripts, expanded when they run
{
  printf '#!/bin/sh\ncase "$*" in *pitlane-reflink-probe*) exec %s "$@" ;; esac\n' "$REALCP"
  printf 'for a; do last=$a; done\nmkdir -p "$last" && : > "$last/partial"\n'
  printf 'printf "cp: error writing: No space left on device\\n" >&2\nexit 1\n'
} > "$PCBIN/cp-fails"
# shellcheck disable=SC2016
{
  printf '#!/bin/sh\ncase "$*" in *pitlane-reflink-probe*) exec %s "$@" ;; esac\n' "$REALCP"
  printf 'for a; do last=$a; done\nmkdir -p "$last" && : > "$last/partial"\nexec sleep 30\n'
} > "$PCBIN/cp-hangs"
# shellcheck disable=SC2016
{
  printf '#!/bin/sh\nfor a; do case $a in --reflink*) echo "cp: unrecognized option $a" >&2; exit 1 ;; esac; done\n'
  printf 'exec %s "$@"\n' "$REALCP"
} > "$PCBIN/cp-noreflink"
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexec %s "$@"\n' "$TMP/pc-cp-args" "$REALCP" > "$PCBIN/cp-logs"
chmod +x "$PCBIN"/cp-*
pc_with_cp() {  # $1 = stand-in; runs the rest with it as `cp`
  local which=$1; shift
  mkdir -p "$PCBIN/$which.d"
  ln -sf "$PCBIN/$which" "$PCBIN/$which.d/cp"
  PATH=$PCBIN/$which.d:$PATH "$@"
}

pc_reset
out=$(pc_with_cp cp-fails wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy: a copy that fails says what cp said' \
  'vendor: could not copy it from the main checkout (cp: error writing: No space left on device) — installing instead' "$out"
eq '...its partial temp is removed' '|' "$(pc_leftovers)"
eq '...and it installs instead' install "$(linked_from)"

pc_reset
NEAR=$(( $(date +%s) + 2 ))
out=$(pc_with_cp cp-hangs wt_bootstrap_deps "$DREPO" "$DWT" "$NEAR" 2>&1)
contains 'pr copy: a copy that outlasts the budget is stopped' \
  'vendor: copying it from the main checkout ran past the' "$out"
eq '...its partial temp is removed, and the dir never appears' '||absent' "$(pc_leftovers)|$(present "$DWT/vendor")"
lacks '...nothing installed in its place' 'installing' "$out"
eq '...recorded not done' dirty "$(wt_state_status "$DWT" vendor)"
PROFILE_PRESENT=1 wt_bootstrap_pending "$DWT"
eq '...so it is pending, and attemptable' vendor "$WT_PENDING_ATTEMPTABLE"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...and the next run copies it' copy "$(linked_from)"

# --reflink=auto where cp takes it; plain cp -a where it does not.
pc_reset
rm -f "$TMP/pc-cp-args"
out=$(pc_with_cp cp-logs wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy: a cp that takes --reflink=auto is given it' "-a --reflink=auto -- $DREPO/vendor " "$(cat "$TMP/pc-cp-args")"
contains '...and the log says the copy may share blocks' 'copy-on-write where the filesystem allows)' "$out"
pc_reset
out=$(pc_with_cp cp-noreflink wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'pr copy: a cp without --reflink still copies, with plain cp -a' copy "$(linked_from)"
lacks '...without the copy failing' 'could not copy' "$out"
lacks '...nor claiming copy-on-write' 'copy-on-write' "$out"
# The probe for what cp and mv take is made under TMPDIR, never in the worktree or its git dir.
pc_reset
mkdir -p "$TMP/pc-tmpdir"
out=$(TMPDIR=$TMP/pc-tmpdir wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'pr copy: the tool probe leaves nothing in TMPDIR, the git dir or the worktree' '|||' \
  "$(ls -A "$TMP/pc-tmpdir")|$(compgen -G "$PCADMIN/*probe*")|$(compgen -G "$PCCOPYING/*probe*")|$(compgen -G "$DWT/*probe*")"
eq '...and copies' copy "$(linked_from)"

# A dir appearing at the copy's place after the last test and before the rename: `mv -T` fails
# rather than move the copy inside it; where mv has no -T, the copy found inside it is taken out.
REALMV=$(command -v mv)
# shellcheck disable=SC2016  # the stand-in's own script, expanded when it runs
{
  printf '#!/bin/sh\ncase "$*" in *pitlane-reflink-probe*) exec %s "$@" ;; esac\n' "$REALMV"
  printf 'for a; do last=$a; done\ncase $last in */vendor) mkdir -p "$last" && : > "$last/raced" ;; esac\n'
  printf 'exec %s "$@"\n' "$REALMV"
} > "$PCBIN/mv-races"
chmod +x "$PCBIN/mv-races"
pc_with_mv() { mkdir -p "$PCBIN/mv.d"; ln -sf "$PCBIN/mv-races" "$PCBIN/mv.d/mv"; PATH=$PCBIN/mv.d:$PATH "$@"; }
pc_reset
out=$(pc_with_mv wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy, mv -T: a dir that appeared first fails the rename' 'vendor: could not move the copy into place (' "$out"
eq '...nothing moved inside it, no temp left' 'present|||' "$(present "$DWT/vendor/raced")|$(compgen -G "$DWT/vendor/vendor.*"; compgen -G "$DWT/vendor/.vendor.pitlane-*")|$(pc_leftovers)"
pc_reset
out=$(WT_CP_REFLINK=no WT_MV_T=no pc_with_mv wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy, mv without -T: the copy found inside the dir is taken out' \
  'vendor: appeared in the worktree while the copy was made — installing over it' "$out"
eq '...nothing of it left inside, no temp left' 'present|||' "$(present "$DWT/vendor/raced")|$(compgen -G "$DWT/vendor/vendor.*"; compgen -G "$DWT/vendor/.vendor.pitlane-*")|$(pc_leftovers)"

# The size after the copy is measured within what is left of the budget, never past it.
# shellcheck disable=SC2016
printf '#!/bin/sh\nexec sleep 30\n' > "$PCBIN/du-hangs"
chmod +x "$PCBIN/du-hangs"
mkdir -p "$PCBIN/du.d"; ln -sf "$PCBIN/du-hangs" "$PCBIN/du.d/du"
pc_reset
t0=$(date +%s)
out=$(PATH=$PCBIN/du.d:$PATH wt_bootstrap_deps "$DREPO" "$DWT" "$(( $(date +%s) + 3 ))" 2>&1)
eq 'pr copy: a du that hangs is stopped with the budget' yes "$([ $(( $(date +%s) - t0 )) -lt 15 ] && echo yes)"
contains '...the copy still logged, without a size' 'vendor: copied from the main checkout in ' "$out"
eq '...and in place' copy "$(linked_from)"

# A copy interrupted by a killed run leaves its temp under its own name; the next run, under the
# dep's lock, removes it. Without the lock it is not judged: another run may be making it.
pc_reset
mkdir -p "$PCCOPYING/vendor.999999.1/pkg" "$DWT/.vendor.pitlane-copying.999999.2"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy: an interrupted copy in the git dir is removed under the lock' "vendor: removed $PCCOPYING/vendor.999999.1" "$out"
contains '...and one beside the dir' "vendor: removed $DWT/.vendor.pitlane-copying.999999.2" "$out"
eq '...both gone' '|' "$(pc_leftovers)"
mkdir -p "$PCCOPYING/vendor.999999.1" "$DWT/.vendor.pitlane-copying.999999.2"
wt_sweep_removed_dep "$DWT" vendor '' 2>/dev/null
eq '...not swept without the lock' 'present|present' \
  "$(present "$PCCOPYING/vendor.999999.1")|$(present "$DWT/.vendor.pitlane-copying.999999.2")"
wt_sweep_removed_dep "$DWT" vendor 1 2>/dev/null
eq '...swept with it' 'absent|absent' \
  "$(present "$PCCOPYING/vendor.999999.1")|$(present "$DWT/.vendor.pitlane-copying.999999.2")"
eq 'copying name: its own marker, not a removal'"'"'s' '.vendor.pitlane-copying.12.345|no|yes|12' \
  "$(wt_copying_dep_name vendor 12 345)|$(wt_is_removed_dep_name .vendor.pitlane-copying.12.345 vendor && echo yes || echo no)|$(wt_is_removed_dep_name .vendor.pitlane-copying.12.345 vendor pitlane-copying && echo yes || echo no)|$(wt_dep_temp_pid .vendor.pitlane-copying.12.345)"

# Deferred at start-up: nothing is copied then, and nothing is left half-made.
pc_reset
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy: at start-up the copy is left for the background run' \
  'vendor: to be copied from the main checkout in the background' "$out"
eq '...nothing copied' 'absent||' "$(present "$DWT/vendor")|$(pc_leftovers)"
eq '...not recorded done' 1 "$(wt_dep_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
  "$(wt_cksum_string "$RINSTALL")" install 1; echo $?)"
# Unapproved: neither copied nor installed.
out=$(WT_APPROVAL=no wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'pr copy: unapproved, nothing is copied' absent "$(present "$DWT/vendor")"

# Already present and sharing nothing (the session installed it by hand): installed over, not copied.
pc_reset
mkdir -p "$DWT/vendor"; printf 'HAND\n' > "$DWT/vendor/hand"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'pr copy: a dir already there is installed over rather than replaced' \
  "vendor: already present in the worktree, sharing no file with another tree — installing over it rather than copying the main checkout's" "$out"
eq '...its own files kept' HAND "$(cat "$DWT/vendor/hand" 2>/dev/null)"

# A copy recorded done is current for a PR's worktree only: it is not a link for the donor search or
# the repairs, and the done check takes it for this lockfile and command alone.
pc_reset
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" >/dev/null 2>&1
eq 'pr copy: (fixture) copied' copy "$(linked_from)"
eq '...current for its own copy' 0 "$(wt_dep_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
  "$(wt_cksum_string "$RINSTALL")" install 1; echo $?)"
eq '...not for a worktree that installs as such' 1 "$(wt_dep_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
  "$(wt_cksum_string "$RINSTALL")" install 0; echo $?)"
eq '...nor for another lockfile' 1 "$(wt_dep_is_done "$DWT" vendor "$(wt_cksum_string other)" \
  "$(wt_cksum_string "$RINSTALL")" install 1; echo $?)"
# A record spelled `copy`, as the first version wrote it, is read the same.
wt_state_set "$DWT" vendor copy "$(wt_cksum_file "$DWT/composer.lock")" "$(wt_cksum_string "$RINSTALL")" 'done'
eq '...a record spelled copy is current too' 0 "$(wt_dep_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
  "$(wt_cksum_string "$RINSTALL")" install 1; echo $?)"
PROFILE_PRESENT=1 wt_bootstrap_pending "$DWT"
eq '...and not pending' '' "$WT_PENDING"
printf 'LOCKV8\n' > "$DWT/composer.lock"
out=$(WT_DEFER=1 wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks '...its lockfile changed: the copy is not moved aside as a link at start-up' 'linked copy' "$out"
eq '...and stays' copy "$(linked_from)"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq '...then installed into' install "$(linked_from)"

rm -rf "$DREPO/vendor/bin"
git -C "$DREPO" config --unset branch.wt-dep1.merge
pc_reset
# The aside name and its one matcher, which the /pitlane-tidy sweep shares: exact shape only.
eq 'aside name: the dir'"'"'s base, our marker, the pid and a random number' '.node_modules.pitlane-removed.12.345' \
  "$(wt_removed_dep_name web/node_modules 12 345)"
eq 'aside name: what it makes is accepted, for that dir' yes \
  "$(wt_is_removed_dep_name "$(wt_removed_dep_name web/node_modules 12 345)" web/node_modules && echo yes || echo no)"
for lookalike in .vendor.pitlane-removed.12.345 .node_modules.pitlane-removed.12 \
  .node_modules.pitlane-removed.12. .node_modules.pitlane-removed..345 .node_modules.pitlane-removed.1x.345 \
  .node_modules.pitlane-removed.12.34x .node_modules.pitlane-removed.12.3.4 node_modules.pitlane-removed.12.345 \
  .node_modules.pitlane-removed.1:2.3; do
  eq "aside name: $lookalike is not ours for web/node_modules" no \
    "$(wt_is_removed_dep_name "$lookalike" web/node_modules && echo yes || echo no)"
done
# The name in the git dir: the dir's whole path, with `%` and `/` encoded, so no two dirs share one.
eq 'admin name: the encoded dir, the pid and a random number' 'web%2Fnode_modules.12.345' \
  "$(wt_removed_dep_admin_name web/node_modules 12 345)"
ne "admin name: a dir whose name holds an encoded slash is not the dir with that slash" \
  "$(wt_removed_dep_admin_name a/b 1 2)" "$(wt_removed_dep_admin_name a%2Fb 1 2)"
eq 'admin name: what it makes is accepted, for that dir' yes \
  "$(wt_is_removed_dep_admin_name "$(wt_removed_dep_admin_name web/node_modules 12 345)" web/node_modules && echo yes || echo no)"
for lookalike in node_modules.12.345 web%2Fnode_modules.12 web%2Fnode_modules.12. web%2Fnode_modules..345 \
  web%2Fnode_modules.1x.345 web%2Fnode_modules.12.3.4 .node_modules.pitlane-removed.12.345 web/node_modules.12.345; do
  eq "admin name: $lookalike is not ours for web/node_modules" no \
    "$(wt_is_removed_dep_admin_name "$lookalike" web/node_modules && echo yes || echo no)"
done
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
donor_rec donor-a "done" 100

git -C "$DREPO" worktree remove --force "$DONORS/donor-a"
rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"
printf 'LOCKV1\n' > "$DWT/composer.lock"

# --- hardlink falls back when the main checkout has nothing to link --------
rm -rf "$DWT/vendor" "$DREPO/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf NOSOURCE > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'with no source directory it installs instead' 'no vendor to link from' "$out"
eq '...and the install really ran' 'NOSOURCE' "$(cat "$DWT/vendor/m" 2>/dev/null)"

# An EMPTY source directory must not count as a successful link.
rm -rf "$DWT/vendor"; mkdir -p "$DREPO/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf EMPTYSRC > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'an empty source directory does not count as linkable' 'is empty' "$out"
eq '...so a real install runs' 'EMPTYSRC' "$(cat "$DWT/vendor/m" 2>/dev/null)"
rmdir "$DREPO/vendor" 2>/dev/null

# --- missing lockfile ------------------------------------------------------
# A linkable source must exist, or the source-missing check fires first and this asserts nothing.
rm -rf "$DWT/vendor"
mkdir -p "$DREPO/vendor/pkg"; printf 'REAL\n' > "$DREPO/vendor/pkg/file.txt"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor nosuch.lock hardlink 'mkdir -p vendor && printf NOLOCK > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a missing lockfile is not treated as a match' 'cannot compare' "$out"
eq '...and it installs rather than linking a tree it cannot validate' 'NOLOCK' \
  "$(cat "$DWT/vendor/m" 2>/dev/null)"

# --- verify decides done vs dirty ------------------------------------------
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor' 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a failing verify is reported' 'verify command failed' "$out"
eq '...and the dependency is recorded as needing a retry, not as done' 1 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'mkdir -p vendor')" install; echo $?)"
eq '...and it really is retried next time' 'yes' \
  "$(out2=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1); case $out2 in *'already up to date'*) echo no ;; *) echo yes ;; esac)"

rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf x > vendor/autoload.php' 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a passing verify records the dependency as done' 0 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'mkdir -p vendor && printf x > vendor/autoload.php')" install; echo $?)"

# --- an interrupted run leaves a partial tree that must be cleared ---------
rm -rf "$DWT/vendor"; mkdir -p "$DWT/vendor"; printf 'PARTIAL\n' > "$DWT/vendor/half.txt"
wt_state_set "$DWT" vendor install LX IX doing
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf CLEAN > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a directory left by an interrupted run is cleared' 'previous run was interrupted' "$out"
eq '...so the retry does not build on debris' '' "$(cat "$DWT/vendor/half.txt" 2>/dev/null)"
eq '...and the fresh install succeeded' 'CLEAN' "$(cat "$DWT/vendor/m" 2>/dev/null)"

# A directory with NO record is left alone: it may predate the plugin or a format change, and
# deleting it would turn an upgrade into a mass reinstall.
rm -rf "$DWT/vendor"; mkdir -p "$DWT/vendor"; printf 'PREEXISTING\n' > "$DWT/vendor/old.txt"
rm -f "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'printf y > vendor/new.txt' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a dependency directory with no record is not deleted' 'PREEXISTING' \
  "$(cat "$DWT/vendor/old.txt" 2>/dev/null)"

# --- skip and store --------------------------------------------------------
rm -rf "$DWT/target"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw target Cargo.lock skip 'mkdir -p target' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a skip dependency is announced' 'strategy is skip' "$out"
eq '...and genuinely not touched' '' "$([ -e "$DWT/target" ] && echo exists)"

rm -rf "$DWT/store1"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw store1 composer.lock store 'mkdir -p store1 && printf s > store1/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'the unimplemented store strategy says so' 'not implemented yet' "$out"
eq '...and installs instead of silently doing nothing' 's' "$(cat "$DWT/store1/m" 2>/dev/null)"

# --- containment -----------------------------------------------------------
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw '../escape' composer.lock install 'printf pwned > ../escape/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a traversing dependency dir is refused' 'not a relative path' "$out"
eq '...and nothing is created outside the worktree' '' \
  "$(cat "$DREPO/.claude/worktrees/escape/m" 2>/dev/null)"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor '../../../etc/passwd' install 'true' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a traversing lock path is refused too' 'refusing lock' "$out"

# --- several dependencies in one run ---------------------------------------
rm -rf "$DWT/a1" "$DWT/b2"
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%sa1%scomposer.lock%sinstall%smkdir -p a1%s%s1%sb2%scomposer.lock%sinstall%smkdir -p b2%s%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'every dependency in the list is processed: the first' yes "$([ -d "$DWT/a1" ] && echo yes)"
eq 'every dependency in the list is processed: the second' yes "$([ -d "$DWT/b2" ] && echo yes)"

# ...and one failing must not stop the next. FRESH directory names: reusing b2 with the same
# install command would be skipped as already done, which would test the cache rather than the
# keep-going behaviour this case is for.
rm -rf "$DWT/c3" "$DWT/d4"
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%sc3%scomposer.lock%sinstall%sexit 7%s%s1%sd4%scomposer.lock%sinstall%smkdir -p d4%s%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'the failing dependency really did fail' '' "$([ -d "$DWT/c3" ] && echo exists)"
eq 'a failing dependency does not stop the ones after it' yes "$([ -d "$DWT/d4" ] && echo yes)"

# --- no profile ------------------------------------------------------------
# shellcheck disable=SC2034
PROFILE_RAW=''
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'with no usable profile the engine does nothing and succeeds' 0 $?

# --- idempotence AFTER a hardlink fell back to install ----------------------
# The state records the PROFILE's strategy, not the one that happened to run. If it recorded the
# fallback instead, the next session would ask for `hardlink`, never match, and reinstall in full
# — every session, silently, in the common case of a branch that touched its lockfile.
rm -rf "$DWT/vendor"
printf 'LOCK-DIFFERENT\n' > "$DWT/composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf ONCE > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'the hardlink falls back as expected' 'differs from the main checkout' "$out"
eq 'and the install ran' 'ONCE' "$(cat "$DWT/vendor/m" 2>/dev/null)"
printf 'AGAIN' > "$DWT/vendor/m"
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a second run over a fallen-back hardlink is already up to date' 'already up to date' "$out"
eq '...and does NOT reinstall' 'AGAIN' "$(cat "$DWT/vendor/m" 2>/dev/null)"
printf 'LOCKV1\n' > "$DWT/composer.lock"

# --- an already-present directory is not claimed as a fresh link ------------
rm -rf "$DWT/vendor"
mkdir -p "$DREPO/vendor/pkg"; printf 'REAL\n' > "$DREPO/vendor/pkg/file.txt"
mkdir -p "$DWT/vendor"; printf 'PREEXISTING\n' > "$DWT/vendor/mine.txt"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'printf SHOULDNOTRUN > /dev/null' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'an existing dependency directory is left alone' 'already present in the worktree' "$out"
eq '...and its contents are untouched' 'PREEXISTING' "$(cat "$DWT/vendor/mine.txt" 2>/dev/null)"
case $out in
  *'hardlinked from the main checkout'*)
    fail=$((fail+1)); printf 'FAIL claimed a hardlink it did not make\n' >&2 ;;
  *) pass=$((pass+1)) ;;
esac

# --- command-position placeholder safety ------------------------------------
# A worktree name comes from a less trusted party than the profile. With {name} in command
# position, a name carrying shell syntax must stop the dependency, not run a second command.
rm -rf "$DWT/vendor" "$TMP/pwned"
WT_NAME='q; touch '"$TMP"'/pwned'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'printf %s {name} > /dev/null' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
eq 'a worktree name carrying shell syntax does not execute' '' \
  "$([ -e "$TMP/pwned" ] && echo pwned)"
contains '...and the refusal names the placeholder' 'interpolate {name}' "$out"
# The same value is harmless when the command never interpolates it.
rm -rf "$DWT/vendor"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf safe > vendor/m' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'a dangerous name does not block commands that never use it' 'safe' \
  "$(cat "$DWT/vendor/m" 2>/dev/null)"
# An ordinary name still interpolates normally.
rm -rf "$DWT/vendor"
WT_NAME='feature-99'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && printf %s {name} > vendor/m' '')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'an ordinary worktree name still expands into the command' 'feature-99' \
  "$(cat "$DWT/vendor/m" 2>/dev/null)"
# A verify command is checked too, not only install.
rm -rf "$DWT/vendor" "$TMP/pwned2"
WT_NAME='x; touch '"$TMP"'/pwned2'
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor' 'test -n "{name}"')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq 'the verify command is guarded as well as the install' '' \
  "$([ -e "$TMP/pwned2" ] && echo pwned)"
# shellcheck disable=SC2034
WT_NAME='dep1'

# --- symlinked parent on the dependency path --------------------------------
# This path runs `rm -rf` and `cp -al`, both of which follow symlinked ancestors.
rm -rf "$DWT/sub" "$TMP/target-dir"
mkdir -p "$TMP/target-dir"; printf 'PRECIOUS\n' > "$TMP/target-dir/keep.txt"
ln -s "$TMP/target-dir" "$DWT/sub"
wt_state_set "$DWT" sub/vendor install LZ IZ doing
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw sub/vendor composer.lock install 'true' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a dependency under a symlinked directory is refused' 'parent directories is a symlink' "$out"
eq '...and nothing outside the worktree is deleted' 'PRECIOUS' \
  "$(cat "$TMP/target-dir/keep.txt" 2>/dev/null)"
rm -f "$DWT/sub"

# --- unknown strategy -------------------------------------------------------
rm -rf "$DWT/weird"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw weird composer.lock sideways 'mkdir -p weird' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'an unrecognised strategy is refused rather than silently succeeding' 'unknown strategy' "$out"
eq '...and nothing is recorded as done for it' 1 \
  "$(wt_state_is_done "$DWT" weird "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'mkdir -p weird')" sideways; echo $?)"

# --- empty fields -----------------------------------------------------------
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw '' composer.lock install 'true' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'an entry with no directory is skipped with a reason' 'no directory to populate' "$out"
rm -rf "$DWT/nocmd"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw nocmd composer.lock install '' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'an install strategy with no command says so' 'no install command' "$out"
eq '...and is recorded as needing another look, not as done' 1 \
  "$(wt_state_is_done "$DWT" nocmd "$(wt_cksum_file "$DWT/composer.lock")" '' install; echo $?)"

# --- wt_budget_left ---------------------------------------------------------
eq 'a past deadline leaves no budget' 0 "$(wt_budget_left $(( $(date +%s) - 10 )))"
eq 'an empty deadline falls back to the default rather than 0' "$WT_DEFAULT_TIMEOUT" \
  "$(wt_budget_left '')"
eq 'a non-numeric deadline falls back to the default too' "$WT_DEFAULT_TIMEOUT" \
  "$(wt_budget_left abc)"
left_now=$(wt_budget_left $(( $(date +%s) + 50 )))
eq 'a future deadline reports roughly the time remaining' yes \
  "$([ "$left_now" -ge 48 ] && [ "$left_now" -le 50 ] && echo yes)"

# --- wt_state_status guard branches -----------------------------------------
# These sit in front of the `rm -rf`: a foreign-format file read as `doing` would delete a tree.
printf 'wtstate%s99%sdep%svendor%sinstall%sL%sI%sdoing%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$DWT")"
eq 'a foreign-version state file reports no status, so nothing is deleted' '' \
  "$(wt_state_status "$DWT" vendor)"
printf 'dep%svendor%sinstall%sL%sI%sdoing%s' \
  "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$DWT")"
eq 'a headerless state file reports no status either' '' "$(wt_state_status "$DWT" vendor)"
rm -f "$(wt_state_path "$DWT")"
eq 'a missing state file reports no status' '' "$(wt_state_status "$DWT" vendor)"
# ...and end to end: such a file must not trigger the interrupted-run cleanup.
rm -rf "$DWT/vendor"; mkdir -p "$DWT/vendor"; printf 'KEEPME\n' > "$DWT/vendor/keep.txt"
printf 'wtstate%s99%sdep%svendor%sinstall%sL%sI%sdoing%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" > "$(wt_state_path "$DWT")"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'true' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
case $out in
  *'previous run was interrupted'*) fail=$((fail+1)); printf 'FAIL deleted a tree on an unreadable state file\n' >&2 ;;
  *) pass=$((pass+1)) ;;
esac
eq 'a tree is not deleted on the strength of an unreadable state file' 'KEEPME' \
  "$(cat "$DWT/vendor/keep.txt" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Build output — artifacts[]
# ---------------------------------------------------------------------------
# A real main checkout with a build of its own, and a worktree whose inputs are or are not the same.
# The fake build counts its runs, so "not built" is observable rather than inferred.
AREPO=$TMP/arepo
git init -q "$AREPO"
git -C "$AREPO" config user.email t@example.com
git -C "$AREPO" config user.name t
mkdir -p "$AREPO/src" "$AREPO/docs"
printf '/public/build/\n/dist/\n' > "$AREPO/.gitignore"
printf 'v1\n' > "$AREPO/src/app.js"
printf 'readme\n' > "$AREPO/docs/notes.md"
printf 'LOCK1\n' > "$AREPO/pnpm-lock.yaml"
git -C "$AREPO" add -A
git -C "$AREPO" commit -qm init
mkdir -p "$AREPO/public/build"
printf 'from-main\n' > "$AREPO/public/build/app.js"
AWT=$AREPO/.claude/worktrees/art1
git -C "$AREPO" worktree add -q "$AWT" -b wt-art1 2>/dev/null
ACNT=$TMP/build-count
ABUILD="printf x >> $ACNT; mkdir -p public/build && printf built > public/build/app.js"
AINPUTS='["src","pnpm-lock.yaml"]'

art_raw() {  # $1 = dir, $2 = inputs (compact JSON), $3 = build, $4 = verify, $5 = link
  printf '0%s%s5%s%s%s%s%s%s%s%s%s%s%s' \
    "$US_" "$RS_" "$US_" "$1" "$US_" "$2" "$US_" "$3" "$US_" "$4" "$US_" "${5-}" "$RS_"
}
art_reset() {  # a worktree with no build output and no record
  rm -rf "$AWT/public" "$ACNT"
  rm -f "$(wt_state_path "$AWT")"
}
# shellcheck disable=SC2012  # the names are the fixture's own, and ls -i is the portable inode read.
inode_of() { ls -i "$1" 2>/dev/null | awk '{print $1}'; }
art_status() { wt_art_state_read "$AWT" "${1:-public/build}" || true; printf '%s' "$WT_DEP_STATUS"; }

# --- inputs unchanged: the main checkout's build is taken ---------------------
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'artifact, inputs unchanged: the main checkout'"'"'s build is taken' 'from-main' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
eq '...without running the build' no "$([ -e "$ACNT" ] && echo yes || echo no)"
ne '...as a COPY by default, not a link into the main checkout' "$(inode_of "$AREPO/public/build/app.js")" \
  "$(inode_of "$AWT/public/build/app.js")"
contains '...and says so' 'copied from the main checkout' "$out"
eq '...recorded done' "done" "$(art_status)"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a second run finds it up to date' 'public/build: already up to date' "$out"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' hardlink)
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'link "hardlink": the same inode as the main checkout'"'"'s' "$(inode_of "$AREPO/public/build/app.js")" \
  "$(inode_of "$AWT/public/build/app.js")"
# Not approved: `dir` is the profile's word, so main's copy is not taken either (ADR-020).
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
out=$(WT_APPROVAL=no wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'unapproved, inputs unchanged: main'"'"'s build is not taken' no "$([ -e "$AWT/public/build" ] && echo yes || echo no)"
contains '...and says why' 'public/build: not taken or built — the profile'"'"'s commands are not approved' "$out"
eq '...and nothing is recorded' '' "$(art_status)"
# Deferred: a real copy is the background run's; a hardlink is cheap enough for start-up.
art_reset
out=$(WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'deferred, link copy: not copied at start-up' no "$([ -e "$AWT/public/build" ] && echo yes || echo no)"
contains '...but in the background' 'public/build: to be copied from the main checkout in the background' "$out"
eq '...and nothing is recorded' '' "$(art_status)"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' hardlink)
WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'deferred, link hardlink: linked at start-up' "$(inode_of "$AREPO/public/build/app.js")" \
  "$(inode_of "$AWT/public/build/app.js")"
# A pull request's worktree copies what the profile hardlinks: its watcher rewrites outputs in place,
# which through a shared inode would write into main's build.
art_reset
git -C "$AREPO" config branch.wt-art1.merge refs/pull/12/head
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'pr, link hardlink: main'"'"'s build is taken' 'from-main' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
eq '...as a copy: no file of it shares an inode' '' "$(find "$AWT/public/build" -type f -links +1)"
contains '...saying why' "public/build: a pull request's worktree takes its own copy" "$out"
contains '...and that it copied' 'public/build: copied from the main checkout' "$out"
wt_art_state_read "$AWT" public/build
eq '...recorded done, as its own copy' "done|own-copy" "$WT_DEP_STATUS|$WT_DEP_STRATEGY"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains '...which the next run finds up to date' 'public/build: already up to date' "$out"
# Linked before this: no longer up to date, and replaced by a copy (in the background when deferred).
git -C "$AREPO" config --unset branch.wt-art1.merge
art_reset
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'pr: (fixture) linked while not yet a pull request' "$(inode_of "$AREPO/public/build/app.js")" \
  "$(inode_of "$AWT/public/build/app.js")"
git -C "$AREPO" config branch.wt-art1.merge refs/pull/12/head
eq 'pr: a linked build output recorded done is pending again' 'build output public/build' \
  "$(PROFILE_PRESENT=1 wt_bootstrap_pending "$AWT"; printf '%s' "$WT_PENDING_ATTEMPTABLE")"
out=$(WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains '...at start-up its copy is left for the background run' 'public/build: to be copied from the main checkout in the background' "$out"
amain=$(inode_of "$AREPO/public/build/app.js")
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...which replaces it with a copy' "from-main|" "$(cat "$AWT/public/build/app.js")|$(find "$AWT/public/build" -type f -links +1)"
eq "...main's file keeps its inode" "$amain" "$(inode_of "$AREPO/public/build/app.js")"
wt_art_state_read "$AWT" public/build
eq '...recorded as its own copy' "done|own-copy" "$WT_DEP_STATUS|$WT_DEP_STRATEGY"
git -C "$AREPO" config --unset branch.wt-art1.merge
# A `doing` record at start-up is the background run's: no wait on its lock.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
wt_art_state_set "$AWT" public/build build k "$(wt_cksum_string "$ABUILD")" doing
out=$(WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'deferred, a build recorded doing: left to the background run' 'public/build: being built in the background' "$out"
eq '...untouched' no "$([ -e "$AWT/public/build" ] && echo yes || echo no)"
if command -v flock >/dev/null 2>&1; then
  # The lock held by another run: start-up does not wait on it.
  art_reset
  ALOCK="$(wt_state_path "$AWT").build.lock"
  # One process holding the lock, so killing it frees it: `flock path sleep` leaves its child holding it.
  ( exec 9>"$ALOCK"; flock 9; exec sleep 30 ) &
  ALOCKPID=$!
  t0=$(date +%s)
  sleep 0.3
  out=$(WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
  eq 'deferred, the lock held elsewhere: no wait for it' yes "$([ $(( $(date +%s) - t0 )) -lt 5 ] && echo yes || echo no)"
  contains '...and it is left to that run' 'public/build: another run here is working on it — leaving it alone' "$out"
  kill "$ALOCKPID" 2>/dev/null; wait "$ALOCKPID" 2>/dev/null
fi
# A `doing` record with the lock free is a killed run's: it does not block.
art_reset
wt_art_state_set "$AWT" public/build build k "$(wt_cksum_string "$ABUILD")" doing
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a stale doing record, the lock free: taken from main' 'from-main' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
# Without flock (stock macOS) nothing can tell a live `doing` from a stale one, so it does not block.
make_noflock_bin
art_reset
wt_art_state_set "$AWT" public/build build k "$(wt_cksum_string "$ABUILD")" doing
out=$(PATH=$NOFLOCK WT_FLOCK_WARNED=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'no flock, a stale doing record: taken from main' 'from-main' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
contains '...saying it goes ahead unlocked' 'public/build: going ahead without the lock' "$out"
lacks '...without claiming another run is working' 'another run here' "$out"
# A dir that main does not gitignore is not main's build output, whatever the branch's .gitignore
# says: a branch must not be able to name one of main's private dirs and have it copied out.
art_reset
printf '/secret/\n' >> "$AWT/.gitignore"
git -C "$AWT" commit -qam 'branch ignores secret/'
mkdir -p "$AREPO/secret"; printf 'private\n' > "$AREPO/secret/data"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw secret '["src"]' "printf x >> $ACNT; mkdir -p secret && printf built > secret/data" '' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'a dir gitignored only on the branch: main'"'"'s is not copied' built "$(cat "$AWT/secret/data" 2>/dev/null)"
contains '...and says why' 'secret: not taken from the main checkout — there it is not gitignored' "$out"
rm -rf "$AREPO/secret" "$AWT/secret"
git -C "$AWT" revert --no-edit HEAD >/dev/null
# A trailing slash would have cp nest main's dir inside the worktree's: refused.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build/ "$AINPUTS" "$ABUILD" '' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a dir with a trailing slash is refused' 'refusing "public/build/"' "$out"
eq '...and nothing is taken' no "$([ -e "$AWT/public/build" ] && echo yes || echo no)"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
# Taking main's copy is bounded by the budget: a copy that runs past it leaves nothing behind.
SLOWCP=$TMP/slowcp-bin
mkdir -p "$SLOWCP"
printf '#!/bin/sh\nsleep 5\nexec %s "$@"\n' "$(command -v cp)" > "$SLOWCP/cp"
chmod +x "$SLOWCP/cp"
art_reset
out=$(PATH=$SLOWCP:$PATH wt_art_take_main "$AREPO" "$AWT" public/build copy 1 2>&1); rc=$?
eq 'a copy past its time: 2 (try again later)' 2 "$rc"
contains '...saying so' 'ran past the 1s left in the budget' "$out"
eq '...and nothing half-copied is left' no "$([ -e "$AWT/public/build" ] && echo yes || echo no)"
# A copy that fails falls back to the build, leaving no half-copied tree for it to be recorded on.
# Root reads an unreadable file anyway, so this is skipped as root.
if [ "$(id -u)" != 0 ]; then
  art_reset
  printf 'secret\n' > "$AREPO/public/build/locked.js"; chmod 000 "$AREPO/public/build/locked.js"
  out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
  contains 'a copy that fails: says it builds instead' 'public/build: could not copy it from the main checkout' "$out"
  contains '...building instead' 'building instead' "$out"
  eq '...the build ran' x "$(cat "$ACNT" 2>/dev/null)"
  eq '...its output is the build'"'"'s' built "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
  eq '...with nothing of the failed copy left' no "$([ -e "$AWT/public/build/locked.js" ] && echo yes || echo no)"
  chmod 600 "$AREPO/public/build/locked.js"; rm -f "$AREPO/public/build/locked.js"
  # A worktree dir that cannot be cleared: cp would nest main's inside it, so it is built instead.
  art_reset
  mkdir -p "$AWT/public/build/stuck"; printf 'old\n' > "$AWT/public/build/stuck/old.js"
  chmod 555 "$AWT/public/build/stuck"
  wt_art_state_set "$AWT" public/build build k "$(wt_cksum_string "$ABUILD")" dirty
  out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
  contains 'a dir rm -rf cannot clear: says so' 'public/build: could not clear what is in the worktree'"'"'s public/build — building instead' "$out"
  eq '...main'"'"'s dir is not nested inside it' no "$([ -e "$AWT/public/build/build" ] && echo yes || echo no)"
  eq '...and the build ran' built "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
  chmod 755 "$AWT/public/build/stuck"
fi
# A change OUTSIDE the inputs does not count.
printf 'more\n' >> "$AWT/docs/notes.md"
git -C "$AWT" commit -qam 'docs only'
art_reset
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a commit outside the inputs still takes the main checkout'"'"'s build' 'from-main' \
  "$(cat "$AWT/public/build/app.js" 2>/dev/null)"

# An uncommitted edit is not the branch: what decides is HEAD.
art_reset
printf 'v3-uncommitted\n' > "$AWT/src/app.js"
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'an uncommitted edit to an input: the main checkout'"'"'s build is still taken' 'from-main' \
  "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
git -C "$AWT" checkout -q -- src/app.js

# --- the main checkout has no build: built ------------------------------------
art_reset
mv "$AREPO/public/build" "$TMP/main-build-aside"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'main has no build output: built' 'built' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
eq '...once' x "$(cat "$ACNT" 2>/dev/null)"
contains '...and says why' 'the main checkout has no build output there' "$out"
eq '...recorded done' "done" "$(art_status)"
mv "$TMP/main-build-aside" "$AREPO/public/build"
# An EMPTY main build is no build.
art_reset
mkdir -p "$TMP/empty-aside"; mv "$AREPO/public/build/app.js" "$TMP/empty-aside/"
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'an empty main build output: built' 'built' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
mv "$TMP/empty-aside/app.js" "$AREPO/public/build/"

# --- an input changed on the worktree's branch: built ------------------------
printf 'v2\n' > "$AWT/src/app.js"
git -C "$AWT" commit -qam 'change an input'
art_reset
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'an input changed in the branch: built, not taken from main' 'built' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
contains '...and says why' 'its inputs differ from the main checkout' "$out"
git -C "$AWT" revert --no-edit HEAD >/dev/null
# The lockfile is an input too.
printf 'LOCK2\n' > "$AWT/pnpm-lock.yaml"
git -C "$AWT" commit -qam 'bump the lockfile'
art_reset
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a lockfile named in the inputs changed: built' 'built' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"

# --- a done build whose inputs a later commit changes: rebuilt by a --finish run, never at start-up --
art_reset
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'stale: (fixture) built once' x "$(cat "$ACNT" 2>/dev/null)"
printf 'v5\n' > "$AWT/src/app.js"
git -C "$AWT" commit -qam 'a later input change'
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'stale: a start-up run does not rebuild it' x "$(cat "$ACNT")"
contains '...says its inputs changed' 'public/build: its inputs changed in a commit since it was built — left as it is for now' "$out"
eq '...and leaves the build there' built "$(cat "$AWT/public/build/app.js" 2>/dev/null)"
eq '...it is pending, and attemptable, so a background run is started for it' \
  'build output public/build|build output public/build' "$(PROFILE_PRESENT=1 pending_all "$AWT")|$(PROFILE_PRESENT=1 pending_attemptable "$AWT")"
eq '...as out of date, not missing' 'artstale|public/build|' "$(PROFILE_PRESENT=1 wt_bootstrap_pending "$AWT"; printf '%s' "${WT_STATUS_ITEMS//"$US_"/|}")"
contains '...which the status line says' 'build output public/build out of date (its inputs changed in a commit; rebuilding in the background)' \
  "$(PROFILE_PRESENT=1 wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" start background)"
contains '...with no background run, as changed since it was built' \
  'build output public/build out of date (its inputs changed in a commit since it was built)' \
  "$(PROFILE_PRESENT=1 wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" start '')"
contains '...after a --finish that did not rebuild it, pointing at stderr' \
  'build output public/build out of date (its inputs changed in a commit, and it was not rebuilt; stderr says why)' \
  "$(PROFILE_PRESENT=1 wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" finish '')"
# Behind a dependency whose failure stands, a run would not rebuild it either.
stale_raw=$PROFILE_RAW
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'true' '')${PROFILE_RAW#0"$US_$RS_"}
printf 'L\n' > "$AWT/composer.lock"
wt_state_set "$AWT" vendor install "$(wt_cksum_file "$AWT/composer.lock")" "$(wt_cksum_string true)" failed 1 'boom'
eq 'stale: behind a dependency whose failure stands, not attemptable' '' "$(PROFILE_PRESENT=1 pending_attemptable "$AWT")"
eq '...though still pending' $'vendor\nbuild output public/build' "$(PROFILE_PRESENT=1 pending_all "$AWT")"
rm -f "$AWT/composer.lock"
PROFILE_RAW=$stale_raw
out=$(WT_FINISH=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'stale: a --finish run rebuilds it' xx "$(cat "$ACNT")"
contains '...saying why' 'public/build: its inputs changed in a commit since it was built — bringing it up to date' "$out"
eq '...and then nothing is pending' '' "$(PROFILE_PRESENT=1 pending_all "$AWT")"
out=$(WT_FINISH=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'stale: no input change since, no rebuild' xx "$(cat "$ACNT")"
contains '...up to date' 'public/build: already up to date' "$out"
printf 'more notes\n' >> "$AWT/docs/notes.md"
git -C "$AWT" commit -qam 'docs only, again'
WT_FINISH=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'stale: a commit outside the inputs does not rebuild it' xx "$(cat "$ACNT")"
printf 'v6-uncommitted\n' > "$AWT/src/app.js"
WT_FINISH=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...nor an uncommitted edit to an input' xx "$(cat "$ACNT")"
git -C "$AWT" checkout -q -- src/app.js
# A record whose inputs key git could not give is not taken as changed.
wt_art_state_set "$AWT" public/build build '' "$(wt_cksum_string "$ABUILD")" "done"
WT_FINISH=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...nor a record with no inputs key' xx "$(cat "$ACNT")"
eq 'inputs key: empty, and 1, when git cannot say' '1|' \
  "$(k=$(wt_art_inputs_key "$TMP/not-a-repo" src); echo "$?|$k")"
git -C "$AWT" revert --no-edit HEAD~1 >/dev/null

# --- held back: unapproved, deferred, dependencies missing ---------------------
art_reset
out=$(WT_APPROVAL=no wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'unapproved, inputs changed: nothing is built' no "$([ -e "$ACNT" ] && echo yes || echo no)"
contains '...and says why' 'not taken or built — the profile'"'"'s commands are not approved' "$out"
eq '...and nothing is recorded' '' "$(art_status)"
# shellcheck disable=SC2034
PROFILE_PRESENT=1
art_items() { wt_bootstrap_pending "$AWT"; printf '%s' "${WT_STATUS_ITEMS//"$US_"/|}"; }
eq '...so it is pending' 'artmissing|public/build|' "$(art_items)"
eq '...by name' 'build output public/build' "$(pending_all "$AWT")"
eq '...and attemptable' 'build output public/build' "$(pending_attemptable "$AWT")"
out=$(WT_DEFER=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'deferred, inputs changed: not built at start-up' no "$([ -e "$ACNT" ] && echo yes || echo no)"
contains '...but in the background' 'public/build: to be built in the background' "$out"
# A build needs its dependencies: one that is not installed holds the build back.
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'true' '')${PROFILE_RAW#0"$US_$RS_"}
printf 'L\n' > "$AWT/composer.lock"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'a dependency not installed: not built' no "$([ -e "$ACNT" ] && echo yes || echo no)"
contains '...and says why' 'the dependencies it builds from are not installed' "$out"
wt_state_set "$AWT" vendor install "$(wt_cksum_file "$AWT/composer.lock")" "$(wt_cksum_string true)" failed 1 'boom'
eq '...a dependency whose failure stands makes the build not attemptable' '' "$(pending_attemptable "$AWT")"
eq '...though still pending' $'vendor\nbuild output public/build' "$(pending_all "$AWT")"
rm -f "$AWT/composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
eq 'profile with only an artifact runs commands (needs approval)' 0 \
  "$(PROFILE_PRESENT=1 PROFILE_HAS_RUNTIME=0 wt_profile_runs_commands; echo $?)"

# --- verify decides, as for deps ----------------------------------------------
AFAIL="printf x >> $ACNT; mkdir -p public/build && printf partial > public/build/app.js; printf 'error: one chunk too big\\n' >&2; exit 1"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$AFAIL" 'test -f public/build/app.js' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'build fails, verify passes: warn' warn "$(art_status)"
contains '...and says so' 'built with warnings' "$out"
eq '...a status item with its reason' 'artwarn|public/build|error: one chunk too big' "$(art_items)"
eq '...and not pending' '' "$(pending_all "$AWT")"
contains 'status: a warned build reads "ready with warnings"' 'build output public/build ready with warnings (error: one chunk too big)' \
  "$(wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" finish '')"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$AFAIL" 'test -f public/build/nope.js' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'build fails, verify fails: failed' failed "$(art_status)"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq '...and is not re-run while its inputs and command are unchanged' x "$(cat "$ACNT")"
contains '...saying the failure stands' 'the recorded build failure stands' "$out"
eq '...a standing status item' 'artstanding|public/build|error: one chunk too big' "$(art_items)"
eq '...pending, but not attemptable' 'build output public/build|' "$(pending_all "$AWT")|$(pending_attemptable "$AWT")"
out=$(wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" start '')
contains 'status: a failed build is named as such' 'build output public/build missing (build failed: error: one chunk too big)' "$out"
contains '...and the retry rule names builds' 'nor a failed build while its inputs and build command are' "$out"
WT_RETRY_FAILED=1 wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '--retry-failed re-runs it' xx "$(cat "$ACNT")"
# A changed input lifts the standing failure.
printf 'v4\n' > "$AWT/src/app.js"
git -C "$AWT" commit -qam 'another input change'
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a changed input retries a failed build' xxx "$(cat "$ACNT")"
# Exit 0 with nothing written, and no verify to ask: not built.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "printf x >> $ACNT; mkdir -p public/build" '' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a build that exits 0 but writes nothing: failed' failed "$(art_status)"
# Exit 0 but verify fails: dirty, no standing failure, built again next run.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" 'test -f public/build/nope.js' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'build exits 0, verify fails: dirty' dirty "$(art_status)"
contains '...and says it is built again' 'the verify command failed (exit 1) — it will be built again next session' "$out"
eq '...missing, not a standing failure' 'artmissing|public/build|dirty' "$(art_items)"
eq '...and attemptable' 'build output public/build' "$(pending_attemptable "$AWT")"
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...built again by the next run' xx "$(cat "$ACNT")"
# A build stopped — by its time limit, the OOM killer or the memory guard — is dirty, not failed.
for stop_rc in 124 137 "$WT_GUARD_REFUSED"; do
  art_reset
  # shellcheck disable=SC2034
  PROFILE_RAW=$(art_raw public/build "$AINPUTS" "printf x >> $ACNT; exit $stop_rc" '' '')
  wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
  eq "a build stopped with $stop_rc: dirty" dirty "$(art_status)"
  eq '...no standing failure' 'artmissing|public/build|dirty' "$(art_items)"
  wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
  eq '...and the next run tries again' xx "$(cat "$ACNT")"
done
# Built, but no budget left for verify: dirty. The build itself spends the budget.
art_reset
ABUDGET=$TMP/budget-gone
rm -f "$ABUDGET"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD; touch $ABUDGET" 'true' '')
out=$(
  # shellcheck disable=SC2329  # replaces the library's, called by wt_bootstrap_artifacts.
  wt_budget_left() { if [ -e "$ABUDGET" ]; then printf 0; else printf 600; fi; }
  wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1
)
eq 'built with no budget left for verify: dirty' dirty "$(art_status)"
contains '...and says so' 'no budget left to verify' "$out"
eq '...no standing failure' 'artmissing|public/build|dirty' "$(art_items)"
rm -f "$ABUDGET"

# A changed build command rebuilds a done build, and lifts a standing failure.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
ick_before=$(wt_art_state_read "$AWT" public/build; printf '%s' "$WT_DEP_ICK")
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD; true" '' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a done build whose command changed: built again' xx "$(cat "$ACNT")"
ne '...and recorded for the new command' "$ick_before" "$(wt_art_state_read "$AWT" public/build; printf '%s' "$WT_DEP_ICK")"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$AFAIL" 'false' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a failed build...' failed "$(art_status)"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...whose command changed: built again' xx "$(cat "$ACNT")"
eq '...and done' "done" "$(art_status)"

# --- the status line and /pitlane-serve name a missing build --------------------
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
out=$(wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" start background)
contains 'status: a build in progress is named' 'build output public/build missing (still building)' "$out"
out=$(wt_bootstrap_pending "$AWT"; wt_bootstrap_status_line "$SLW" start approval)
contains 'status: an unapproved build is held back' 'build output public/build missing (held back)' "$out"
wt_serve_missing "$AWT"
eq 'serve: a missing build is a named missing piece' 'build output public/build not built' "$WT_SERVE_MISSING"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$AFAIL" 'false' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
wt_serve_missing "$AWT"
eq 'serve: a failed build is named with its reason' \
  'build output public/build not built (its build failed: error: one chunk too big)' "$WT_SERVE_MISSING"
# A recorded build whose dir was deleted since is missing again.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq 'a build in place is not missing' '' "$(art_items)"
rm -rf "$AWT/public/build"
eq '...until its dir is deleted' 'artmissing|public/build|done' "$(art_items)"
wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>/dev/null
eq '...when the next run builds it again' 'built' "$(cat "$AWT/public/build/app.js" 2>/dev/null)"

# --- what is never touched ----------------------------------------------------
# The developer's own build, with no record of ours, is left as it is.
art_reset
mkdir -p "$AWT/public/build"; printf 'mine\n' > "$AWT/public/build/app.js"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
eq 'a build already in the worktree is left alone' 'mine' "$(cat "$AWT/public/build/app.js")"
contains '...and says so' 'already present in the worktree' "$out"
# A dir that is not gitignored is the branch's own files: never cleared, never built into.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw src "$AINPUTS" "$ABUILD" '' '')
mv "$AREPO/public/build" "$TMP/main-build-aside"
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a dir that is not gitignored is refused' 'src: not touched — it is not gitignored' "$out"
eq '...and its tracked files are intact' 'v4' "$(cat "$AWT/src/app.js")"
eq '...and nothing is built' no "$([ -e "$ACNT" ] && echo yes || echo no)"
# Gitignored, but holding a force-added tracked file.
mkdir -p "$AWT/dist"; printf 'tracked\n' > "$AWT/dist/keep.js"
git -C "$AWT" add -f dist/keep.js && git -C "$AWT" commit -qm 'force-add into dist'
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw dist "$AINPUTS" "$ABUILD" '' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a gitignored dir holding a tracked file is refused' 'dist: not touched — it is not gitignored, or holds tracked files' "$out"
eq '...and the tracked file is intact' 'tracked' "$(cat "$AWT/dist/keep.js")"
mv "$TMP/main-build-aside" "$AREPO/public/build"
# A symlinked dir would have the build written, and cleared, wherever it points.
art_reset
mkdir -p "$AWT/public" "$TMP/link-target"; printf 'outside\n' > "$TMP/link-target/app.js"
ln -s "$TMP/link-target" "$AWT/public/build"
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build "$AINPUTS" "$ABUILD" '' '')
out=$(wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a symlinked artifact dir is refused' 'public/build: not touched — it is a symlink' "$out"
eq '...and what it points at is intact' 'outside' "$(cat "$TMP/link-target/app.js")"
rm -f "$AWT/public/build"
# A command interpolating an unsafe placeholder is not run.
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build '["pnpm-lock.yaml"]' "printf x >> $ACNT; echo {name}" '' '')
printf 'LOCK9\n' > "$AWT/pnpm-lock.yaml"; git -C "$AWT" commit -qam 'lock 9'
out=$(WT_NAME='a;b' wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a build interpolating an unsafe {name} is refused' 'refusing to run its commands' "$out"
eq '...and not run' no "$([ -e "$ACNT" ] && echo yes || echo no)"
art_reset
# shellcheck disable=SC2034
PROFILE_RAW=$(art_raw public/build '["pnpm-lock.yaml"]' "$ABUILD" "echo {name}" '')
out=$(WT_NAME='a;b' wt_bootstrap_artifacts "$AREPO" "$AWT" "$FAR" 2>&1)
contains 'a verify interpolating an unsafe {name} is refused' 'public/build: refusing to run its commands — they interpolate {name}' "$out"
eq '...and the build is not run either' no "$([ -e "$ACNT" ] && echo yes || echo no)"
art_reset
# shellcheck disable=SC2034
PROFILE_PRESENT=0 PROFILE_RAW=''

# ---------------------------------------------------------------------------
# Drift reporting
# ---------------------------------------------------------------------------
# Against the REAL reference/detection.json — a fixture table would only prove the fixture, and the
# point is that adding an ecosystem there needs no change here. The path is pinned rather than
# inherited: wt_report_drift prefers an ambient WT_DETECTION_JSON and the default is resolved from
# CLAUDE_PLUGIN_ROOT, which is set inside any Claude Code session, so without this the suite could
# silently assert against an installed copy of the table instead of this repo's.
WT_DETECTION_JSON=$(cd "$(dirname "${BASH_SOURCE[0]}")/../reference" && pwd -P)/detection.json
export WT_DETECTION_JSON

DRTREE=$TMP/drift
mkdir -p "$DRTREE"
: > "$DRTREE/composer.lock"
CURDET=$(wt_json_get detectionVersion <"$WT_DETECTION_JSON")
eq 'the detection table reports a version, so the drift fixtures mean something' yes \
  "$([ -n "$CURDET" ] && echo yes)"

CK=$(wt_cksum_file "$DRTREE/composer.lock")
# The checksums now come out of PROFILE_RAW, the same stream a real load produces.
raw_with() {  # $1 = lockChecksum to record
  printf '0%s%s1%svendor%scomposer.lock%sinstall%sx%s%s%s%s' \
    "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$1" "$RS_"
}
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$CK")

eq 'a profile that matches the checkout reports no drift at all' '' \
  "$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)"

# A gained ecosystem. This is the one that broke: with a single-element markers array the last
# unterminated line was dropped by `read`, so nearly every marker went unchecked.
: > "$DRTREE/pnpm-lock.yaml"
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a lockfile the profile never saw is reported' 'pnpm-lock.yaml' "$out"
contains '...and points at the fix' 'pitlane-setup' "$out"
: > "$DRTREE/Gemfile.lock"
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a second gained ecosystem is reported too' 'Gemfile.lock' "$out"
rm -f "$DRTREE/Gemfile.lock" "$DRTREE/pnpm-lock.yaml"

# FALSE POSITIVES ARE THE FAILURE MODE HERE. A warning that fires on a checkout that has not
# drifted, whose suggested fix produces an identical profile, is how people learn to ignore the
# warning that matters. Two shapes of that, both real:
#
#   1. A rule with several markers records only the one it matched. bun.lock and bun.lockb belong
#      to one rule, so a repo with both must not be told it "gained" the sibling.
: > "$DRTREE/bun.lock"
: > "$DRTREE/bun.lockb"
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock","bun.lock"]' '' 2>&1)
lacks 'a sibling marker of an already-recorded rule is not reported as gained' 'bun.lockb' "$out"
rm -f "$DRTREE/bun.lock" "$DRTREE/bun.lockb"
#   2. detection.json's sameDirPolicy accepts only one rule per target directory, so a stale
#      package-lock.json beside the pnpm-lock.yaml that won is not a new ecosystem. The profile
#      already has a dependency on that directory, which is how it is recognised.
: > "$DRTREE/pnpm-lock.yaml"
: > "$DRTREE/package-lock.json"
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%snode_modules%spnpm-lock.yaml%sinstall%sx%s%s%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
out=$(wt_report_drift "$DRTREE" "$CURDET" '["pnpm-lock.yaml"]' '' 2>&1)
lacks 'a second lockfile claiming a directory the profile already covers is not reported' \
  'package-lock.json' "$out"
rm -f "$DRTREE/pnpm-lock.yaml" "$DRTREE/package-lock.json"
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$CK")

# A lost marker.
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock","pnpm-lock.yaml"]' '' 2>&1)
contains 'a lockfile the profile expects and is now gone is reported' 'no longer has: pnpm-lock.yaml' "$out"

# The toolchain marker: a branch that gained a flake is now installing on the wrong toolchain.
: > "$DRTREE/flake.nix"
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a newly appeared flake.nix is reported as a toolchain change' 'toolchain marker changed' "$out"
contains '...naming both sides' 'none -> flake.nix' "$out"
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' 'flake.nix' 2>&1)
eq '...and says nothing when it was already recorded' '' "$out"
rm -f "$DRTREE/flake.nix"

# The detection table version.
out=$(wt_report_drift "$DRTREE" 0 '["composer.lock"]' '' 2>&1)
contains 'an older detection table version is reported' 'detection table is now version' "$out"

# THE LOCKFILE CHECKSUMS, which live in deps[] and not in `evidence`. They must be checked even
# when there is no evidence block at all — a hand-written profile still records them, and gating
# them on evidence left the one comparator calibration shipped unwired for exactly those profiles.
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "1 1")
out=$(wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a lockfile changed since calibration is reported' 'has changed since calibration' "$out"
out=$(wt_report_drift "$DRTREE" '' '' '' 2>&1)
contains 'and it is STILL reported when the profile carries no evidence block' \
  'has changed since calibration' "$out"
out=$(WT_DETECTION_JSON=/nonexistent/table.json wt_report_drift "$DRTREE" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'and even when the detection table cannot be read' 'has changed since calibration' "$out"
# A lockfile the profile names that has since vanished.
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%svendor%sgone.lock%sinstall%sx%s%s9 9%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
contains 'a lockfile that has disappeared is reported' 'no longer exists' \
  "$(wt_report_drift "$DRTREE" '' '' '' 2>&1)"

# WITHOUT a loaded profile there is nothing in PROFILE_RAW, so the checksums come from lib.sh's
# file-based comparator instead. Both routes must reach the same verdict on the same profile, or
# a hook and the calibrate skill would disagree about whether a repo has drifted.
cat > "$DRTREE/p-stale.json" <<JSON
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
 "install":"x","lockChecksum":"1 1"}]}
JSON
# shellcheck disable=SC2034
PROFILE_RAW=''
out=$(wt_report_drift "$DRTREE" '' '' '' "$DRTREE/p-stale.json" 2>&1)
contains 'with no loaded profile the checksums are still compared, via the file' \
  'has changed since calibration' "$out"
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "1 1")
out2=$(wt_report_drift "$DRTREE" '' '' '' 2>&1)
eq 'and both routes agree that this profile has drifted' \
  "$(printf '%s' "$out" | grep -c 'changed since calibration')" \
  "$(printf '%s' "$out2" | grep -c 'changed since calibration')"
cat > "$DRTREE/p-fresh.json" <<JSON
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
 "install":"x","lockChecksum":"$CK"}]}
JSON
# shellcheck disable=SC2034
PROFILE_RAW=''
eq 'and both agree when it has NOT drifted: the file route is silent' '' \
  "$(wt_report_drift "$DRTREE" '' '' '' "$DRTREE/p-fresh.json" 2>&1)"
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$CK")
eq '...as is the loaded-profile route' '' "$(wt_report_drift "$DRTREE" '' '' '' 2>&1)"
# A record carrying a copy list after its lockChecksum: the checksum is still the sixth field, so a
# reader that lost track of the seventh would report drift on every hardlinked dir, or miss it.
raw_copy_with() {  # $1 = lockChecksum to record
  printf '0%s%s1%svendor%scomposer.lock%shardlink%sx%s%s%s%s["composer"]%s' \
    "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$1" "$US_" "$RS_"
}
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_copy_with "$CK")
eq 'drift: a matching record with a copy list is silent on the loaded-profile route' '' \
  "$(wt_report_drift "$DRTREE" '' '' '' 2>&1)"
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_copy_with "1 1")
contains '...and a stale one is still reported' 'has changed since calibration' \
  "$(wt_report_drift "$DRTREE" '' '' '' 2>&1)"
cat > "$DRTREE/p-copy.json" <<JSON
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
 "install":"x","lockChecksum":"$CK","copy":["composer",".package-lock.json"]}]}
JSON
# shellcheck disable=SC2034
PROFILE_RAW=''
eq '...and silent on the file route too' '' "$(wt_report_drift "$DRTREE" '' '' '' "$DRTREE/p-copy.json" 2>&1)"

# With everything matching and no evidence, it says nothing at all.
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$CK")
eq 'a matching profile with no evidence block says nothing' '' \
  "$(wt_report_drift "$DRTREE" '' '' '' 2>&1)"

# It must never block, whatever it finds.
wt_report_drift "$DRTREE" 0 '["composer.lock"]' 'flake.nix' >/dev/null 2>&1
eq 'drift reporting always succeeds — it warns, it never blocks' 0 $?

# WHOSE LOCKFILE IS COMPARED: the main checkout's, which is what calibration read. A worktree whose
# own lockfile differs is a branch that touches dependencies, not drift.
DMR=$TMP/driftmain
git init -q "$DMR"
git -C "$DMR" config user.email t@example.com
git -C "$DMR" config user.name t
printf 'MAINLOCK\n' > "$DMR/composer.lock"
git -C "$DMR" add composer.lock; git -C "$DMR" commit -qm init
DMW=$DMR/.claude/worktrees/branch
git -C "$DMR" worktree add -q "$DMW" -b wt-branch 2>/dev/null
MCK=$(wt_cksum_file "$DMR/composer.lock")
printf 'BRANCHLOCK\n' > "$DMW/composer.lock"
cat > "$DMR/p-main.json" <<JSON
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
 "install":"x","lockChecksum":"$MCK"}]}
JSON
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$MCK")
eq "a branch whose lockfile differs from main's gets no drift warning" '' \
  "$(wt_report_drift "$DMW" '' '' '' '' "$DMR" 2>&1)"
eq '...nor when the main checkout is found from the worktree' '' "$(wt_report_drift "$DMW" '' '' '' 2>&1)"
# shellcheck disable=SC2034
PROFILE_RAW=''
eq '...nor by the file route' '' "$(wt_report_drift "$DMW" '' '' '' "$DMR/p-main.json" "$DMR" 2>&1)"
# The main checkout's lockfile moved on since calibration, while this worktree's still matches it.
printf 'MAINLOCK\n' > "$DMW/composer.lock"
printf 'MAINLOCK2\n' > "$DMR/composer.lock"
out=$(wt_report_drift "$DMW" '' '' '' "$DMR/p-main.json" "$DMR" 2>&1)
contains "main's lockfile changed since calibration: the file route warns" 'has changed since calibration' "$out"
# shellcheck disable=SC2034
PROFILE_RAW=$(raw_with "$MCK")
out2=$(wt_report_drift "$DMW" '' '' '' '' "$DMR" 2>&1)
contains '...and so does the loaded-profile route, naming the main checkout' \
  'composer.lock in the main checkout has changed since calibration' "$out2"
contains '...and pointing at the fix' '/pitlane-setup' "$out2"
contains '...with the main checkout found from the worktree too' 'in the main checkout has changed' \
  "$(wt_report_drift "$DMW" '' '' '' 2>&1)"
eq '...and both routes agree' \
  "$(printf '%s' "$out" | grep -c 'changed since calibration')" \
  "$(printf '%s' "$out2" | grep -c 'changed since calibration')"
rm -f "$DMR/composer.lock"
contains "a lockfile gone from the main checkout is reported as such" 'composer.lock no longer exists in the main checkout' \
  "$(wt_report_drift "$DMW" '' '' '' '' "$DMR" 2>&1)"
printf 'MAINLOCK\n' > "$DMR/composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=''

# A Python virtualenv calibrated as a hardlink: its scripts name the main checkout, so the worktree
# would install into, and import from, the main checkout. Warned about, once per run.
VNR=$TMP/venvwarn
mkdir -p "$VNR/env" "$VNR/vendor"
: > "$VNR/env/pyvenv.cfg"
venv_warning() {  # $@ = dir:strategy pairs; prints what wt_warn_hardlinked_venvs logs
  local pair raw
  raw=$(printf '0%s%s' "$US_" "$RS_")
  for pair in "$@"; do
    raw+=$(printf '1%s%s%scomposer.lock%s%s%sx%s%s%s' "$US_" "${pair%%:*}" "$US_" "$US_" "${pair#*:}" "$US_" "$US_" "$US_" "$RS_")
  done
  PROFILE_RAW=$raw WT_VENV_HARDLINK_WARNED='' wt_warn_hardlinked_venvs "$VNR" 2>&1
}
out=$(venv_warning .venv:hardlink)
contains 'a hardlinked .venv is warned about' '.venv: hardlinked, but a Python virtualenv' "$out"
contains '...naming the danger' "installs here go into the main checkout's venv" "$out"
contains '...and the fix' '/pitlane-setup' "$out"
contains 'a nested one too' 'services/api/.venv: hardlinked' "$(venv_warning services/api/.venv:hardlink)"
contains 'and one known by its pyvenv.cfg in the main checkout' 'env: hardlinked' "$(venv_warning env:hardlink)"
eq 'a hardlinked vendor is not' '' "$(venv_warning vendor:hardlink)"
eq 'nor an installed .venv' '' "$(venv_warning .venv:install)"
eq 'nor a dir merely ending in venv' '' "$(venv_warning my.venv:hardlink)"
contains 'several are named in one line' '.venv, env: hardlinked' "$(venv_warning .venv:hardlink vendor:hardlink env:hardlink)"
# A dir outside the checkout is never probed for a pyvenv.cfg, even where one exists — both at the
# path it names and at that path under the checkout, so the guard alone is what keeps it quiet.
mkdir -p "$TMP/outside-venv" "$VNR$TMP/abs-venv" "$TMP/abs-venv"
: > "$TMP/outside-venv/pyvenv.cfg"; : > "$VNR$TMP/abs-venv/pyvenv.cfg"; : > "$TMP/abs-venv/pyvenv.cfg"
eq 'a ../ dir holding a pyvenv.cfg is not probed' '' "$(venv_warning ../outside-venv:hardlink)"
eq 'nor an absolute one' '' "$(venv_warning "$TMP/abs-venv:hardlink")"
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%s.venv%scomposer.lock%shardlink%sx%s%s%s' "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
# shellcheck disable=SC2034  # read by wt_warn_hardlinked_venvs
WT_VENV_HARDLINK_WARNED=''
wt_warn_hardlinked_venvs "$VNR" 2>"$TMP/venv1"
wt_warn_hardlinked_venvs "$VNR" 2>"$TMP/venv2"
contains 'once per run: the first call warns' 'Python virtualenv' "$(cat "$TMP/venv1")"
eq '...and a second round says nothing' '' "$(cat "$TMP/venv2")"

# A profile calibrated before deps[].copy existed: a hardlinked dir whose detection rule lists paths
# its package manager rewrites in place, with no `copy` of its own. Warned about, once per run.
copy_warning() {  # $@ = dir:lock:strategy[:copy] entries; prints what wt_warn_uncopied_links logs
  local e raw rest d l st cp
  raw=$(printf '0%s%s' "$US_" "$RS_")
  for e in "$@"; do
    d=${e%%:*}; rest=${e#*:}; l=${rest%%:*}; rest=${rest#*:}
    st=${rest%%:*}; cp=''; [ "$st" = "$rest" ] || cp=${rest#*:}
    raw+=$(printf '1%s%s%s%s%s%s%sx%s%s%s%s%s' "$US_" "$d" "$US_" "$l" "$US_" "$st" "$US_" "$US_" "$US_" "$US_" "$cp" "$RS_")
  done
  PROFILE_RAW=$raw WT_COPY_WARNED='' wt_warn_uncopied_links 2>&1
}
# The warning matches on how the backend renders markers and copyPaths, so it runs on each backend
# this machine has: one that rendered them differently would silence it.
copy_warning_suite() {
  local out
  out=$(copy_warning vendor:composer.lock:hardlink)
  contains 'an uncopied hardlinked dir is warned about' 'vendor (composer): hardlinked' "$out"
  contains '...naming the danger' 'rewrites those paths in place' "$out"
  contains '...and the fix' '/pitlane-setup' "$out"
  contains 'a file path, keyed on its lockfile' 'node_modules (.package-lock.json)' \
    "$(copy_warning node_modules:package-lock.json:hardlink)"
  contains 'the rule for the dir the profile names, not the first with that lockfile' 'node_modules (.yarn-integrity)' \
    "$(copy_warning node_modules:yarn.lock:hardlink)"
  contains 'a nested project too' 'app/vendor (composer)' "$(copy_warning app/vendor:app/composer.lock:hardlink)"
  eq 'not when its lockfile sits elsewhere' '' "$(copy_warning app/vendor:composer.lock:hardlink)"
  eq 'not with a copy list of its own' '' "$(copy_warning 'vendor:composer.lock:hardlink:["composer"]')"
  eq 'nor an explicitly empty one: the developer chose' '' "$(copy_warning 'vendor:composer.lock:hardlink:[]')"
  eq 'not for a rule with nothing to copy' '' "$(copy_warning vendor/bundle:Gemfile.lock:hardlink)"
  eq 'not for an installed dir' '' "$(copy_warning vendor:composer.lock:install)"
  eq 'not for a lockfile no rule knows' '' "$(copy_warning vendor:custom.lock:hardlink)"
  eq 'not for a dir no rule with that lockfile names' '' "$(copy_warning lib:composer.lock:hardlink)"
  contains 'several in one line' 'vendor (composer), node_modules (.package-lock.json): hardlinked' \
    "$(copy_warning vendor:composer.lock:hardlink vendor/bundle:Gemfile.lock:hardlink node_modules:package-lock.json:hardlink)"
  eq 'no detection table: nothing to compare, nothing said' '' \
    "$(WT_DETECTION_JSON=/nonexistent/table.json copy_warning vendor:composer.lock:hardlink)"
}
for COPY_BACKEND in python3 jq; do
  if ! command -v "$COPY_BACKEND" >/dev/null 2>&1; then
    printf 'NOTE: %s not on PATH — wt_warn_uncopied_links not exercised on it\n' "$COPY_BACKEND" >&2
    continue
  fi
  if [ "$COPY_BACKEND" = python3 ]; then
    WT_JSON_BACKEND=python3 copy_warning_suite
  else
    WT_JSON_BACKEND='' copy_warning_suite
  fi
done
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%svendor%scomposer.lock%shardlink%sx%s%s%s' "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
# shellcheck disable=SC2034  # read by wt_warn_uncopied_links
WT_COPY_WARNED=''
wt_warn_uncopied_links 2>"$TMP/copy1"
wt_warn_uncopied_links 2>"$TMP/copy2"
contains 'once per run: the first call warns' 'vendor (composer)' "$(cat "$TMP/copy1")"
eq '...and a second round says nothing' '' "$(cat "$TMP/copy2")"
# shellcheck disable=SC2034
PROFILE_RAW=''
# shellcheck disable=SC2034
PROFILE_RAW=''

# ---------------------------------------------------------------------------
# Layer 3 — port allocation
# ---------------------------------------------------------------------------
PREPO=$TMP/prepo
mkdir -p "$PREPO"
git init -q "$PREPO"
git -C "$PREPO" config user.email t@example.com
git -C "$PREPO" config user.name t
: >"$PREPO/f"; git -C "$PREPO" add -A; git -C "$PREPO" commit -qm init
git -C "$PREPO" worktree add -q "$PREPO/.claude/worktrees/alpha" -b wa 2>/dev/null
git -C "$PREPO" worktree add -q "$PREPO/.claude/worktrees/beta"  -b wb 2>/dev/null
PA=$PREPO/.claude/worktrees/alpha
PB=$PREPO/.claude/worktrees/beta

# --- wt_runtime_siblings ---
# It SETS rather than prints, so a caller can have the records AND the trust flag. Capturing the
# records in a command substitution would discard the flag — the trap this function's header
# describes, and the reason the first version could not be used by the seed at all.
sib() { wt_runtime_siblings "$1" "$2"; printf '%s' "$WT_SIBLINGS"; }

wt_runtime_siblings "$PREPO" "$PA"
eq 'no allocations yet means no sibling records' '' "$WT_SIBLINGS"
eq 'and the enumeration is reported as trustworthy' 1 "$WT_SIBLINGS_OK"

wt_runtime_state_set "$PB" beta_slug 3900 derived .e ours none ''
wt_runtime_siblings "$PREPO" "$PA"
eq 'a sibling with an allocation is reported, slug and port' "beta_slug${US_}3900${RS_}" "$WT_SIBLINGS"
eq 'the flag survives into the CALLER, not just a subshell' 1 "$WT_SIBLINGS_OK"
wt_runtime_siblings "$PREPO" "$PB"
eq 'and a worktree does not report ITSELF as a sibling' '' "$WT_SIBLINGS"

# A repository it cannot read at all reports UNTRUSTWORTHY, not "no siblings". The seed fails
# closed on this flag, so the two must never look the same.
wt_runtime_siblings "$TMP/not-a-repo-at-all" "$PA"
eq 'an unreadable repository reports no siblings' '' "$WT_SIBLINGS"
eq '...and says the enumeration cannot be trusted' 0 "$WT_SIBLINGS_OK"
# A real repository with no linked worktrees is a TRUSTWORTHY "none" — a different thing entirely.
FRESH=$TMP/freshrepo
git init -q "$FRESH"; git -C "$FRESH" config user.email t@e; git -C "$FRESH" config user.name t
wt_runtime_siblings "$FRESH" "$FRESH"
eq 'a repo with no linked worktrees reports no siblings' '' "$WT_SIBLINGS"
eq '...and IS trustworthy' 1 "$WT_SIBLINGS_OK"

# THE ORPHAN CASE. `git worktree remove` deletes the admin directory but `rm -rf` on the checkout
# does not — measured — so a stale entry keeps holding its allocation. Treating it as live makes
# the name permanently unreusable: the next worktree of that name steps around a port nothing is
# using, forever.
mv "$PB" "$PB.hidden"
eq 'an admin dir whose checkout is gone is NOT a live sibling' '' "$(sib "$PREPO" "$PA")"
mv "$PB.hidden" "$PB"
eq 'and it counts again once the checkout is back' "beta_slug${US_}3900${RS_}" "$(sib "$PREPO" "$PA")"

# A RELATIVE gitdir pointer, which git 2.48+ writes under worktree.useRelativePaths. Resolving it
# against the hook's working directory instead of the admin directory would classify every sibling
# as a deleted orphan — collision avoidance silently off, while the flag still claimed the scan was
# fine.
BADMIN=$PREPO/.git/worktrees/beta
cp "$BADMIN/gitdir" "$TMP/gitdir.abs"
printf '../../../.claude/worktrees/beta/.git\n' > "$BADMIN/gitdir"
eq 'a relative gitdir pointer still resolves to a live sibling' "beta_slug${US_}3900${RS_}" \
  "$(cd / && sib "$PREPO" "$PA")"
cp "$TMP/gitdir.abs" "$BADMIN/gitdir"

# A sibling that has never allocated a port contributes nothing rather than an empty record, which
# would otherwise look like a claim on port "".
wt_runtime_state_set "$PB" beta_slug '' '' '' '' none ''
# A PORTLESS SIBLING STILL COUNTS. Skipping these was a hole in the one guard between a derived
# database name and a colleague's data: a worktree that seeded but never allocated a port — a
# profile with `seed` and no `runtime.port` — was invisible to the seed's collision check. The port
# loop is unaffected, since an empty port never equals a candidate.
eq 'a sibling with no port still contributes its slug' "beta_slug${US_}${RS_}" \
  "$(sib "$PREPO" "$PA")"
# A corrupt or foreign-version sibling state file contributes nothing either.
printf 'garbage' > "$BADMIN/worktree-bootstrap-state"
eq 'a corrupt sibling state file contributes no record' '' "$(sib "$PREPO" "$PA")"
printf 'wtstate%s99%srt%sx%s3901%sderived%s.e%sours%snone%s%s1%s' \
  "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_" \
  > "$BADMIN/worktree-bootstrap-state"
eq 'a foreign-version sibling state file contributes no record' '' "$(sib "$PREPO" "$PA")"
# An admin dir with no gitdir pointer at all cannot be classified, so the scan is not trustworthy.
mv "$BADMIN/gitdir" "$BADMIN/gitdir.away"
wt_runtime_siblings "$PREPO" "$PA"
eq 'an unclassifiable admin entry drops the trust flag' 0 "$WT_SIBLINGS_OK"
mv "$BADMIN/gitdir.away" "$BADMIN/gitdir"
wt_runtime_state_set "$PB" beta_slug 3900 derived .e ours none ''

# --- wt_port_in_use is ADVISORY, and is tested for itself ---
wt_port_in_use ''    ; eq 'port_in_use rejects an empty port'       1 $?
wt_port_in_use abc   ; eq 'port_in_use rejects a non-numeric port'  1 $?
wt_port_in_use 0     ; eq 'port_in_use rejects zero'                1 $?
# With no `timeout` on PATH it answers "do not know" rather than risking an unbounded connect on
# the path that blocks session start.
# SC2123: assigning PATH is the POINT — the guard under test is "no coreutils timeout on PATH".
# shellcheck disable=SC2123
eq 'port_in_use without coreutils timeout answers no, without probing' 1 \
  "$(PATH=/nonexistent; wt_port_in_use 4100; echo $?)"
# A port something IS listening on, using a real listener so the probe itself is exercised.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$TMP/lport" <<'PYL' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
time.sleep(20)
PYL
  LPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/lport" ] && break; sleep 0.2; done
  LPORT=$(cat "$TMP/lport" 2>/dev/null)
  if [ -n "$LPORT" ]; then
    wt_port_in_use "$LPORT"; eq 'port_in_use finds a real listener' 0 $?
  fi
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
fi

# --- wt_runtime_claim_port ---
# Determinism first: it is what a bookmarked URL depends on.
rm -f "$(wt_state_path "$PA")"
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200; p_first=$WT_PORT
in_range_b 'a claimed port is inside the span' 4100 200 "$p_first"
eq 'the derived port is what a bare derivation gives' "$(wt_derive_port alpha_slug 4100 200)" \
  "$p_first"
eq 'and it is reported as derived, not probed' 'derived' "$WT_PORT_SOURCE"

# THE CLAIM IS WRITTEN, and inside the lock. A lock around a read-only computation serialises
# nothing: two sessions would each take it in turn, each see no sibling record, and each pick the
# same port. So the record must exist the moment the lock is dropped.
eq 'claiming a port RECORDS it, so the next holder can see the claim' "$p_first" \
  "$(wt_runtime_state_get "$PA" port)"
eq 'and records how it was arrived at' 'derived' "$(wt_runtime_state_get "$PA" portsource)"
eq 'and the slug it belongs to' 'alpha_slug' "$(wt_runtime_state_get "$PA" slug)"
# The lock must be free again afterwards — a leaked fd 7 would hold it across the seed.
eq 'the ports lock is released, not leaked' 0 \
  "$(flock -w 1 "$(wt_lock_path "$PREPO" _runtime-ports)" -c true >/dev/null 2>&1; echo $?)"

# THE CLAIM MUST BE WRITTEN *BEFORE* THE LOCK IS DROPPED, not merely written. Writing it after the
# release re-opens the very race the lock exists for: the next holder enumerates siblings and still
# sees nothing. The order is asserted deterministically by shadowing the release so it notes
# whether the record was already on disk when it ran — a concurrency test for this would be
# inherently flaky, and flaky is how an ordering guarantee quietly stops being checked.
rm -f "$(wt_state_path "$PA")"
rm -f "$TMP/lock-order"
(
  # SC2329: invoked indirectly — it shadows the real release for this subshell.
  # The marker goes to a FILE, not stdout: the call under test has its own output redirected, so
  # anything printed here would be swallowed and the assertion would pass on an empty string.
  # shellcheck disable=SC2329
  wt_lock_release() {
    if [ -r "$(wt_state_path "$PA")" ]; then printf 'recorded-then-released' >"$TMP/lock-order"
    else printf 'released-too-early' >"$TMP/lock-order"; fi
    eval "exec $1>&-" 2>/dev/null || true
  }
  wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 >/dev/null 2>&1
)
eq 'the allocation is recorded BEFORE the lock is released' 'recorded-then-released' \
  "$(cat "$TMP/lock-order" 2>/dev/null)"

# Existing runtime state is CARRIED FORWARD by the claim, not blanked — otherwise every claim would
# erase the seed marker and re-clone the database.
wt_runtime_state_set "$PA" alpha_slug "$p_first" derived .env.wt ours "done" SEEDCK
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200
eq 'a re-claim preserves the seed status' 'done' "$(wt_runtime_state_get "$PA" seedstatus)"
eq 'and the env file it wrote' '.env.wt' "$(wt_runtime_state_get "$PA" envfile)"

# ...but a CHANGED slug is a different logical allocation: its database has not been seeded, so
# inheriting a `done` marker would skip seeding the new one entirely.
wt_runtime_claim_port "$PREPO" "$PA" changed_slug 4100 200
eq 'a changed slug resets the seed status' 'none' "$(wt_runtime_state_get "$PA" seedstatus)"
eq 'and does not carry the old env file across' '' "$(wt_runtime_state_get "$PA" envfile)"

# THE RECORDED PORT WINS OVER RE-DERIVATION — the acceptance criterion "reopening a worktree lands
# on the same port it had before".
wt_runtime_state_set "$PA" alpha_slug 4242 probed .e ours none ''
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200
eq 'a recorded port for the SAME slug is reused verbatim' 4242 "$WT_PORT"
eq 'and its recorded source is preserved, not reset to derived' 'probed' "$WT_PORT_SOURCE"
# A recorded port outside the port space is no more usable than a derived one would be.
wt_runtime_state_set "$PA" alpha_slug 99999 derived .e ours none ''
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200
in_range_b 'a recorded port outside the port space is re-derived' 4100 200 "$WT_PORT"

# PROBING FORWARD past a live sibling, pinned by pointing the sibling at exactly the port this slug
# derives to, so the collision is certain rather than incidental.
rm -f "$(wt_state_path "$PA")"
want=$(wt_derive_port alpha_slug 4100 200)
wt_runtime_state_set "$PB" beta_slug "$want" derived .e ours none ''
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200; p_probe=$WT_PORT
ne 'a port claimed by a live sibling is stepped over' "$want" "$p_probe"
in_range_b 'and the replacement is still inside the span' 4100 200 "$p_probe"
eq 'and it is reported as probed, so teardown knows it was not derived' 'probed' "$WT_PORT_SOURCE"
rm -f "$(wt_state_path "$PA")"
contains 'and it says which port it stepped over' 'is taken by another worktree' \
  "$(wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 2>&1 >/dev/null)"

# TWO siblings, so the inner record loop really has to examine more than one. With one sibling a
# mutation that stops after the first record passes, and in a three-worktree repo the second
# sibling's port is handed straight to a new worktree.
git -C "$PREPO" worktree add -q "$PREPO/.claude/worktrees/gamma" -b wg 2>/dev/null
PG=$PREPO/.claude/worktrees/gamma
c1=$(wt_port_candidates alpha_slug 4100 200 | sed -n 1p)
c2=$(wt_port_candidates alpha_slug 4100 200 | sed -n 2p)
c3=$(wt_port_candidates alpha_slug 4100 200 | sed -n 3p)
wt_runtime_state_set "$PB" beta_slug  "$c1" derived .e ours none ''
wt_runtime_state_set "$PG" gamma_slug "$c2" derived .e ours none ''
rm -f "$(wt_state_path "$PA")"
wt_runtime_siblings "$PREPO" "$PA"
eq 'both siblings appear in one enumeration' 2 \
  "$(printf '%s' "$WT_SIBLINGS" | tr -cd "$RS_" | wc -c | tr -d ' ')"
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200
eq 'two claimed candidates are both stepped over' "$c3" "$WT_PORT"
git -C "$PREPO" worktree remove --force "$PG" 2>/dev/null

# A LIVE SIBLING ON THE SAME SLUG IS A REAL COLLISION, not an exemption. An earlier version
# skipped it, reasoning that it must be this worktree seen through a stale record — but self is
# excluded BY PATH and a dead worktree by the liveness check, so the only thing that exemption
# could ever match is a different live worktree whose name slugifies the same. Stepping the port
# forward is right; it is the DATABASE the two would still share, which wt_runtime_handoff warns
# about separately because no port move can fix it.
rm -f "$(wt_state_path "$PA")"
wt_runtime_state_set "$PB" alpha_slug "$want" derived .e ours none ''
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200
ne 'a live sibling on the same slug is stepped over like any other' "$want" "$WT_PORT"
wt_runtime_state_set "$PB" beta_slug 3900 derived .e ours none ''

# A span of 1 with the single port already claimed: every candidate is taken, so it keeps the
# derived value and says so. It must not hang, loop, or print nothing.
rm -f "$(wt_state_path "$PA")"
wt_runtime_state_set "$PB" beta_slug 4100 derived .e ours none ''
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 1 2>/dev/null
eq 'a fully-claimed span keeps the derived port rather than failing' 4100 "$WT_PORT"
eq 'and reports it as derived, since nothing was successfully probed' 'derived' "$WT_PORT_SOURCE"
rm -f "$(wt_state_path "$PA")"
contains 'and warns that it may fail to bind' 'may fail to bind' \
  "$(wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 1 2>&1 >/dev/null)"
# A ZERO-PADDED base on that same path. wt_is_posint accepts "04100" and bash reads a leading zero
# as OCTAL, so a message computing base+span without the 10# prefix is a fatal arithmetic error —
# on the one path that is already reporting a problem, which is the worst place to add a second one.
rm -f "$(wt_state_path "$PA")"
contains 'the fully-claimed message survives a zero-padded base' 'may fail to bind' \
  "$(wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 04100 1 2>&1 >/dev/null)"
rm -f "$(wt_state_path "$PA")"
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 04100 1 2>/dev/null
eq 'and a zero-padded base still derives a decimal port' 4100 "$WT_PORT"
wt_runtime_state_set "$PB" beta_slug 3900 derived .e ours none ''

# An unusable port configuration yields nothing at all rather than a wrong number. The validator
# only WARNS about these, so the engine is what actually has to refuse.
rm -f "$(wt_state_path "$PA")"
for bad in '0 200' '4100 0' 'x 200' '4100 x' '80 10' '65000 1000'; do
  # SC2086: the split is the POINT — each entry is a base/span pair to be separated.
  # shellcheck disable=SC2086
  set -- $bad
  wt_runtime_claim_port "$PREPO" "$PA" alpha_slug "$1" "$2" 2>/dev/null
  eq "an unusable port config ($bad) yields no port" '' "$WT_PORT"
  eq "an unusable port config ($bad) resets the source too" 'derived' "$WT_PORT_SOURCE"
  eq "an unusable port config ($bad) records nothing" 1 \
    "$(wt_runtime_state_get "$PA" port >/dev/null 2>&1; echo $?)"
done

# WITHOUT flock, allocation must still happen — stock macOS has no flock(1), and refusing to
# allocate there would be worse than allocating unserialised.
rm -f "$(wt_state_path "$PA")"
NOFLOCK=$TMP/noflock; mkdir -p "$NOFLOCK"
for c in git date mktemp cksum tr cat sed find mv rm mkdir printf timeout python3; do
  cp="$(command -v "$c" 2>/dev/null)" && ln -sf "$cp" "$NOFLOCK/$c"
done
noflock_claim() {
  # shellcheck disable=SC2123
  PATH=$NOFLOCK
  # shellcheck disable=SC2034
  WT_FLOCK_WARNED=''
  wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 2>/dev/null
  printf '%s' "$WT_PORT"
}
noflock_port=$(noflock_claim)
in_range_b 'a port is still allocated with no flock on PATH' 4100 200 "$noflock_port"
# A helper rather than an inline subshell so the shellcheck directives attach to the assignments
# they describe. PATH is narrowed on purpose (no flock), and WT_FLOCK_WARNED is reset so the
# library's one-shot warning can fire again — it is read by the sourced library, not by this file.
noflock_stderr() {
  # shellcheck disable=SC2123
  PATH=$NOFLOCK
  # shellcheck disable=SC2034
  WT_FLOCK_WARNED=''
  rm -f "$(wt_state_path "$PA")"
  # SC2069: the order captures stderr ONLY, which is what this assertion reads. Deliberate.
  # shellcheck disable=SC2069
  wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 2>&1 >/dev/null
}
lacks 'and the message does not claim a competing worktree that does not exist' \
  'another worktree is allocating' "$(noflock_stderr)"

# --- the foreign-listener warning is ADVISORY ---
# Shadowing the probe rather than binding a socket: what is under test is that the ANSWER does not
# move the port, not the probe itself (which is asserted directly above).
rm -f "$(wt_state_path "$PA")"
wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200; p_clean=$WT_PORT
rm -f "$(wt_state_path "$PA")"
p_busy=$(
  # SC2329: invoked INDIRECTLY — it shadows the real probe for this subshell.
  # shellcheck disable=SC2329
  wt_port_in_use() { return 0; }
  wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 2>/dev/null
  printf '%s' "$WT_PORT"
)
eq 'a foreign listener does NOT move the port — it only warns' "$p_clean" "$p_busy"
rm -f "$(wt_state_path "$PA")"
contains 'and the warning says the port was left alone' 'leaving the port as it is' \
  "$(# shellcheck disable=SC2329
     wt_port_in_use() { return 0; }
     wt_runtime_claim_port "$PREPO" "$PA" alpha_slug 4100 200 2>&1 >/dev/null)"
rm -f "$(wt_state_path "$PA")"

# ---------------------------------------------------------------------------
# Layer 3 — the env override file
# ---------------------------------------------------------------------------
EREPO=$TMP/erepo
mkdir -p "$EREPO"
git init -q "$EREPO"
git -C "$EREPO" config user.email t@example.com
git -C "$EREPO" config user.name t
printf '.env.worktree.local\nignored/\n' >"$EREPO/.gitignore"
: >"$EREPO/f"
git -C "$EREPO" add -A; git -C "$EREPO" commit -qm init
git -C "$EREPO" worktree add -q "$EREPO/.claude/worktrees/ew" -b ew 2>/dev/null
EW=$EREPO/.claude/worktrees/ew
EF=.env.worktree.local

# A pairs stream shaped exactly like group 3 of a profile scan.
mk_pairs() {  # $@ = KEY=VALUE
  local kv
  for kv in "$@"; do printf '3%s%s%s%s%s' "$US_" "${kv%%=*}" "$US_" "${kv#*=}" "$RS_"; done
}

WT_NAME=alice/fix-99
WT_SLUG=alice_fix_99
WT_PATH=$EW
WT_ROOT=$EREPO
WT_PORT=3812
export WT_NAME WT_SLUG WT_PATH WT_ROOT WT_PORT

# --- wt_runtime_env_state ---
eq 'an absent override file is absent' 'absent' "$(wt_runtime_env_state "$EW" "$EF")"

# --- writing it ---
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}' 'APP_ENV=dev')"
eq 'writing the override file reports written' 'written' "$WT_ENV_WROTE"
eq 'the port line is written from the profile-named variable' 'SERVER_PORT=3812' \
  "$(grep '^SERVER_PORT=' "$EW/$EF")"
eq 'a {slug} placeholder is expanded in a value' 'DATABASE_NAME=demo_alice_fix_99' \
  "$(grep '^DATABASE_NAME=' "$EW/$EF")"
eq 'a literal value is written as-is' 'APP_ENV=dev' "$(grep '^APP_ENV=' "$EW/$EF")"
eq 'the file now reads as ours' 'ours' "$(wt_runtime_env_state "$EW" "$EF")"
# These files hold database names and, in a repo that puts one there, a connection string.
# `stat` differs between GNU and BSD, so both spellings are tried.
eq 'and it is not world-readable' '600' \
  "$(stat -c '%a' "$EW/$EF" 2>/dev/null || stat -f '%Lp' "$EW/$EF" 2>/dev/null)"
eq 'no temporary file is left beside it' 0 \
  "$(find "$EW" -maxdepth 1 -name '.wtenv.*' 2>/dev/null | wc -l | tr -d ' ')"
# A file the plugin CREATED is the block and nothing else: begin line first, end line last.
eq 'a created file starts with the block begin line' "$WT_ENV_BEGIN" "$(head -1 "$EW/$EF")"
eq 'and ends with its end line' "$WT_ENV_END" "$(tail -1 "$EW/$EF")"
case $WT_ENV_BEGIN in
  "$WT_ENV_MARKER"*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL the begin line does not start with the ownership marker\n' >&2 ;;
esac
case $WT_ENV_END in
  "$WT_ENV_MARKER"*) fail=$((fail + 1)); printf 'FAIL the end line would read as a second begin line\n' >&2 ;;
  '#'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL the end line is not a comment\n' >&2 ;;
esac

# REWRITING keeps values in sync when the profile changes.
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3999 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')"
eq 'a rewrite updates the port' 'SERVER_PORT=3999' "$(grep '^SERVER_PORT=' "$EW/$EF")"
eq 'and drops a variable the profile no longer names' 0 \
  "$(grep -c '^APP_ENV=' "$EW/$EF" | tr -d ' ')"

# WORKTREE_URL rides in the same block, beside the port; it is re-checked at the writer, because the
# line is unquoted in a file a dotenv parser reads.
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3999 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" '' 'http://localhost:3999'
eq 'the url is written into the block as WORKTREE_URL' 'WORKTREE_URL=http://localhost:3999' \
  "$(grep '^WORKTREE_URL=' "$EW/$EF")"
eq '...inside the block, before its end line' "$WT_ENV_END" "$(tail -1 "$EW/$EF")"
# shellcheck disable=SC2016  # the $(...) is the payload, kept literal.
out=$(wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3999 "$(mk_pairs 'A=1')" '' 'http://x/$(touch pwned)' 2>&1)
eq 'an unsafe url is not written' 0 "$(grep -c '^WORKTREE_URL=' "$EW/$EF" | tr -d ' ')"
contains '...and says why' 'skipping WORKTREE_URL' "$out"
eq '...while the rest of the block still is' 'A=1' "$(grep '^A=' "$EW/$EF")"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3999 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')"
eq 'no url, no WORKTREE_URL line' 0 "$(grep -c '^WORKTREE_URL=' "$EW/$EF" | tr -d ' ')"

# A FILE THE PLUGIN HAS NEVER WRITTEN GETS THE BLOCK APPENDED. It is the developer's
# configuration, copied in, and the app loads it by name — so the overrides have to go INTO it,
# after the developer's lines, where dotenv's last-assignment-wins resolves them for the plugin.
printf 'SECRET=keep-me\nDATABASE_NAME=shared_db\n' >"$EW/$EF"
eq 'a file without a block reads as unmarked' 'unmarked' "$(wt_runtime_env_state "$EW" "$EF")"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')"
eq 'an unmarked file with nothing recorded is written' 'written' "$WT_ENV_WROTE"
eq 'the developer lines stay first, untouched' 'SECRET=keep-me|DATABASE_NAME=shared_db' \
  "$(head -2 "$EW/$EF" | paste -sd '|' -)"
eq 'the block follows them' "$WT_ENV_BEGIN" "$(sed -n 3p "$EW/$EF")"
eq 'so the plugin assignment is the LAST one, which dotenv honours' 'DATABASE_NAME=demo_alice_fix_99' \
  "$(grep '^DATABASE_NAME=' "$EW/$EF" | tail -1)"
eq 'and the file now reads as ours' 'ours' "$(wt_runtime_env_state "$EW" "$EF")"

# A LINE BELOW THE BLOCK KEEPS WINNING: a rewrite replaces the block IN PLACE, never moves it.
printf 'SERVER_PORT=9999\n' >>"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3813 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" "ours"
eq 'a rewrite updates the block' 'SERVER_PORT=3813' "$(grep '^SERVER_PORT=' "$EW/$EF" | head -1)"
eq 'and the developer override below it is still last' 'SERVER_PORT=9999' \
  "$(tail -1 "$EW/$EF")"
eq 'and the lines above it survive the rewrite' 'SECRET=keep-me' "$(head -1 "$EW/$EF")"
eq 'and there is still exactly one block' 1 "$(grep -c "^$WT_ENV_MARKER" "$EW/$EF" | tr -d ' ')"

# A BLOCK THE DEVELOPER DELETED IS A FILE THEY TOOK OVER — but only the state record can tell that
# apart from a file never written, so the recorded disposition is what decides.
printf 'DATABASE_NAME=someone_elses_db\n' >"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" ours
eq 'a recorded-ours file whose block is gone is developer-managed' 'developer' "$WT_ENV_WROTE"
eq 'and is left byte for byte alone' 'DATABASE_NAME=someone_elses_db' "$(cat "$EW/$EF")"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" theirs
eq 'and so is one already recorded as theirs' 'developer' "$WT_ENV_WROTE"
eq 'still byte for byte' 'DATABASE_NAME=someone_elses_db' "$(cat "$EW/$EF")"
# Putting the begin line back hands it back.
printf '%s\n' "$WT_ENV_MARKER" >>"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" theirs
eq 'a restored marker line hands the file back' 'written' "$WT_ENV_WROTE"
eq 'keeping the developer line above the block' 'DATABASE_NAME=someone_elses_db' "$(head -1 "$EW/$EF")"
# Deleting a file the plugin created hands it back too.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'DATABASE_NAME=demo_{slug}')" theirs
eq 'deleting the file hands ownership back to the plugin' 'written' "$WT_ENV_WROTE"

# A path that is not a regular readable file is a REFUSAL, not a developer take-over: nothing can
# be written there, and advice about deleting a block from a directory would be nonsense.
rm -f "$EW/$EF"; mkdir -p "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" 2>/dev/null
eq 'a directory at the path is skipped, not developer-managed' 'skipped' "$WT_ENV_WROTE"
contains 'and says what is wrong with it' 'not a regular file' \
  "$(wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" 2>&1)"
rmdir "$EW/$EF"

# A DEVELOPER FILE KEEPS ITS OWN MODE through a write and a release; only a file the plugin
# creates is 0600. A container user reading a bind-mounted env file would otherwise lose access.
rm -f "$EW/$EF"
printf 'SECRET=1\n' >"$EW/$EF"; chmod 644 "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')"
eq 'an existing file keeps its mode through a write' '644' \
  "$(stat -c '%a' "$EW/$EF" 2>/dev/null || stat -f '%Lp' "$EW/$EF" 2>/dev/null)"
wt_runtime_env_release "$EW" "$EF"
eq 'and through a release' '644' \
  "$(stat -c '%a' "$EW/$EF" 2>/dev/null || stat -f '%Lp' "$EW/$EF" 2>/dev/null)"
rm -f "$EW/$EF"

# AN UNCONSTRAINED PLACEHOLDER CARRYING SHELL SYNTAX IS REFUSED, per variable. The file is one the
# app's dotenv parser reads, and some dialects run `$(...)` in an unquoted value.
# shellcheck disable=SC2016  # the $(...) is the hostile TEXT under test, never to be expanded here.
out=$(WT_NAME='x$(touch pwned)' wt_runtime_env_write "$EW" "$EF" '' '' \
  "$(mk_pairs 'DB=app_{name}' 'SAFE=demo_{slug}')" 2>&1)
contains 'a {name} value with shell syntax is skipped, saying why' 'its {name} expands to text with shell syntax' "$out"
eq 'and is not written' 0 "$(grep -c '^DB=' "$EW/$EF" | tr -d ' ')"
eq 'while the other variables still are' 'SAFE=demo_alice_fix_99' "$(grep '^SAFE=' "$EW/$EF")"
rm -f "$EW/$EF"
# A LINE BREAK IN THE NAME cannot forge an assignment through the block's comment line.
WT_NAME="$(printf 'a\nFORGED=1')" wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'A=1')"
eq 'a line break in the worktree name is folded out of the comment line' 0 \
  "$(grep -c '^FORGED=' "$EW/$EF" | tr -d ' ')"
rm -f "$EW/$EF"

# A `<file>:<VAR>` key applies to that one file, in place of the shared VAR there; a key scoped to
# another file is not written here at all. Every VAR appears once.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' \
  "$(mk_pairs 'CENTRAL=central_{slug}' "$EF:CENTRAL=central_{slug}_test" 'SHARED=1' 'other.env:ONLY_THERE=1')"
eq 'scoped: the file-scoped value replaces the shared one' 'CENTRAL=central_alice_fix_99_test' \
  "$(grep '^CENTRAL=' "$EW/$EF")"
eq 'scoped: and the var is written once' 1 "$(grep -c '^CENTRAL=' "$EW/$EF" | tr -d ' ')"
eq 'scoped: shared vars are still written' 'SHARED=1' "$(grep '^SHARED=' "$EW/$EF")"
eq 'scoped: a key scoped to another file is not written here' 0 "$(grep -c 'ONLY_THERE' "$EW/$EF" | tr -d ' ')"
rm -f "$EW/$EF"

# An EMPTY existing file has no block either, so the same rule applies to it.
: >"$EW/$EF"
eq 'an empty existing file reads as unmarked' 'unmarked' "$(wt_runtime_env_state "$EW" "$EF")"
rm -f "$EW/$EF"

# A LAST LINE WITH NO NEWLINE must not be glued onto the begin line, which would turn the
# developer's assignment into part of a comment and the begin line into part of a value.
printf 'LAST=1' >"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'A=1')"
eq 'an unterminated last line keeps its own line' 'LAST=1' "$(head -1 "$EW/$EF")"
eq 'and the begin line starts the next one' "$WT_ENV_BEGIN" "$(sed -n 2p "$EW/$EF")"
rm -f "$EW/$EF"

# CRLF files keep their line endings outside the block; the block is found through them.
printf 'WIN=1\r\n' >"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'A=1')"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'A=2')" ours
eq 'a CRLF line outside the block is carried through byte for byte' "WIN=1$CR_" "$(head -1 "$EW/$EF")"
eq 'and a rewrite through CRLF content still leaves one block' 1 \
  "$(grep -c "^$WT_ENV_MARKER" "$EW/$EF" | tr -d ' ')"
rm -f "$EW/$EF"

# A FILE FROM AN OLDER RELEASE began with a longer marker line and had no end line. It is a block
# running to end of file, so a rewrite replaces all of it rather than keeping its old values.
printf '%s — delete this line to take ownership of this file\nOLD=1\n' "$WT_ENV_MARKER" >"$EW/$EF"
eq 'an old whole-file marker reads as ours' 'ours' "$(wt_runtime_env_state "$EW" "$EF")"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'NEW=1')" ours
eq 'and a rewrite drops the old values' 0 "$(grep -c '^OLD=' "$EW/$EF" | tr -d ' ')"
eq 'leaving a file that is only the new block' "$WT_ENV_BEGIN" "$(head -1 "$EW/$EF")"
rm -f "$EW/$EF"

# TWO BLOCKS — pasted by hand — collapse into one on the next rewrite.
{ printf 'A=0\n'; printf '%s\nX=1\n%s\n' "$WT_ENV_BEGIN" "$WT_ENV_END"; printf 'B=0\n'
  printf '%s\nY=1\n%s\n' "$WT_ENV_BEGIN" "$WT_ENV_END"; printf 'C=0\n'; } >"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'Z=1')" ours
eq 'two blocks become one' 1 "$(grep -c "^$WT_ENV_MARKER" "$EW/$EF" | tr -d ' ')"
eq 'with every line outside them kept, in order' 'A=0|B=0|C=0' \
  "$(grep -E '^[ABC]=' "$EW/$EF" | paste -sd '|' -)"
eq 'and neither old block values survive' 0 "$(grep -cE '^[XY]=' "$EW/$EF" | tr -d ' ')"
rm -f "$EW/$EF"

# --- wt_runtime_env_release: teardown's half ---
printf 'SECRET=keep-me\n' >"$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')"
wt_runtime_env_release "$EW" "$EF"
eq 'releasing removes the block and keeps the developer lines' 'SECRET=keep-me' "$(cat "$EW/$EF")"
eq 'and the file no longer reads as ours' 'unmarked' "$(wt_runtime_env_state "$EW" "$EF")"
wt_runtime_env_release "$EW" "$EF"
eq 'releasing a file with no block leaves it alone' 'SECRET=keep-me' "$(cat "$EW/$EF")"
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')"
printf '\n\n' >>"$EW/$EF"
wt_runtime_env_release "$EW" "$EF"
eq 'a file that was only the block (and blank lines) is removed' 0 \
  "$([ -e "$EW/$EF" ] && echo 1 || echo 0)"
ln -sf "$TMP/marker-bearing-release" "$EW/$EF"
printf '%s\nX=1\n' "$WT_ENV_MARKER" >"$TMP/marker-bearing-release"
wt_runtime_env_release "$EW" "$EF"
eq 'release never writes through a symlink' "$WT_ENV_MARKER|X=1" \
  "$(paste -sd '|' - <"$TMP/marker-bearing-release")"
rm -f "$EW/$EF"

# THE MARKER IS PREFIX-MATCHED, so a future version can extend that line without every file
# written by this one suddenly freezing itself as developer-managed.
printf '%s (v2)\nX=1\n' "$WT_ENV_MARKER" >"$EW/$EF"
eq 'a marker line with something appended is still ours' 'ours' "$(wt_runtime_env_state "$EW" "$EF")"
rm -f "$EW/$EF"

# NOT GITIGNORED — refused, because an override file that shows up as an untracked change gets
# committed by accident, and then every teammate's worktree points at one database.
wt_runtime_env_write "$EW" tracked.env SERVER_PORT 3812 "$(mk_pairs 'A=1')"
eq 'a path that is not gitignored is refused' 'skipped' "$WT_ENV_WROTE"
eq 'and nothing is written there' 0 "$([ -e "$EW/tracked.env" ] && echo 1 || echo 0)"
contains 'and it says why' 'not gitignored' \
  "$(wt_runtime_env_write "$EW" tracked.env SERVER_PORT 3812 "$(mk_pairs 'A=1')" 2>&1)"

# THE WORKTREE'S OWN .gitignore GOVERNS, not the main checkout's — a branch can legitimately differ,
# and asking the wrong one would refuse a path the app actually loads.
printf 'branch-only.env\n' >>"$EW/.gitignore"
wt_runtime_env_write "$EW" branch-only.env SERVER_PORT 3812 "$(mk_pairs 'A=1')"
eq "a path ignored only by the WORKTREE's .gitignore is accepted" 'written' "$WT_ENV_WROTE"
git -C "$EW" checkout -q -- .gitignore 2>/dev/null || printf '.env.worktree.local\nignored/\n' >"$EW/.gitignore"
rm -f "$EW/branch-only.env"

# SYMLINKS, at the leaf and at a parent. runtime.env.file comes from a committed profile, so it
# arrives with anyone's branch, and a write through a link lands outside the worktree entirely.
OUTSIDE=$TMP/outside-target
: >"$OUTSIDE"
ln -sf "$OUTSIDE" "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')"
eq 'a symlinked override path is refused' 'skipped' "$WT_ENV_WROTE"
eq 'and the file it pointed at is untouched' 0 "$(wc -c <"$OUTSIDE" | tr -d ' ')"
rm -f "$EW/$EF"
mkdir -p "$TMP/outside-dir"
ln -sfn "$TMP/outside-dir" "$EW/ignored"
wt_runtime_env_write "$EW" ignored/x.env SERVER_PORT 3812 "$(mk_pairs 'A=1')"
eq 'a symlinked PARENT directory is refused too' 'skipped' "$WT_ENV_WROTE"
eq 'and nothing is written through it' 0 \
  "$(find "$TMP/outside-dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
# The refusal must come from OUR guard, named as such. git happens to refuse this path too
# ("pathspec is beyond a symbolic link", rc 128), so without pinning the message the two guards
# overlap and removing ours would look harmless.
contains 'and the refusal is ours, naming the symlinked parent' 'parent directories is a symlink' \
  "$(wt_runtime_env_write "$EW" ignored/x.env SERVER_PORT 3812 "$(mk_pairs 'A=1')" 2>&1)"
rm -f "$EW/ignored"

# A git THAT CANNOT ANSWER is a refusal, not permission. exit 0 means ignored and 1 means not;
# anything else (no git, a corrupt index, a path beyond a symlink) must not be read as a yes —
# that is how an override file ends up tracked and committed for the whole team.
eq 'a git that fails an unexpected way means the file is not written' 'skipped' \
  "$(rm -f "$EW/$EF"
     # shellcheck disable=SC2329
     wt_git() { return 128; }
     wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" >/dev/null 2>&1
     printf '%s' "$WT_ENV_WROTE")"
eq 'and nothing is left on disk' 0 "$([ -e "$EW/$EF" ] && echo 1 || echo 0)"
contains 'and it reports the exit code rather than guessing' 'could not ask git' \
  "$(# shellcheck disable=SC2329
     wt_git() { return 128; }
     wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" 2>&1)"

# A path escaping the worktree is refused on shape alone, before anything is resolved.
for bad in ../escape.env /abs.env '' .; do
  wt_runtime_env_write "$EW" "$bad" SERVER_PORT 3812 "$(mk_pairs 'A=1')" >/dev/null 2>&1
  eq "an unsafe env path (${bad:-<empty>}) is refused" 'skipped' "$WT_ENV_WROTE"
done
eq 'and nothing escaped the worktree' 0 "$([ -e "$TMP/escape.env" ] && echo 1 || echo 0)"

# A BAD KEY IS SKIPPED, NOT FATAL — the other variables are still worth writing. Re-checked here
# rather than trusted from validation, because this is a public entry point and WT_SKIP_VALIDATION
# can bypass the validator entirely.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'GOOD=1' 'BAD KEY=2' 'ALSO_GOOD=3')"
eq 'a malformed key does not stop the file being written' 'written' "$WT_ENV_WROTE"
eq 'the good keys are there' 2 \
  "$(grep -c -e '^GOOD=' -e '^ALSO_GOOD=' "$EW/$EF" | tr -d ' ')"
eq 'and the malformed one is not' 0 "$(grep -c 'BAD KEY' "$EW/$EF" | tr -d ' ')"
contains 'and it says which key it skipped' 'BAD KEY' \
  "$(rm -f "$EW/$EF"; wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'BAD KEY=2')" 2>&1)"

# No port variable and no vars: the file is still written, with just the marker, so its presence
# still means "this worktree is managed" rather than looking absent.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' ''
eq 'a file with nothing to put in it is still written' 'written' "$WT_ENV_WROTE"
eq 'and reads as ours' 'ours' "$(wt_runtime_env_state "$EW" "$EF")"
eq 'and contains no KEY=VALUE lines' 0 \
  "$(grep -c -v '^#' "$EW/$EF" | tr -d ' ')"

# EVERY ENVIRONMENT, not just the default one. `vars` is a plain map, so isolating development and
# test at once is a matter of the engine writing all of it faithfully — the acceptance criterion
# that says two worktrees must not destroy each other's TEST runs either.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 \
  "$(mk_pairs 'DATABASE_NAME=demo_{slug}' 'TEST_DATABASE_NAME=demo_{slug}_test' 'CI_DATABASE_NAME=demo_{slug}_ci')"
eq 'the development database is isolated' 'DATABASE_NAME=demo_alice_fix_99' \
  "$(grep '^DATABASE_NAME=' "$EW/$EF")"
eq 'the test database is isolated too' 'TEST_DATABASE_NAME=demo_alice_fix_99_test' \
  "$(grep '^TEST_DATABASE_NAME=' "$EW/$EF")"
eq 'and so is CI' 'CI_DATABASE_NAME=demo_alice_fix_99_ci' \
  "$(grep '^CI_DATABASE_NAME=' "$EW/$EF")"

# {port} resolves from the exported WT_PORT, which is what makes a URL in a value work.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(mk_pairs 'APP_URL=http://localhost:{port}/')"
eq 'a {port} placeholder resolves from the allocated port' 'APP_URL=http://localhost:3812/' \
  "$(grep '^APP_URL=' "$EW/$EF")"

# A value carrying a newline cannot forge a second line. The JSON layer folds these, so this is the
# backstop for a pairs stream built any other way.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(printf '3%sA%sx%sFORGED=1%s' "$US_" "$US_" "$NL_" "$RS_")"
eq 'a newline in a value cannot forge a second assignment' 0 \
  "$(grep -c '^FORGED=' "$EW/$EF" | tr -d ' ')"

# THE PORT VARIABLE IS A KEY TOO, and was written unchecked at first while the vars keys beside it
# were guarded. It lands on the left of a `KEY=value` line exactly as they do, validation only
# WARNS about it, and WT_SKIP_VALIDATION removes even that.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" 'A=1' 3812 "$(mk_pairs 'GOOD=1')"
eq 'a malformed port var does not stop the file being written' 'written' "$WT_ENV_WROTE"
eq 'and no forged assignment reaches the file' 0 "$(grep -c '^A=1=' "$EW/$EF" | tr -d ' ')"
eq 'and the legitimate variables are still there' 'GOOD=1' "$(grep '^GOOD=' "$EW/$EF")"
contains 'and it says the port line was skipped' 'skipping the port line' \
  "$(rm -f "$EW/$EF"; wt_runtime_env_write "$EW" "$EF" 'A=1' 3812 '' 2>&1)"
eq 'and the summary does not claim a port it did not write' 0 \
  "$(rm -f "$EW/$EF"; wt_runtime_env_write "$EW" "$EF" 'A=1' 3812 '' 2>&1 | grep -c 'A=1=3812' | tr -d ' ')"
# A port VAR with no port value must not be announced either.
rm -f "$EW/$EF"
lacks 'a port var with no derived port is not announced' '(SERVER_PORT=)' \
  "$(wt_runtime_env_write "$EW" "$EF" SERVER_PORT '' "$(mk_pairs 'A=1')" 2>&1)"
eq 'and no bare port line is written' 0 "$(grep -c '^SERVER_PORT' "$EW/$EF" | tr -d ' ')"

# A CR forges a line as readily as an LF, and only the LF sibling was pinned.
rm -f "$EW/$EF"
wt_runtime_env_write "$EW" "$EF" '' '' "$(printf '3%sA%sx%sFORGEDCR=1%s' "$US_" "$US_" "$CR_" "$RS_")"
# ANCHORED: folding leaves the text on the SAME line (`A=x FORGEDCR=1`), which is the point —
# what must not exist is a second ASSIGNMENT, so the pattern has to be anchored to a line start.
eq 'a carriage return in a value cannot forge a second assignment' 0 \
  "$(grep -c '^FORGEDCR=' "$EW/$EF" | tr -d ' ')"
eq 'and the folded value stays on the one line it belongs to' 'A=x FORGEDCR=1' \
  "$(grep '^A=' "$EW/$EF")"

# --- wt_runtime_env_state: the arms that only another guard was covering ---
# This is a public accessor whose answer is RECORDED as envstate, so each arm has to hold on its
# own rather than be saved by the write-side symlink check.
rm -f "$EW/$EF"
printf '%s\nX=1\n' "$WT_ENV_MARKER" >"$TMP/marker-bearing"
ln -sf "$TMP/marker-bearing" "$EW/$EF"
eq 'a symlink pointing at a marker-bearing file is THEIRS, not ours' 'theirs' \
  "$(wt_runtime_env_state "$EW" "$EF")"
rm -f "$EW/$EF"
ln -sf "$TMP/does-not-exist-at-all" "$EW/$EF"
eq 'a dangling symlink is theirs, not absent' 'theirs' "$(wt_runtime_env_state "$EW" "$EF")"
rm -f "$EW/$EF"
mkdir -p "$EW/$EF"
eq 'the path existing as a directory is theirs' 'theirs' "$(wt_runtime_env_state "$EW" "$EF")"
rmdir "$EW/$EF"
if [ "$(id -u)" != 0 ]; then
  printf '%s\n' "$WT_ENV_MARKER" >"$EW/$EF"
  chmod 000 "$EW/$EF"
  eq 'an unreadable file is theirs — we cannot prove we wrote it' 'theirs' \
    "$(wt_runtime_env_state "$EW" "$EF")"
  chmod 600 "$EW/$EF"
fi
rm -f "$EW/$EF"

# The marker's CONTRACT, independent of its exact text: it must be a comment, so that a dotenv
# reader ignores it rather than choking on the first line of every file this writes.
case $WT_ENV_MARKER in
  '#'*) pass=$((pass + 1)) ;;
  *) fail=$((fail + 1)); printf 'FAIL the env marker is not a comment line: %q\n' "$WT_ENV_MARKER" >&2 ;;
esac

# --- the failure paths, which decide whether a failed write leaves debris ---
# A leaked .wtenv.* is not gitignored, so it shows up as an untracked change — the precise harm the
# gitignore guard exists to prevent.
rm -f "$EW/$EF"
eq 'a mktemp that fails is reported, not ignored' 'skipped' \
  "$(# shellcheck disable=SC2329
     mktemp() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" >/dev/null 2>&1
     printf '%s' "$WT_ENV_WROTE")"
contains 'and it says so' 'could not write' \
  "$(# shellcheck disable=SC2329
     mktemp() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" 2>&1)"
eq 'a failed mv leaves no temporary file behind' 0 \
  "$(# shellcheck disable=SC2329
     mv() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" >/dev/null 2>&1
     find "$EW" -maxdepth 1 -name '.wtenv.*' 2>/dev/null | wc -l | tr -d ' ')"
contains 'and a failed mv is reported rather than claimed as success' 'could not write' \
  "$(# shellcheck disable=SC2329
     mv() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" 2>&1)"
# A FAILED WRITE MUST NOT BE PROMOTED. The shadow below fails WITHOUT writing anything, so a
# version that ignores the status would move an empty file into place and report success — and if
# the lost line were the marker, every later session would read the file as developer-owned and
# never touch it again. Asserting only "no temp left behind" misses that entirely, because the
# unchecked path cleans up after itself by succeeding.
rm -f "$EW/$EF"
eq 'a failed write is reported, not promoted' 'skipped' \
  "$(# shellcheck disable=SC2329
     printf() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" >/dev/null 2>&1
     command printf '%s' "$WT_ENV_WROTE")"
eq 'and no override file is left in place after it' 0 \
  "$([ -e "$EW/$EF" ] && echo 1 || echo 0)"
eq 'and no temporary file is left behind either' 0 \
  "$(# shellcheck disable=SC2329
     printf() { return 1; }
     wt_runtime_env_write "$EW" "$EF" P 1 "$(mk_pairs 'A=1')" >/dev/null 2>&1
     find "$EW" -maxdepth 1 -name '.wtenv.*' 2>/dev/null | wc -l | tr -d ' ')"

# The unsafe-path refusal must be OURS, named as such: git also refuses some of these paths, so
# without pinning the message the shape guard could be deleted unnoticed.
for bad in ../escape.env /abs.env; do
  contains "the refusal for $bad is the shape guard, not git" 'not a relative path inside the worktree' \
    "$(wt_runtime_env_write "$EW" "$bad" P 1 "$(mk_pairs 'A=1')" 2>&1)"
done
contains 'and a trailing slash is refused as a directory' 'names a directory' \
  "$(wt_runtime_env_write "$EW" 'ignored/' P 1 "$(mk_pairs 'A=1')" 2>&1)"
eq 'nothing escaped into the worktrees directory' 0 \
  "$([ -e "$EREPO/.claude/worktrees/escape.env" ] && echo 1 || echo 0)"

# THE ACCEPTANCE CRITERION IN FULL: a file the developer took over survives a re-bootstrap AND is
# not re-announced. The once-ness lives in the caller's state record, so what this function owes is
# SILENCE — a wt_log added here would make every session warn, and nothing pinned that.
rm -f "$EW/$EF"
printf 'DATABASE_NAME=colleagues_db\n' >"$EW/$EF"
before=$(cat "$EW/$EF")
eq 'the developer path says nothing itself' '' \
  "$(wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" ours 2>&1)"
wt_runtime_env_write "$EW" "$EF" SERVER_PORT 3812 "$(mk_pairs 'A=1')" theirs
eq 'a second consecutive run still reports developer-managed' 'developer' "$WT_ENV_WROTE"
eq 'and the file is byte-identical after both runs' "$before" "$(cat "$EW/$EF")"

rm -f "$EW/$EF"
unset WT_PORT

# ---------------------------------------------------------------------------
# Layer 3 — the seed contract
# ---------------------------------------------------------------------------
SREPO2=$TMP/srepo
mkdir -p "$SREPO2"
git init -q "$SREPO2"
git -C "$SREPO2" config user.email t@example.com
git -C "$SREPO2" config user.name t
printf '.env.worktree.local\n' >"$SREPO2/.gitignore"
: >"$SREPO2/f"; git -C "$SREPO2" add -A; git -C "$SREPO2" commit -qm init
git -C "$SREPO2" worktree add -q "$SREPO2/.claude/worktrees/sw" -b sw 2>/dev/null
SW=$SREPO2/.claude/worktrees/sw
mkdir -p "$SW/.claude"
SEEDREL=.claude/worktree-seed.sh

# The default state for these tests: a trustworthy sibling scan with no siblings, and an env file
# this plugin owns. Each refusal below flips exactly one of those.
# shellcheck disable=SC2034
WT_SIBLINGS_OK=1
# shellcheck disable=SC2034
WT_SIBLINGS=''
# shellcheck disable=SC2034
PROFILE_SEED_TIMEOUT=30
# shellcheck disable=SC2034
PROFILE_SHELL=''
seed_deadline() { printf '%s' "$(( $(date +%s) + 300 ))"; }
write_seed() { printf '%s' "$1" >"$SW/$SEEDREL"; chmod +x "$SW/$SEEDREL"; }
reset_seed_state() { rm -f "$(wt_state_path "$SW")"; }

WT_NAME=seedwt; WT_SLUG=seed_slug; WT_PATH=$SW; WT_ROOT=$SREPO2
export WT_NAME WT_SLUG WT_PATH WT_ROOT

# --- the happy path, and what the script actually receives -----------------------------------
reset_seed_state
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
{ printf "name=%s\n" "$WT_NAME"
  printf "slug=%s\n" "$WT_SLUG"
  printf "port=%s\n" "$WT_PORT"
  printf "path=%s\n" "$WT_PATH"
  printf "root=%s\n" "$WT_ROOT"
  printf "envfile=%s\n" "$WT_ENV_FILE"
  printf "cwd=%s\n" "$PWD"
} >"$WT_PATH/seed-saw.txt"
'
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'a seed that succeeds is recorded done' 'done' "$WT_SEED_STATUS"
eq 'the seed receives WT_SLUG'     'slug=seed_slug'              "$(grep '^slug='    "$SW/seed-saw.txt")"
eq 'the seed receives WT_PORT'     'port=3812'                   "$(grep '^port='    "$SW/seed-saw.txt")"
eq 'the seed receives WT_ENV_FILE' 'envfile=.env.worktree.local' "$(grep '^envfile=' "$SW/seed-saw.txt")"
eq 'the seed receives WT_ROOT'     "root=$SREPO2"                "$(grep '^root='    "$SW/seed-saw.txt")"
eq 'the seed receives WT_NAME'     'name=seedwt'                 "$(grep '^name='    "$SW/seed-saw.txt")"
eq 'and it runs with the WORKTREE as its working directory' "cwd=$SW" \
  "$(grep '^cwd=' "$SW/seed-saw.txt")"
eq 'the outcome is recorded in the state file' 'done' "$(wt_runtime_state_get "$SW" seedstatus)"
ne 'along with a fingerprint of the script' '' "$(wt_runtime_state_get "$SW" seedcksum)"

# --- SKIP when nothing has changed, RETRY when the script does -------------------------------
rm -f "$SW/seed-saw.txt"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'a second run with an unchanged script does not re-run it' 0 \
  "$([ -e "$SW/seed-saw.txt" ] && echo 1 || echo 0)"
eq 'and still reports done' 'done' "$WT_SEED_STATUS"
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
printf changed >"$WT_PATH/seed-saw.txt"
'
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'editing the script makes it run again' 'changed' "$(cat "$SW/seed-saw.txt" 2>/dev/null)"
# A CHANGED SLUG is a different database, so a `done` marker from the old one must not skip it.
rm -f "$SW/seed-saw.txt"
wt_runtime_seed "$SREPO2" "$SW" other_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'a changed slug re-runs the seed for the new database' 'changed' \
  "$(cat "$SW/seed-saw.txt" 2>/dev/null)"

# --- A FAILURE IS NOT RE-PAID EVERY SESSION --------------------------------------------------
# Calibration deliberately scaffolds a stub that exits non-zero until edited. Retrying it forever
# would burn the whole seed timeout on every session for a failure already reported.
reset_seed_state
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
printf ran >>"$WT_PATH/seed-runs.txt"
echo "worktree-seed.sh is still the unedited stub" >&2
exit 1
'
rm -f "$SW/seed-runs.txt"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a failing seed is recorded failed' 'failed' "$WT_SEED_STATUS"
eq 'and the session survives it' 0 $?
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'an unchanged failing seed is NOT retried on later sessions' 'ran' \
  "$(cat "$SW/seed-runs.txt" 2>/dev/null)"
contains 'and it says how to try again' 'Edit it to try again' \
  "$(wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>&1)"
# ...but editing it retries by itself, with no reset step to remember.
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
printf ran >>"$WT_PATH/seed-runs.txt"
exit 0
'
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'editing a failed seed retries it without any reset step' 'ranran' \
  "$(cat "$SW/seed-runs.txt" 2>/dev/null)"
eq 'and it is recorded done this time' 'done' "$WT_SEED_STATUS"

# --- A HANGING SEED IS STOPPED, and still leaves a usable session ----------------------------
reset_seed_state
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
sleep 30
'
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
  "$(( $(date +%s) + 2 ))" 2>/dev/null
eq 'a seed that outruns its budget is stopped and recorded as a timeout' 'timeout' "$WT_SEED_STATUS"
eq 'and the timeout is recorded, so an unchanged script is not re-run' 'timeout' \
  "$(wt_runtime_state_get "$SW" seedstatus)"
# The budget comes out of what is LEFT, not a fresh allowance: both run inside one hook invocation.
reset_seed_state
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
  "$(( $(date +%s) - 10 ))" 2>/dev/null
eq 'an exhausted budget does not start the seed at all' 'failed' "$WT_SEED_STATUS"
contains 'and says why' 'no time left' \
  "$(reset_seed_state
     wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
       "$(( $(date +%s) - 10 ))" 2>&1)"

# --- THE THREE REFUSALS ----------------------------------------------------------------------
# This is the one step that fails CLOSED: everything else in layer 3 fails open, because a missing
# port costs a bind error while a wrong database name destroys a colleague's work.
reset_seed_state
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
printf ran >>"$WT_PATH/seed-refuse.txt"
'
rm -f "$SW/seed-refuse.txt"

# 1. The env file is the developer's, so the app is pointed somewhere WT_SLUG does not describe.
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local theirs "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a developer-managed env file refuses the seed' 'refused' "$WT_SEED_STATUS"
contains 'and explains how to hand it back' "Put the plugin's block back" \
  "$(wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local theirs "$SEEDREL" "$(seed_deadline)" 2>&1)"

# 2. The sibling scan could not run, so it cannot be shown that nobody else owns this slug. The
# seed runs that scan ITSELF now — inheriting a flag a previous caller happened to leave was a real
# defect, because wt_runtime_claim_port returns before scanning whenever a port is already recorded
# and never runs at all for a profile with a seed and no runtime.port. So this is forced by
# shadowing the scan rather than by setting a global the function no longer reads.
seed_with_broken_scan() {
  # shellcheck disable=SC2329
  wt_runtime_siblings() { WT_SIBLINGS=''; WT_SIBLINGS_OK=0; }
  wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
  printf '%s' "$WT_SEED_STATUS"
}
reset_seed_state
eq 'an untrustworthy sibling scan refuses the seed — it fails CLOSED' 'refused' \
  "$(seed_with_broken_scan 2>/dev/null)"
contains 'and says it could not enumerate the other worktrees' 'could not enumerate' \
  "$( # shellcheck disable=SC2329
      wt_runtime_siblings() { WT_SIBLINGS=''; WT_SIBLINGS_OK=0; }
      reset_seed_state
      wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
        "$(seed_deadline)" 2>&1)"

# 3. Another LIVE worktree already owns this slug — with a real sibling worktree, not a hand-set
# global, since the whole point is that the seed establishes this for itself. There is no safe way
# to invent an alternative database name, so it refuses and names the collision.
git -C "$SREPO2" worktree add -q "$SREPO2/.claude/worktrees/rival" -b rival 2>/dev/null
RIVAL=$SREPO2/.claude/worktrees/rival
wt_runtime_state_set "$RIVAL" seed_slug 3900 derived .e ours "done" RCK
reset_seed_state
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a slug another live worktree owns refuses the seed' 'refused' "$WT_SEED_STATUS"
contains 'and names what to do about it' 'Rename this worktree' \
  "$(reset_seed_state
     wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
       "$(seed_deadline)" 2>&1)"
# A PORTLESS rival still blocks it — that sibling seeded a database even though it never got a port.
wt_runtime_state_set "$RIVAL" seed_slug '' '' .e ours "done" RCK
reset_seed_state
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a rival with no port recorded still blocks the seed' 'refused' "$WT_SEED_STATUS"

# NOT ONE of the refusals may have run the script — asserted before the positive case below.
eq 'no refusal ever ran the script' 0 \
  "$([ -e "$SW/seed-refuse.txt" ] && echo 1 || echo 0)"

# A DIFFERENT slug on that sibling is not a collision, which proves the refusals were about the
# collision rather than about refusing everything.
wt_runtime_state_set "$RIVAL" other_slug 3900 derived .e ours "done" RCK
reset_seed_state
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'a sibling on a different slug does not refuse it' 'done' "$WT_SEED_STATUS"
eq 'and the script really did run that time' 'ran' "$(cat "$SW/seed-refuse.txt" 2>/dev/null)"

# AN ORPHANED rival — its checkout deleted with `rm -rf` rather than `git worktree remove` — must
# NOT block the seed, or a name becomes permanently unusable.
wt_runtime_state_set "$RIVAL" seed_slug 3900 derived .e ours "done" RCK
mv "$RIVAL" "$RIVAL.gone"
reset_seed_state
rm -f "$SW/seed-refuse.txt"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'an orphaned rival does not block the seed forever' 'done' "$WT_SEED_STATUS"
mv "$RIVAL.gone" "$RIVAL"
git -C "$SREPO2" worktree remove --force "$RIVAL" 2>/dev/null

# THE SKIP COMES FIRST, before any refusal. A worktree that seeded successfully and whose developer
# then took ownership of the env file must stay quiet — the file is a supported escape hatch and
# the outcome is already recorded, so re-asking the refusal questions would warn on every session
# about a seed that is not going to run anyway.
reset_seed_state
rm -f "$SW/seed-refuse.txt"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'a seed that has run is recorded done' 'done' "$WT_SEED_STATUS"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local theirs "$SEEDREL" "$(seed_deadline)"
eq 'taking ownership of the env file afterwards still reports done, not refused' 'done' \
  "$WT_SEED_STATUS"
eq 'and says nothing at all about it' '' \
  "$(wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local theirs "$SEEDREL" "$(seed_deadline)" 2>&1)"

# A WORKTREE MUST RECOGNISE ITSELF among the siblings, even when git wrote its gitdir pointer
# RELATIVELY (2.48+ worktree.useRelativePaths). Without collapsing the `..` segments, the path never
# string-equals our own, this worktree appears as its own rival, and the seed then refuses on every
# single session — blaming a colleague's worktree that does not exist, in a design where refusing
# looks deliberate.
SWADMIN=$SREPO2/.git/worktrees/sw
cp "$SWADMIN/gitdir" "$TMP/sw-gitdir.abs"
printf '../../../.claude/worktrees/sw/.git\n' >"$SWADMIN/gitdir"
reset_seed_state
rm -f "$SW/seed-refuse.txt"
# Give ourselves a recorded slug, so a failure to exclude self shows up as a self-collision.
wt_runtime_state_set "$SW" seed_slug 3812 derived .env.worktree.local ours none ''
( cd / && wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
    "$(seed_deadline)" >/dev/null 2>&1
  printf '%s' "$WT_SEED_STATUS" ) >"$TMP/self-seed-status"
eq 'a worktree with a RELATIVE gitdir pointer does not refuse itself as a rival' 'done' \
  "$(cat "$TMP/self-seed-status")"
cp "$TMP/sw-gitdir.abs" "$SWADMIN/gitdir"

# A COMMITTED-BUT-NOT-EXECUTABLE seed is a SKIP, not a failure. `chmod +x` does not change a file's
# content, so recording a failure would fingerprint the script and then refuse to retry it —
# leaving "edit it to try again" as the only escape from a problem editing does not fix.
reset_seed_state
rm -f "$SW/seed-runs.txt"
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
printf ran >>"$WT_PATH/seed-runs.txt"
'
chmod -x "$SW/$SEEDREL"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a non-executable seed is skipped, not failed' 'skipped' "$WT_SEED_STATUS"
eq 'and it did not run' 0 "$([ -e "$SW/seed-runs.txt" ] && echo 1 || echo 0)"
contains 'and it says to chmod +x rather than to edit it' 'chmod +x' \
  "$(wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
       "$(seed_deadline)" 2>&1)"
eq 'and no fingerprint is recorded, so chmod +x alone makes it run' '' \
  "$(wt_runtime_state_get "$SW" seedcksum)"
chmod +x "$SW/$SEEDREL"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" "$(seed_deadline)"
eq 'chmod +x alone is enough to run it, with no edit' 'ran' "$(cat "$SW/seed-runs.txt" 2>/dev/null)"

# A TIMEOUT CAUSED BY A SHORT BUDGET STAYS RETRYABLE. If a slow dependency install ate the budget,
# the script was never the problem — fingerprinting it would wedge seeding permanently, and
# "edit the script" would be advice about a script that is fine.
reset_seed_state
# SC2016: single-quoted ON PURPOSE — the $WT_* references must reach the SCRIPT and be expanded
# when the seed runs with the environment the contract gives it, not by this suite.
# shellcheck disable=SC2016
write_seed '#!/usr/bin/env bash
sleep 30
'
if command -v timeout >/dev/null 2>&1; then
  # A generous profile allowance, but only ~2s of budget left: the clamp bites, so the timeout is
  # the budget's fault and not the script's.
  # shellcheck disable=SC2034
  PROFILE_SEED_TIMEOUT=120
  wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
    "$(( $(date +%s) + 2 ))" 2>/dev/null
  eq 'a budget-starved seed is recorded as a timeout' 'timeout' "$WT_SEED_STATUS"
  eq 'but WITHOUT a fingerprint, so the next session tries again' '' \
    "$(wt_runtime_state_get "$SW" seedcksum)"
  contains 'and it blames the budget rather than the script' 'used the budget' \
    "$(reset_seed_state
       wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
         "$(( $(date +%s) + 2 ))" 2>&1)"
  # ...whereas a seed given its FULL allowance and still hanging is the script's fault, so that one
  # IS fingerprinted and not retried until it changes.
  reset_seed_state
  # shellcheck disable=SC2034
  PROFILE_SEED_TIMEOUT=2
  wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .env.worktree.local ours "$SEEDREL" \
    "$(seed_deadline)" 2>/dev/null
  eq 'a seed that hangs with its full allowance is a timeout too' 'timeout' "$WT_SEED_STATUS"
  ne 'and IS fingerprinted, so it is not retried until it changes' '' \
    "$(wt_runtime_state_get "$SW" seedcksum)"
  # shellcheck disable=SC2034
  PROFILE_SEED_TIMEOUT=30
fi

# --- the script itself must be the one this branch committed ---------------------------------
reset_seed_state
rm -f "$SW/$SEEDREL"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .e ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a seed script that is not there is skipped, not an error' 'skipped' "$WT_SEED_STATUS"
ln -sf /bin/echo "$SW/$SEEDREL"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .e ours "$SEEDREL" "$(seed_deadline)" 2>/dev/null
eq 'a symlinked seed script is refused' 'refused' "$WT_SEED_STATUS"
rm -f "$SW/$SEEDREL"
for bad in ../evil.sh /etc/evil.sh; do
  wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .e ours "$bad" "$(seed_deadline)" 2>/dev/null
  eq "a seed path escaping the worktree ($bad) is refused" 'refused' "$WT_SEED_STATUS"
done

# --- a path carrying shell syntax is DATA, not a command -------------------------------------
# The worktree path (which embeds an untrusted name) never enters the command string, and the seed
# path is quoted. A file whose NAME contains shell syntax must run, not be interpreted.
reset_seed_state
mkdir -p "$SW/.claude"
ODD=".claude/we'ird;\$(touch PWNED).sh"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf odd >"$WT_PATH/seed-odd.txt"\n' >"$SW/$ODD"
chmod +x "$SW/$ODD"
wt_runtime_seed "$SREPO2" "$SW" seed_slug 3812 .e ours "$ODD" "$(seed_deadline)" 2>/dev/null
eq 'a seed path containing shell syntax is executed, not interpreted' 'odd' \
  "$(cat "$SW/seed-odd.txt" 2>/dev/null)"
eq 'and nothing it looked like was run' 0 \
  "$( { [ -e "$SW/PWNED" ] || [ -e PWNED ]; } && echo 1 || echo 0)"

reset_seed_state
rm -rf "$SW/seed-saw.txt" "$SW/seed-runs.txt" "$SW/seed-refuse.txt" "$SW/seed-odd.txt"
unset WT_SIBLINGS WT_SIBLINGS_OK

# ---------------------------------------------------------------------------
# The runtime hand-off
# ---------------------------------------------------------------------------
PROFILE_HAS_RUNTIME=0
eq 'with no runtime block the hand-off is silent (touch nothing)' '' \
  "$(wt_runtime_handoff "$DREPO" "$DWT" 2>&1)"
PROFILE_HAS_RUNTIME=1
# With a runtime block but nothing in it to act on, it is still silent about ports and files and
# reports only what it settled on — there is no port var, no env file and no seed to mention.
contains 'with a runtime block it reports the slug it settled on' 'runtime: slug=' \
  "$(wt_runtime_handoff "$DREPO" "$DWT" '' 2>&1)"
# shellcheck disable=SC2034
PROFILE_HAS_RUNTIME=0

# runtime.url is expanded once, here, and published for the session's environment and status line.
PROFILE_HAS_RUNTIME=1 PROFILE_RT_URL='http://{slug}.localhost:3000/'
WT_RUNTIME_URL=stale WT_RUNTIME_PORT=stale
wt_runtime_handoff "$DREPO" "$DWT" '' 2>/dev/null
eq 'hand-off: the url is expanded and published' "http://$WT_SLUG.localhost:3000/" "$WT_RUNTIME_URL"
eq '...and no port is published when none was derived' '' "$WT_RUNTIME_PORT"
PROFILE_RT_URL='http://localhost:{port}'
out=$(wt_runtime_handoff "$DREPO" "$DWT" '' 2>&1)
contains 'hand-off: a url needing a port this worktree lacks is not set, and says so' 'WORKTREE_URL is not set' "$out"
wt_runtime_handoff "$DREPO" "$DWT" '' 2>/dev/null
eq '...and publishes nothing' '' "$WT_RUNTIME_URL"
PROFILE_HAS_RUNTIME=0 PROFILE_RT_URL='http://localhost:3000'
WT_RUNTIME_URL=stale
wt_runtime_handoff "$DREPO" "$DWT" '' 2>/dev/null
eq 'hand-off: no runtime block clears a url left from an earlier run' '' "$WT_RUNTIME_URL"
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_RT_URL=''

# --- the session's own environment (CLAUDE_ENV_FILE) ---------------------------------------------
CEF=$TMP/claude-env/sessionstart-hook-0.sh
mkdir -p "${CEF%/*}"
PROFILE_RT_PORTVAR=SERVER_PORT WT_RUNTIME_PORT=4123 WT_RUNTIME_URL='http://localhost:4123'
wt_session_env_export "$CEF"
eq 'session env: a file that did not exist is created with the two fixed exports' \
  "export WORKTREE_PORT='4123'${NL_}export WORKTREE_URL='http://localhost:4123'" "$(cat "$CEF")"
# The exports must be read back by a shell as exactly these values.
eq '...which a shell reads back as the values' 'http://localhost:4123 4123' \
  "$(env -i bash -c ". '$CEF'; printf '%s %s' \"\$WORKTREE_URL\" \"\$WORKTREE_PORT\"")"
# The file is sourced before every Bash call, approved profile or not: runtime.port.var never names
# an export, or a branch could set it to BASH_ENV or PATH and run its own code (ADR-021).
for pv in SERVER_PORT BASH_ENV PATH NODE_OPTIONS; do
  : >"$CEF"
  PROFILE_RT_PORTVAR=$pv wt_session_env_export "$CEF"
  eq "session env: port.var=$pv is never exported" 0 "$(grep -c "^export $pv=" "$CEF" | tr -d ' ')"
  eq "...only the two fixed names appear (port.var=$pv)" 'WORKTREE_PORT WORKTREE_URL' \
    "$(sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$CEF" | tr '\n' ' ' | sed 's/ $//')"
  eq "...and nothing else is written (port.var=$pv)" 2 "$(wc -l <"$CEF" | tr -d ' ')"
done
# A port var spelled to break out of the line changes nothing either.
: >"$CEF"
PROFILE_RT_PORTVAR='A=1; touch pwned #' wt_session_env_export "$CEF"
eq 'session env: a hostile port var leaves the exports as they were' \
  "export WORKTREE_PORT='4123'${NL_}export WORKTREE_URL='http://localhost:4123'" "$(cat "$CEF")"
printf 'export OTHER=1\n' >"$CEF"
wt_session_env_export "$CEF"
eq 'session env: additive — what was there stays first' 'export OTHER=1' "$(head -1 "$CEF")"
eq '...and the exports follow' 3 "$(wc -l <"$CEF" | tr -d ' ')"
eq 'session env: an empty CLAUDE_ENV_FILE does nothing, silently' '' "$(wt_session_env_export '' 2>&1)"
out=$(wt_session_env_export "$TMP/no-such-dir/env.sh" 2>&1); rc=$?
eq 'session env: an unwritable target is harmless' 0 "$rc"
# The ONLY stderr is the plugin's own warning: bash's "No such file or directory" for the failed open
# must not leak beside it.
eq '...and the only output is the plugin'"'"'s warning' 1 "$(printf '%s\n' "$out" | grep -c .)"
contains '...which says so' 'could not append to CLAUDE_ENV_FILE' "$out"
lacks '...and bash'"'"'s own error does not leak' 'No such file' "$out"
eq '...creating nothing' no "$([ -e "$TMP/no-such-dir" ] && echo yes || echo no)"
out=$(wt_session_env_export "$TMP/claude-env" 2>&1)
contains 'session env: a directory is not written through' 'is not a regular file' "$out"
: >"$CEF"
# shellcheck disable=SC2016  # the $(...) is the payload, kept literal.
WT_RUNTIME_URL='http://x/$(touch pwned)' wt_session_env_export "$CEF"
eq 'session env: an unsafe url is not exported (the port still is)' "export WORKTREE_PORT='4123'" "$(cat "$CEF")"
: >"$CEF"
WT_RUNTIME_PORT='4123x' wt_session_env_export "$CEF"
eq 'session env: a port that is not a number is not exported (the url still is)' \
  "export WORKTREE_URL='http://localhost:4123'" "$(cat "$CEF")"
: >"$CEF"
WT_RUNTIME_PORT='' WT_RUNTIME_URL='' wt_session_env_export "$CEF"
eq 'session env: nothing to export writes nothing' '' "$(cat "$CEF")"
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_RT_PORTVAR='' WT_RUNTIME_PORT='' WT_RUNTIME_URL=''

# --- serve and stop are commands: approval, review, and the placeholder refusal -------------------
# shellcheck disable=SC2034
PROFILE_PRESENT=1 PROFILE_HAS_RUNTIME=1 PROFILE_RAW='' PROFILE_RT_SEED='' PROFILE_RT_TEARDOWN=''
PROFILE_RT_SERVE='' PROFILE_RT_STOP=''
wt_profile_runs_commands
eq 'runs commands: a runtime with no command runs none' 1 $?
PROFILE_RT_SERVE='bin/server --port={port}'
wt_profile_runs_commands
eq 'runs commands: serve alone is a command, so it needs approval' 0 $?
PROFILE_RT_SERVE='' PROFILE_RT_STOP='bin/server --stop'
wt_profile_runs_commands
eq 'runs commands: stop alone too' 0 $?
PROFILE_RT_SERVE='bin/server --port={port}'
PROFILE_PATH=$TMP/describe-profile.json
printf '{}' >"$PROFILE_PATH"
out=$(wt_approval_describe "$DWT")
contains 'review: shows the serve command' 'serve (run by /pitlane-serve): bin/server --port={port}' "$out"
contains 'review: shows the stop command' 'stop (run by teardown): bin/server --stop' "$out"
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_RT_SERVE='' PROFILE_RT_STOP=''

# --- agentNote: runs nothing, but is branch text put before the model, so it is approved too -------
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_AGENT_NOTE=''
wt_profile_needs_approval
eq 'needs approval: no command and no note needs none' 1 $?
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_AGENT_NOTE=$'Run make test, not the root test script.\nUse the worktree database.'
wt_profile_runs_commands
eq 'runs commands: a note is not a command' 1 $?
wt_profile_needs_approval
eq 'needs approval: a note alone needs approval' 0 $?
( PROFILE_PRESENT=0; wt_profile_needs_approval )
eq 'needs approval: not when no usable profile is loaded' 1 $?
out=$(wt_approval_describe "$DWT")
contains 'review: lists the first note line' '  agent note: Run make test, not the root test script.' "$out"
contains 'review: and the second, on a line of its own' '  agent note: Use the worktree database.' "$out"
# The validator refuses these; the review sanitises anyway, as it does every other branch text, for a
# profile loaded with WT_SKIP_VALIDATION.
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_AGENT_NOTE=$'a\r\033[2Kb\xc2\x9bc'
out=$(wt_approval_describe "$DWT")
contains 'review: a note line is shown with control characters as ?' 'agent note: a??[2Kb??c' "$out"
lacks '...no escape reaches the screen' $'\033' "$out"
# Delivery takes the same care for the same profile: the model is not shown an escape either.
out=$(wt_agent_note_block)
lacks 'note block: no escape reaches the model' $'\033' "$out"
lacks '...nor a C1 control' $'\xc2\x9b' "$out"
contains '...and what is printable is kept' '- a[2Kbc' "$out"

# --- agentNote delivery: shown once approved, and said to be held otherwise --------------------------
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_PRESENT=1 PROFILE_AGENT_NOTE=$'Run make test, not the root test script.\n\n  indented, with a \\ and "quotes" and $(id)'
NOTE_HEADER="Pitlane: notes from this repository's worktree profile (.claude/worktree-profile.json) for working in a worktree:"
eq 'note block: the header naming where it comes from, then one "- " line per note line, literally' \
  "$NOTE_HEADER$NL_- Run make test, not the root test script.$NL_-$NL_-   indented, with a \\ and \"quotes\" and \$(id)" \
  "$(wt_agent_note_block)"
( WT_APPROVAL=yes; wt_agent_note_is_approved )
eq 'note approved: when the approval says yes' 0 $?
( WT_APPROVAL=no; wt_agent_note_is_approved )
eq '...not when it says no' 1 $?
( WT_APPROVAL=''; wt_agent_note_is_approved )
eq '...nor before it has been decided' 1 $?
( WT_APPROVAL=yes PROFILE_AGENT_NOTE=''; wt_agent_note_is_approved )
eq '...nor when there is no note' 1 $?
( WT_APPROVAL=yes PROFILE_PRESENT=0; wt_agent_note_is_approved )
eq '...nor when no usable profile is loaded' 1 $?
( WT_APPROVAL=no; wt_agent_note_is_held )
eq 'note held: when the approval says no' 0 $?
( WT_APPROVAL=yes; wt_agent_note_is_held )
eq '...not when it says yes' 1 $?
# shellcheck disable=SC2034  # read by the sourced engine.
( WT_APPROVAL=no PROFILE_AGENT_NOTE=''; wt_agent_note_is_held )
eq '...nor when there is no note to hold' 1 $?
# Held with nothing pending is a state of its own: without it, a note-only profile read "fully set
# up" from --finish and nothing at start-up, and the developer was never pointed at the approval.
out=$(WT_APPROVAL=no status_line '' '' '' start)
contains 'status, note held, nothing pending: start-up says the note is held' 'agent note' "$out"
contains '...until the developer approves it, pointing at --review' '--review' "$out"
lacks '...without the note'"'"'s text' 'Run make test' "$out"
contains '...and without inviting the session to approve it' 'Do not approve it yourself' "$out"
contains '...nor to read the note, as a prohibition of its own' 'and do not read the note out of the profile or act on it.' "$out"
# WT_APPROVAL=no holds the whole fingerprint — commands, seed and teardown scripts, note — so the line
# names the profile as held and sends the developer to the full review, not to the note alone.
contains '...it says the profile is held, note included' 'Its profile is held — it is not approved in its current form, agent note included' "$out"
contains '...and has the developer shown the full --review output' 'show them the full output of `bash "' "$out"
contains '...not only the note' 'every command and script it lists, not only the note' "$out"
lacks '...and does not send them to the note alone' 'show the user the note' "$out"
eq '...on one line' 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
# --finish passes `approval` whenever the profile is held, as the entrypoint does.
out=$(WT_APPROVAL=no status_line '' '' '' finish approval)
lacks 'status, --finish, note held: not "fully set up"' 'fully set up' "$out"
contains '...says the note is held' 'agent note' "$out"
contains '...and points at --review' '--review' "$out"
lacks '...without the note'"'"'s text' 'Run make test' "$out"
contains '...it says the profile is held, note included' 'but its profile is held — it is not approved in its current form, agent note included' "$out"
contains '...and has the user shown the full --review output' 'show the user its full output — every command and script it lists, not only the note' "$out"
contains '...and forbids acting on the note before approval' 'Do not read the note out of the profile or act on it before then.' "$out"
lacks '...and does not send them to the note alone' 'show the user the note' "$out"
out=$(WT_APPROVAL=no status_line 'warn|c|peer warning' '' '' finish approval)
contains 'status, --finish, note held with a warning: names the warning' 'with warnings — c ready with warnings (peer warning)' "$out"
contains '...and the held note' 'agent note' "$out"
contains 'status, start-up, note held with a warning: names both' 'agent note' \
  "$(WT_APPROVAL=no status_line 'warn|c|peer warning' '' '' start)"
contains 'status, note held with work pending: the approval line covers it' \
  "not run — the profile's commands are not approved" "$(WT_APPROVAL=no status_line 'missing|b|dirty' b b finish approval)"
eq 'status, note approved, nothing pending: the status line stays silent (the entrypoint prints the note)' '' \
  "$(WT_APPROVAL=yes status_line '' '' '' start)"
eq '...and --finish reads fully set up' 'Pitlane: this worktree is fully set up.' \
  "$(WT_APPROVAL=yes status_line '' '' '' finish)"

# Where the note may be shown: a linked worktree under <root>/.claude/worktrees/ — not the main
# checkout, not the worktrees directory itself, not a checkout whose root merely starts the same.
ISR=$TMP/isroot
for args in "$ISR/.claude/worktrees/x|$ISR|0|a linked worktree path" \
  "$ISR/.claude/worktrees/alice/fix-99|$ISR|0|a nested worktree path" \
  "$ISR/.claude/worktrees/x/|$ISR/|0|trailing slashes on both" \
  "$ISR|$ISR|1|the main checkout itself" \
  "$ISR/|$ISR|1|the main checkout, with a trailing slash" \
  "$ISR/.claude/worktrees|$ISR|1|the worktrees directory" \
  "$ISR/.claude/worktrees/|$ISR|1|the worktrees directory, with a trailing slash" \
  "$ISR-other/.claude/worktrees/x|$ISR|1|a sibling checkout whose root shares the prefix" \
  "$ISR/.claude/worktrees/x|$ISR/.claude/worktrees/x|1|a worktree taken as its own main checkout" \
  "$ISR/sub/.claude/worktrees/x|$ISR|1|a worktrees directory deeper in the checkout"; do
  IFS='|' read -r is_top is_root is_want is_label <<<"$args"
  wt_is_worktree_of "$is_top" "$is_root"
  eq "worktree of: $is_label" "$is_want" $?
done

# The same rule from a directory, git asked: the worktree and its main checkout, or 1.
PDREPO=$(cd -P "$DREPO" && pwd -P)
wt_linked_worktree_at "$DWT"
eq 'linked worktree at: a worktree root' "0 $PDREPO/.claude/worktrees/dep1 $PDREPO" "$? $WT_LINKED_WORKTREE $WT_LINKED_ROOT"
mkdir -p "$DWT/deep/er"
wt_linked_worktree_at "$DWT/deep/er"
eq '...and a directory inside it' "0 $PDREPO/.claude/worktrees/dep1" "$? $WT_LINKED_WORKTREE"
wt_linked_worktree_at "$DREPO"
eq '...not the main checkout' '1 ' "$? $WT_LINKED_WORKTREE"
mkdir -p "$DREPO/.claude/worktrees/plain"
wt_linked_worktree_at "$DREPO/.claude/worktrees/plain"
eq '...nor a plain directory under .claude/worktrees/, where git answers with the main checkout' '1 ' "$? $WT_LINKED_WORKTREE"
wt_linked_worktree_at "$TMP/no-such-dir/.claude/worktrees/x"
eq '...nor a directory that does not exist' 1 $?
wt_linked_worktree_at ''
eq '...nor no directory at all' 1 $?

# The in-process pre-check: no interpreter unless the profile it would load may carry a note. It may
# only ever say "no" where the load would find no note too.
PCW=$TMP/precheck/wt PCR=$TMP/precheck/root
mkdir -p "$PCW/.claude" "$PCR/.claude"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq 'note pre-check: no profile anywhere is a no' 1 $?
printf '{"schemaVersion":1,"agentNote":["x"]}\n' >"$PCR/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...the main checkout'"'"'s profile is read when the worktree has none' 0 $?
printf '{"schemaVersion":1}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...but the worktree'"'"'s own copy wins, as in wt_load_profile_for: no key there is a no' 1 $?
printf '{\n  "schemaVersion": 1,\n  "agentNote": [\n    "x"\n  ]\n}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW/" "$PCR/"
eq '...a key across a multi-line file is a yes, trailing slashes or not' 0 $?
printf '{"schemaVersion":1,"agent\\u004eote":["x"]}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...a key spelt with a \u escape, which decodes to agentNote, is a yes' 0 $?
printf '{"schemaVersion":1,"x":"\0","agentNote":["x"]}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...a NUL byte does not hide the key behind it' 0 $?
printf '{"schemaVersion":1,"copy":["agentNote"]}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...the quoted word anywhere is a yes: it errs towards loading, never towards skipping' 0 $?
printf '{"schemaVersion":1,"agentNotes":["x"],"copy":["agent note"]}\n' >"$PCW/.claude/worktree-profile.json"
wt_profile_may_carry_agent_note "$PCW" "$PCR"
eq '...a profile that never spells the key is a no' 1 $?
# shellcheck disable=SC2034  # read by the sourced engine.
PROFILE_AGENT_NOTE=''
# shellcheck disable=SC2034
PROFILE_PRESENT=0 PROFILE_HAS_RUNTIME=0

eq 'runtime command: placeholders expand' 'bin/server --port=4123 --name=feat_x' \
  "$(WT_PORT=4123 WT_SLUG=feat_x wt_runtime_command 'bin/server --port={port} --name={slug}')"
out=$(WT_NAME='q; touch pwned' wt_runtime_command 'bin/server --tag={name}'); rc=$?
eq 'runtime command: an unsafe {name} is refused' 1 "$rc"
contains '...naming the placeholder' '{name}' "$out"
lacks '...and printing no command' 'bin/server' "$out"
eq 'runtime command: a harmless {name} expands' 'bin/server --tag=alice/fix-99' \
  "$(WT_NAME='alice/fix-99' wt_runtime_command 'bin/server --tag={name}')"
# shellcheck disable=SC2016  # the $(...) is the payload, kept literal.
WT_PATH='/tmp/a$(x)' wt_runtime_command 'cd {worktree} && run' >/dev/null
eq 'runtime command: an unsafe {worktree} is refused' 1 $?
wt_runtime_command '' >/dev/null
eq 'runtime command: none in the profile is refused' 1 $?

# ---------------------------------------------------------------------------
# /pitlane-serve's process bookkeeping: identity, liveness, the `serve` record, stop, probe
# ---------------------------------------------------------------------------
# Every process started here is a group of its own, killed on the way out whatever happened.
SV_GROUPS=''
stop_test_servers() {
  local g
  for g in $SV_GROUPS; do kill -s KILL -- "-$g" 2>/dev/null; done
}
trap 'stop_test_servers; rm -rf "$TMP"' EXIT
sv_group() {  # $1 = pid file, $2 = inner script; starts it in a session of its own and prints its pid
  local pid=''
  rm -f "$1"
  # shellcheck disable=SC2016  # $$ belongs to the inner shell.
  setsid bash -c 'printf "%s\n" "$$" >"$0"; eval "$1"' "$1" "$2" </dev/null >/dev/null 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    pid=$(cat "$1" 2>/dev/null)
    [ -n "$pid" ] && break
    sleep 0.1
  done
  SV_GROUPS="$SV_GROUPS $pid"
  printf '%s' "$pid"
}
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

if [ -r /proc/self/stat ] && command -v setsid >/dev/null 2>&1; then
  eq 'identity: field 22 of /proc/<pid>/stat, tagged' "stat:$(awk '{ print $22 }' "/proc/$$/stat")" "$(wt_proc_identity $$)"
  # A command name holding `) ` must not shift the fields: they start after the LAST `) `.
  cp "$(command -v sleep)" "$TMP/x) 1 2"
  "$TMP/x) 1 2" 30 &
  odd=$!
  want=$(python3 -c 'import sys; s=open("/proc/%s/stat" % sys.argv[1]).read(); print("stat:" + s[s.rindex(")") + 2:].split()[19])' "$odd")
  eq 'identity: a command name holding ") " does not shift the fields' "$want" "$(wt_proc_identity "$odd")"
  eq 'pgrp: field 5, past the command name' "$(python3 -c 'import os,sys; print(os.getpgid(int(sys.argv[1])))' "$odd")" "$(wt_proc_pgrp "$odd")"
  kill "$odd" 2>/dev/null; wait "$odd" 2>/dev/null
  wt_proc_identity "$odd" >/dev/null
  eq 'identity: a process that is gone has none' 1 $?
  wt_proc_identity 'x1' >/dev/null
  eq 'identity: a non-number is refused' 1 $?

  # A zombie answers kill -0 but is not alive.
  python3 -c '
import os, sys, time
p = os.fork()
if p == 0:
    os._exit(0)
open(sys.argv[1], "w").write(str(p))
time.sleep(5)' "$TMP/zombie.pid" &
  zparent=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/zombie.pid" ] && break; sleep 0.1; done
  sleep 0.2
  zpid=$(cat "$TMP/zombie.pid")
  eq 'alive: the zombie still answers kill -0' yes "$(kill -0 "$zpid" 2>/dev/null && echo yes || echo no)"
  eq 'alive: but is not alive' no "$(wt_pid_alive "$zpid" && echo yes || echo no)"
  eq 'alive: this shell is' yes "$(wt_pid_alive $$ && echo yes || echo no)"
  kill "$zparent" 2>/dev/null; wait "$zparent" 2>/dev/null

  # The record: one slot, carried beside every other kind.
  SVW=$TMP/serve-wt
  mkdir -p "$SVW"
  wt_runtime_state_set "$SVW" sv 4321 derived .env ours none '' 2>/dev/null
  wt_serve_record_read "$SVW"
  eq 'record: none yet' 1 $?
  wt_serve_check "$SVW"
  eq 'check: nothing recorded is 1' 1 $?
  gp=$(sv_group "$TMP/g1.pid" 'sleep 300 & exec sleep 300')
  gid=$(wt_proc_identity "$gp")
  wt_serve_record_write "$SVW" "$gp" "$gp" "$gid" 'ck 1' 'http://localhost:4321/'
  wt_serve_record_read "$SVW"
  eq 'record: read back' "$gp|$gp|$gid|ck 1|http://localhost:4321/" \
    "$WT_SERVE_PID|$WT_SERVE_PGID|$WT_SERVE_IDENTITY|$WT_SERVE_CKSUM|$WT_SERVE_URL"
  eq 'record: the rt record beside it is kept' 4321 "$(wt_runtime_state_get "$SVW" port)"
  wt_serve_check "$SVW"
  eq 'check: alive with its identity is 0' 0 $?

  # PID reuse, simulated: the PID is alive but its start time is not the recorded one.
  wt_serve_record_write "$SVW" "$gp" "$gp" 'stat:1' 'ck 1' 'http://localhost:4321/'
  wt_serve_check "$SVW"
  eq 'check: a live PID with another identity is 3' 3 $?
  wt_serve_stop "$SVW"
  eq 'stop: a recycled PID is reported as such' 3 $?
  eq 'stop: and is NOT signalled' yes "$(wt_pid_alive "$gp" && echo yes || echo no)"
  eq '...nor is its group' 2 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  wt_serve_record_read "$SVW"
  eq 'stop: its record is cleared' 1 $?
  eq '...and the rt record kept' 4321 "$(wt_runtime_state_get "$SVW" port)"

  # The real thing: TERM to the whole group, the leader's child included.
  wt_serve_record_write "$SVW" "$gp" "$gp" "$gid" 'ck 1' 'http://localhost:4321/'
  t0=$(date +%s)
  PITLANE_SERVE_STOP_SECONDS=5 wt_serve_stop "$SVW" 2>"$TMP/stop.err"
  eq 'stop: its own server is stopped' 0 $?
  # SIGTERM reaches the leader's child too, so nothing waits out the grace for a SIGKILL.
  eq '...by SIGTERM to the whole group, well inside the grace' yes "$([ $(( $(date +%s) - t0 )) -lt 3 ] && echo yes || echo no)"
  eq '...with no SIGKILL' '' "$(cat "$TMP/stop.err")"
  sleep 0.2
  eq 'stop: the leader is gone' no "$(wt_pid_alive "$gp" && echo yes || echo no)"
  eq '...and every process of its group' 0 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  wt_serve_record_read "$SVW"
  eq 'stop: the record is gone' 1 $?
  wt_serve_stop "$SVW"
  eq 'stop: nothing recorded is 1' 1 $?

  # Exited: a dead PID is not signalled, and the record goes.
  wt_serve_record_write "$SVW" "$gp" "$gp" "$gid" 'ck 1' 'http://localhost:4321/'
  wt_serve_check "$SVW"
  eq 'check: an exited server is 2' 2 $?
  wt_serve_stop "$SVW"
  eq 'stop: an exited server is 2' 2 $?
  wt_serve_record_read "$SVW"
  eq '...and its record is cleared' 1 $?

  # One that ignores TERM is killed once the grace is up.
  gp=$(sv_group "$TMP/g2.pid" 'trap "" TERM; sleep 300 & while :; do sleep 1; done')
  wt_serve_record_write "$SVW" "$gp" "$gp" "$(wt_proc_identity "$gp")" 'ck 1' 'http://localhost:4321/'
  t0=$(date +%s)
  PITLANE_SERVE_STOP_SECONDS=1 wt_serve_stop "$SVW" 2>"$TMP/stop.err"
  eq 'stop: a server that ignores TERM is stopped by KILL' 0 $?
  contains '...and says so' 'sending SIGKILL' "$(cat "$TMP/stop.err")"
  eq '...after the grace, not the default 10s' yes "$([ $(( $(date +%s) - t0 )) -lt 6 ] && echo yes || echo no)"
  eq '...and nothing of its group is left' 0 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"

  # A leader recorded without a group of its own is signalled alone.
  gp=$(sv_group "$TMP/g3.pid" 'sleep 300 & exec sleep 300')
  wt_serve_record_write "$SVW" "$gp" '' "$(wt_proc_identity "$gp")" 'ck 1' 'http://localhost:4321/'
  wt_serve_stop "$SVW"
  eq 'stop: with no group recorded, the PID is stopped' 0 $?
  sleep 0.2
  eq '...and only the PID: its group keeps its other member' 1 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  kill -s KILL -- "-$gp" 2>/dev/null

  # The probe: any HTTP answer counts; curl, or /dev/tcp with *.localhost taken as loopback.
  sport=$(free_port)
  gp=$(sv_group "$TMP/g4.pid" "exec python3 -m http.server $sport --bind 127.0.0.1")
  for _ in $(seq 1 50); do WT_CURL='' wt_serve_answers "http://127.0.0.1:$sport/" && break; sleep 0.1; done
  eq 'answers: /dev/tcp reaches a listening port' 0 "$(WT_CURL='' wt_serve_answers "http://127.0.0.1:$sport/"; echo $?)"
  eq 'answers: /dev/tcp takes *.localhost as loopback' 0 "$(WT_CURL='' wt_serve_answers "http://alpha.localhost:$sport/x"; echo $?)"
  if command -v curl >/dev/null 2>&1; then
    eq 'answers: curl, and a 404 is an answer' 0 "$(wt_serve_answers "http://127.0.0.1:$sport/no-such-page"; echo $?)"
  fi
  wt_serve_probe "http://127.0.0.1:$sport/" "$gp" 5
  eq 'probe: answers while its process lives' 0 $?
  kill -s KILL -- "-$gp" 2>/dev/null
  sleep 0.2
  eq 'answers: /dev/tcp, nothing listening' 1 "$(WT_CURL='' wt_serve_answers "http://127.0.0.1:$sport/"; echo $?)"
  eq 'answers: curl, nothing listening' 1 "$(wt_serve_answers "http://127.0.0.1:$sport/"; echo $?)"
  gp=$(sv_group "$TMP/g5.pid" 'exec sleep 300')
  wt_serve_probe "http://127.0.0.1:$sport/" "$gp" 1
  eq 'probe: out of time while the process lives is 1' 1 $?
  kill -s KILL -- "-$gp" 2>/dev/null
  sleep 0.2
  wt_serve_probe "http://127.0.0.1:$sport/" "$gp" 5
  eq 'probe: a process that is gone is 2, at once' 2 $?

  # A record the reader cannot trust is no record: a live process named in it is never signalled.
  SVR=$TMP/serve-corrupt
  mkdir -p "$SVR"
  wt_runtime_state_set "$SVR" sv 4321 derived .env ours none '' 2>/dev/null
  SVRF=$(wt_state_path "$SVR")
  victim=$(sv_group "$TMP/victim.pid" 'exec sleep 300')
  vid=$(wt_proc_identity "$victim")
  US=$'\x1f' RS=$'\x1e'
  corrupt() {  # $1 = label, $2 = the whole state file
    printf '%s' "$2" >"$SVRF"
    wt_serve_record_read "$SVR"
    eq "record: $1 is not read" 1 $?
    eq '...and leaves no PID' '' "$WT_SERVE_PID"
    PITLANE_SERVE_STOP_SECONDS=1 wt_serve_stop "$SVR"
    eq '...stop finds nothing recorded' 1 $?
    eq '...and does not signal the process named in it' yes "$(wt_pid_alive "$victim" && echo yes || echo no)"
  }
  rec="serve$US$victim$US$victim$US$vid${US}ck${US}http://localhost:4321/${US}1$US"
  corrupt 'a wrong state version' "wtstate${US}99$RS$rec$RS"
  corrupt 'a serve record before the header' "$rec${RS}wtstate$US$WT_STATE_VERSION$RS"
  corrupt 'a non-numeric pid' "wtstate$US$WT_STATE_VERSION${RS}serve${US}12a$US$victim$US$vid${US}ck${US}http://localhost:4321/${US}1$RS"
  corrupt 'an unknown stopby' "wtstate$US$WT_STATE_VERSION$RS${rec}reboot$RS"
  printf '%s' "wtstate$US$WT_STATE_VERSION$RS${rec}signal$RS" >"$SVRF"
  wt_serve_record_read "$SVR"
  eq 'record: the same record, well formed, is read' "$victim|signal" "$WT_SERVE_PID|$WT_SERVE_STOPBY"
  printf '%s' "wtstate$US$WT_STATE_VERSION$RS$rec$RS" >"$SVRF"
  wt_serve_record_read "$SVR"
  eq 'record: one written before stopby existed reads as signal' "$victim|signal" "$WT_SERVE_PID|$WT_SERVE_STOPBY"
  kill -s KILL -- "-$victim" 2>/dev/null

  # The group is ours only while the process holding its id is the recorded one: a group whose id
  # has passed to another process — simulated by a wrong identity — is neither signalled nor
  # counted as left, so a stop treats it as stopped.
  gp=$(sv_group "$TMP/g6.pid" 'sleep 300 & exec sleep 300')
  WT_SERVE_PID=$gp WT_SERVE_PGID=$gp WT_SERVE_IDENTITY='stat:1'
  eq 'group: a live id with another identity is not ours' no "$(wt_serve_group_ours && echo yes || echo no)"
  eq '...is not what is left of the server' no "$(wt_serve_remains && echo yes || echo no)"
  wt_serve_signal KILL
  sleep 0.2
  eq '...and a SIGKILL meant for the group is not sent' 2 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  WT_SERVE_IDENTITY=$(wt_proc_identity "$gp")
  eq 'group: with its identity it is ours' yes "$(wt_serve_group_ours && echo yes || echo no)"
  kill -s KILL "$gp" 2>/dev/null
  sleep 0.2
  eq 'group: once its leader exits, the members it left are still ours' yes \
    "$(wt_serve_group_ours && echo yes || echo no)"
  kill -s KILL -- "-$gp" 2>/dev/null
  sleep 0.2
  eq 'group: and with none left it is not' no "$(wt_serve_group_ours && echo yes || echo no)"

  # With no group recorded, a PID that ignores TERM is SIGKILLed alone, after its identity is proved.
  gp=$(sv_group "$TMP/g7.pid" 'trap "" TERM; sleep 300 & while :; do sleep 1; done')
  wt_serve_record_write "$SVW" "$gp" '' "$(wt_proc_identity "$gp")" 'ck 1' 'http://localhost:4321/'
  PITLANE_SERVE_STOP_SECONDS=1 wt_serve_stop "$SVW" 2>"$TMP/stop.err"
  eq 'stop: no group, TERM ignored: stopped by SIGKILL to the PID' 0 $?
  contains '...and says so' 'sending SIGKILL' "$(cat "$TMP/stop.err")"
  eq '...the PID is gone' no "$(wt_pid_alive "$gp" && echo yes || echo no)"
  eq '...and only it: its group keeps its other member' 1 "$(pgrep -g "$gp" -f 'sleep 300' 2>/dev/null | wc -l | tr -d ' ')"
  kill -s KILL -- "-$gp" 2>/dev/null

  # A stopped-by-command record is not checked as a process, and a stop runs runtime.stop.
  wt_serve_record_write "$SVW" 99999999 '' '' 'ck 1' 'http://127.0.0.1:1/' command
  wt_serve_check "$SVW"
  eq 'check: a stopped-by-command record is 4' 4 $?
  PROFILE_RT_STOP='' wt_serve_stop "$SVW"
  eq 'stop: by command, with no runtime.stop, cannot stop it' 5 $?
  contains '...saying why' 'the profile names none' "$WT_SERVE_STOP_WHY"
  wt_serve_record_read "$SVW"
  eq '...and keeps the record' command "$WT_SERVE_STOPBY"
  PROFILE_SHELL='' PROFILE_SHELLARGS='' PROFILE_RT_STOP='touch stopped-{port}' WT_GUARD=off wt_serve_stop "$SVW" 2>/dev/null
  eq 'stop: by command runs runtime.stop, expanded, in the worktree' 0 $?
  eq '...{port} from the rt record' yes "$([ -e "$SVW/stopped-4321" ] && echo yes || echo no)"
  wt_serve_record_read "$SVW"
  eq '...and clears the record' 1 $?

  # The serve MIRROR: in a linked worktree every record write is copied to
  # <common>/worktree-servers/<admin id>.<pid>.<when>, which outlives the worktree's admin dir.
  MR=$TMP/mirror-repo
  git init -q "$MR"
  git -C "$MR" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  MW=$MR/.claude/worktrees/mw
  git -C "$MR" worktree add -q "$MW" -b worktree-mw 2>/dev/null
  MW=$(cd -P "$MW" && pwd -P)
  MDIR=$(cd -P "$MR/.git" && pwd -P)/worktree-servers
  wt_runtime_state_set "$MW" mw-slug 4555 derived .env ours none '' 2>/dev/null
  gp=$(sv_group "$TMP/m1.pid" 'sleep 300 & exec sleep 300')
  gid=$(wt_proc_identity "$gp")
  WT_NAME='' wt_serve_record_write "$MW" "$gp" "$gp" "$gid" 'ck 1' 'http://localhost:4555/'
  wt_serve_record_read "$MW"
  mfile=$MDIR/mw.$gp.$WT_SERVE_WHEN
  eq 'mirror: a record written in a linked worktree is mirrored as <admin id>.<pid>.<when>' "$mfile" \
    "$(ls -d "$MDIR"/* 2>/dev/null)"
  wt_serve_mirror_parse "$mfile"
  eq 'mirror: it carries the worktree, admin id, name, slug and port beside the record' \
    "$MW|mw|mw|mw-slug|4555|$gp|$gp|$gid|http://localhost:4555/|signal" \
    "$WT_SERVE_MIRROR_PATH|$WT_SERVE_MIRROR_ADMIN|$WT_SERVE_MIRROR_NAME|$WT_SERVE_MIRROR_SLUG|$WT_SERVE_MIRROR_PORT|$WT_SERVE_PID|$WT_SERVE_PGID|$WT_SERVE_IDENTITY|$WT_SERVE_URL|$WT_SERVE_STOPBY"
  wt_serve_record_write "$MW" 99999999 '' '' 'ck 2' 'http://127.0.0.1:1/' command
  wt_serve_record_read "$MW"
  eq 'mirror: a rewritten record replaces its mirror' "$MDIR/mw.99999999.$WT_SERVE_WHEN" "$(ls -d "$MDIR"/* 2>/dev/null)"
  wt_serve_record_write "$MW" ''
  eq 'mirror: a removed record removes its mirror' '' "$(ls -A "$MDIR")"

  # Teardown holds the bootstrap lock on fd 8 while it stops the server: the record write under it
  # must not reopen fd 8, which would drop that lock.
  MLOCK=$(wt_state_path "$MW").lock
  wt_lock_acquire "$MLOCK" 1 8
  WT_STATE_LOCK_HELD=1 wt_serve_record_write "$MW" ''
  eq 'record: a write by a caller holding the lock leaves the lock held' held \
    "$(flock -n "$MLOCK" true 2>/dev/null && echo free || echo held)"
  wt_lock_release 8

  # Removed as Claude Code removes a native worktree, directory and admin dir at once: the mirror is
  # the record left. A re-entered worktree of the same name gets the same admin id, and its own
  # server's records never touch the earlier one's.
  wt_serve_record_write "$MW" "$gp" "$gp" "$gid" 'ck 1' 'http://localhost:4555/'
  wt_serve_record_read "$MW"
  mfile=$MDIR/mw.$gp.$WT_SERVE_WHEN
  git -C "$MR" worktree remove --force "$MW"
  eq 'mirror: it outlives the worktree and its admin dir' yes "$([ -f "$mfile" ] && echo yes || echo no)"
  git -C "$MR" worktree add -q "$MW" -b worktree-mw-again 2>/dev/null
  gp2=$(sv_group "$TMP/m2.pid" 'exec sleep 300')
  wt_serve_record_write "$MW" "$gp2" "$gp2" "$(wt_proc_identity "$gp2")" 'ck 1' 'http://localhost:4555/'
  eq 'mirror: a re-entered worktree mirrors its own server beside the earlier one' 2 "$(count_in "$MDIR")"
  wt_serve_record_write "$MW" ''
  eq '...and clearing its record removes only its own mirror' "$mfile" "$(ls -d "$MDIR"/* 2>/dev/null)"
  kill -s KILL -- "-$gp2" 2>/dev/null

  # Stopping from a mirror, as /pitlane-tidy and a teardown of a worktree already gone do.
  mirror_file() {  # $1 = file, $2 = pid, $3 = identity, $4 = stopby, $5 = url
    printf '%s' "wtstate$US$WT_STATE_VERSION${RS}worktree$US$MW${US}mw${US}mw${US}mw-slug${US}4555${RS}serve$US$2$US$2$US$3${US}ck$US$5${US}1$US$4$RS" >"$1"
  }
  mirror_file "$MDIR/mw.recycled" "$gp" 'stat:1' signal 'http://localhost:4555/'
  wt_serve_stop_mirrored "$MDIR/mw.recycled" "$MR"
  eq 'stop from mirror: a PID with another start identity is 3' 3 $?
  eq '...and NOT signalled' yes "$(wt_pid_alive "$gp" && echo yes || echo no)"
  eq '...nor its group' 2 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  eq '...and the mirror is forgotten' no "$([ -e "$MDIR/mw.recycled" ] && echo yes || echo no)"
  printf 'wtstate%s99%s' "$US" "$RS" >"$MDIR/mw.foreign"
  cat "$mfile" >>"$MDIR/mw.foreign"
  wt_serve_stop_mirrored "$MDIR/mw.foreign" "$MR"
  eq 'stop from mirror: a mirror of another version is not read' 1 $?
  eq '...the process it names is not signalled' yes "$(wt_pid_alive "$gp" && echo yes || echo no)"
  eq '...and the file is kept' yes "$([ -e "$MDIR/mw.foreign" ] && echo yes || echo no)"
  rm -f "$MDIR/mw.foreign"
  PITLANE_SERVE_STOP_SECONDS=5 wt_serve_stop_mirrored "$mfile" "$MR"
  eq 'stop from mirror: its own server is stopped' 0 $?
  sleep 0.2
  eq '...every process of its group' 0 "$(pgrep -g "$gp" 2>/dev/null | wc -l | tr -d ' ')"
  eq '...and the mirror is forgotten' '' "$(ls -A "$MDIR")"
  mirror_file "$MDIR/mw.cmd" 4242 '' command 'http://127.0.0.1:1/'
  WT_APPROVAL=no PROFILE_SHELL='' PROFILE_SHELLARGS='' PROFILE_RT_STOP='touch stopped-{port}-{slug}' WT_GUARD=off \
    wt_serve_stop_mirrored "$MDIR/mw.cmd" "$MR" 2>/dev/null
  eq 'stop from mirror: by command, unapproved, is not run' 5 $?
  eq '...nothing ran' no "$([ -e "$MR/stopped-4555-mw-slug" ] && echo yes || echo no)"
  eq '...and the mirror is kept' yes "$([ -e "$MDIR/mw.cmd" ] && echo yes || echo no)"
  WT_APPROVAL=yes PROFILE_SHELL='' PROFILE_SHELLARGS='' PROFILE_RT_STOP='touch stopped-{port}-{slug}' WT_GUARD=off \
    wt_serve_stop_mirrored "$MDIR/mw.cmd" "$MR" 2>/dev/null
  eq 'stop from mirror: by command runs runtime.stop in the given directory' 0 $?
  eq '...expanded with the port and slug the mirror recorded' yes "$([ -e "$MR/stopped-4555-mw-slug" ] && echo yes || echo no)"
  eq '...and forgets the mirror' no "$([ -e "$MDIR/mw.cmd" ] && echo yes || echo no)"

  # The /dev/tcp fallback: a bracketed IPv6 host is unbracketed; one never closed is refused aloud.
  if python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1", 0))' 2>/dev/null; then
    sport6=$(python3 -c 'import socket; s=socket.socket(socket.AF_INET6); s.bind(("::1", 0)); print(s.getsockname()[1])')
    gp=$(sv_group "$TMP/g8.pid" "exec python3 -m http.server $sport6 --bind ::1")
    for _ in $(seq 1 50); do WT_CURL='' wt_serve_answers "http://[::1]:$sport6/" && break; sleep 0.1; done
    eq 'answers: /dev/tcp reaches a bracketed IPv6 host' 0 "$(WT_CURL='' wt_serve_answers "http://[::1]:$sport6/x"; echo $?)"
    kill -s KILL -- "-$gp" 2>/dev/null
  else
    printf 'SKIP IPv6 probe: no ::1 on this host\n' >&2
  fi
  out=$(WT_CURL='' wt_serve_answers 'http://[::1:8080/' 2>&1); rc=$?
  eq 'answers: an unclosed [ is refused' 1 "$rc"
  contains '...saying so' 'opens an IPv6 [ and never closes it' "$out"
  out=$(WT_CURL='' wt_serve_answers 'http://localhost:http/' 2>&1); rc=$?
  eq 'answers: a port that is not a number is refused' 1 "$rc"
  contains '...saying so' 'no host and port to connect to' "$out"
  # A host that drops the connection attempt: given 2s, never the OS's own minutes-long timeout.
  t0=$(date +%s)
  WT_CURL='' wt_serve_answers 'http://10.255.255.1:81/'
  eq 'answers: an unreachable host does not answer' 1 $?
  eq '...within the 2s bound' yes "$([ $(( $(date +%s) - t0 )) -le 3 ] && echo yes || echo no)"

  # The probe with no process: only the time limit, and the URL is asked at least once.
  wt_serve_probe 'http://127.0.0.1:1/' '' 0
  eq 'probe: no process, out of time is 1' 1 $?
else
  printf 'SKIP serve bookkeeping: needs /proc and setsid\n' >&2
fi

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
