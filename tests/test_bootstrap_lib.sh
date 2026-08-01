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

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n      expected: %q\n      actual:   %q\n' "$1" "$2" "$3" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL %s\n      expected to contain: %q\n      actual: %q\n' "$1" "$2" "$3" >&2 ;;
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

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
