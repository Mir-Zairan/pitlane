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
#                   is this hook's business. Phase 1 measured that the session blocks until this
#                   returns, which is what makes a synchronous bootstrap safe.
#   WorktreeCreate  Fires for the mid-session EnterWorktree tool and for subagents with
#                   isolation:"worktree" — never for launch-time `claude -w`, because plugin hooks
#                   join the registry after the worktree already exists (ADR-009). stdout IS the
#                   worktree path and nothing else. It REPLACES native creation on those paths, so
#                   this hook creates the worktree AND owes `.worktreeinclude` itself.
#
# Registering the second one is Phase 3's decision, taken because those two paths otherwise get no
# bootstrap at all — a subagent lands in a checkout with no dependencies. Its one unrecoverable
# failure mode is bought off by wt_symlink_refuses running before anything is created; what that
# does NOT buy off is recorded in the phase handoff.
#
# ADR-003 governs everything below: warn on stderr, still emit the path, exit 0. `set -e` is
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
# defensible at all. Claude Code performs the same refusal — measured in Phase 1, its message
# names `.claude`, `.claude/worktrees` and the worktree directory itself — but on the hook path it
# fires only AFTER the hook has run. Phase 1 measured the consequence: the session failed while
# the hook's worktree stayed registered OUTSIDE the repository, with whatever it had installed,
# seeded or allocated already done and nothing to roll it back. ADR-009 calls that row "cannot be
# fully recovered" and treats it as the strongest argument against taking over creation.
#
# Doing the check FIRST converts that into native's own behaviour: refuse, create nothing, print
# no path, and let Claude Code report the failure. It is a copy of a rule this plugin does not
# own, so it can drift if a future release tightens it — that is recorded in the phase handoff
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
# is to exit 0 having warned, whatever happened here (ADR-003).
wt_bootstrap_worktree() {  # $1 = main checkout, $2 = worktree, $3 = 1 if we own .worktreeinclude
  local root=${1%/} worktree=${2%/} own_include=${3:-0}
  local started deadline budget elapsed held=0

  started=$(date +%s 2>/dev/null) || started=''
  deadline=''
  if [ -n "$started" ]; then
    # CLAMPED BELOW THE HOOK'S OWN TIMEOUT. The platform's timer starts first, and the default
    # bootstrap budget is exactly the hook timeout — so without this the platform kills the hook
    # before the internal guard can fire, and ADR-003's warn-and-continue path never runs. On the
    # WorktreeCreate branch that is worse than slow: the path is printed only after this returns,
    # so creation fails outright while the worktree is already registered and half-populated,
    # which is precisely the unrecoverable state the symlink pre-check exists to avoid.
    # lib.sh already treats this as a rule for the profile's two timeouts; the DEFAULT needs it too.
    budget=$PROFILE_BOOTSTRAP_TIMEOUT
    if [ "$budget" -gt $((WT_HOOK_TIMEOUT - 30)) ]; then
      budget=$((WT_HOOK_TIMEOUT - 30))
      wt_log "the bootstrap budget (${PROFILE_BOOTSTRAP_TIMEOUT}s) leaves no room under the ${WT_HOOK_TIMEOUT}s hook timeout — using ${budget}s so a slow step is reported rather than killed"
    fi
    deadline=$((started + budget))
  fi

  # A second lock, scoped to THIS worktree, so two sessions entering the same worktree at once do
  # not both walk the whole sequence. The per-dependency locks are for contention BETWEEN
  # worktrees and do not cover that. Not holding it is not a reason to stop — the per-dependency
  # state makes a concurrent run mostly a no-op.
  #
  # It sits beside the state file, in the worktree's private git dir, NOT in the checkout. Lock
  # files are never unlinked, so one in the working tree would be a permanent untracked entry in
  # `git status` of a repo whose .gitignore knows nothing about this plugin — committable by
  # accident, and enough to make `git worktree remove` refuse without --force, which Phase 5 would
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
      "${PROFILE_EV_DETECTION:-}" "${PROFILE_EV_MARKERS:-}" "${PROFILE_EV_SHELL:-}" "$PROFILE_PATH"
  fi

  wt_bootstrap_deps "$root" "$worktree" "$deadline"
  # THE DEADLINE IS PASSED IN. `timeouts.seedSeconds` and `timeouts.bootstrapSeconds` run inside
  # ONE hook invocation, so it is their SUM that must fit — a seed that took a fresh allowance
  # would let the platform kill the hook before any internal guard fired, which is the one failure
  # ADR-003 exists to prevent.
  wt_runtime_handoff "$root" "$worktree" "$deadline"

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
      # HEAD (measured in Phase 1). Since this hook replaces native creation on these paths, basing
      # on local HEAD would silently hand a colleague a worktree cut from whatever happened to be
      # checked out — a wrong base is worse than a missing one, because it looks fine.
      #
      # So: match the default. What is NOT matched is a user who has configured
      # `worktree.baseRef: head`; reading their settings is out of this phase's scope and the gap
      # is recorded in the handoff rather than guessed at.
      base=refs/remotes/origin/HEAD
      if ! wt_git "$root" rev-parse --verify --quiet "$base" >/dev/null 2>&1; then
        base=HEAD
        wt_log "no origin/HEAD in this repository — basing $branch on local HEAD"
      fi
      out=$(wt_git "$root" worktree add -b "$branch" "$worktree" "$base" 2>&1) || true
      [ -n "$out" ] && wt_log "$out"
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
    # path (measured in Phase 1), so the plugin owes the behaviour here.
    wt_bootstrap_worktree "$root" "$worktree" 1

    # The one line that must reach stdout, printed LAST so nothing above can interleave with it.
    printf '%s\n' "$worktree"
    exit 0
    ;;

  SessionStart)
    # Only a genuinely new or resumed session can need bootstrapping. `compact` fires
    # mid-session, where the "the model cannot race the hook" measurement in ADR-009 —
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
      *) exit 0 ;;
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
      wt_log "no usable profile at $PROFILE_PATH — run /worktree-calibrate to write one; doing the safe minimum"
    fi

    # `.worktreeinclude` ON THE FIRST BOOTSTRAP ONLY. Native `claude -w` has already honoured it —
    # but a worktree made with plain `git worktree add` (the only way to check out an existing
    # branch, ADR-013) never had it applied by anyone, and measured on a real repository it arrived
    # with neither `.env.local` nor the developer's `.env.dev.local`. The copier only ever fills
    # gaps, so where native did the work this is a no-op; and once the worktree has a state file it
    # is skipped, so later sessions do not pay for the walk over the main checkout. The profile's
    # copy[] is applied every session regardless, because native knows nothing about it.
    own_include=0
    [ -f "$(wt_state_path "$worktree")" ] || own_include=1
    wt_bootstrap_worktree "$root" "$worktree" "$own_include"

    # NOTHING to stdout: for SessionStart, stdout becomes model context.
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
