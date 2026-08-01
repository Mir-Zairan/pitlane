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
printf '%s\n' '.env' 'secrets/**' 'nested/deep/**' 'tracked.txt' 'config.local' 'key.pem' \
  'mode.local' '*.local' > "$REPO/.worktreeinclude"
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
  wt_git() { return 128; }
  wt_copy_config "$REPO" "$WT15" 0 2>&1
)
contains 'a failing check-ignore is reported as a failure, not as nothing-ignored' \
  'could not ask git which paths are gitignored' "$out"
eq '...and nothing is copied on that run' '' "$(find "$WT15" -type f 2>/dev/null)"

printf '%d passed, %d failed\n' "$pass" "$fail" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
