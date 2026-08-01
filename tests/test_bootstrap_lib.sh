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
# ADR-007's other half: matching is not enough, it must ALSO be gitignored.
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

  # The ADR-003 behaviour: contention must never stall a session. Hold the lock from a child,
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

# The timestamp the phase's task list asks for: recorded, and never part of the freshness
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
eq '...and is recorded as not done, so the next session retries' 1 \
  "$(wt_state_is_done "$DWT" vendor "$(wt_cksum_file "$DWT/composer.lock")" \
       "$(wt_cksum_string 'exit 1')" install; echo $?)"

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
# The point of hardlinking: the same inode, so 397 MB costs almost nothing.
eq 'hardlink: the file really is the same inode, not a copy' \
  "$(stat -c '%i' "$DREPO/vendor/pkg/file.txt" 2>/dev/null || stat -f '%i' "$DREPO/vendor/pkg/file.txt")" \
  "$(stat -c '%i' "$DWT/vendor/pkg/file.txt" 2>/dev/null || stat -f '%i' "$DWT/vendor/pkg/file.txt")"

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
# All FOUR kinds of evidence, against the real reference/detection.json — a fixture table would
# only prove the fixture, and the point is that adding an ecosystem there needs no change here.

DRTREE=$TMP/drift
mkdir -p "$DRTREE"
: > "$DRTREE/composer.lock"
CURDET=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['detectionVersion'])" \
  "$WT_DETECTION_JSON_DEFAULT" 2>/dev/null)

# Baseline: evidence matching reality says nothing at all.
cat > "$DRTREE/p-clean.json" <<JSON
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
 "install":"x","lockChecksum":"$(cksum < "$DRTREE/composer.lock")"}],
 "evidence":{"detectionVersion":$CURDET,"markers":["composer.lock"],"shellMarker":""}}
JSON
eq 'a profile that matches the checkout reports no drift at all' '' \
  "$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock"]' '' 2>&1)"

# A gained ecosystem. This is the one that broke: with a single-element markers array the last
# unterminated line was dropped by `read`, so nearly every marker went unchecked.
: > "$DRTREE/pnpm-lock.yaml"
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a lockfile the profile never saw is reported' 'pnpm-lock.yaml' "$out"
contains '...and points at the fix' 'worktree-calibrate' "$out"
# Every rule in the table must be checked, not just the first: a single-marker rule is the common
# shape, so dropping the last line made the whole check silently useless.
: > "$DRTREE/Gemfile.lock"
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a second gained ecosystem is reported too' 'Gemfile.lock' "$out"
rm -f "$DRTREE/Gemfile.lock" "$DRTREE/pnpm-lock.yaml"

# A lost marker.
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock","pnpm-lock.yaml"]' '' 2>&1)
contains 'a lockfile the profile expects and is now gone is reported' 'no longer has: pnpm-lock.yaml' "$out"

# The toolchain marker: a branch that gained a flake is now installing on the wrong toolchain.
: > "$DRTREE/flake.nix"
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a newly appeared flake.nix is reported as a toolchain change' 'toolchain marker changed' "$out"
contains '...naming both sides' 'none -> flake.nix' "$out"
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" "$CURDET" '["composer.lock"]' 'flake.nix' 2>&1)
eq '...and says nothing when it was already recorded' '' "$out"
rm -f "$DRTREE/flake.nix"

# The detection table version.
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" 0 '["composer.lock"]' '' 2>&1)
contains 'an older detection table version is reported' 'detection table is now version' "$out"

# The per-lockfile checksums Phase 2 shipped and left unwired.
cat > "$DRTREE/p-stale.json" <<'JSON'
{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
 "install":"x","lockChecksum":"1 1"}],
 "evidence":{"detectionVersion":1,"markers":["composer.lock"],"shellMarker":""}}
JSON
out=$(wt_report_drift "$DRTREE" "$DRTREE/p-stale.json" "$CURDET" '["composer.lock"]' '' 2>&1)
contains 'a lockfile changed since calibration is reported' 'has changed since calibration' "$out"

# A profile with NO evidence block cannot report drift, and must not pretend to.
eq 'a profile with no evidence says nothing' '' \
  "$(wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" '' '' '' 2>&1)"

# It must never block, whatever it finds.
wt_report_drift "$DRTREE" "$DRTREE/p-stale.json" 0 '["composer.lock"]' 'flake.nix' >/dev/null 2>&1
eq 'drift reporting always succeeds — it warns, it never blocks' 0 $?
# ...including when the table itself is unreadable.
eq 'an unreadable detection table is silent rather than noisy' '' \
  "$(WT_DETECTION_JSON=/nonexistent/table.json wt_report_drift "$DRTREE" "$DRTREE/p-clean.json" \
       1 '["composer.lock"]' '' 2>&1)"

# ---------------------------------------------------------------------------
# The Phase 4 hand-off
# ---------------------------------------------------------------------------
PROFILE_HAS_RUNTIME=0
eq 'with no runtime block the hand-off is silent (ADR-006: touch nothing)' '' \
  "$(wt_runtime_handoff "$DREPO" "$DWT" 2>&1)"
PROFILE_HAS_RUNTIME=1
contains 'with a runtime block it says the work is not implemented yet' 'not implemented yet' \
  "$(wt_runtime_handoff "$DREPO" "$DWT" 2>&1)"
contains '...and is honest about what that costs the developer' 'shares the app' \
  "$(wt_runtime_handoff "$DREPO" "$DWT" 2>&1)"
# shellcheck disable=SC2034
PROFILE_HAS_RUNTIME=0

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
