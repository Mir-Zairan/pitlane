#!/usr/bin/env bash
#
# Mechanical detection for /worktree-calibrate. Reads reference/detection.json, inspects a
# repository, and prints what it found.
#
# THIS IS NOT A HOOK, and the distinction matters in both directions.
#
# It is invoked by the calibrate SKILL, with a human present, once per repository. So it may
# take seconds, spawn interpreters freely, and run a bounded `--version` probe — none of
# which a hook could do. But it is still plain deterministic shell with NO model and NO
# network, because that is what makes the mechanical half of calibration repeatable: the
# same repository must produce the same proposal every run, which turns "a second
# calibration changes nothing" into something a test can assert rather than something a
# developer has to trust. ADR-002 draws the line at hook time; this is the deterministic
# half of the other side of that line.
#
# WHAT IT DOES NOT DO. It proposes; it never concludes. Layer 3 is not inferred here — every
# runtime line is labelled `hint` and nothing else, because nothing in a repository states
# that an env var selects a tenant database, and a wrong guess there does not produce a
# broken worktree, it corrupts a colleague's data (ADR-006). It also writes nothing at all:
# the skill owns the profile.
#
# OUTPUT: tab-separated records on stdout, one per line, first field is the label.
# Deliberately not JSON. The consumers are a model that reads it and a test suite that greps
# it, and JSON would have meant a third JSON *writer* in a codebase whose two existing JSON
# readers have already diverged twice — with every value needing escaping. Tabs, CRs and LFs
# are stripped from every field on the way out, so a record can never split in the wrong
# place.
#
#   detectionVersion <v>
#   repoRoot         <abs path>
#   shell            <wrapper>                  ("" means the host shell)
#   shellArgs        argv|string
#   shellMarker      <file>                     ("" when nothing matched)
#   shellReason      <why>
#   shellWarn        <warning>                  (only when the matched rule carries one)
#   probe            <tool>  ok|fail|timeout  <version line, or why it did not run>
#   dep              <n> <dir> <lock> <strategy> <install> <verify>
#                    (a NESTED project's dir and lock carry its directory, and its commands
#                    start with `cd '<dir>' &&` — they run from the worktree root like the rest)
#   depReason        <n> <why this strategy>
#   depNote          <n> <caveat worth reading>
#   depDowngrade     <n> <from> <to> <why>
#   dropped          <marker> <dir> <why it was not used>
#   hazard           <n> <id> <action> <flag> <why>
#   hazardChain      <n> <the resolved script chain>
#   escalate         <n> <id> <action> <why this needs a human>   (a rule MATCHED: it will)
#   unreadable       <n> <id> <action> <why this needs a human>   (trail unfollowable: it might)
#   corroborate      <n> <file> <what it independently confirms>
#   config           <repo-relative path>
#   hint             port|db|service <name> <where it was seen>
#   compose          <file> explicit:<name>|env|directory <published host ports>
#                    (`directory`: each worktree gets its own stack, and its host ports collide)
#   assign           <name> <file> <count> <first line:text>   (an inline NAME=value for a hinted
#                    variable: it beats every env file, so it bypasses the overrides)
#   ignore           <path> ok|missing           (a path the plugin creates in a checkout)
#   warn             <message>
#
# WT_SKIP_PROBES=1 skips the toolchain version probes. They are the only part of detection
# whose answer depends on the host rather than on the repository, so they are also the only
# part a test cannot assert deterministically.
#
# Exit status: 0 whenever it produced a proposal, 1 only if it could not run at all — no
# such directory, no detection table, no JSON backend. An unusual repository is never a
# failure; it legitimately yields a proposal with no deps.
set -uo pipefail

# SC1091: shellcheck only FOLLOWS a sourced file when invoked with -x, and the pre-commit
# gate lints each changed file on its own. The two directives below still tell it where
# lib.sh is for anyone running `shellcheck -x`.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TAB=$'\t'

# Where the detection table lives. CLAUDE_PLUGIN_ROOT is set for an installed plugin; the
# relative fallback lets the tests run this in place.
WT_DETECTION_JSON=${WT_DETECTION_JSON:-}
if [ -z "$WT_DETECTION_JSON" ]; then
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/reference/detection.json" ]; then
    WT_DETECTION_JSON="${CLAUDE_PLUGIN_ROOT}/reference/detection.json"
  else
    WT_DETECTION_JSON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && cd .. && pwd)/reference/detection.json"
  fi
fi

ROOT=${1:-$PWD}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

emit() {
  local out='' f first=1
  for f in "$@"; do
    f=$(printf '%s' "$f" | tr -d '\t\r\n')
    if [ "$first" = 1 ]; then out=$f; first=0; else out="$out$TAB$f"; fi
  done
  printf '%s\n' "$out"
}

warn() { emit warn "$*"; }

# ---------------------------------------------------------------------------
# Reading simple arrays out of the detection table
# ---------------------------------------------------------------------------

# Split a compact JSON array of plain strings — `["a","b"]` — into one item per line.
#
# A deliberate, bounded shortcut, safe only because of where its input comes from:
# reference/detection.json is OUR file, shipped with the plugin, and every array this is
# applied to holds bare filenames, globs or hazard ids. It is never applied to anything read
# out of a repository. An item containing a quote or a backslash is refused rather than
# mangled, so the shortcut cannot quietly become wrong if the table gains an odd value.
json_array_items() {  # $1 = compact JSON array
  local raw=${1-} item
  case $raw in
    '' | '[]' | 'null') return 0 ;;
    '['*']') ;;
    *) wt_log "expected a JSON array from the detection table, got: $raw"; return 1 ;;
  esac
  raw=${raw#[}
  raw=${raw%]}
  # printf WITH a trailing newline. Without it the final item has no delimiter, `read`
  # returns 1 at EOF, and the loop body never runs for it — so a one-item array yielded
  # nothing at all and a two-item array silently dropped the last. That is how every
  # dependency in a real repository went undetected.
  printf '%s\n' "$raw" | tr ',' '\n' | while IFS= read -r item; do
    item=${item# }
    item=${item#\"}
    item=${item%\"}
    case $item in
      '') continue ;;
      *[\\\"]*)
        # wt_log, NOT warn: warn writes a record to STDOUT, which is this function's item
        # stream, so a refused item became an item for every caller.
        wt_log "refusing a detection-table array item containing a quote or backslash: $item"
        continue
        ;;
    esac
    printf '%s\n' "$item"
  done
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

if [ ! -d "$ROOT" ]; then
  wt_log "no such directory: $ROOT"
  exit 1
fi
ROOT=$(cd "$ROOT" && pwd -P) || exit 1

if [ ! -r "$WT_DETECTION_JSON" ]; then
  wt_log "cannot read the detection table at $WT_DETECTION_JSON"
  exit 1
fi
if ! wt_has_json; then
  wt_log "neither jq nor python3 is on PATH — cannot read the detection table"
  exit 1
fi

DETVER=$(wt_json_get detectionVersion <"$WT_DETECTION_JSON") || DETVER=''
if [ -z "$DETVER" ]; then
  wt_log "$WT_DETECTION_JSON has no detectionVersion — refusing to detect from a table I cannot identify"
  exit 1
fi

emit detectionVersion "$DETVER"
emit repoRoot "$ROOT"

# `git check-ignore` needs a repository. A scratch directory that is not one still gets a
# useful dependency and shell proposal, so this warns rather than failing.
IS_GIT=0
if wt_git "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  IS_GIT=1
else
  warn "$ROOT is not a git repository — gitignored-config candidates cannot be confirmed, so none are proposed"
fi

PROBE_TIMEOUT=$(wt_json_get shellProbe.timeoutSeconds <"$WT_DETECTION_JSON") || PROBE_TIMEOUT=''
wt_is_seconds "$PROBE_TIMEOUT" || PROBE_TIMEOUT=60

NEVER_GLOBS=$(wt_json_get configCandidates.neverPropose.globs <"$WT_DETECTION_JSON") || NEVER_GLOBS=''
NEVER_HINT=$(wt_json_get runtimeHints.neverHintPattern <"$WT_DETECTION_JSON") || NEVER_HINT=''

# ---------------------------------------------------------------------------
# The toolchain shell
# ---------------------------------------------------------------------------
# First match wins in table order; the table ends in a marker:null catch-all, so this always
# terminates with an answer and there is no no-match branch to get wrong.

SHELL_CMD='' SHELL_ARGS='argv' SHELL_MARKER='' SHELL_REASON='' SHELL_WARN=''
while IFS=$WT_US read -r -d "$WT_RS" s_marker s_shell s_args s_reason s_warn; do
  if [ -n "$s_marker" ] && [ ! -e "$ROOT/$s_marker" ]; then continue; fi
  SHELL_CMD=$s_shell
  SHELL_ARGS=${s_args:-argv}
  SHELL_MARKER=$s_marker
  SHELL_REASON=$s_reason
  SHELL_WARN=$s_warn
  break
done < <(wt_json_records shells marker shell shellArgs reason warn <"$WT_DETECTION_JSON")

emit shell "$SHELL_CMD"
emit shellArgs "$SHELL_ARGS"
emit shellMarker "$SHELL_MARKER"
emit shellReason "$SHELL_REASON"
[ -n "$SHELL_WARN" ] && emit shellWarn "$SHELL_WARN"

# ---------------------------------------------------------------------------
# Following a manifest script to what it actually runs
# ---------------------------------------------------------------------------

# Read one key out of a manifest, rendered as text.
manifest_value() {  # $1 = manifest path, $2 = dotted key
  wt_json_get "$2" <"$1" 2>/dev/null || printf ''
}

# Resolve a manifest script to the whole chain of things it invokes, and print the
# accumulated text. Sets CHAIN_UNRESOLVED=1 when the trail runs into something this cannot
# read (a code callback, a script file, an external tool).
#
# MATCHING THE WHOLE CHAIN IS THE POINT, not a refinement. A probe returns a script's
# IMMEDIATE value, and in real repositories that value is almost always a reference to
# somewhere else. The repo this design came from defeats a one-level matcher twice over:
#
#   post-install-cmd -> ["@duckdb:install-lib", "@cache:clear", "@db", ...]   sees only "@db"
#   @db              -> [..., "@db:migrate", ...]                            one hop to the match
#   @db:migrate      -> App\Composer\Scripts::dbMigrate                     camelCase, hence -i
#
# A naive matcher therefore reports the very repository the hazard rule was written from as
# clean. This follows `@name` and `npm|pnpm|yarn run <name>` references within the same
# manifest, which are the forms that are mechanically resolvable, and flags anything else as
# unresolved rather than treating it as safe.
# RESULTS COME BACK IN GLOBALS, NOT ON STDOUT, and that is the whole point of the shape.
# An earlier version printed the chain and let the caller capture it with `$( )`. Command
# substitution runs in a SUBSHELL, so every CHAIN_UNRESOLVED=1 it set was discarded and the
# caller always read the initial 0 — which made the "a trail we cannot follow is not evidence
# of safety" escalation dead code. A migration hidden behind a code callback was therefore
# neutralised silently, with no human asked, which is the one decision the table says must
# never be made silently.
CHAIN_TEXT=''
CHAIN_UNRESOLVED=0
resolve_chain() {  # $1 = manifest path, $2 = dotted key; sets CHAIN_TEXT, CHAIN_UNRESOLVED
  local manifest=$1 key=$2 depth=0 maxdepth text pending next seen='' ref resolved leafpat
  CHAIN_TEXT=''
  CHAIN_UNRESOLVED=0
  maxdepth=$(wt_json_get chainMaxDepth <"$WT_DETECTION_JSON" 2>/dev/null) || maxdepth=''
  wt_is_seconds "$maxdepth" || maxdepth=5

  pending=$(manifest_value "$manifest" "$key")
  [ -n "$pending" ] || return 1
  text=$pending

  while [ "$depth" -lt "$maxdepth" ] && [ -n "$pending" ]; do
    depth=$((depth + 1))
    next=''
    # Composer-style `@name`, and npm-style `npm run name`. tr the punctuation that
    # surrounds them in a JSON array so the names come out as bare words.
    for ref in $(printf '%s' "$pending" | tr '[]{},"' '      ' \
                 | grep -oE '(@[A-Za-z0-9_:.-]+|(npm|pnpm|yarn)[[:space:]]+run[[:space:]]+[A-Za-z0-9_:.-]+)' 2>/dev/null \
                 | sed -E 's/^(npm|pnpm|yarn)[[:space:]]+run[[:space:]]+//; s/^@//'); do
      case " $seen " in *" $ref "*) continue ;; esac
      seen="$seen $ref"
      # A script name containing a dot cannot be addressed by the dotted-path JSON layer.
      case $ref in
        *.*) CHAIN_UNRESOLVED=1; continue ;;
      esac
      resolved=$(manifest_value "$manifest" "scripts.$ref")
      if [ -n "$resolved" ]; then
        next="$next $resolved"
        text="$text -> $resolved"
      else
        CHAIN_UNRESOLVED=1
      fi
    done
    pending=$next
  done

  # Running out of depth budget is ALSO an unfollowable trail. Without this, a repository only
  # had to nest its migration one hop deeper than the budget to be reported as a
  # fully-followed, migration-free chain — and the emitted hazardChain record then asserted a
  # completeness the resolver never achieved.
  if [ -n "$pending" ]; then
    CHAIN_UNRESOLVED=1
    text="$text -> (unfollowed after $maxdepth hops: $pending)"
  fi

  # A leaf that is a code callback or a script path is a trail we cannot follow. The pattern
  # is anchored so `\.js` does not also swallow `.json` — `cp config.json.dist config.json`
  # is not an unfollowable trail.
  leafpat=$(wt_json_get unresolvedLeafPattern <"$WT_DETECTION_JSON" 2>/dev/null) || leafpat=''
  [ -n "$leafpat" ] || leafpat='::|\.(sh|php|js|mjs|cjs|rb|py)([[:space:]"'"'"']|$)|bin/'
  if printf '%s' "$text" | grep -qE "$leafpat" 2>/dev/null; then
    CHAIN_UNRESOLVED=1
  fi

  CHAIN_TEXT=$text
  return 0
}

# Judge the resolved chain against every escalation rule.
check_escalations() {  # $1 = dep index, $2 = hazard id, $3 = chain text
  local n=$1 hid=$2 chain=$3 e_id e_action e_pat e_ci e_why e_unres e_unwhy
  local fb_id='' fb_action='' fb_why='' matched
  # EVERY pattern is tested before the unresolved fallback is used. Returning on the first
  # rule that merely carries an unresolvedAction would report that rule's id and reason for a
  # chain that actually matched a LATER rule's pattern — the wrong reason for the right alarm.
  while IFS=$WT_US read -r -d "$WT_RS" e_id e_action e_pat e_ci e_why e_unres e_unwhy; do
    matched=0
    if [ -n "$e_pat" ]; then
      if [ "$e_ci" = true ]; then
        printf '%s' "$chain" | grep -qiE "$e_pat" 2>/dev/null && matched=1
      else
        printf '%s' "$chain" | grep -qE "$e_pat" 2>/dev/null && matched=1
      fi
    fi
    if [ "$matched" = 1 ]; then
      emit escalate "$n" "$e_id" "${e_action:-refuse-and-ask}" "$e_why"
      return 0
    fi
    if [ -z "$fb_id" ] && [ -n "$e_unres" ]; then
      fb_id=$e_id; fb_action=$e_unres; fb_why=$e_unwhy
    fi
  done < <(wt_json_records escalations id action pattern caseInsensitive reason \
           resolveIndirection.unresolvedAction resolveIndirection.unresolvedReason \
           <"$WT_DETECTION_JSON")

  # A trail that cannot be followed is not evidence of safety — but it is not evidence of
  # DANGER either, and reporting it under the same label as a real pattern match would be a
  # false claim. Almost every composer post-install chain ends in a code callback, so that
  # conflation would fire on nearly every repository and the alarm would stop meaning
  # anything. Different label, different action: the developer still gets asked, but is told
  # honestly which of the two they are looking at.
  if [ "$CHAIN_UNRESOLVED" = 1 ] && [ -n "$fb_id" ]; then
    emit unreadable "$n" "$fb_id" "$fb_action" "$fb_why"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Corroboration: cite it, never import it
# ---------------------------------------------------------------------------
# Where the repository has already answered the same question in something that gets
# exercised, say so — "your own CI already passes --no-scripts" is independent confirmation
# and far more convincing than a rule from a table. The FLAGS are never imported: CI
# optimises for a throwaway machine running one job, and its --no-dev / --filter would leave
# a development worktree with no dev dependencies and half a workspace.

# How many files to cite per dependency before summarising. A real repository invokes
# composer in thirteen workflows; thirteen near-identical lines bury the one fact that
# matters, which is WHAT they agree on.
CORROBORATE_MAX=3
KEEP_FLAGS=''

corroborate() {  # $1 = dep index, $2 = the proposed install command
  local n=$1 install=$2 tool src f rel cited=0 total=0 flags='' fileflags first='' fl
  tool=${install%% *}
  [ -n "$tool" ] || return 0

  KEEP_FLAGS=$(json_array_items "$(wt_json_get corroboration.keepFlags.flags <"$WT_DETECTION_JSON")" | tr '\n' ' ')

  while IFS= read -r src; do
    [ -n "$src" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      rel=${f#"$ROOT"/}
      fileflags=$(tool_flags_in "$tool" "$rel") || continue
      total=$((total + 1))
      [ -z "$first" ] && first=$rel
      for fl in $fileflags; do
        case " $flags " in *" $fl "*) ;; *) flags="$flags $fl" ;; esac
      done
      if [ "$cited" -lt "$CORROBORATE_MAX" ]; then
        if [ -n "$fileflags" ]; then
          emit corroborate "$n" "$rel" \
            "this repo's own $tool invocation here passes${fileflags} — independent confirmation, and those are safety flags to KEEP, never to strip"
        else
          emit corroborate "$n" "$rel" "this repo invokes $tool here too; compare, but do not import CI-only flags"
        fi
        cited=$((cited + 1))
      fi
    done < <(corroborate_candidates "$src")
  done < <(json_array_items "$(wt_json_get corroboration.sources <"$WT_DETECTION_JSON")")

  if [ "$total" -gt "$cited" ]; then
    if [ -n "$flags" ]; then
      emit corroborate "$n" "($((total - cited)) more)" \
        "$total files in this repo invoke $tool, and across them these safety flags appear:${flags} — strong corroboration, and none of them may be stripped"
    else
      emit corroborate "$n" "($((total - cited)) more)" \
        "$total files in this repo invoke $tool; none of them pass a safety flag, so there is nothing here to corroborate a hazard decision"
    fi
  fi
  return 0
}

# The files a corroboration source expands to. A directory (.github/workflows) is searched
# one level down; anything else is taken literally.
# One path per line, so the caller can read them with `read -r` — an unquoted command
# substitution word-split them, so a workflow named `a b.yml` became two bogus paths and one
# literally named `*` re-expanded its own directory.
#
# Symlinks are refused rather than followed. A repo with `.github/workflows` symlinked outside
# the checkout would otherwise have files from outside cited as this repository's own CI
# evidence — corroboration that looks like the repo agreeing with itself when it does not.
corroborate_candidates() {  # $1 = source entry
  local src=$1 f real
  if [ -L "$ROOT/$src" ]; then
    wt_log "ignoring the corroboration source $src because it is a symlink"
    return 0
  fi
  if [ -d "$ROOT/$src" ]; then
    real=$(cd "$ROOT/$src" && pwd -P) || return 0
    case $real/ in
      "$ROOT"/*) ;;
      *) wt_log "ignoring the corroboration source $src because it resolves outside the repository"; return 0 ;;
    esac
    for f in "$ROOT/$src"/*; do
      [ -f "$f" ] || continue
      [ -L "$f" ] && continue
      printf '%s\n' "$f"
    done
  elif [ -f "$ROOT/$src" ]; then
    printf '%s\n' "$ROOT/$src"
  fi
}

# The keepFlags present ON THE LINES THAT INVOKE $1, not merely somewhere in the file.
# Measured on a real repository: matching the whole file credited pnpm with composer's
# --no-scripts, because both tools appear in one workflow. Returns 1 when the tool is not
# invoked in the file at all.
tool_flags_in() {  # $1 = tool, $2 = repo-relative file
  local tool=$1 rel=$2 lines found='' fl
  lines=$(grep -F "$tool " "$ROOT/$rel" 2>/dev/null) || return 1
  [ -n "$lines" ] || return 1
  for fl in $KEEP_FLAGS; do
    case $lines in *"$fl"*) found="$found $fl" ;; esac
  done
  printf '%s' "$found"
  return 0
}

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
# First match wins PER MARKER, then at most one entry per target directory.

CLAIMED_MARKERS=' '
CLAIMED_DIRS=' '
MATCHED_MARKERS=' '
N=0

claimed() {  # $1 = list, $2 = needle
  case "$1" in *" $2 "*) return 0 ;; esac
  return 1
}

# One pass of the dependency rules over the directory $1 — '' for the repository root, or a
# repo-relative directory ending in `/` for a nested project with its own lockfile. Every path the
# rules name is taken relative to it, so a nested composer project is judged exactly as the root one
# is: same strategy, same hazards, same escalations.
detect_deps_in() {  # $1 = directory prefix
  local pre=${1-} d_markers d_dir d_strategy d_install d_verify d_reason d_hazards d_when d_requires
  local d_fallback d_notes marker m strategy fallback install verify hid h_manifest h_probes h_action
  local h_flag h_why x_id x_manifest x_probes x_action x_flag x_why hit probed pkey
  while IFS=$WT_US read -r -d "$WT_RS" \
        d_markers d_dir d_strategy d_install d_verify d_reason d_hazards \
        d_when d_requires d_fallback d_notes; do
  
    marker=''
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      [ -e "$ROOT/$pre$m" ] || continue
      claimed "$CLAIMED_MARKERS" "$pre$m" && continue
      marker=$m
      break
    done < <(json_array_items "$d_markers")
    [ -n "$marker" ] || continue
  
    # A guarded rule — Yarn Berry — only applies when its witness file is present. It sits
    # before the classic rule, so a Berry repo takes it and a classic repo falls through.
    if [ -n "$d_when" ] && [ ! -e "$ROOT/$pre$d_when" ]; then
      continue
    fi
  
    # A NESTED lockfile is proposed only on evidence that someone installs it there: its
    # directory exists in this checkout AND is gitignored, so a fresh worktree would lack it. A
    # tracked lockfile with no installed tree beside it is usually a test fixture, and a committed
    # dependency directory needs nothing from the plugin. Rules that populate a shared cache
    # outside the project (no `dir`) have nothing nested to provide.
    if [ -n "$pre" ]; then
      [ -n "$d_dir" ] || continue
      if [ ! -d "$ROOT/$pre$d_dir" ]; then
        NESTED_SKIPPED=$((NESTED_SKIPPED + 1))
        [ "$NESTED_SKIPPED" -le "$WT_NESTED_REPORT_MAX" ] && emit dropped "$pre$marker" "$pre$d_dir" \
          "a nested lockfile, but $pre$d_dir is not installed in this checkout — a fixture, or a tree nobody installs; not proposed"
        CLAIMED_MARKERS="$CLAIMED_MARKERS$pre$marker "
        continue
      fi
      # A JS WORKSPACE MEMBER is the root install's, even with a stray lockfile of its own: the root
      # install creates its node_modules, so a second entry would install over the root's tree —
      # the conflicting-owner case CLAIMED_DIRS exists to prevent. Which directories a workspace
      # covers is a glob list; rather than evaluate it, any nested JS tree in a repo that declares a
      # workspace is dropped, with the reason, for the developer to overrule.
      case ${d_dir##*/} in
        node_modules | cache)
          if [ "$JS_WORKSPACE" = 1 ]; then
            emit dropped "$pre$marker" "$pre$d_dir" \
              "the repository declares a JS workspace, whose root install may already populate $pre$d_dir — not proposed; add it by hand if it really is a separate project"
            CLAIMED_MARKERS="$CLAIMED_MARKERS$pre$marker "
            continue
          fi
          ;;
      esac
      if ! wt_git "$ROOT" check-ignore -q -- "$pre$d_dir" 2>/dev/null; then
        emit dropped "$pre$marker" "$pre$d_dir" \
          "a nested lockfile whose $pre$d_dir is not gitignored — it arrives with the checkout, so there is nothing to provide"
        CLAIMED_MARKERS="$CLAIMED_MARKERS$pre$marker "
        continue
      fi
    fi
  
    # At most one entry per target directory. Two rules claiming node_modules with opposite
    # strategies would make bootstrap hardlink a tree and then reinstall over it.
    if [ -n "$d_dir" ] && claimed "$CLAIMED_DIRS" "$pre$d_dir"; then
      emit dropped "$pre$marker" "$pre$d_dir" \
        "another lockfile already claims $pre$d_dir; two entries for one directory would conflict, so this repo appears to have more than one live lockfile for it"
      CLAIMED_MARKERS="$CLAIMED_MARKERS$pre$marker "
      continue
    fi
  
    strategy=$d_strategy
    # `hardlink` only means anything when the directory really exists here. For poetry, pipenv
    # and bundler an in-project directory is OPT-IN rather than the default, so proposing
    # hardlink unconditionally would name a directory that is not there.
    if [ "$d_requires" = true ] && [ -n "$d_dir" ] && [ ! -d "$ROOT/$pre$d_dir" ]; then
      fallback=${d_fallback:-install}
      emit depDowngrade "$N" "$d_strategy" "$fallback" \
        "$d_dir does not exist in this checkout, so there is nothing to hardlink — this tool only creates it in-project when explicitly configured to"
      strategy=$fallback
    fi
  
    CLAIMED_MARKERS="$CLAIMED_MARKERS$pre$marker "
    [ -n "$d_dir" ] && CLAIMED_DIRS="$CLAIMED_DIRS$pre$d_dir "
    # The toolchain probes key on the BARE marker, so a tool whose only lockfile is nested is still
    # probed — an install that fails in every worktree must not go unwarned just because it is not at
    # the root. The probe loop runs each tool once however many entries matched it.
    claimed "$MATCHED_MARKERS" "$marker" || MATCHED_MARKERS="$MATCHED_MARKERS$marker "
  
    # Hazards are applied to the install command BEFORE it is emitted, so what the developer
    # sees proposed is what would actually run.
    install=$d_install
    while IFS= read -r hid; do
      [ -n "$hid" ] || continue
      h_manifest='' h_probes='' h_action='' h_flag='' h_why=''
      while IFS=$WT_US read -r -d "$WT_RS" x_id x_manifest x_probes x_action x_flag x_why; do
        [ "$x_id" = "$hid" ] || continue
        h_manifest=$x_manifest; h_probes=$x_probes; h_action=$x_action
        h_flag=$x_flag; h_why=$x_why
        break
      done < <(wt_json_records hazards id manifest probes action neutralise reason <"$WT_DETECTION_JSON")
      [ -n "$h_action" ] || continue
      [ -n "$h_manifest" ] && h_manifest=$pre$h_manifest
      [ -n "$h_manifest" ] && [ ! -e "$ROOT/$h_manifest" ] && continue
  
      # EVERY probe key, not one. `composer install` fires pre-install-cmd,
      # post-install-cmd, post-autoload-dump and the post-package-* hooks, and a framework repo
      # conventionally hangs its migration off post-autoload-dump — so probing a single key
      # reported such a repo as clean and proposed a plain install that would migrate the
      # shared database.
      # An EMPTY probes list means "this hazard needs no probing" — its mere manifest being
      # present is the finding, which is how a Rakefile-based rule works. Requiring a probe hit
      # unconditionally dropped such a rule entirely, so it was unreachable and the developer was
      # never told the install command may wrap a schema load.
      hit=0 probed=0
      while IFS= read -r pkey; do
        [ -n "$pkey" ] || continue
        probed=1
        [ -n "$h_manifest" ] || continue
        resolve_chain "$ROOT/$h_manifest" "$pkey" || continue
        [ -n "$CHAIN_TEXT" ] || continue
        hit=1
        emit hazardChain "$N" "$pkey: $CHAIN_TEXT"
        check_escalations "$N" "$hid" "$CHAIN_TEXT"
      done < <(json_array_items "$h_probes")
      if [ "$probed" = 1 ] && [ "$hit" = 0 ]; then
        # Keys were probed and none of them exist in this manifest: nothing to report.
        continue
      fi
  
      case $h_action in
        neutralise)
          if [ -n "$h_flag" ]; then
            case " $install " in
              *" $h_flag "*) ;;
              *) install="$install $h_flag" ;;
            esac
          fi
          emit hazard "$N" "$hid" neutralise "$h_flag" "$h_why"
          ;;
        *) emit hazard "$N" "$hid" "$h_action" "$h_flag" "$h_why" ;;
      esac
    done < <(json_array_items "$d_hazards")
  
    # A nested entry's commands run from the worktree ROOT, like every other entry's, so they are
    # prefixed with a `cd` into their own directory. The prefix passed a conservative character set
    # before it got here, so single-quoting it is exact.
    verify=$d_verify
    if [ -n "$pre" ]; then
      install="cd '${pre%/}' && $install"
      [ -n "$verify" ] && verify="cd '${pre%/}' && $verify"
    fi
    emit dep "$N" "$pre$d_dir" "$pre$marker" "$strategy" "$install" "$verify"
    emit depReason "$N" "$d_reason"
    [ -n "$d_notes" ] && emit depNote "$N" "$d_notes"
    if [ -n "$pre" ]; then
      emit depNote "$N" "nested: ${pre%/} has its own lockfile and an installed, gitignored $d_dir, so a root install does not provide it"
    else
      # Corroboration cites CI lines that invoke the ROOT install; a nested project's install line
      # would be credited with the root's flags.
      corroborate "$N" "$install"
    fi
  
    N=$((N + 1))
  done < <(wt_json_records deps markers dir strategy install verify reason hazards \
           when.exists requiresDir fallbackStrategy notes <"$WT_DETECTION_JSON")
}

detect_deps_in ''

# ---------------------------------------------------------------------------
# Nested projects with their own lockfile
# ---------------------------------------------------------------------------
# Detection used to match root markers only, on the assumption that a root install populates the
# nested trees. That holds for a workspace — one root lockfile, installed once — and fails for a
# nested project that keeps its OWN lockfile outside any workspace, which a root install does not
# touch (a tool-per-
# directory composer layout, a sub-project with its own package-lock). Such projects are found
# through `git ls-files`, so an ignored tree — a node_modules full of other people's lockfiles —
# is never walked and an untracked scratch directory is never proposed.

WT_NESTED_MAX=${WT_NESTED_MAX:-32}
JS_WORKSPACE=0
if [ -e "$ROOT/pnpm-workspace.yaml" ] || grep -qs '"workspaces"[[:space:]]*:' "$ROOT/package.json"; then
  JS_WORKSPACE=1
fi
WT_NESTED_REPORT_MAX=10
NESTED_SKIPPED=0
if [ "$IS_GIT" = 1 ]; then
  ALL_MARKERS=' '
  while IFS=$WT_US read -r -d "$WT_RS" d_markers; do
    while IFS= read -r m; do
      [ -n "$m" ] && ALL_MARKERS="$ALL_MARKERS$m "
    done < <(json_array_items "$d_markers")
  done < <(wt_json_records deps markers <"$WT_DETECTION_JSON")
  nested=0
  while IFS= read -r pre; do
    [ -n "$pre" ] || continue
    nested=$((nested + 1))
    if [ "$nested" -gt "$WT_NESTED_MAX" ]; then
      warn "more than $WT_NESTED_MAX nested directories carry their own lockfile — only the first $WT_NESTED_MAX were considered; list any others in deps[] by hand"
      break
    fi
    case $pre in
      -* | *[!A-Za-z0-9._/@+-]*)
        warn "the nested lockfile directory \"$pre\" has characters this detection will not put in a command — add it to deps[] by hand if it needs installing"
        continue
        ;;
    esac
    detect_deps_in "$pre/"
  done < <(wt_git "$ROOT" ls-files -z 2>/dev/null | tr '\0' '\n' | while IFS= read -r f; do
             case $f in */*) ;; *) continue ;; esac
             claimed "$ALL_MARKERS" "${f##*/}" && printf '%s\n' "${f%/*}"
           done | LC_ALL=C sort -u)
  if [ "$NESTED_SKIPPED" -gt "$WT_NESTED_REPORT_MAX" ]; then
    warn "$NESTED_SKIPPED nested lockfiles have no installed tree beside them (fixtures, most likely); only the first $WT_NESTED_REPORT_MAX are listed"
  fi
fi

if [ "$N" = 0 ]; then
  warn "no dependency lockfile recognised in $ROOT — the profile will have no deps[], which is valid"
fi

# ---------------------------------------------------------------------------
# Toolchain probes
# ---------------------------------------------------------------------------
# One bounded version check per detected tool. Seconds, no side effects, nothing installed.
# This catches the largest real class of "the profile looks right and is wrong": a wrong
# wrapper, or a toolchain simply absent from the host.
#
# Deliberately NOT a trial install. That costs minutes on a real repository, and an install
# that migrates the shared database exits 0 — so the dangerous variant is exactly the one
# that would pass. Phase 6 owns the real run.

probe_tool() {  # $1 = tool, $2 = version arguments
  local tool=$1 args=$2
  if [ -z "$SHELL_CMD" ]; then
    # </dev/null so the probed command cannot read the caller's stdin. Measured: the probe
    # loop reads its records from a process substitution on stdin, so a tool that reads stdin
    # — a wrapper prompting to trust a substituter, for instance — swallowed the remaining
    # probe records and later tools vanished from the output with no warning at all.
    ( cd "$ROOT" && timeout "$PROBE_TIMEOUT" "$tool" "$args" ) </dev/null 2>&1
    return
  fi
  case $SHELL_ARGS in
    string)
      # nix-shell --run takes ONE argument. `nix-shell --run composer --version` would read
      # `--version` as another nix flag.
      # shellcheck disable=SC2086  # the wrapper is several words, split on purpose
      ( cd "$ROOT" && timeout "$PROBE_TIMEOUT" $SHELL_CMD "$tool $args" ) </dev/null 2>&1
      ;;
    *)
      # shellcheck disable=SC2086  # same
      ( cd "$ROOT" && timeout "$PROBE_TIMEOUT" $SHELL_CMD "$tool" "$args" ) </dev/null 2>&1
      ;;
  esac
}

# WT_SKIP_PROBES exists for the test suite and for a re-run on a repo whose toolchain is
# known good. It is the one part of detection whose result depends on the HOST rather than on
# the repository, so it is also the one part that cannot be asserted deterministically.
if [ -n "${WT_SKIP_PROBES:-}" ]; then
  emit warn "toolchain probes skipped (WT_SKIP_PROBES is set) — the shell wrapper is unverified"
fi

while IFS=$WT_US read -r -d "$WT_RS" p_marker p_tool p_args; do
  [ -n "${WT_SKIP_PROBES:-}" ] && break
  [ -n "$p_marker" ] && [ -n "$p_tool" ] || continue
  claimed "$MATCHED_MARKERS" "$p_marker" || continue
  if out=$(probe_tool "$p_tool" "$p_args"); then
    # The LAST non-empty line, not the first: a nix wrapper prints its own warnings ahead of
    # the command's output, so head -1 reported "Git tree is dirty" as the tool's version.
    emit probe "$p_tool" ok "$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
  else
    rc=$?
    if [ "$rc" = 124 ]; then
      # INCONCLUSIVE, not a failure. A cold nix flake evaluation measured over 60s on the
      # real repository, and calling that "the wrapper is wrong" sends the developer to fix
      # something that is not broken.
      emit probe "$p_tool" timeout "gave up after ${PROBE_TIMEOUT}s"
      warn "the $p_tool probe timed out after ${PROBE_TIMEOUT}s, which is INCONCLUSIVE rather than a failure — a cold nix or container evaluation can take longer than this. Re-run calibration once the toolchain is warm if you want the check."
    else
      emit probe "$p_tool" fail "$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
      if [ -n "$SHELL_CMD" ]; then
        warn "$p_tool did not run inside \"$SHELL_CMD\": either the wrapper is wrong for this repo or the toolchain is missing, and an install would fail the same way inside a worktree"
      else
        warn "$p_tool is not on PATH and no toolchain wrapper was detected, so installs would run on the host and fail the same way inside a worktree"
      fi
    fi
  fi
done < <(wt_json_records shellProbe.tools marker tool versionArgs <"$WT_DETECTION_JSON")

# ---------------------------------------------------------------------------
# Gitignored config a fresh checkout would miss
# ---------------------------------------------------------------------------
# Proposed as a .worktreeinclude, never as profile `copy` entries (ADR-007), and only when
# ACTUALLY gitignored — native copying applies the gitignored-only rule, so listing a
# tracked file there achieves nothing.

if [ "$IS_GIT" = 1 ]; then
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    for cand in "$ROOT"/$glob; do
      [ -e "$cand" ] || continue
      rel=${cand#"$ROOT"/}
      skip=0
      while IFS= read -r never; do
        [ -n "$never" ] || continue
        # shellcheck disable=SC2254  # the pattern is a glob from the detection table
        case $rel in $never) skip=1; break ;; esac
      done < <(json_array_items "$NEVER_GLOBS")
      [ "$skip" = 1 ] && continue
      wt_git "$ROOT" check-ignore -q "$rel" 2>/dev/null && emit config "$rel"
    done
  done < <(json_array_items "$(wt_json_get configCandidates.globs <"$WT_DETECTION_JSON")")
fi

# ---------------------------------------------------------------------------
# Layer 3: HINTS ONLY
# ---------------------------------------------------------------------------
# Nothing below concludes anything, and that is not caution for its own sake. Layer 3 is
# never inferred (ADR-006): nothing in a repository states that an env var selects a tenant
# database, and a wrong guess here does not produce a broken worktree — it corrupts a
# colleague's data. Every line is a `hint` for the skill to put beside a question.

scan_hints() {  # $1 = kind, $2 = ERE, $3 = dotted path to the source list
  local kind=$1 pat=$2 listpath=$3 f name
  [ -n "$pat" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$ROOT/$f" ] || continue
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      # A credential-shaped NAME is never offered as a runtime candidate. Found by running
      # this against a real repository, where the tenancy family matched a variable called
      # ACCOUNTING_CREDENTIAL_KEY: the name itself is not a leak, but a hint is a suggestion,
      # and suggesting that one invites a secret into a committed profile (ADR-008).
      if [ -n "$NEVER_HINT" ] && printf '%s' "$name" | grep -qE "$NEVER_HINT" 2>/dev/null; then
        continue
      fi
      emit hint "$kind" "$name" "$f"
      claimed "$HINT_NAMES" "$name" || HINT_NAMES="$HINT_NAMES$name "
    done < <(grep -ohE "$pat" "$ROOT/$f" 2>/dev/null | sort -u)
  done < <(json_array_items "$(wt_json_get "$listpath" <"$WT_DETECTION_JSON")")
}

HINT_NAMES=' '
scan_hints port "$(wt_json_get runtimeHints.portVarPattern <"$WT_DETECTION_JSON")" runtimeHints.portSources
scan_hints db   "$(wt_json_get runtimeHints.dbVarPattern   <"$WT_DETECTION_JSON")" runtimeHints.portSources

# Service names from a compose file, which is usually where a port collision lives.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$ROOT/$f" ] || continue
  while IFS= read -r svc; do
    [ -n "$svc" ] || continue
    emit hint service "$svc" "$f"
  done < <(sed -n 's/^  \([a-zA-Z0-9_.-]*\):[[:space:]]*$/\1/p' "$ROOT/$f" 2>/dev/null | sort -u)

  # WHAT NAMES THIS STACK, which decides whether two worktrees share it. With no top-level `name:`
  # and no COMPOSE_PROJECT_NAME, compose names the project after the DIRECTORY — so each worktree
  # starts a stack of its own, and every published host port collides with the main checkout's.
  # Whether that is wanted is the developer's call; this only says which case applies. The .env
  # files are asked only whether the variable is SET, never for its value.
  # Compose reads its own settings from the .env beside the compose file (or --env-file) and from
  # nothing else — not .env.local — so only that file is asked. A `name:` that interpolates a
  # variable is controllable from the environment, not fixed, so it reads as `env` too.
  cname=$(sed -n 's/^name:[[:space:]]*\([^#]*\).*/\1/p' "$ROOT/$f" 2>/dev/null | head -1)
  cname=$(printf '%s' "$cname" | sed 's/[[:space:]]*$//; s/^["'"'"']//; s/["'"'"']$//')
  fdir=$(dirname "$ROOT/$f")
  # SC2016: the `${` is a literal compose interpolation being looked for, not shell expansion.
  # shellcheck disable=SC2016
  case $cname in
    *'${'*) project='env' ;;
    ?*) project="explicit:$cname" ;;
    *)
      if grep -qsE '^[[:space:]]*(export[[:space:]]+)?COMPOSE_PROJECT_NAME=' "$fdir/.env"; then
        project='env'
      else
        project='directory'
      fi
      ;;
  esac
  # PUBLISHED HOST PORTS, counted only inside a `ports:` block — an environment entry like
  # `- REDIS_URL=redis://cache:6379` also ends in `:<digits>` and publishes nothing. Short syntax
  # counts an item that names a host side (`"8080:8080"`, `"127.0.0.1:${APP_PORT:-8080}:8080"`;
  # a bare `"3000"` gets a random host port and cannot collide); long syntax counts `published:`.
  published=$(awk '
    function indent(l) { match(l, /^[ ]*/); return RLENGTH }
    /^[ ]*#/ || /^[ ]*$/ { next }
    inblock && indent($0) <= bindent { inblock = 0 }
    /^[ ]*ports:[ ]*$/ { inblock = 1; bindent = indent($0); next }
    inblock && /^[ ]*-[ ]*"?[^"# ]*[0-9}]:[0-9]+(\/[a-z]+)?"?[ ]*(#.*)?$/ && $0 !~ /=/ { n++ ; next }
    inblock && /^[ ]*(- )?published:/ { n++ }
    END { print n + 0 }' "$ROOT/$f" 2>/dev/null)
  emit compose "$f" "$project" "${published:-0}"
done < <(json_array_items "$(wt_json_get runtimeHints.serviceSources <"$WT_DETECTION_JSON")")

# ---------------------------------------------------------------------------
# Inline assignments that would bypass the overrides
# ---------------------------------------------------------------------------
# A `NAME=value` written into the repo's own commands — its agent guide, README, Makefile, manifest
# scripts — sets NAME in the PROCESS environment, which beats every dotenv file the plugin writes
# into. A session that follows those instructions inside a worktree then runs against whatever the
# instructions pinned, usually the shared state. Only names already offered as a port or database
# hint are looked for, so this reports on the variables calibration is about to ask about and on
# nothing else. One record per name and file: how often, and the first place it appears.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$ROOT/$f" ] || continue
  for name in $HINT_NAMES; do
    hits=$(grep -nE "(^|[^A-Za-z0-9_])$name=[^[:space:]=]" "$ROOT/$f" 2>/dev/null) || continue
    count=$(printf '%s\n' "$hits" | grep -c .)
    first=$(printf '%s\n' "$hits" | head -1 | cut -c1-160)
    emit assign "$name" "$f" "$count" "$first"
  done
done < <(json_array_items "$(wt_json_get runtimeHints.assignSources <"$WT_DETECTION_JSON")")

# ---------------------------------------------------------------------------
# The plugin's own paths inside a checkout
# ---------------------------------------------------------------------------
# Each must be gitignored. An untracked one is work to the teardown guard, so the worktree it sits
# in is never torn down; a committed opt-out marker turns layer 3 off for everyone.
if [ "$IS_GIT" = 1 ]; then
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if wt_git "$ROOT" check-ignore -q -- "$p" 2>/dev/null; then
      emit ignore "$p" ok
    else
      emit ignore "$p" missing
    fi
  done < <(json_array_items "$(wt_json_get runtimeHints.pluginPaths <"$WT_DETECTION_JSON")")
fi

exit 0
