#!/usr/bin/env bash
#
# Exercises hooks/scripts/bootstrap-lib.sh — the bootstrap engine.
#
# Unlike tests/test_lib.sh this suite is NOT run once per JSON backend: nothing in the engine
# parses JSON. It reads the PROFILE_* variables lib.sh already produced, so the cross-backend
# parity guard belongs to that suite and repeating it here would only double the runtime.
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

dep_raw() {  # $1 = dir, $2 = lock, $3 = strategy, $4 = install, $5 = verify
  printf '0%s%s1%s%s%s%s%s%s%s%s%s%s%s' \
    "$US_" "$RS_" "$US_" "$1" "$US_" "$2" "$US_" "$3" "$US_" "$4" "$US_" "$5" "$RS_"
}

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
contains '...told /pitlane-finish retries only on the user'"'"'s word' '/pitlane-finish can retry it on their word' "$out"
eq 'status, complete with a warning: not a bare "fully set up"' \
  'Pitlane: this worktree is set up, with warnings — c ready with warnings (peer warning).' \
  "$(status_line 'warn|c|peer warning' '' '' finish)"
contains '...and at start-up it is said, not swallowed' 'set up, with warnings — c ready with warnings' \
  "$(status_line 'warn|c|peer warning' '' '' start)"
eq 'status, complete and clean: silent at start-up' '' "$(status_line '' '' '' start)"
eq '...and "fully set up" from --finish' 'Pitlane: this worktree is fully set up.' "$(status_line '' '' '' finish)"
contains 'status: a name the branch wrote is shown printable' 'x?[31m missing' \
  "$(status_line "missing|x"$'\033'"[31m|dirty" x x start)"
WT_STATUS_ITEMS='' WT_PENDING='' WT_PENDING_ATTEMPTABLE=''

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
# ...and out of the record, at the next install of that dir that leaves it alone.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && touch vendor/autoload.php # v3' 'test -r vendor/autoload.php')
wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>/dev/null
eq '...a re-install after the restore drops it from the record' 'changed|vendor' "$(changed_recs)"
# A path in two dependencies' records is reported once.
printf 'placeholder: 2\n' >> "$DWT/conf/work space.yaml"
wt_install_note_changes "$DWT" other '' 2>/dev/null
eq '...a path two installs changed is reported once' 'conf/work space.yaml' "$(wt_install_changed_paths "$DWT")"
git -C "$DWT" checkout -q -- . ; rm -rf "$DWT/vendor"; rm -f "$(wt_state_path "$DWT")"

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
fi

# Untracked and ignored files are what an install is for.
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock install 'mkdir -p vendor && touch vendor/autoload.php new.txt && echo x > ignored.log' 'test -r vendor/autoload.php')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
lacks 'tracked: an install writing only untracked and ignored files reports nothing' 'changed tracked files' "$out"
eq '...and writes no record' '' "$(changed_recs)"
rm -rf "$DWT/vendor" "$DWT/new.txt" "$DWT/ignored.log"; rm -f "$(wt_state_path "$DWT")"

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

# --- hardlink falls back when the lockfiles differ -------------------------
rm -rf "$DWT/vendor"
printf 'LOCKV2-DIFFERENT\n' > "$DWT/composer.lock"
# shellcheck disable=SC2034
PROFILE_RAW=$(dep_raw vendor composer.lock hardlink 'mkdir -p vendor && printf FELLBACK > vendor/m' '')
out=$(wt_bootstrap_deps "$DREPO" "$DWT" "$FAR" 2>&1)
contains 'a worktree whose lockfile differs is NOT given the main checkout tree' 'differs from the main checkout' "$out"
eq '...it gets a real install instead' 'FELLBACK' "$(cat "$DWT/vendor/m" 2>/dev/null)"
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
# shellcheck disable=SC2034
PROFILE_RAW=$(printf '0%s%s1%s.venv%scomposer.lock%shardlink%sx%s%s%s' "$US_" "$RS_" "$US_" "$US_" "$US_" "$US_" "$US_" "$US_" "$RS_")
# shellcheck disable=SC2034  # read by wt_warn_hardlinked_venvs
WT_VENV_HARDLINK_WARNED=''
wt_warn_hardlinked_venvs "$VNR" 2>"$TMP/venv1"
wt_warn_hardlinked_venvs "$VNR" 2>"$TMP/venv2"
contains 'once per run: the first call warns' 'Python virtualenv' "$(cat "$TMP/venv1")"
eq '...and a second round says nothing' '' "$(cat "$TMP/venv2")"
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

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
