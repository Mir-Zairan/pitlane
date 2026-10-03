# shellcheck shell=bash
#
# Helpers for the suites that drive /pitlane-serve and check what it left running — sourced, never
# run. `serve` needs CREATE_HOOK (bootstrap.sh) and TMP (where its stderr is appended) set by the
# sourcing suite.

# How many entries directory $1 holds; 0 when it does not exist.
count_in() { find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }

alive() { kill -0 "$1" 2>/dev/null && echo yes || echo no; }

# Every live process whose working directory is under $1, one `pid cwd` per line.
running_under() {  # $1 = directory
  local p cwd
  for p in /proc/[0-9]*; do
    cwd=$(readlink "$p/cwd" 2>/dev/null) || continue
    case $cwd/ in "$1"/*) printf '%s %s\n' "${p#/proc/}" "$cwd" ;; esac
  done
}

# /pitlane-serve, run from worktree $1 with $2 (--serve or --serve-stop): its one line on stdout.
serve() {  # $1 = worktree, $2 = mode
  # shellcheck disable=SC2154  # CREATE_HOOK and TMP are the sourcing suite's
  ( cd "$1" && bash "$CREATE_HOOK" "$2" 2>>"$TMP/serve-err" )
}

# Field $2 of worktree $1's `serve` record (1 pid, 5 url, 7 stopby), or nothing.
served_field() {  # $1 = worktree, $2 = field number
  python3 -c 'import sys
try:
    data = open(sys.argv[1], encoding="latin-1").read()
except OSError:
    sys.exit(0)
for rec in data.split("\x1e"):
    f = rec.split("\x1f")
    if f[0] == "serve" and len(f) > int(sys.argv[2]):
        print(f[int(sys.argv[2])])' "$(git -C "$1" rev-parse --absolute-git-dir)/worktree-bootstrap-state" "$2"
}
served_pid() { served_field "$1" 1; }
