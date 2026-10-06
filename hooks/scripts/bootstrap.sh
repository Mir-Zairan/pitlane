#!/usr/bin/env bash
#
# Bootstrap entrypoint. Resolves the worktree and the main checkout, loads the profile, and runs
# layer 2 — config, dependencies, drift — before handing off to layer 3's stub.
#
# It handles BOTH events, and BOTH are wired (hooks/hooks.json), because the contracts differ in a
# way that is easy to get fatally wrong:
#
#   SessionStart    Fires for launch-time `claude -w`. stdout is INJECTED INTO THE MODEL'S
#                   CONTEXT, so nothing may go there. Creation was native, so `.worktreeinclude`
#                   has ALREADY been honoured and must not be redone; only the profile's copy[]
#                   is this hook's business. The session measurably blocks until this
#                   returns, which is what makes a synchronous bootstrap safe.
#   WorktreeCreate  Fires for the mid-session EnterWorktree tool and for subagents with
#                   isolation:"worktree" — never for launch-time `claude -w`, because plugin hooks
#                   join the registry after the worktree already exists. stdout IS the
#                   worktree path and nothing else. It REPLACES native creation on those paths, so
#                   this hook creates the worktree AND owes `.worktreeinclude` itself.
#
# Registering the second one is a deliberate decision, taken because those two paths otherwise get no
# bootstrap at all — a subagent lands in a checkout with no dependencies. Its one unrecoverable
# failure mode is bought off by wt_symlink_refuses running before anything is created; what that
# does NOT buy off is a known, accepted gap.
#
# Everything below follows one rule: warn on stderr, still emit the path, exit 0. `set -e` is
# deliberately NOT used — a bootstrap that aborts halfway costs the user their session, which is
# strictly worse than a worktree missing its dependencies.
set -uo pipefail

# SC1091: shellcheck only FOLLOWS a sourced file when invoked with -x, and the pre-commit
# gate lints each changed file on its own. The directives below still tell it where the
# libraries are for anyone running `shellcheck -x`. bootstrap-lib.sh sources lib.sh itself,
# and lib.sh's own guard makes that idempotent.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bootstrap-lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/bootstrap-lib.sh"

# `bootstrap.sh --finish`: run from inside a worktree (the /pitlane-finish skill does) to complete
# whatever its start-up bootstrap had to leave out, with no hook time limit. It is the SessionStart
# path with the payload built here instead of read from stdin.
#
# `--finish --background` is the same run, started detached by a SessionStart that deferred its slow
# steps (WT_DEFER below): it records its pid where /pitlane-finish and later sessions can see it.
#
# `--finish --retry-failed` also re-runs an install whose recorded failure stands. Never automatic:
# /pitlane-finish passes it only on the user's word, after showing them the recorded reason.
WT_FINISH='' WT_BACKGROUND='' WT_RETRY_FAILED=''
WT_BOOTSTRAP_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/bootstrap.sh"
export WT_BOOTSTRAP_SCRIPT
if [ "${1-}" = --finish ]; then
  WT_FINISH=1
  case ${2-} in
    --background) WT_BACKGROUND=1 ;;
    --retry-failed) WT_RETRY_FAILED=1 ;;
  esac
  # Either JSON backend: a jq-only host must not get an empty payload, which would make the
  # background run — and /pitlane-finish — silently do nothing.
  HOOK_INPUT=$(python3 -c 'import json,os; print(json.dumps({"hook_event_name":"SessionStart","source":"startup","cwd":os.getcwd()}))' 2>/dev/null) \
    || HOOK_INPUT=$(jq -nc --arg c "$PWD" '{hook_event_name:"SessionStart",source:"startup",cwd:$c}' 2>/dev/null) \
    || HOOK_INPUT=''
  WT_INPUT_READ=1
  export HOOK_INPUT WT_INPUT_READ
fi
export WT_FINISH WT_BACKGROUND WT_RETRY_FAILED

# `bootstrap.sh --review` and `bootstrap.sh --approve <fingerprint>`, run from a worktree or the main
# checkout: show what the profile there would run, and approve exactly that content. Never run by a
# hook, and /pitlane-finish runs --approve only on the user's explicit word. --approve takes the
# fingerprint --review printed, so what is approved is what was shown: a file edited in between
# changes the fingerprint and the approval is refused.
wt_approval_cli() {  # $1 = --review or --approve, $2 = fingerprint for --approve
  local mode=$1 want=${2-} here=$PWD worktree root rundir fp store
  if ! wt_has_json; then
    printf 'Pitlane: neither jq nor python3 is on PATH, so the profile cannot be read.\n'
    return 0
  fi
  case "$here/" in
    *"$WT_SUBPATH"*)
      worktree=$(wt_repo_root "$here") || worktree=$here
      root=$(wt_main_root "$here") || root=''
      if [ -z "$root" ]; then
        printf 'Pitlane: cannot find the main checkout for %s.\n' "$here"
        return 0
      fi
      wt_load_profile_for "$worktree" "$root"
      rundir=$worktree
      ;;
    *)
      if ! root=$(wt_repo_root "$here"); then
        printf 'Pitlane: %s is not inside a git repository.\n' "$here"
        return 0
      fi
      wt_load_profile "$root"
      rundir=$root
      ;;
  esac
  if [ "${PROFILE_PRESENT:-0}" != 1 ]; then
    printf 'Pitlane: no usable profile at %s — nothing to approve.\n' "$PROFILE_PATH"
    return 0
  fi
  if ! wt_profile_runs_commands; then
    printf 'Pitlane: %s runs no commands, so it needs no approval.\n' "$PROFILE_PATH"
    return 0
  fi
  if ! fp=$(wt_approval_fingerprint "$rundir"); then
    printf 'Pitlane: cannot fingerprint %s — no sha256sum, shasum, openssl or python3 worked.\n' "$PROFILE_PATH"
    return 0
  fi
  store=$(wt_approvals_path "$rundir") || store=''

  if [ "$mode" = --review ]; then
    wt_approval_describe "$rundir"
    if wt_approval_known "$fp" "$store"; then
      printf 'Approved: this exact content is approved (fingerprint %s).\n' "$fp"
    else
      printf 'NOT approved (fingerprint %s). Read the commands above and the scripts named, and approve only if you trust all of them:\n  bash "%s" --approve %s\n' "$fp" "$WT_BOOTSTRAP_SCRIPT" "$fp"
    fi
    case ${PITLANE_TRUST_PROFILES:-} in
      1 | yes | on | true) printf 'PITLANE_TRUST_PROFILES is set, so the hooks run these without approval anyway.\n' ;;
    esac
    return 0
  fi

  if [ "$want" != "$fp" ]; then
    printf 'Pitlane: not approved — %s is not the current fingerprint (%s). The profile or one of its scripts changed since it was reviewed; run --review again.\n' "${want:-<none given>}" "$fp"
    return 0
  fi
  if [ -z "$store" ] || ! wt_approval_record "$fp" "$rundir"; then
    printf 'Pitlane: could not record the approval in %s.\n' "${store:-the shared git directory}"
    return 0
  fi
  printf 'Pitlane: approved %s for every worktree of this repository that carries this exact content. Run /pitlane-finish in the worktree to run the setup it held back.\n' "$PROFILE_PATH"
}
# `bootstrap.sh --serve` and `--serve-stop`, run from a worktree by /pitlane-serve (ADR-021): start
# the profile's runtime.serve detached and say where it answers, or stop the one server Pitlane
# recorded starting here. ONE line on stdout either way; non-zero when the app was not served or the
# server would not stop. Never run by a hook.
wt_serve_cli() {  # $1 = --serve or --serve-stop
  local mode=$1 here=$PWD worktree root rc not_one
  not_one='Pitlane: run /pitlane-serve from inside a worktree under .claude/worktrees/ — this is not one.'
  case "$here/" in
    *"$WT_SUBPATH"*) ;;
    *)
      printf '%s\n' "$not_one"
      return 1
      ;;
  esac
  if ! worktree=$(wt_repo_root "$here"); then
    printf '%s\n' "$not_one"
    return 1
  fi
  if ! root=$(wt_main_root "$here"); then
    printf 'Pitlane: cannot find the main checkout for %s.\n' "$here"
    return 1
  fi
  # A path under .claude/worktrees/ is not yet a worktree: from that directory itself, or a plain
  # directory beneath it, git answers with the MAIN checkout, and serve would start (and record) the
  # main checkout's app. Only a linked worktree that sits under <root>/.claude/worktrees/ qualifies.
  case "$worktree/" in
    "$root$WT_SUBPATH"?*) ;;
    *) printf '%s\n' "$not_one"; return 1 ;;
  esac
  WT_NAME=$(wt_name_from_path "$worktree")
  WT_SLUG=$(wt_slugify "$WT_NAME") || WT_SLUG=''
  WT_PATH=$worktree
  WT_ROOT=$root
  export WT_NAME WT_SLUG WT_PATH WT_ROOT
  wt_prime_paths "$root" "$worktree"

  # Stopping by signal runs nothing the profile names, so it needs neither the profile nor its
  # approval. A server recorded as stopped by command is stopped by runtime.stop, which is the
  # profile's command: that needs both, like serve itself.
  if [ "$mode" = --serve-stop ]; then
    # A /pitlane-serve still probing holds the serve lock and may not have recorded its server yet:
    # stopping now would find nothing, or race the record it is about to write. Held until exit.
    # Without flock(1) nothing is serialised, as in wt_serve_start.
    wt_lock_acquire "$(wt_serve_lockfile "$worktree")" "${WT_SERVE_LOCK_SECONDS:-5}" 7
    case $? in
      0) ;;
      1)
        if command -v flock >/dev/null 2>&1; then
          printf 'Pitlane: nothing stopped — a /pitlane-serve is still starting the app here; wait for it to finish, then stop it again.\n'
          return 1
        fi
        ;;
      *)
        printf 'Pitlane: nothing stopped — cannot take the serve lock at %s.\n' "$(wt_serve_lockfile "$worktree")"
        return 1
        ;;
    esac
    if wt_serve_record_read "$worktree" && [ "$WT_SERVE_STOPBY" = command ]; then
      if ! wt_has_json; then
        printf 'Pitlane: the server at %s was not stopped — only runtime.stop can stop it, and neither jq nor python3 is on PATH to read the profile.\n' "$WT_SERVE_URL"
        return 1
      fi
      wt_load_profile_for "$worktree" "$root"
      if [ "${PROFILE_PRESENT:-0}" != 1 ]; then
        printf 'Pitlane: the server at %s was not stopped — only runtime.stop can stop it, and there is no usable profile at %s.\n' "$WT_SERVE_URL" "$PROFILE_PATH"
        return 1
      fi
      wt_approval_check "$worktree"
      if [ "${WT_APPROVAL:-}" = no ]; then
        wt_approval_held_line ''
        return 1
      fi
    fi
    wt_serve_stop "$worktree"
    rc=$?
    case $rc in
      0)
        if [ "$WT_SERVE_STOPBY" = command ]; then
          printf 'Pitlane: stopped the server at %s (by runtime.stop).\n' "$WT_SERVE_URL"
        else
          printf 'Pitlane: stopped the server at %s (pid %s).\n' "$WT_SERVE_URL" "$WT_SERVE_PID"
        fi
        ;;
      1) printf 'Pitlane: no server started by Pitlane is recorded for this worktree — nothing stopped.\n' ;;
      2) printf 'Pitlane: the server Pitlane started here (pid %s) had already exited — nothing stopped.\n' "$WT_SERVE_PID" ;;
      3) printf 'Pitlane: pid %s now belongs to another process, not the server Pitlane started — left alone; nothing stopped.\n' "$WT_SERVE_PID" ;;
      5)
        printf 'Pitlane: the server at %s was not stopped — %s.\n' "$WT_SERVE_URL" "$WT_SERVE_STOP_WHY"
        return 1
        ;;
      *)
        printf 'Pitlane: the server at %s (pid %s) did not stop, even on SIGKILL.\n' "$WT_SERVE_URL" "$WT_SERVE_PID"
        return 1
        ;;
    esac
    return 0
  fi

  if ! wt_has_json; then
    printf 'Pitlane: not served — neither jq nor python3 is on PATH, so the profile cannot be read.\n'
    return 1
  fi
  wt_load_profile_for "$worktree" "$root"
  if [ "${PROFILE_PRESENT:-0}" != 1 ]; then
    printf 'Pitlane: not served — there is no usable profile at %s; /pitlane-setup writes one.\n' "$PROFILE_PATH"
    return 1
  fi
  if [ "${PROFILE_HAS_RUNTIME:-0}" != 1 ] || [ -z "${PROFILE_RT_SERVE:-}" ]; then
    printf 'Pitlane: not served — the profile names no runtime.serve, so Pitlane does not know how this app starts; /pitlane-setup can add one.\n'
    return 1
  fi
  wt_approval_check "$worktree"
  if [ "${WT_APPROVAL:-}" = no ]; then
    wt_approval_held_line ''
    return 1
  fi
  wt_background_wait "$worktree"
  wt_serve_start "$worktree"
}

case ${1-} in
  --review | --approve)
    wt_approval_cli "$@"
    exit 0
    ;;
  --serve | --serve-stop)
    wt_serve_cli "$1"
    exit $?
    ;;
  # `bootstrap.sh --changed`, run from a worktree: each tracked path an install changed and that is
  # still changed, one per line and nothing else on stdout, nothing when there is none. A name
  # holding a control byte is printed $'…'-quoted. /pitlane-finish reads it to offer restores.
  --changed)
    if worktree=$(wt_repo_root "$PWD"); then
      changed=$(wt_paths_display "$(wt_install_changed_paths "$worktree")" "$WT_NL")
      [ -z "$changed" ] || printf '%s\n' "$changed"
    else
      wt_log "$PWD is not inside a git repository"
    fi
    exit 0
    ;;
  # `bootstrap.sh --restore <path>`: puts back one path --changed printed, and nothing else, matched
  # literally. Run by /pitlane-finish only on the user's word, path by path; exits 1 when refused.
  --restore)
    if ! worktree=$(wt_repo_root "$PWD"); then
      wt_log "$PWD is not inside a git repository"
      exit 1
    fi
    wt_install_restore "$worktree" "${2-}"
    exit $?
    ;;
esac

wt_read_input

# Probe the JSON backend explicitly and SAY SO when it is missing. Without this the hook
# is indistinguishable from a no-op: every field read returns empty, the event can't be
# identified, and the user gets no clue why nothing happened.
if ! wt_has_json; then
  wt_log "neither jq nor python3 is on PATH — cannot read the hook payload, doing nothing"
  exit 0
fi

event=$(wt_read_field hook_event_name) || event=''
name=$(wt_read_field name) || name=''
source_kind=$(wt_read_field source) || source_kind=''
payload_cwd=$(wt_read_field cwd) || payload_cwd=''
here=${payload_cwd:-$PWD}

# Refuse a worktree path that a symlink could redirect out of the repository.
#
# THE ORDER OF THIS CHECK IS THE WHOLE POINT, and it is why registering WorktreeCreate is
# defensible at all. Claude Code performs the same refusal — measured, its message
# names `.claude`, `.claude/worktrees` and the worktree directory itself — but on the hook path it
# fires only AFTER the hook has run. The measured consequence: the session failed while
# the hook's worktree stayed registered OUTSIDE the repository, with whatever it had installed,
# seeded or allocated already done and nothing to roll it back. That outcome cannot be
# fully recovered, and is the strongest argument against taking over creation.
#
# Doing the check FIRST converts that into native's own behaviour: refuse, create nothing, print
# no path, and let Claude Code report the failure. It is a copy of a rule this plugin does not
# own, so it can drift if a future release tightens it — that is stated here
# rather than pretended away.
wt_symlink_refuses() {  # $1 = main checkout, $2 = the worktree path about to be created
  local root=${1%/} worktree=${2-}
  if [ -L "$root/.claude" ]; then
    wt_log "refusing: $root/.claude is a symlink, which could redirect worktree creation outside the repository"
    return 0
  fi
  if [ -L "$root/.claude/worktrees" ]; then
    wt_log "refusing: $root/.claude/worktrees is a symlink, which could redirect worktree creation outside the repository"
    return 0
  fi
  if [ -n "$worktree" ] && [ -L "$worktree" ]; then
    wt_log "refusing: $worktree is a symlink, which could redirect worktree creation outside the repository"
    return 0
  fi
  return 1
}

# Layer 2, shared by both events. Everything after "the worktree exists and the profile is loaded"
# is identical; the branches differ only in their own contracts and in whether native creation has
# already honoured `.worktreeinclude`.
#
# It NEVER returns non-zero and never lets a step's failure reach the caller: the entrypoint's job
# is to exit 0 having warned, whatever happened here.
wt_bootstrap_worktree() {  # $1 = main checkout, $2 = worktree, $3 = 1 if we own .worktreeinclude
  local root=${1%/} worktree=${2%/} own_include=${3:-0}
  local started deadline hook_deadline budget reserve elapsed held=0

  started=$(date +%s 2>/dev/null) || started=''
  deadline='' hook_deadline=''
  # Finishing from /pitlane-finish runs outside any hook, so the only limit is a generous one.
  if [ "${WT_FINISH:-}" = 1 ]; then
    WT_HOOK_TIMEOUT=${WT_FINISH_LIMIT:-3600}
    PROFILE_BOOTSTRAP_TIMEOUT=$((WT_HOOK_TIMEOUT - 30))
    [ "${PROFILE_SEED_TIMEOUT:-0}" -ge 1200 ] 2>/dev/null || PROFILE_SEED_TIMEOUT=1200
  fi
  if [ -n "$started" ]; then
    # CLAMPED BELOW THE HOOK'S OWN TIMEOUT. The platform's timer starts first, and the default
    # bootstrap budget is exactly the hook timeout — so without this the platform kills the hook
    # before the internal guard can fire, and the warn-and-continue path never runs. On the
    # WorktreeCreate branch that is worse than slow: the path is printed only after this returns,
    # so creation fails outright while the worktree is already registered and half-populated,
    # which is precisely the unrecoverable state the symlink pre-check exists to avoid.
    # lib.sh already treats this as a rule for the profile's two timeouts; the DEFAULT needs it too.
    budget=$PROFILE_BOOTSTRAP_TIMEOUT
    if [ "$budget" -gt $((WT_HOOK_TIMEOUT - 30)) ]; then
      budget=$((WT_HOOK_TIMEOUT - 30))
      wt_log "the bootstrap budget (${PROFILE_BOOTSTRAP_TIMEOUT}s) leaves no room under the ${WT_HOOK_TIMEOUT}s hook timeout — using ${budget}s so a slow step is reported rather than killed"
    fi
    # TWO DEADLINES, so a slow install cannot starve the seed. Dependencies stop at
    # bootstrapSeconds; the seed then gets its own seedSeconds on top — the SUM the profile is
    # validated against. Before, the seed ran on whatever the installs had left, and measured on a
    # real repository a toolchain download ate it all: the env overrides pointed at databases
    # that were never made. The seed's share is reserved out of the hook's window, capped at half
    # of it, because both timeouts default to the hook timeout itself when a profile sets neither.
    hook_deadline=$((started + WT_HOOK_TIMEOUT - 30))
    reserve=0
    if [ "${PROFILE_HAS_RUNTIME:-0}" = 1 ] && [ -n "${PROFILE_RT_SEED:-}" ]; then
      reserve=${PROFILE_SEED_TIMEOUT:-0}
      [ "$reserve" -le $(((WT_HOOK_TIMEOUT - 30) / 2)) ] 2>/dev/null || reserve=$(((WT_HOOK_TIMEOUT - 30) / 2))
    fi
    deadline=$((started + budget))
    [ "$deadline" -le $((hook_deadline - reserve)) ] || deadline=$((hook_deadline - reserve))
  fi
  # Published for the start-up status line, whose git status must fit the same budget.
  WT_BOOTSTRAP_DEADLINE=$deadline

  # A second lock, scoped to THIS worktree, so two sessions entering the same worktree at once do
  # not both walk the whole sequence. The per-dependency locks are for contention BETWEEN
  # worktrees and do not cover that. Not holding it is not a reason to stop — the per-dependency
  # state makes a concurrent run mostly a no-op.
  #
  # It sits beside the state file, in the worktree's private git dir, NOT in the checkout. Lock
  # files are never unlinked, so one in the working tree would be a permanent untracked entry in
  # `git status` of a repo whose .gitignore knows nothing about this plugin — committable by
  # accident, and enough to make `git worktree remove` refuse without --force, which teardown would
  # then have to work around.
  wt_prime_paths "$root" "$worktree"
  wt_lock_acquire "$(wt_state_path "$worktree").lock" 5 8 && held=1

  # The copy walk and the drift check both cost real time — `git ls-files` over the main checkout,
  # and one interpreter start — so the "global" budget has to bound them too, not just the
  # dependency step.
  if [ "$(wt_budget_left "$deadline")" -gt 0 ]; then
    wt_copy_config "$root" "$worktree" "$own_include"
  else
    wt_log "no time left to copy config — leaving it for the next session"
  fi

  # wt_load_profile publishes the evidence fields, so this does not re-split the scalar record.
  # A second positional read of the same sixteen fields would have to agree with lib.sh's forever,
  # and nothing would notice if the two drifted apart.
  if [ "$(wt_budget_left "$deadline")" -gt 0 ]; then
    wt_report_drift "$worktree" \
      "${PROFILE_EV_DETECTION:-}" "${PROFILE_EV_MARKERS:-}" "${PROFILE_EV_SHELL:-}" "$PROFILE_PATH" "$root"
  fi
  wt_warn_hardlinked_venvs "$root"
  # One interpreter start when the profile has an uncopied hardlink, so inside the budget like drift.
  [ "$(wt_budget_left "$deadline")" -le 0 ] || wt_warn_uncopied_links

  # Decided AFTER the copy: it is what brings a personal profile's seed and teardown scripts into
  # the worktree, and the fingerprint is of the files as they will run. Before anything executes.
  wt_approval_check "$worktree"

  wt_bootstrap_deps "$root" "$worktree" "$deadline"
  wt_bootstrap_artifacts "$root" "$worktree" "$deadline"
  # THE DEADLINE IS PASSED IN. `timeouts.seedSeconds` and `timeouts.bootstrapSeconds` run inside
  # ONE hook invocation, so it is their SUM that must fit — a seed that took a fresh allowance
  # would let the platform kill the hook before any internal guard fired, which is the one failure
  # the warn-and-exit-0 rule exists to prevent.
  wt_runtime_handoff "$root" "$worktree" "${hook_deadline:-$deadline}"

  [ "$held" -eq 1 ] && wt_lock_release 8

  if [ -n "$started" ]; then
    elapsed=$(( $(date +%s) - started ))
    wt_log "bootstrap finished in ${elapsed}s"
  fi
  return 0
}

case $event in
  WorktreeCreate)
    # stdout is the path. Every message below goes to stderr.
    root=$(wt_main_root "$here") || root=$(wt_repo_root "$here") || root=''
    if [ -z "$root" ]; then
      # No path we could print would be enterable, so say why and let Claude Code report
      # the failure rather than emitting a guess.
      wt_log "cannot resolve a repository from $here — leaving worktree creation to Claude Code"
      exit 0
    fi

    if [ -z "$name" ]; then
      wt_log "WorktreeCreate payload had no name; cannot derive a worktree path"
      exit 0
    fi

    # `name` arrives already resolved (measured: `claude -w "#1"` delivers `pr-1`), but it
    # is still untrusted text and it is about to become BOTH a path component and the one
    # line on the stdout protocol channel.
    case $name in
      *$'\n'* | *$'\r'*)
        # A newline would put a second line on stdout, which breaks the protocol outright.
        wt_log "refusing a worktree name containing a newline"
        exit 0
        ;;
    esac
    dir=${name//\//-}
    case $dir in
      '' | '.' | '..')
        # "." and ".." would escape the worktrees directory and hand back .claude itself.
        wt_log "refusing the unsafe worktree name \"$name\""
        exit 0
        ;;
    esac

    worktree="$root/.claude/worktrees/$dir"
    # A BRANCH NAME HAS STRICTER RULES THAN A DIRECTORY. `worktree-my fix` is not a legal ref, so
    # `git worktree add -b` failed and the hook printed no path — the creation failed outright for a
    # name the directory itself would have taken. git decides what is legal; anything it refuses has
    # its characters outside a plain set turned into `-`, and if even that is refused (a `..`, a
    # trailing `.lock`) the slug is used, which is [a-z0-9_] by construction. The directory keeps
    # the name as given.
    branch="worktree-$dir"
    if ! wt_git "$root" check-ref-format --branch "$branch" >/dev/null 2>&1; then
      branch="worktree-$(printf '%s' "$dir" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')"
      if ! wt_git "$root" check-ref-format --branch "$branch" >/dev/null 2>&1; then
        branch="worktree-$(wt_slugify "$name" 2>/dev/null || printf 'wt')"
      fi
      wt_log "\"worktree-$dir\" is not a legal branch name — using $branch"
    fi

    # BEFORE ANY SIDE EFFECT. See wt_symlink_refuses: on this path Claude Code's own refusal
    # arrives too late to matter, so it has to happen here or not at all.
    if wt_symlink_refuses "$root" "$worktree"; then
      exit 0
    fi

    if [ -d "$worktree" ]; then
      # Reopening. Measured: the hook is re-invoked for an existing name, so this is a
      # normal path, not an error.
      wt_log "reopening existing worktree $worktree"
    elif wt_git "$root" show-ref --verify --quiet "refs/heads/$branch"; then
      # The branch already exists — check it out rather than inventing a new name, which
      # would orphan whatever the user kept on it.
      out=$(wt_git "$root" worktree add "$worktree" "$branch" 2>&1) || true
      [ -n "$out" ] && wt_log "$out"
    else
      # WHICH REF A NEW BRANCH IS BASED ON. Native creation follows Claude Code's `worktree.baseRef`
      # setting, whose default `fresh` means the repo's default branch ON THE REMOTE, not local
      # HEAD (measured). Since this hook replaces native creation on these paths, basing
      # on local HEAD would silently hand a colleague a worktree cut from whatever happened to be
      # checked out — a wrong base is worse than a missing one, because it looks fine.
      #
      # So: match the default. What is NOT matched is a user who has configured
      # `worktree.baseRef: head`; reading their settings is out of this hook's scope and the gap
      # is acknowledged rather than guessed at.
      #
      # EXCEPT WHEN THE PARENT SESSION WORKS IN A LINKED WORKTREE. `cwd` is that session's directory
      # (measured), and a subagent it starts almost always assists with its work — a worktree cut
      # from the default branch silently lacks it, a pull request under review most of all. So the
      # new branch starts from the commit that worktree has checked out; its uncommitted changes
      # cannot come along, and the log says so.
      #
      # A pull request's commit stays a pull request's: the new worktree is marked as one before
      # its path is printed (wt_pr_origin_mark), or it is not based there at all.
      default_base=refs/remotes/origin/HEAD
      if ! wt_git "$root" rev-parse --verify --quiet "$default_base" >/dev/null 2>&1; then
        default_base=HEAD
      fi
      base=$default_base parent_name='' parent_is_pr=0
      if wt_parent_worktree "$root" "$payload_cwd"; then
        base=$WT_PARENT_COMMIT
        parent_name=$(wt_name_from_path "$WT_PARENT_WORKTREE")
        wt_parent_is_pr "$root" && parent_is_pr=1
        base_short=$(wt_git "$root" rev-parse --short "$base" 2>/dev/null) || base_short=$base
        wt_log "basing $branch on $parent_name's current commit ($base_short) — the session that started it works there; uncommitted changes are not included"
        [ "$parent_is_pr" = 0 ] \
          || wt_log "$parent_name is, or may be, a pull request's worktree — so $branch is treated as one too"
      elif [ "$default_base" = HEAD ]; then
        wt_log "no origin/HEAD in this repository — basing $branch on local HEAD"
      fi
      out=$(wt_git "$root" worktree add -b "$branch" "$worktree" "$base" 2>&1) || true
      [ -n "$out" ] && wt_log "$out"
      if [ "$parent_is_pr" = 1 ] && [ -d "$worktree" ] \
         && ! wt_pr_origin_mark "$worktree" "$parent_name" "$base"; then
        wt_log "could not mark $worktree as started from a pull request's worktree — basing $branch on $default_base instead"
        if ! wt_git "$root" worktree remove --force "$worktree" >/dev/null 2>&1; then
          wt_log "could not remove the unmarked $worktree — leaving worktree creation to Claude Code"
          exit 0
        fi
        wt_git "$root" branch -D "$branch" >/dev/null 2>&1 || true
        out=$(wt_git "$root" worktree add -b "$branch" "$worktree" "$default_base" 2>&1) || true
        [ -n "$out" ] && wt_log "$out"
      fi
    fi

    # Never print a path that isn't there. Claude Code would fail the session on a path it
    # cannot enter, and a bare "Preparing worktree" line in the log reads like success.
    if [ ! -d "$worktree" ]; then
      wt_log "could not create $worktree — leaving worktree creation to Claude Code"
      exit 0
    fi

    WT_NAME=$name
    WT_SLUG=$(wt_slugify "$name") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile_for "$worktree" "$root"
    wt_log "worktree=$worktree slug=$WT_SLUG profile=$([ "$PROFILE_PRESENT" = 1 ] && echo "$PROFILE_PATH" || echo none)"

    # own_include=1: registering this hook DISABLES native `.worktreeinclude` handling on this
    # path (measured), so the plugin owes the behaviour here.
    wt_bootstrap_worktree "$root" "$worktree" 1

    # The one line that must reach stdout, printed LAST so nothing above can interleave with it.
    printf '%s\n' "$worktree"
    exit 0
    ;;

  SessionStart)
    # Only a genuinely new or resumed session can need bootstrapping. `compact` fires
    # mid-session, where the "the model cannot race the hook" measurement —
    # taken at startup — does not apply, and where re-running a bootstrap would be pure
    # cost. Stay silent rather than logging on every compaction.
    case $source_kind in
      startup | resume | '') ;;
      *) exit 0 ;;
    esac

    # Measured: for `claude -w <name>` this fires with cwd already set to the worktree.
    # For a session in the main checkout there is nothing to bootstrap, so stay silent —
    # a plugin that logs on every single session start is a plugin people uninstall.
    case "$here/" in
      *"$WT_SUBPATH"*) ;;
      *)
        [ "${WT_FINISH:-}" = 1 ] && printf 'Pitlane: run /pitlane-finish from inside a worktree under .claude/worktrees/ — this is not one.\n'
        exit 0
        ;;
    esac

    worktree=$(wt_repo_root "$here") || worktree=$here
    root=$(wt_main_root "$here") || root=''
    if [ -z "$root" ]; then
      wt_log "could not resolve the main checkout for $worktree — skipping bootstrap"
      exit 0
    fi

    # SessionStart carries no `name`, so it comes from the directory — but NOT from its basename
    # (wt_name_from_path says why).
    WT_NAME=$(wt_name_from_path "$worktree")
    WT_SLUG=$(wt_slugify "$WT_NAME") || WT_SLUG=''
    WT_PATH=$worktree
    WT_ROOT=$root
    export WT_NAME WT_SLUG WT_PATH WT_ROOT
    wt_load_profile_for "$worktree" "$root"

    wt_log "worktree $WT_NAME at $worktree (main checkout $root, slug $WT_SLUG)"
    if [ "$PROFILE_PRESENT" = 1 ]; then
      wt_log "profile $PROFILE_PATH: shell=${PROFILE_SHELL:-<host>} runtime=$([ "$PROFILE_HAS_RUNTIME" = 1 ] && echo yes || echo no)"
    else
      wt_log "no usable profile at $PROFILE_PATH — run /pitlane-setup to write one; doing the safe minimum"
    fi

    # `.worktreeinclude` ON THE FIRST BOOTSTRAP ONLY. Native `claude -w` has already honoured it —
    # but a worktree made with plain `git worktree add` (the only way to check out an existing
    # branch) never had it applied by anyone, and measured on a real repository it arrived
    # with neither `.env.local` nor the developer's `.env.dev.local`. The copier only ever fills
    # gaps, so where native did the work this is a no-op; and once the worktree has a state file it
    # is skipped, so later sessions do not pay for the walk over the main checkout. The profile's
    # copy[] is applied every session regardless, because native knows nothing about it.
    # /pitlane-finish while a background run is still going: wait for it rather than race it, then
    # walk the sequence once more, which finds it done and reports so.
    if [ "${WT_FINISH:-}" = 1 ]; then
      if [ "${WT_BACKGROUND:-}" = 1 ]; then
        wt_background_claim "$worktree"
      else
        wt_background_wait "$worktree"
      fi
    fi

    # DEFERRED, on a normal start. Claude Code holds the session's first prompt until this hook
    # returns, and measured on a real repository the installs and the seed made that four and a half
    # minutes — for a prompt that needed neither. So the start-up run does only what is cheap and what
    # everything else depends on (config, hardlinks, the port and the env overrides), and the rest is
    # handed to a detached `--finish --background`. PITLANE_BACKGROUND=off keeps it all in the hook.
    WT_DEFER=0
    if [ "${WT_FINISH:-}" != 1 ] && wt_background_enabled; then
      WT_DEFER=1
    fi

    own_include=0
    [ -f "$(wt_state_path "$worktree")" ] || own_include=1
    wt_bootstrap_worktree "$root" "$worktree" "$own_include"
    # A session that started while this background run was going was told "in progress" and started
    # no run of its own — but it may have found work this run had already walked past (a lockfile
    # changed by a checkout). So the run goes round again for it, a bounded number of times.
    if [ "${WT_BACKGROUND:-}" = 1 ]; then
      rounds=0
      while wt_background_take_again "$worktree" && [ "$rounds" -lt 3 ]; do
        rounds=$((rounds + 1))
        wt_log "a session started meanwhile — going round once more"
        wt_bootstrap_worktree "$root" "$worktree" 0
      done
    fi

    # stdout is the model's context here, so it stays EMPTY when the worktree is complete and clean —
    # and gets one short notice when it is not, because a session that mistakes a half-set-up worktree for a
    # ready one goes on to install and clone by hand (measured: it is what sessions did before this
    # plugin existed). /pitlane-finish reads the same list as a plain status line.
    wt_bootstrap_pending "$worktree"
    pending=$WT_PENDING
    if [ "${WT_FINISH:-}" = 1 ]; then
      wt_bootstrap_status_line "$worktree" finish "$([ "${WT_APPROVAL:-}" = no ] && echo approval)"
      exit 0
    fi
    # The session's own environment gets WORKTREE_PORT and WORKTREE_URL (ADR-021) — from the start-up hook
    # only, since Claude Code reads CLAUDE_ENV_FILE once, when this hook exits.
    wt_session_env_export "${CLAUDE_ENV_FILE:-}"
    how=''
    if [ -n "$pending" ]; then
      if [ "${WT_APPROVAL:-}" = no ]; then
        # Nothing a background run could do: everything left needs the commands that are held back.
        wt_log "not run, pending approval: $(printf '%s' "$pending" | paste -sd, - | sed 's/,/, /g')"
        how=approval
      # A run is started only for work it would attempt: an install whose failure stands is not.
      elif [ "$WT_DEFER" = 1 ] && [ -n "$WT_PENDING_ATTEMPTABLE" ] && wt_background_start "$worktree"; then
        wt_log "finishing in the background: $(printf '%s' "$pending" | paste -sd, - | sed 's/,/, /g') — progress in $(wt_background_logfile "$worktree")"
        how=background
      else
        wt_log "not finished: $(printf '%s' "$pending" | paste -sd, - | sed 's/,/, /g')"
      fi
    fi
    wt_bootstrap_status_line "$worktree" start "$how" "${WT_BOOTSTRAP_DEADLINE:-}"
    exit 0
    ;;

  '')
    # An unreadable or empty payload. Never treat this as SessionStart: on the
    # WorktreeCreate path an unexplained empty stdout costs the user their session, so it
    # has to be visible.
    wt_log "could not read hook_event_name from the payload — doing nothing"
    exit 0
    ;;

  *)
    wt_log "unexpected hook event \"$event\" — doing nothing"
    exit 0
    ;;
esac
