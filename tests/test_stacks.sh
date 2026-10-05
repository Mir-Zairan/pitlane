#!/usr/bin/env bash
#
# End-to-end tests against REAL toolchains: one invented repository per stack (tests/stack_fixtures.sh),
# each built with its own package manager, approved through `bootstrap.sh --review`/`--approve` the way
# a developer does, given two worktrees that go through the real SessionStart bootstrap and
# `bootstrap.sh --finish`, and then removed through the real WorktreeRemove teardown.
#
# The other suites prove the engine's logic with stand-in commands; this one proves the profile shapes
# /pitlane-setup writes actually produce a working checkout: the stack's own runtime loads the
# dependencies in the worktree, each worktree gets its own port in its env file, the main checkout
# and its dependency directories are untouched, and teardown takes back what was allocated.
#
#   tests/test_stacks.sh                       # every stack, on every JSON backend present
#   tests/test_stacks.sh pnpm uv               # a subset
#   nix shell nixpkgs#jq -c tests/test_stacks.sh
#   PITLANE_STACKS_KEEP=1 tests/test_stacks.sh # keep the scratch directory for a post-mortem
#
# Needs the network (each fixture installs one tiny package) and is slow. A stack whose toolchain is
# neither on PATH nor obtainable with `nix shell`, or whose fixture cannot be built (offline, registry
# down), prints SKIP with the reason and does not fail the run. A toolchain taken from nix also becomes
# the profile's `shell` wrapper, so those stacks exercise the toolchain path as well.
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones.
set -uo pipefail

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPTS=$(cd "$TESTS/../hooks/scripts" && pwd)
HOOK=$SCRIPTS/bootstrap.sh
REMOVE_HOOK=$SCRIPTS/teardown.sh
# shellcheck source=stack_fixtures.sh
# shellcheck disable=SC1091
. "$TESTS/stack_fixtures.sh"
# shellcheck source=serve_helpers.sh
# shellcheck disable=SC1091
. "$TESTS/serve_helpers.sh"

STACK_ALL=(pnpm npm bun uv composer bundler cargo go monorepo noprofile compose)

usage() { printf 'usage: %s [stack...]\n  stacks: %s\n' "$0" "${STACK_ALL[*]}" >&2; }
selected=()
for a in "$@"; do
  case " ${STACK_ALL[*]} " in
    *" $a "*) selected+=("$a") ;;
    *) usage; exit 2 ;;
  esac
done
[ "${#selected[@]}" -gt 0 ] || selected=("${STACK_ALL[@]}")

SCRATCH=$(mktemp -d)
SCRATCH=$(cd -P "$SCRATCH" && pwd -P)
# Go writes its module cache read-only, so plain rm -rf cannot clear it.
# Every app /pitlane-serve started is stopped by its recorded group, whatever happened.
SERVED_GROUPS=''
cleanup() {
  local g
  for g in $SERVED_GROUPS; do kill -s KILL -- "-$g" 2>/dev/null; done
  if [ -n "${PITLANE_STACKS_KEEP:-}" ]; then
    printf 'kept %s\n' "$SCRATCH" >&2
    return
  fi
  chmod -R u+w "$SCRATCH" 2>/dev/null
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Resolved with the developer's HOME, before it is moved: `nixpkgs` from the registry is a download
# under ~/.cache, and a scratch HOME would fetch all of nixpkgs again. The store path it resolved to
# is used directly instead, so `nix shell` only evaluates.
NIX_SHELL_PREFIX='' NIXPKGS_REF=''
if command -v nix >/dev/null 2>&1; then
  nixpkgs_path=$(nix --extra-experimental-features nix-command --extra-experimental-features flakes \
    flake metadata nixpkgs --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])' 2>/dev/null) || nixpkgs_path=''
  if [ -n "$nixpkgs_path" ]; then
    NIX_SHELL_PREFIX="nix --extra-experimental-features nix-command --extra-experimental-features flakes shell"
    NIXPKGS_REF="path:$nixpkgs_path"
  fi
fi

GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM
# Synchronous, so what the start-up run did can be asserted the moment it returns.
PITLANE_BACKGROUND=off
export PITLANE_BACKGROUND
# Approval goes through --review/--approve like a developer's, so nothing may short-circuit it.
unset PITLANE_TRUST_PROFILES XDG_CONFIG_HOME
# Same reason as tests/test_bootstrap.sh: a corepack-managed pnpm keeps itself under the real HOME.
if [ -z "${COREPACK_HOME:-}" ] && [ -d "$HOME/.cache/node/corepack" ]; then
  COREPACK_HOME=$HOME/.cache/node/corepack
  export COREPACK_HOME
fi
HOME=$SCRATCH/home
mkdir -p "$HOME"
export HOME
# Never let go fetch a newer toolchain mid-test; keep its module cache deletable.
GOTOOLCHAIN=local
GOFLAGS=-modcacherw
export GOTOOLCHAIN GOFLAGS

pass=0 fail=0 backends_run=0
BACKEND=none STACK=none
RESULTS=()

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s/%s] %s\n      expected: %q\n      actual:   %q\n' "$BACKEND" "$STACK" "$1" "$2" "$3" >&2
  fi
}

ne() {  # $1 = label, $2, $3 = values that must differ
  if [ "$2" != "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s/%s] %s\n      both were: %q\n' "$BACKEND" "$STACK" "$1" "$2" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL [%s/%s] %s\n      expected to contain: %q\n      actual: %q\n' "$BACKEND" "$STACK" "$1" "$2" "$3" >&2 ;;
  esac
}

exists() { [ -e "$1" ] && echo yes || echo no; }
# SC2012: one known path, so no name parsing; `stat` spells this differently on GNU and BSD.
# shellcheck disable=SC2012
inode() { ls -di -- "$1" 2>/dev/null | awk '{ print $1 }'; }

# Every regular file under $1 as `path inode checksum`: what an in-place write through a shared inode
# changes in the main checkout, where a content digest alone would miss a write of identical bytes.
inode_snapshot() {  # $1 = directory or file
  if [ -d "$1" ]; then
    ( cd "$1" && find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
        printf '%s %s %s\n' "$f" "$(inode "$f")" "$(cksum <"$f")"
      done )
  elif [ -e "$1" ]; then
    printf '%s %s\n' "$(inode "$1")" "$(cksum <"$1")"
  fi
}

# Show the end of a hook's stderr after a failed assertion about it.
show_log() {  # $1 = log file
  [ -s "$1" ] && sed 's/^/      | /' "$1" | tail -n 15 >&2
}

# Run a command string in $1 inside the stack's toolchain: the same wrapper its profile names.
tc() {  # $1 = directory, $2 = command string
  if [ -n "$STACK_SHELL" ]; then
    # SC2086: STACK_SHELL is a command prefix, split into words exactly as the plugin splits `shell`.
    # shellcheck disable=SC2086
    ( cd "$1" && $STACK_SHELL bash -c "$2" )
  else
    ( cd "$1" && bash -c "$2" )
  fi
}

# Decide where each command the stack needs comes from. Sets STACK_SHELL ('' = all on the host), or
# STACK_SKIP and returns 1.
resolve_toolchain() {  # $1 = stack
  local spec cmd pkg missing='' pkgs=''
  STACK_SHELL='' STACK_SKIP=''
  for spec in $("stack_tools_$1"); do
    cmd=${spec%%=*} pkg=${spec#*=}
    command -v "$cmd" >/dev/null 2>&1 && continue
    missing="$missing $cmd"
    if [ -z "$pkg" ]; then
      STACK_SKIP="$cmd is not on PATH and cannot be fetched"
      return 1
    fi
    case " $pkgs " in *" $NIXPKGS_REF#$pkg "*) ;; *) pkgs="$pkgs $NIXPKGS_REF#$pkg" ;; esac
  done
  [ -z "$missing" ] && return 0
  if [ -z "$NIX_SHELL_PREFIX" ]; then
    STACK_SKIP="not on PATH:$missing — and no nix to fetch it"
    return 1
  fi
  STACK_SHELL="$NIX_SHELL_PREFIX$pkgs --command"
  if ! tc "$SCRATCH" 'true' >/dev/null 2>&1; then
    STACK_SKIP="not on PATH:$missing — and \`nix shell\` could not provide it"
    return 1
  fi
}

# A digest of a directory's names, file contents and symlink targets. Link counts and times are
# deliberately left out: a hardlink copy raises the count, and that is not a change to the bytes.
dir_digest() {  # $1 = directory
  [ -d "$1" ] || { echo absent; return; }
  ( cd "$1" && {
      find . -print
      find . -type f -exec cksum {} +
      find . -type l -exec sh -c 'for l; do printf "%s -> %s\n" "$l" "$(readlink "$l")"; done' _ {} +
    } | LC_ALL=C sort | cksum )
}

# What must not change in the main checkout: its commit, every tracked, untracked and ignored path
# (an env file or a stray lockfile appearing there is a change), the CONTENTS of every untracked and
# ignored one — .env, .bundle/config, what .worktreeinclude copies: an edit through a hardlink or by
# the env writer keeps the path list identical — and its dependency trees' bytes.
main_snapshot() {  # $1 = repo
  local d p
  git -C "$1" rev-parse HEAD
  git -C "$1" status --porcelain --ignored | grep -v '^!! \.claude/worktrees/$'
  # --directory collapses an ignored tree to one entry, so a dependency dir is one line, skipped here
  # and digested below. An empty directory holds no content: `git worktree add` leaves one behind.
  git -C "$1" ls-files --others --directory --no-empty-directory -z | tr '\0' '\n' | while IFS= read -r p; do
    case " $STACK_DEPDIRS .claude/worktrees " in *" ${p%/} "*) continue ;; esac
    if [ -d "$1/$p" ]; then
      printf '%s %s\n' "$p" "$(dir_digest "$1/$p")"
    else
      printf '%s %s\n' "$p" "$(cksum <"$1/$p")"
    fi
  done
  for d in $STACK_DEPDIRS; do printf '%s %s\n' "$d" "$(dir_digest "$1/$d")"; done
}

envval() {  # $1 = worktree, $2 = env file, $3 = var
  grep "^$3=" "$1/$2" 2>/dev/null | tail -1 | cut -d= -f2-
}

session_start() {  # $1 = worktree, $2 = stderr log; prints stdout
  ( cd "$1" && printf '{"hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$1" \
    | bash "$HOOK" 2>"$2" )
}

teardown() {  # $1 = worktree, $2 = repo, $3 = stderr log; sets TEARDOWN_OUT and TEARDOWN_RC
  TEARDOWN_RC=0
  TEARDOWN_OUT=$(cd "$2" && printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s","reason":"session_exit","cwd":"%s"}' "$1" "$2" \
    | bash "$REMOVE_HOOK" 2>"$3") || TEARDOWN_RC=$?
}

# Approve the profile from the main checkout, as /pitlane-finish does on the developer's word.
approve() {  # $1 = repo
  local review fp
  review=$(cd "$1" && bash "$HOOK" --review 2>&1)
  fp=$(printf '%s\n' "$review" | sed -n 's/^NOT approved (fingerprint \([0-9a-f]*\)).*/\1/p')
  ne 'review: names the fingerprint to approve' '' "$fp"
  contains 'approve: records the reviewed fingerprint' 'approved' "$(cd "$1" && bash "$HOOK" --approve "$fp" 2>&1)"
}

# What the app at URL $1 answers, or `NO ANSWER: <why>`.
fetch() {
  python3 -c 'import sys, urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=5).read().decode())
except Exception as e:
    print("NO ANSWER: %s" % e)' "$1"
}

# /pitlane-serve in worktree $1 on port $2: the stack's own app, through the profile's shell, answers
# on the worktree's port from the worktree's checkout. It is left running; serve_stop stops it.
serve_check() {  # $1 = worktree, $2 = its port, $3 = log
  local w=$1 port=$2 name=${1##*/} out pid expect
  out=$(cd "$w" && bash "$HOOK" --serve 2>"$3")
  pid=$(served_pid "$w")
  [ -z "$pid" ] || SERVED_GROUPS="$SERVED_GROUPS $pid"
  eq "$name: /pitlane-serve starts the app on the worktree's port" "Pitlane: serving at http://localhost:$port/" "$out"
  [ "$out" = "Pitlane: serving at http://localhost:$port/" ] || show_log "$3"
  expect=${STACK_SERVE_EXPECT//\{port\}/$port}
  contains "$name: the app answers from the worktree's own checkout ($STACK_SERVE)" "$expect" \
    "$(fetch "http://localhost:$port$STACK_SERVE_PATH")"
}

serve_stop() {  # $1 = worktree, $2 = its port, $3 = log
  local w=$1 port=$2 name=${1##*/} out
  out=$(cd "$w" && bash "$HOOK" --serve-stop 2>>"$3")
  contains "$name: --serve-stop stops it" "Pitlane: stopped the server at http://localhost:$port/" "$out"
  contains "$name: and its port no longer answers" 'NO ANSWER' "$(fetch "http://localhost:$port/")"
}

# A server in the main checkout, started by hand on a port of its own, the way a developer runs one
# beside their worktrees. No worktree recorded it, so no teardown may stop it. The host's own
# python3 file server, not the stack's app: the stack's runtime may write into the main checkout's
# dependency tree (a venv's bytecode), which main_snapshot would rightly count as a change. Sets
# MAIN_SRV and MAIN_PORT. Started from this shell, not a $(...): a subshell inherits the EXIT trap,
# so bash would not exec the server, and it would hold the substitution's pipe open.
start_main_server() {  # $1 = repo, $2 = log
  local i
  MAIN_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  ( cd "$1" && exec setsid python3 -m http.server "$MAIN_PORT" --bind 127.0.0.1 ) </dev/null >"$2" 2>&1 &
  MAIN_SRV=$!
  SERVED_GROUPS="$SERVED_GROUPS $MAIN_SRV"
  for i in $(seq 1 120); do
    case $(fetch "http://localhost:$MAIN_PORT/") in 'NO ANSWER'*) sleep 0.5 ;; *) break ;; esac
  done
}

# One worktree through start-up and --finish, with every per-worktree assertion. Sets WT_PORT_SEEN.
exercise_worktree() {  # $1 = repo, $2 = name, $3 = scratch dir for logs
  local r=$1 name=$2 logs=$3 w out port expect
  w=$r/.claude/worktrees/$name
  git -C "$r" worktree add -q "$w" -b "worktree-$name" 2>/dev/null
  [ "$name" != beta ] || [ -z "$STACK_ART_CHANGE" ] || (cd "$w" && bash -c "$STACK_ART_CHANGE")
  out=$(session_start "$w" "$logs/$name.start")
  # Fully set up: stdout is empty, or, with a serve profile, the one line naming /pitlane-serve (ADR-021).
  expect=''
  [ -z "$STACK_SERVE" ] || expect="Pitlane: this worktree is set up. To run the app, use /pitlane-serve (it serves at http://localhost:$(envval "$w" "$STACK_ENVFILE" APP_PORT)/), not the repo's own start command."
  eq "$name: SessionStart reports the worktree fully set up" "$expect" "$out"
  [ "$out" = "$expect" ] || show_log "$logs/$name.start"
  out=$(cd "$w" && bash "$HOOK" --finish 2>"$logs/$name.finish")
  eq "$name: --finish reports the worktree fully set up" 'Pitlane: this worktree is fully set up.' "$out"
  local d first f own
  local c under
  for d in $STACK_LINKDIRS; do
    first=$(cd "$r" && find "$d" -type f | LC_ALL=C sort | while IFS= read -r f; do
      under=0
      for c in $STACK_COPY; do case $f/ in "$c"/*) under=1 ;; esac; done
      [ "$under" = 1 ] || { printf '%s\n' "$f"; break; }
    done)
    eq "$name: $d is hardlinked from the main checkout, not reinstalled ($first)" "$(inode "$r/$first")" "$(inode "$w/$first")"
  done
  # What its package manager rewrites in place is the worktree's own copy (deps[].copy).
  for c in $STACK_COPY; do
    [ -e "$r/$c" ] || continue
    first=$(cd "$r" && find "$c" -type f | LC_ALL=C sort | head -n 1)
    ne "$name: $first is a copy, not a link into the main checkout" "$(inode "$r/$first")" "$(inode "$w/$first")"
    eq "$name: ...with the main checkout's bytes" "$(cksum <"$r/$first")" "$(cksum <"$w/$first" 2>/dev/null)"
  done
  # The worktree is inside the main checkout, so a runtime that walks up parent directories finds
  # main's tree: only a file in the worktree's own tree proves its install happened.
  # SC2086: each entry is a glob, expanded on purpose, relative to the worktree.
  # shellcheck disable=SC2086
  for f in $STACK_OWNFILES; do
    own=$(cd "$w" && for g in $f; do [ -e "$g" ] && { (cd -P "$(dirname "$g")" && pwd -P); break; }; done)
    eq "$name: the worktree's own tree holds $f" yes "$(case $own/ in "$w"/*) echo yes ;; esac)"
  done
  for d in $STACK_DEPDIRS; do
    case " $STACK_LINKDIRS " in *" $d "*) continue ;; esac
    case " $(printf '%s' "$STACK_OWNFILES" | tr -s ' \n' '  ')" in
      *" $d/"*) ;;
      *) eq "$name: the fixture names a file the worktree's own $d must hold" "a file under $d/" "none" ;;
    esac
  done
  if [ -n "$STACK_ART_FILE" ] && [ "$name" = beta ]; then
    eq "$name: an input changed on its branch, so its build output was built" "$STACK_ART_EXPECT" \
      "$(cat "$w/$STACK_ART_FILE" 2>/dev/null)"
  elif [ -n "$STACK_ART_FILE" ]; then
    eq "$name: its inputs match, so it holds the main checkout's build output" "$(cat "$r/$STACK_ART_FILE")" \
      "$(cat "$w/$STACK_ART_FILE" 2>/dev/null)"
    ne "$name: ...as a copy, not a link a rebuild would write through" "$(inode "$r/$STACK_ART_FILE")" \
      "$(inode "$w/$STACK_ART_FILE")"
  fi
  eq "$name: the bootstrap left nothing untracked or modified, so teardown will not hold it" '' \
    "$(git -C "$w" status --porcelain)"

  port=$(envval "$w" "$STACK_ENVFILE" APP_PORT)
  WT_PORT_SEEN=$port
  eq "$name: the port is written to $STACK_ENVFILE, inside the profile's span" yes \
    "$(case $port in '' | *[!0-9]*) ;; *) [ "$port" -ge "$STACK_PORT_BASE" ] && [ "$port" -lt $((STACK_PORT_BASE + 200)) ] && echo yes ;; esac)"
  eq "$name: and the per-worktree database name beside it" "fixture_$name" "$(envval "$w" "$STACK_ENVFILE" APP_DATABASE)"
  eq "$name: the seed ran and got the same port" "$port" "$(cat "$STACK_DB/$name" 2>/dev/null)"

  expect=${STACK_EXPECT//\{slug\}/$name}
  expect=${expect//\{port\}/$port}
  # Nothing on the environment's search paths may stand in for the worktree's own tree.
  out=$(tc "$w" "unset NODE_PATH PYTHONPATH RUBYLIB; export PROBE_ROOT=$(printf '%q' "$w"); $STACK_PROBE" \
    2>"$logs/$name.probe")
  eq "$name: the stack's own runtime uses the dependencies in the worktree ($STACK_PROBE)" "$expect" "$out"
  [ "$out" = "$expect" ] || show_log "$logs/$name.probe"
  [ -z "$STACK_SERVE" ] || serve_check "$w" "$port" "$logs/$name.serve"
  [ "$name" = alpha ] && inplace_check "$r" "$w" "$logs"
}

# ADR-022: commands that rewrite a hardlinked dir's files in place, run in the worktree, must leave
# the main checkout's dependency trees byte-identical and on the same inodes. The worktree's copy
# paths must change, or the command proved nothing.
inplace_check() {  # $1 = repo, $2 = worktree, $3 = scratch dir for logs
  local r=$1 w=$2 logs=$3 cmd kind d main_before main_after wt_before wt_after rc c
  for kind in local net; do
    cmd=$STACK_INPLACE
    [ "$kind" = net ] && cmd=$STACK_INPLACE_NET
    [ -n "$cmd" ] || continue
    main_before='' wt_before=''
    for d in $STACK_LINKDIRS; do main_before+=$(inode_snapshot "$r/$d"); done
    for c in $STACK_COPY; do wt_before+=$(inode_snapshot "$w/$c"); done
    tc "$w" "$cmd" >"$logs/inplace.$kind" 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$kind" = net ]; then
      printf 'NOTE [%s/%s] "%s" failed (offline?) — its in-place check is not counted\n' "$BACKEND" "$STACK" "$cmd" >&2
      show_log "$logs/inplace.$kind"
    else
      eq "in place: \`$cmd\` runs in the worktree" 0 "$rc"
      [ "$rc" -eq 0 ] || show_log "$logs/inplace.$kind"
      wt_after=''
      for c in $STACK_COPY; do wt_after+=$(inode_snapshot "$w/$c"); done
      ne "in place: \`$cmd\` rewrote the worktree's copy paths ($STACK_COPY)" "$wt_before" "$wt_after"
      main_after=''
      for d in $STACK_LINKDIRS; do main_after+=$(inode_snapshot "$r/$d"); done
      eq "in place: ...and the main checkout's $STACK_LINKDIRS kept every byte and inode" "$main_before" "$main_after"
    fi
    # The command may edit the manifest and lockfile; teardown keeps a worktree with changes.
    git -C "$w" checkout -q -- .
  done
}

# A hardlink donor: two worktrees whose branches carry the same lockfile change. The first installs
# (main's lockfile differs); the second links from the first, and an in-place rewrite run there must
# leave the first worktree's tree and the main checkout's keeping every byte and inode.
donor_check() {  # $1 = repo, $2 = scratch dir for logs
  local r=$1 logs=$2 g d out first f p c under rc donor_before main_before
  [ -n "$STACK_LOCK_CHANGE" ] || return 0
  g=$r/.claude/worktrees/gamma d=$r/.claude/worktrees/delta
  git -C "$r" worktree add -q "$g" -b worktree-gamma 2>/dev/null
  if ! tc "$g" "$STACK_LOCK_CHANGE" >"$logs/lockchange" 2>&1; then
    printf 'NOTE [%s/%s] "%s" failed (offline?) — the donor check is not counted\n' "$BACKEND" "$STACK" "$STACK_LOCK_CHANGE" >&2
    show_log "$logs/lockchange"
    git -C "$r" worktree remove --force "$g"
    git -C "$r" branch -qD worktree-gamma
    return 0
  fi
  git -C "$g" commit -qam 'changes the lockfile'
  git -C "$r" worktree add -q "$d" -b worktree-delta worktree-gamma 2>/dev/null
  session_start "$g" "$logs/gamma.start" >/dev/null
  contains "gamma: its lockfile differs from the main checkout's, so it installs" \
    'differs from the main checkout — installing instead' "$(cat "$logs/gamma.start")"
  session_start "$d" "$logs/delta.start" >/dev/null
  out=$(cat "$logs/delta.start")
  for f in $STACK_LINKDIRS; do
    contains "delta: $f is hardlinked from worktree gamma" "$f: hardlinked from worktree gamma (" "$out"
    first=$(cd "$g" && find "$f" -type f | LC_ALL=C sort | while IFS= read -r p; do
      under=0
      for c in $STACK_COPY; do case $p/ in "$c"/*) under=1 ;; esac; done
      [ "$under" = 1 ] || { printf '%s\n' "$p"; break; }
    done)
    eq "delta: ...sharing gamma's inodes ($first)" "$(inode "$g/$first")" "$(inode "$d/$first")"
    ne "delta: ...not the main checkout's" "$(inode "$r/$first")" "$(inode "$d/$first")"
  done
  [ "$out" = "${out#*hardlinked from worktree}" ] && show_log "$logs/delta.start"
  donor_before='' main_before=''
  for f in $STACK_LINKDIRS; do
    donor_before+=$(inode_snapshot "$g/$f"); main_before+=$(inode_snapshot "$r/$f")
  done
  tc "$d" "$STACK_INPLACE" >"$logs/donor.inplace" 2>&1
  rc=$?
  eq "delta: \`$STACK_INPLACE\` runs" 0 "$rc"
  [ "$rc" -eq 0 ] || show_log "$logs/donor.inplace"
  local donor_after='' main_after=''
  for f in $STACK_LINKDIRS; do
    donor_after+=$(inode_snapshot "$g/$f"); main_after+=$(inode_snapshot "$r/$f")
  done
  eq "delta: ...and gamma's $STACK_LINKDIRS kept every byte and inode" "$donor_before" "$donor_after"
  eq "delta: ...and so did the main checkout's" "$main_before" "$main_after"
  git -C "$d" checkout -q -- .
  remove_worktree "$r" delta "$logs"
  remove_worktree "$r" gamma "$logs"
}

# A dir linked from the main checkout whose branch then commits a lockfile change is installed fresh,
# not over the link: the branch's install runs a real in-place writer (relink_setup_<stack>), and the
# main checkout's tree must keep every byte and inode.
relink_check() {  # $1 = repo, $2 = scratch dir for logs
  local r=$1 logs=$2 z f main_before main_after out
  [ -n "$STACK_RELINK_FILE" ] && [ -n "$STACK_LOCK_CHANGE" ] || return 0
  z=$r/.claude/worktrees/zeta
  git -C "$r" worktree add -q "$z" -b worktree-zeta 2>/dev/null
  session_start "$z" "$logs/zeta.start" >/dev/null
  eq "zeta: $STACK_RELINK_FILE is hardlinked from the main checkout" "$(inode "$r/$STACK_RELINK_FILE")" \
    "$(inode "$z/$STACK_RELINK_FILE")"
  # Before the writer exists: npm runs a root postinstall even for `--package-lock-only`, and that one
  # would be the developer's own command writing through the link, which this check is not about.
  if ! tc "$z" "$STACK_LOCK_CHANGE" >"$logs/relink.lockchange" 2>&1; then
    printf 'NOTE [%s/%s] "%s" failed (offline?) — the relink check is not counted\n' "$BACKEND" "$STACK" "$STACK_LOCK_CHANGE" >&2
    show_log "$logs/relink.lockchange"
  else
    "relink_setup_$STACK" "$z"
    git -C "$z" add -A
    git -C "$z" commit -qm 'changes the lockfile, and patches a dependency in place on install'
    approve "$z"
    main_before=''
    for f in $STACK_LINKDIRS; do main_before+=$(inode_snapshot "$r/$f"); done
    session_start "$z" "$logs/zeta.restart" >/dev/null
    out=$(cd "$z" && bash "$HOOK" --finish 2>"$logs/zeta.finish")
    # `npm install` may rewrite the tracked lockfile, which --finish rightly reports.
    eq 'zeta: --finish reports the worktree set up' yes "$(case $out in
      'Pitlane: this worktree is fully set up.' | 'Pitlane: this worktree is set up, with warnings — an install changed '*) echo yes ;;
      *) printf '%s' "$out" ;; esac)"
    out=$(cat "$logs/zeta.restart" "$logs/zeta.finish" "$(git -C "$z" rev-parse --absolute-git-dir)/worktree-bootstrap.log" 2>/dev/null)
    contains 'zeta: its lockfile changed, so the linked copy is removed before the install' \
      'changed since it was linked — removing the linked copy and installing fresh' "$out"
    contains "zeta: ...the branch's install patched its own $STACK_RELINK_FILE" 'patched by the branch' \
      "$(cat "$z/$STACK_RELINK_FILE" 2>/dev/null)"
    for f in $STACK_LINKDIRS; do
      eq "zeta: ...and no file in its $f is a link any more" '' "$(find "$z/$f" -type f -links +1 -print)"
    done
    main_after=''
    for f in $STACK_LINKDIRS; do main_after+=$(inode_snapshot "$r/$f"); done
    eq "zeta: ...while the main checkout's $STACK_LINKDIRS kept every byte and inode" "$main_before" "$main_after"
  fi
  git -C "$z" checkout -q -- .
  # Kept on another ref, so the teardown does not hold the worktree for its unmerged commits.
  git -C "$r" branch -f relink-kept worktree-zeta
  remove_worktree "$r" zeta "$logs"
  git -C "$r" branch -qD relink-kept
}

remove_worktree() {  # $1 = repo, $2 = name, $3 = scratch dir for logs
  local r=$1 name=$2 w
  w=$r/.claude/worktrees/$name
  teardown "$w" "$r" "$3/$name.teardown"
  eq "$name: teardown exits 0 with nothing on stdout" "0:" "$TEARDOWN_RC:$TEARDOWN_OUT"
  eq "$name: teardown removed the worktree" no "$(exists "$w")"
  [ -e "$w" ] && show_log "$3/$name.teardown"
  eq "$name: and git no longer lists it" '' "$(git -C "$r" worktree list --porcelain | grep -F "worktree $w" || true)"
  eq "$name: and forgot its runtime allocation" no "$(exists "$r/.git/worktree-ledger/$name")"
}

# The case with no profile: nothing may appear anywhere.
run_noprofile() {  # $1 = repo, $2 = logs
  local r=$1 logs=$2 w out
  w=$r/.claude/worktrees/plain
  git -C "$r" worktree add -q "$w" -b worktree-plain 2>/dev/null
  out=$(session_start "$w" "$logs/plain.start")
  eq 'SessionStart writes nothing to stdout' '' "$out"
  eq 'and puts nothing in the worktree — no deps, no env file, no copied config' '' \
    "$(git -C "$w" status --porcelain --ignored)"
  eq 'and allocates nothing' no "$(exists "$r/.git/worktree-ledger/plain")"
  out=$(cd "$w" && bash "$HOOK" --finish 2>"$logs/plain.finish")
  eq '--finish adds nothing either' '' "$(git -C "$w" status --porcelain --ignored)"
  remove_worktree "$r" plain "$logs"
}

run_stack() {  # $1 = stack, $2 = index (for its port base)
  local stack=$1 r logs before t0 fail0 p_alpha p_beta b_pid=
  STACK=$stack
  t0=$SECONDS fail0=$fail
  STACK_DEPDIRS='' STACK_LINKDIRS='' STACK_OWNFILES='' STACK_PROBE='' STACK_EXPECT='' STACK_ENVFILE=''
  STACK_SERVE='' STACK_SERVE_PATH='' STACK_SERVE_EXPECT=''
  # shellcheck disable=SC2034  # STACK_ARTIFACTS is read by write_profile, in stack_fixtures.sh
  STACK_ARTIFACTS='' STACK_ART_FILE='' STACK_ART_CHANGE='' STACK_ART_EXPECT=''
  STACK_DETECTED_LINKDIRS='' STACK_DETECT_ERRORS='' STACK_COPY='' STACK_INPLACE='' STACK_INPLACE_NET='' STACK_LOCK_CHANGE='' STACK_RELINK_FILE=''
  # A band of its own, offset per run, so the other suites running in parallel cannot collide with it.
  STACK_PORT_BASE=$((20000 + $$ % 3 * 3300 + $2 * 300))
  local dir=$SCRATCH/$BACKEND/$stack
  r=$dir/repo logs=$dir/logs STACK_DB=$dir/databases
  mkdir -p "$r" "$logs" "$STACK_DB"

  if ! resolve_toolchain "$stack"; then
    printf 'SKIP [%s/%s] %s\n' "$BACKEND" "$stack" "$STACK_SKIP" >&2
    RESULTS+=("$stack $BACKEND SKIP 0s")
    return
  fi
  git init -q "$r"
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  if ! "fixture_$stack" "$r" >"$logs/fixture" 2>&1; then
    printf 'SKIP [%s/%s] the fixture could not be built with %s (offline?):\n' \
      "$BACKEND" "$stack" "${STACK_SHELL:-the host toolchain}" >&2
    show_log "$logs/fixture"
    RESULTS+=("$stack $BACKEND SKIP $((SECONDS - t0))s")
    return
  fi
  git -C "$r" add -A
  git -C "$r" commit -qm 'fixture'
  before=$(main_snapshot "$r")
  # The profile is detection's proposal, so a default that disagrees with the real tool fails here.
  eq "detection's deps agree with the fixture (verify supplied only where withheld)" '' "$STACK_DETECT_ERRORS"
  eq 'detection hardlinks exactly the dirs this stack expects' "$STACK_LINKDIRS" "$STACK_DETECTED_LINKDIRS"

  if [ "$stack" = noprofile ]; then
    run_noprofile "$r" "$logs"
  else
    approve "$r"
    exercise_worktree "$r" alpha "$logs"
    p_alpha=$WT_PORT_SEEN
    exercise_worktree "$r" beta "$logs"
    p_beta=$WT_PORT_SEEN
    ne 'two worktrees get distinct ports' "$p_alpha" "$p_beta"
    donor_check "$r" "$logs"
    relink_check "$r" "$logs"
    if [ -n "$STACK_SERVE" ]; then
      # Both apps at once, each on its own port: the case a hardcoded start command cannot serve.
      contains "alpha's app still answers beside beta's" "${STACK_SERVE_EXPECT//\{port\}/$p_alpha}" \
        "$(fetch "http://localhost:$p_alpha$STACK_SERVE_PATH")"
      start_main_server "$r" "$logs/main.serve"
      contains "a server in the main checkout answers beside them" '.gitignore' "$(fetch "http://localhost:$MAIN_PORT/")"
      serve_stop "$r/.claude/worktrees/alpha" "$p_alpha" "$logs/alpha.serve"
      # beta's app is left running: its teardown must stop it.
      b_pid=$(served_pid "$r/.claude/worktrees/beta")
      ne "beta's app is recorded before its teardown" '' "$b_pid"
      eq "...and running" yes "$(alive "$b_pid")"
    fi
    eq 'the main checkout is unchanged while worktrees are live' "$before" "$(main_snapshot "$r")"
    remove_worktree "$r" alpha "$logs"
    remove_worktree "$r" beta "$logs"
    eq 'teardown released each seeded database' '' "$(ls -A "$STACK_DB")"
    if [ -n "$STACK_SERVE" ]; then
      eq "beta's teardown stopped the app /pitlane-serve started there" no "$(alive "$b_pid")"
      contains "...its port no longer answers" 'NO ANSWER' "$(fetch "http://localhost:$p_beta/")"
      eq "the main checkout's server is still running after both teardowns" yes "$(alive "$MAIN_SRV")"
      contains '...and still answers' '.gitignore' "$(fetch "http://localhost:$MAIN_PORT/")"
      kill -s TERM -- "-$MAIN_SRV" 2>/dev/null
      for _ in $(seq 1 50); do [ "$(alive "$MAIN_SRV")" = no ] && break; sleep 0.1; done
    fi
    eq 'nothing started in this stack is left running' '' "$(running_under "$dir")"
  fi
  eq 'the main checkout is unchanged after teardown' "$before" "$(main_snapshot "$r")"

  local verdict=PASS
  [ "$fail" -gt "$fail0" ] && verdict=FAIL
  printf '%s [%s/%s] %ss%s\n' "$verdict" "$BACKEND" "$stack" "$((SECONDS - t0))" \
    "$([ -n "$STACK_SHELL" ] && printf ' (toolchain from nix:%s)' "$(printf '%s' "$STACK_SHELL" | sed -e "s|^$NIX_SHELL_PREFIX||" -e 's| --command$||' -e 's| [^ ]*#| |g')")" >&2
  RESULTS+=("$stack $BACKEND $verdict $((SECONDS - t0))s")
}

run_suite() {
  local s i
  for s in "${selected[@]}"; do
    for i in "${!STACK_ALL[@]}"; do
      [ "${STACK_ALL[$i]}" = "$s" ] && run_stack "$s" "$i"
    done
  done
  STACK=none
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_stacks.sh\n' >&2
      printf '      Or set WT_TEST_ALLOW_MISSING_BACKEND=1 to accept a one-sided run.\n' >&2
      fail=$((fail + 1))
      continue
    fi
    unset WT_JSON_BACKEND
  else
    if ! command -v python3 >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: python3 not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: python3 not on PATH, so backend parity is untested.\n' >&2
      fail=$((fail + 1))
      continue
    fi
    export WT_JSON_BACKEND=python3
  fi
  printf -- '--- backend: %s ---\n' "$BACKEND" >&2
  backends_run=$((backends_run + 1))
  run_suite
done
BACKEND=none

printf '%s\n' "${RESULTS[@]}" | awk '{ printf "  %-10s %-8s %-5s %s\n", $1, $2, $3, $4 }' >&2
skipped=$(printf '%s\n' "${RESULTS[@]}" | grep -c ' SKIP ')
printf '%d passed, %d failed, %d stack run(s) skipped, %d backend(s) exercised\n' \
  "$pass" "$fail" "$skipped" "$backends_run" >&2
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
