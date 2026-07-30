#!/usr/bin/env bash
#
# Exercises every function in hooks/scripts/lib.sh.
#
# Runs the whole suite once per available JSON backend (jq and python3), because the two
# implementations of wt_json_get have to be byte-identical and the only way to keep them
# that way is to test both. The machine this plugin was written on has python3 and no jq,
# so without WT_JSON_BACKEND the jq branch would never have been executed at all.
#
#   tests/test_lib.sh                            # every backend present on this machine
#   nix shell nixpkgs#jq -c tests/test_lib.sh    # ...including jq, if it isn't installed
#
# By default a missing backend is a FAILURE, not a skip: a suite whose whole purpose is
# cross-backend parity must not report success having silently tested one side. Set
# WT_TEST_ALLOW_MISSING_BACKEND=1 to downgrade that to a warning.
#
# Note the parity guarantee is jq >= 1.7: older jq routed all numbers through doubles,
# so `1.0` came back as `1` and large integers in exponent notation.
#
# Deliberately not `set -e`: a failed assertion must not stop the remaining ones, or a
# single break hides everything after it.
set -uo pipefail

LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")/../hooks/scripts" && pwd)/lib.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 backends_run=0
US=$'\037'
RS=$'\036'

eq() {  # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s] %s\n      expected: %q\n      actual:   %q\n' "$BACKEND" "$1" "$2" "$3" >&2
  fi
}

rc_is() { eq "$1" "$2" "$3"; }  # $1 = label, $2 = expected rc, $3 = actual rc

ne() {  # $1 = label, $2, $3 = values that must differ
  if [ "$2" != "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL [%s] %s\n      both were: %q\n' "$BACKEND" "$1" "$2" >&2
  fi
}

contains() {  # $1 = label, $2 = needle, $3 = haystack
  case $3 in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1))
       printf 'FAIL [%s] %s\n      expected to contain: %q\n      actual: %q\n' \
         "$BACKEND" "$1" "$2" "$3" >&2 ;;
  esac
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

PAYLOAD='{"name":"colleague/QT-999","cwd":"/some/dir","blocking":true,"quiet":false,
          "count":7,"big":12345678901234567890,"float":1.5,"neg":-3,
          "tool_input":{"file_path":"/a/b.php"},"nested":{"deep":{"k":"v"}},
          "obj":{"a":1},"arr":[1,2],"emptyobj":{},"emptyarr":[],
          "uni":{"a":"café"},"unistr":"café",
          "str":"hello","nul":null,"empty":""}'

cat >"$TMP/profile-v1.json" <<'JSON'
{
  "schemaVersion": 1,
  "shell": "nix develop --command",
  "copy": [],
  "deps": [{"dir":"vendor","lock":"composer.lock","strategy":"hardlink"}],
  "runtime": {"slug":"{name}","port":{"var":"SERVER_PORT","base":3786,"span":200}},
  "timeouts": {"bootstrapSeconds": 900, "seedSeconds": 120}
}
JSON

printf '\xef\xbb\xbf{"schemaVersion":1,"shell":"bom-survived"}' >"$TMP/profile-bom.json"
printf '{ "schemaVersion": 99, "shell": "should-be-ignored" }'  >"$TMP/profile-v99.json"
printf '{ "shell": "should-be-ignored" }'                       >"$TMP/profile-noversion.json"
printf '{ this is not json'                                     >"$TMP/profile-broken.json"
printf '{ "schemaVersion": 1 }'                                 >"$TMP/profile-minimal.json"
printf '{ "schemaVersion": 1, "runtime": false }'               >"$TMP/profile-runtime-false.json"
printf '{ "schemaVersion": 1, "runtime": {} }'                  >"$TMP/profile-runtime-empty.json"
printf '{ "schemaVersion": 1, "timeouts": {"bootstrapSeconds": 0, "seedSeconds": "abc"} }' \
  >"$TMP/profile-bad-timeouts.json"
printf '{ "schemaVersion": 1, "timeouts": {"bootstrapSeconds": -5, "seedSeconds": "1; touch %s/pwned"} }' \
  "$TMP" >"$TMP/profile-hostile-timeouts.json"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Plain repo with a linked worktree, for wt_repo_root vs wt_main_root.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
printf 'x\n' >"$REPO/f"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init
git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/wt" -b worktree-wt >/dev/null 2>&1
WT="$REPO/.claude/worktrees/wt"

# A --separate-git-dir repo: its common dir is NOT <root>/.git, which is what broke the
# rev-parse --git-common-dir implementation of wt_main_root.
SEP="$TMP/sep"
SEPGIT="$TMP/sepgit"
mkdir -p "$SEP"
git -C "$SEP" init -q -b main --separate-git-dir="$SEPGIT" >/dev/null 2>&1
printf 'x\n' >"$SEP/f"
git -C "$SEP" add -A
git -C "$SEP" commit -qm init
git -C "$SEP" worktree add -q "$SEP/.claude/worktrees/w" -b worktree-w >/dev/null 2>&1
SEPWT="$SEP/.claude/worktrees/w"

# A submodule: its common dir is <super>/.git/modules/<name>. Getting {root} wrong here
# would make Phase 3 write dependency trees inside git's own metadata.
SUPER="$TMP/super"
mkdir -p "$SUPER"
git -C "$SUPER" init -q -b main
printf 'x\n' >"$SUPER/f"
git -C "$SUPER" add -A
git -C "$SUPER" commit -qm init
git -C "$SUPER" -c protocol.file.allow=always submodule add -q "$REPO" sub >/dev/null 2>&1
git -C "$SUPER" commit -qm sub >/dev/null 2>&1
SUB="$SUPER/sub"

# ---------------------------------------------------------------------------
# The suite, run once per backend
# ---------------------------------------------------------------------------

run_suite() {
  # Fresh shell state each time: lib.sh has a double-source guard.
  unset WT_LIB_SOURCED WT_INPUT_READ HOOK_INPUT
  # shellcheck source-path=SCRIPTDIR/../hooks/scripts
  # shellcheck source=lib.sh
  . "$LIB"

  local out err got

  # --- wt_log ---------------------------------------------------------------
  out=$(wt_log "hello" 2>/dev/null)
  eq 'wt_log writes nothing to stdout' '' "$out"
  err=$(wt_log "hello" 2>&1 >/dev/null)
  eq 'wt_log writes a prefixed line to stderr' 'worktree: hello' "$err"
  err=$(wt_log "one
two" 2>&1 >/dev/null)
  eq 'wt_log prefixes EVERY line, not just the first' 'worktree: one
worktree: two' "$err"
  err=$(wt_log "" 2>&1 >/dev/null)
  eq 'wt_log of an empty string is one bare prefix' 'worktree: ' "$err"

  # --- backend selection ----------------------------------------------------
  wt_has_json
  rc_is 'wt_has_json true when a backend exists' 0 $?
  if [ "$BACKEND" = python3 ]; then
    wt_use_jq
    rc_is 'wt_use_jq false when WT_JSON_BACKEND=python3' 1 $?
  else
    wt_use_jq
    rc_is 'wt_use_jq true on the jq backend' 0 $?
  fi

  # --- wt_read_field --------------------------------------------------------
  eq 'read_field string'          'colleague/QT-999' "$(wt_read_field name "$PAYLOAD")"
  eq 'read_field nested one deep' '/a/b.php'         "$(wt_read_field tool_input.file_path "$PAYLOAD")"
  eq 'read_field nested two deep' 'v'                "$(wt_read_field nested.deep.k "$PAYLOAD")"
  eq 'read_field true is lowercase'  'true'  "$(wt_read_field blocking "$PAYLOAD")"
  eq 'read_field false is lowercase' 'false' "$(wt_read_field quiet "$PAYLOAD")"
  eq 'read_field integer'         '7'        "$(wt_read_field count "$PAYLOAD")"
  eq 'read_field negative'        '-3'       "$(wt_read_field neg "$PAYLOAD")"
  eq 'read_field float'           '1.5'      "$(wt_read_field float "$PAYLOAD")"
  eq 'read_field object is compact json' '{"a":1}' "$(wt_read_field obj "$PAYLOAD")"
  eq 'read_field array is compact json'  '[1,2]'   "$(wt_read_field arr "$PAYLOAD")"
  eq 'read_field empty object'    '{}'       "$(wt_read_field emptyobj "$PAYLOAD")"
  eq 'read_field empty array'     '[]'       "$(wt_read_field emptyarr "$PAYLOAD")"
  # ensure_ascii=False: python's json.dumps escapes non-ASCII by default, jq does not.
  # Without the flag these two backends disagree byte-for-byte on any non-ASCII value.
  eq 'read_field non-ascii inside an object is not \u-escaped' '{"a":"café"}' \
    "$(wt_read_field uni "$PAYLOAD")"
  eq 'read_field non-ascii string' 'café' "$(wt_read_field unistr "$PAYLOAD")"

  wt_read_field missing "$PAYLOAD" >/dev/null
  rc_is 'read_field missing returns 1' 1 $?
  wt_read_field nul "$PAYLOAD" >/dev/null
  rc_is 'read_field null returns 1' 1 $?
  wt_read_field empty "$PAYLOAD" >/dev/null
  rc_is 'read_field empty string returns 1' 1 $?
  wt_read_field 'a.b.c.d' "$PAYLOAD" >/dev/null
  rc_is 'read_field deep miss returns 1' 1 $?
  # A path that descends THROUGH a scalar: jq's getpath raises here, hence the try/catch.
  wt_read_field 'str.nope' "$PAYLOAD" >/dev/null
  rc_is 'read_field through a scalar returns 1' 1 $?
  eq 'read_field through a scalar prints nothing' '' "$(wt_read_field 'str.nope' "$PAYLOAD")"
  wt_read_field name '' >/dev/null
  rc_is 'read_field with empty json returns 1' 1 $?
  wt_read_field name 'not json at all' >/dev/null
  rc_is 'read_field with unparseable json returns 1' 1 $?
  # An empty path is where the backends used to diverge outright: jq's "" | split(".")
  # is [], and getpath([]) returns the WHOLE DOCUMENT as if it were a field value.
  wt_read_field '' "$PAYLOAD" >/dev/null
  rc_is 'read_field with an empty path returns 1' 1 $?
  eq 'read_field with an empty path prints nothing' '' "$(wt_read_field '' "$PAYLOAD")"
  # A field name that would have broken the reference implementation's interpolated
  # jq filter / python source.
  eq 'read_field quote-bearing name is data, not code' '' "$(wt_read_field 'a"; print(1)#' "$PAYLOAD")"

  # --- wt_json_get, multi-field ---------------------------------------------
  eq 'json_get returns N fields US-separated in order' \
    "hello${US}7${US}${US}v" \
    "$(printf '%s' "$PAYLOAD" | wt_json_get str count missing nested.deep.k)"
  wt_json_get >/dev/null 2>&1 </dev/null
  rc_is 'json_get with no paths returns 1' 1 $?

  # --- wt_read_input --------------------------------------------------------
  # stdin can only be consumed once; wt_read_input must cache it.
  got=$(printf '%s' "$PAYLOAD" | (wt_read_input; wt_read_input; wt_read_field name))
  eq 'read_input caches stdin so a second read still works' 'colleague/QT-999' "$got"
  got=$(printf '%s' "$PAYLOAD" | (wt_read_input; bash -c ". '$LIB'; wt_read_input; wt_read_field name"))
  eq 'read_input exports the payload so a child does not re-read stdin' 'colleague/QT-999' "$got"
  # An unguarded `cat` blocks forever on an open-but-not-closed stdin; the [ -t 0 ] guard
  # is what stops a hook run from a terminal hanging the session. 124 = timeout fired.
  timeout 3 bash -c ". '$LIB'; wt_read_input" </dev/null >/dev/null 2>&1
  rc_is 'read_input on closed stdin returns promptly' 0 $?

  # --- wt_read_file_field ---------------------------------------------------
  eq 'read_file_field scalar' 'nix develop --command' \
    "$(wt_read_file_field "$TMP/profile-v1.json" shell)"
  eq 'read_file_field nested number' '900' \
    "$(wt_read_file_field "$TMP/profile-v1.json" timeouts.bootstrapSeconds)"
  eq 'read_file_field empty array is compact json' '[]' \
    "$(wt_read_file_field "$TMP/profile-v1.json" copy)"
  wt_read_file_field "$TMP/nope.json" shell >/dev/null
  rc_is 'read_file_field missing file returns 1' 1 $?
  wt_read_file_field "$TMP/profile-broken.json" shell >/dev/null
  rc_is 'read_file_field broken json returns 1' 1 $?
  wt_read_file_field "$TMP" shell >/dev/null
  rc_is 'read_file_field on a directory returns 1' 1 $?
  # A UTF-8 BOM is accepted by jq, so python must accept it too or the two backends
  # disagree about whether a committed profile exists at all.
  eq 'read_file_field tolerates a UTF-8 BOM' 'bom-survived' \
    "$(wt_read_file_field "$TMP/profile-bom.json" shell)"

  # --- wt_repo_root / wt_main_root ------------------------------------------
  eq 'repo_root in the main checkout'  "$REPO" "$(wt_repo_root "$REPO")"
  eq 'repo_root inside a worktree is the worktree' "$WT" "$(wt_repo_root "$WT")"
  eq 'main_root in the main checkout'  "$REPO" "$(wt_main_root "$REPO")"
  eq 'main_root inside a worktree is the MAIN checkout' "$REPO" "$(wt_main_root "$WT")"
  # --git-common-dir would answer "$SEPGIT" here, and "$SUPER/.git/modules/sub" below —
  # both a path inside the git directory, returned with a success code.
  eq 'main_root with --separate-git-dir is the worktree, not the git dir' \
    "$SEP" "$(wt_main_root "$SEP")"
  eq 'main_root in a submodule is the submodule checkout, not .git/modules' \
    "$SUB" "$(wt_main_root "$SUB")"
  # A linked worktree of a --separate-git-dir repo has NO correct answer available: git
  # itself reports the git dir as the main worktree. Failing is the contract, because a
  # confidently wrong {root} is what would hardlink dependencies into .git.
  wt_main_root "$SEPWT" >/dev/null 2>&1
  rc_is 'main_root fails rather than guess for a separate-git-dir worktree' 1 $?
  err=$(wt_main_root "$SEPWT" 2>&1 >/dev/null)
  contains 'that failure is explained' 'cannot locate the main checkout' "$err"
  eq 'main_root prints nothing when it fails' '' "$(wt_main_root "$SEPWT" 2>/dev/null)"
  wt_repo_root "$TMP/does-not-exist" >/dev/null
  rc_is 'repo_root on a missing dir returns 1' 1 $?
  wt_main_root "$TMP/does-not-exist" >/dev/null
  rc_is 'main_root on a missing dir returns 1' 1 $?
  wt_repo_root "$TMP" >/dev/null 2>&1
  rc_is 'repo_root outside a repo returns 1' 1 $?
  wt_main_root "$TMP" >/dev/null 2>&1
  rc_is 'main_root outside a repo returns 1' 1 $?
  eq 'repo_root does not emit a trailing newline' "$REPO" "$(wt_repo_root "$REPO" | od -c | head -1 >/dev/null; wt_repo_root "$REPO")"
  # `git -C` does NOT override an inherited GIT_DIR — and GIT_DIR is exported by every
  # git hook and by `git rebase --exec`, from which a user might well start claude.
  eq 'repo_root ignores an inherited GIT_DIR' "$SEP" \
    "$(GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" wt_repo_root "$SEP")"
  eq 'main_root ignores an inherited GIT_DIR' "$SEP" \
    "$(GIT_DIR="$REPO/.git" GIT_WORK_TREE="$REPO" wt_main_root "$SEP")"

  # --- wt_slugify -----------------------------------------------------------
  eq 'slugify documented example' 'colleague_qt_999' "$(wt_slugify 'colleague/QT-999')"
  eq 'slugify collapses runs'     'feature_ab_12'    "$(wt_slugify 'feature/AB--12')"
  eq 'slugify keeps underscores'  'a_b'              "$(wt_slugify 'a_b')"
  eq 'slugify trims edges'        'a'                "$(wt_slugify '--a--')"
  eq 'slugify is idempotent'      'colleague_qt_999' "$(wt_slugify "$(wt_slugify 'colleague/QT-999')")"
  eq 'slugify digits survive'     '1234'             "$(wt_slugify '1234')"
  eq 'slugify spaces'             'my_branch'        "$(wt_slugify 'My Branch')"
  eq 'slugify is stable across calls' "$(wt_slugify 'QT-1')" "$(wt_slugify 'QT-1')"
  # The slug keys a database name and a port, so distinct names must stay DISTINCT.
  # A shared 'wt' fallback would put every non-ASCII-named worktree on one database.
  local s_ja s_ko s_slash s_dash s_empty
  s_ja=$(wt_slugify '日本'); s_ko=$(wt_slugify '한국')
  s_slash=$(wt_slugify '///'); s_dash=$(wt_slugify '-'); s_empty=$(wt_slugify '')
  case $s_ja in wt_[0-9]*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL [%s] slugify non-ascii falls back to a checksum: %q\n' "$BACKEND" "$s_ja" >&2 ;;
  esac
  ne 'two non-ascii names must not collide' "$s_ja" "$s_ko"
  ne '"///" and "-" must not collide' "$s_slash" "$s_dash"
  eq 'slugify fallback is deterministic' "$s_empty" "$(wt_slugify '')"

  # --- wt_expand ------------------------------------------------------------
  # shellcheck disable=SC2034  # read by wt_expand in the sourced lib
  WT_NAME='QT-999' WT_SLUG='qt_999' WT_PORT='3801' WT_PATH='/r/.claude/worktrees/x' WT_ROOT='/r'
  eq 'expand name'     'QT-999'  "$(wt_expand '{name}')"
  eq 'expand slug'     'qt_999'  "$(wt_expand '{slug}')"
  eq 'expand port'     '3801'    "$(wt_expand '{port}')"
  eq 'expand worktree' '/r/.claude/worktrees/x' "$(wt_expand '{worktree}')"
  eq 'expand root'     '/r'      "$(wt_expand '{root}')"
  eq 'expand mixed' 'demo_qt_999 on 3801 in /r' "$(wt_expand 'demo_{slug} on {port} in {root}')"
  eq 'expand repeats a placeholder' 'qt_999-qt_999' "$(wt_expand '{slug}-{slug}')"
  eq 'expand leaves an unknown placeholder alone' '{nope}' "$(wt_expand '{nope}')"
  # SC2016: the single quotes are the point — ${FOO} must reach wt_expand as literal text.
  # shellcheck disable=SC2016
  eq 'expand leaves a shell variable alone' '${FOO}' "$(wt_expand '${FOO}')"
  # shellcheck disable=SC2016
  eq 'expand leaves an awk program alone' 'awk {print $1}' "$(wt_expand 'awk {print $1}')"
  eq 'expand leaves an unclosed brace alone' 'a{name' "$(wt_expand 'a{name')"
  eq 'expand leaves a bare brace alone' 'a{' "$(wt_expand 'a{')"
  eq 'expand passes text through untouched' 'no placeholders' "$(wt_expand 'no placeholders')"
  eq 'expand of empty is empty' '' "$(wt_expand '')"
  eq 'expand mixes known and unknown' '/r and {other}' "$(wt_expand '{root} and {other}')"
  eq 'expand handles a doubled brace' '{QT-999}' "$(wt_expand '{{name}}')"
  # The reason wt_expand is a single left-to-right scan: a chain of ${s//} substitutions
  # would rescan the substituted value and let a worktree NAME inject a placeholder.
  # This MUST be a prefix assignment, not a subshell — inside ( ) the pass/fail counters
  # are incremented in a child and discarded, which made this assertion unable to fail.
  WT_NAME='{root}' eq 'expand never rescans a substituted value' '{root}' \
    "$(WT_NAME='{root}' wt_expand '{name}')"
  unset WT_NAME WT_SLUG WT_PORT WT_PATH WT_ROOT
  eq 'expand with unset values yields empty' '' "$(wt_expand '{name}{slug}{port}')"

  # --- wt_is_seconds --------------------------------------------------------
  wt_is_seconds 600;   rc_is 'is_seconds 600' 0 $?
  wt_is_seconds 1;     rc_is 'is_seconds 1' 0 $?
  wt_is_seconds 0;     rc_is 'is_seconds rejects 0 (timeout 0 means NO timeout)' 1 $?
  wt_is_seconds 000;   rc_is 'is_seconds rejects 000' 1 $?
  wt_is_seconds 010;   rc_is 'is_seconds accepts 010' 0 $?
  wt_is_seconds -5;    rc_is 'is_seconds rejects negative' 1 $?
  wt_is_seconds abc;   rc_is 'is_seconds rejects text' 1 $?
  wt_is_seconds '';    rc_is 'is_seconds rejects empty' 1 $?
  wt_is_seconds '1 2'; rc_is 'is_seconds rejects a space' 1 $?
  wt_is_seconds '1;x'; rc_is 'is_seconds rejects a shell metacharacter' 1 $?

  # --- wt_load_profile ------------------------------------------------------
  local pdir="$TMP/proj"
  mkdir -p "$pdir/.claude"
  local target="$pdir/.claude/worktree-profile.json"

  rm -f "$target"
  wt_load_profile "$pdir"
  rc_is 'load_profile returns 0 with no profile' 0 $?
  eq 'no profile -> not present'      '0'   "$PROFILE_PRESENT"
  eq 'no profile -> empty shell'      ''    "$PROFILE_SHELL"
  eq 'no profile -> no runtime'       '0'   "$PROFILE_HAS_RUNTIME"
  eq 'no profile -> default timeout'  '600' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'no profile -> path still reported' "$target" "$PROFILE_PATH"
  # A trailing slash on the root must not double up in a user-facing warning.
  wt_load_profile "$pdir/"
  eq 'load_profile normalises a trailing slash' "$target" "$PROFILE_PATH"

  cp "$TMP/profile-v1.json" "$target"
  wt_load_profile "$pdir"
  eq 'v1 profile -> present'       '1' "$PROFILE_PRESENT"
  eq 'v1 profile -> shell'         'nix develop --command' "$PROFILE_SHELL"
  eq 'v1 profile -> has runtime'   '1' "$PROFILE_HAS_RUNTIME"
  eq 'v1 profile -> timeouts read' '900' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'v1 profile -> seed timeout'  '120' "$PROFILE_SEED_TIMEOUT"
  eq 'v1 profile is silent' '' "$(wt_load_profile "$pdir" 2>&1 >/dev/null)"

  cp "$TMP/profile-minimal.json" "$target"
  wt_load_profile "$pdir"
  eq 'minimal profile -> present'         '1'   "$PROFILE_PRESENT"
  eq 'minimal profile -> no runtime'      '0'   "$PROFILE_HAS_RUNTIME"
  eq 'minimal profile -> default timeout' '600' "$PROFILE_BOOTSTRAP_TIMEOUT"

  # ADR-006: absent runtime means touch nothing. An explicit false or {} says the same.
  cp "$TMP/profile-runtime-false.json" "$target"
  wt_load_profile "$pdir"
  eq 'runtime:false -> no runtime' '0' "$PROFILE_HAS_RUNTIME"
  cp "$TMP/profile-runtime-empty.json" "$target"
  wt_load_profile "$pdir"
  eq 'runtime:{} -> no runtime' '0' "$PROFILE_HAS_RUNTIME"

  # timeout 0 means NO timeout, so a typo in a committed profile must not disarm the
  # one guard against a hanging bootstrap.
  cp "$TMP/profile-bad-timeouts.json" "$target"
  wt_load_profile "$pdir" 2>/dev/null
  eq 'bootstrapSeconds 0 falls back to the default'  '600' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'seedSeconds "abc" falls back to the default'   '600' "$PROFILE_SEED_TIMEOUT"
  err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
  contains 'a rejected timeout is reported' 'not a positive number of seconds' "$err"

  cp "$TMP/profile-hostile-timeouts.json" "$target"
  wt_load_profile "$pdir" 2>/dev/null
  eq 'negative bootstrapSeconds falls back'    '600' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'command-injecting seedSeconds falls back' '600' "$PROFILE_SEED_TIMEOUT"
  eq 'no command in a profile value was executed' '0' "$([ -e "$TMP/pwned" ] && echo 1 || echo 0)"

  cp "$TMP/profile-v99.json" "$target"
  wt_load_profile "$pdir" 2>/dev/null
  rc_is 'unknown schemaVersion still returns 0' 0 $?
  eq 'unknown schemaVersion -> not present' '0'  "$PROFILE_PRESENT"
  eq 'unknown schemaVersion -> reported'    '99' "$PROFILE_SCHEMA_VERSION"
  eq 'unknown schemaVersion -> shell ignored' '' "$PROFILE_SHELL"
  err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
  contains 'unknown schemaVersion warns' 'schemaVersion 99' "$err"

  cp "$TMP/profile-noversion.json" "$target"
  wt_load_profile "$pdir" 2>/dev/null
  eq 'no schemaVersion -> not present'   '0' "$PROFILE_PRESENT"
  eq 'no schemaVersion -> shell ignored' ''  "$PROFILE_SHELL"
  err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
  contains 'no schemaVersion warns' 'no schemaVersion' "$err"

  cp "$TMP/profile-broken.json" "$target"
  wt_load_profile "$pdir" 2>/dev/null
  rc_is 'broken profile still returns 0' 0 $?
  eq 'broken profile -> not present' '0' "$PROFILE_PRESENT"
  err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
  contains 'broken profile warns' 'could not be parsed' "$err"

  cp "$TMP/profile-bom.json" "$target"
  wt_load_profile "$pdir"
  eq 'BOM profile -> present' '1' "$PROFILE_PRESENT"
  eq 'BOM profile -> shell read' 'bom-survived' "$PROFILE_SHELL"

  # A profile that exists but cannot be read must SAY so, not look like no profile.
  cp "$TMP/profile-v1.json" "$target"
  chmod 000 "$target"
  if [ -r "$target" ]; then          # running as root: the chmod proves nothing
    pass=$((pass + 1))
  else
    wt_load_profile "$pdir" 2>/dev/null
    eq 'unreadable profile -> not present' '0' "$PROFILE_PRESENT"
    err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
    contains 'unreadable profile warns' 'not readable' "$err"
  fi
  chmod 644 "$target"

  # A directory at the profile path must warn about that, not about JSON.
  rm -f "$target"
  mkdir -p "$target"
  wt_load_profile "$pdir" 2>/dev/null
  eq 'directory at the profile path -> not present' '0' "$PROFILE_PRESENT"
  err=$(wt_load_profile "$pdir" 2>&1 >/dev/null)
  contains 'directory at the profile path warns' 'not a regular file' "$err"
  rmdir "$target"

  # --- wt_json_records ------------------------------------------------------
  # The array reader. Everything here is asserted on BOTH backends, because this is a
  # second implementation of wt_json_get's value rendering and the two have already
  # genuinely diverged twice in this library's history (non-ASCII escaping, and a
  # UTF-8 BOM). Byte-for-byte agreement is the property under test, not "it works".
  recs='{"deps":[
      {"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"composer install"},
      {"dir":"node_modules","lock":"pnpm-lock.yaml","strategy":"install"}],
    "empty":[],"notarr":{"a":1},"scalar":"str",
    "types":[{"n":5,"neg":-2,"flt":1.5,"t":true,"f":false,"o":{"x":1},"arr":[1,2],"nul":null}],
    "deep":{"inner":[{"dir":"a"},{"dir":"b"}]},
    "seps":[{"v":"a\u001fb","w":"keep"},{"v":"c\u001ed","w":"also"}],
    "nested":[{"p":{"var":"SERVER_PORT"}}],
    "nonobj":["hello",42,null],
    "multiline":[{"install":"line1\nline2"}],
    "unicode":[{"v":"café — über"}],
    "tricky":[{"v":"a b  c"},{"v":""},{"v":"--flag=x"}]}'
  jr() { printf '%s' "$recs" | wt_json_records "$@"; }

  # The whole point: one record per element, US between fields, RS after EVERY record
  # including the last. A missing optional field is an EMPTY field, not a dropped one —
  # dropping it would shift every later column, which is the defect this separator
  # choice exists to prevent.
  eq 'records: two elements, missing optional field kept as empty' \
    "vendor${US}composer.lock${US}hardlink${US}composer install${RS}node_modules${US}pnpm-lock.yaml${US}install${US}${RS}" \
    "$(jr deps dir lock strategy install)"

  # Data conditions all produce no records and rc 0. rc must NOT depend on the backend:
  # jq exits non-zero on a parse error while python exits 0, so the function normalises.
  eq 'records: empty array -> nothing' '' "$(jr empty a)"
  rc_is 'records: empty array -> rc 0' 0 "$(jr empty a >/dev/null; echo $?)"
  eq 'records: path is an object, not an array -> nothing' '' "$(jr notarr a)"
  rc_is 'records: not-an-array -> rc 0' 0 "$(jr notarr a >/dev/null; echo $?)"
  eq 'records: absent path -> nothing' '' "$(jr nope a)"
  rc_is 'records: absent path -> rc 0' 0 "$(jr nope a >/dev/null; echo $?)"
  eq 'records: path is a scalar -> nothing' '' "$(jr scalar a)"
  eq 'records: unparseable document -> nothing' '' \
    "$(printf 'not json at all' | wt_json_records deps dir)"
  rc_is 'records: unparseable document -> rc 0, same on both backends' 0 \
    "$(printf 'not json at all' | wt_json_records deps dir >/dev/null; echo $?)"

  # Value rendering must match wt_json_get exactly, including python's True/False trap.
  eq 'records: scalar rendering matches wt_json_get' \
    "5${US}-2${US}1.5${US}true${US}false${US}{\"x\":1}${US}[1,2]${US}${RS}" \
    "$(jr types n neg flt t f o arr nul)"

  # The DOTTED array path — half of the documented traversal, and previously untested:
  # a mutation replacing the split with a single top-level lookup passed every assertion.
  eq 'records: a dotted path to the array itself' "a${RS}b${RS}" \
    "$(jr deep.inner dir)"

  # An option-like path must be DATA, not a jq option. Measured before the `--` was added:
  # jq returned nothing while python returned a record, so the same committed profile gave
  # two teammates different dependency lists.
  eq 'records: an option-like path is data, not an option' "${RS}${RS}" "$(jr deps -i)"
  eq 'get: an option-like path is data, not an option' 'x' \
    "$(printf '%s' '{"-i":"x"}' | wt_json_get -i)"

  # An empty path argument is a caller error, not "the whole document": jq's split(".") on
  # "" yields [], and getpath([]) returns the document, where python returned "".
  rc_is 'records: an empty field path is rejected' 1 "$(jr deps '' >/dev/null 2>&1; echo $?)"
  rc_is 'records: an empty array path is rejected' 1 "$(jr '' dir >/dev/null 2>&1; echo $?)"
  rc_is 'get: an empty path is rejected' 1 \
    "$(printf '%s' '{}' | wt_json_get '' >/dev/null 2>&1; echo $?)"

  # A valid document followed by junk, and two concatenated documents. jq reads stdin as a
  # STREAM, so both parsed happily there while python's json.load raised — one teammate got
  # a working profile from bytes that gave another teammate none.
  eq 'records: a document with trailing junk yields nothing' '' \
    "$(printf '%s' '{"deps":[{"dir":"v"}]} junk' | wt_json_records deps dir)"
  eq 'get: a document with trailing junk yields nothing' '' \
    "$(printf '%s' '{"a":"1"} junk' | wt_json_get a)"
  eq 'records: two concatenated documents yield nothing' '' \
    "$(printf '%s' '{"deps":[{"dir":"v"}]}{"deps":[{"dir":"w"}]}' | wt_json_records deps dir)"
  eq 'get: two concatenated documents yield nothing' '' \
    "$(printf '%s' '{"a":"1"}{"a":"2"}' | wt_json_get a)"

  # A value carrying the separators themselves. JSON encodes \u001f/\u001e legally and the
  # profile arrives on colleagues' branches, so without stripping this injects a phantom
  # field and shifts `w` into the wrong variable — undetectable by any caller.
  eq 'records: an embedded US in a value cannot inject a field' \
    "ab${US}keep${RS}cd${US}also${RS}" "$(jr seps v w)"
  n=0 cols=''
  while IFS=$US read -r -d "$RS" sv sw; do
    n=$((n + 1))
    cols="${cols}[${sv}|${sw}]"
  done < <(jr seps v w)
  eq 'records: separator-bearing values still yield exactly two records' 2 "$n"
  eq 'records: the second field stays in its own column' '[ab|keep][cd|also]' "$cols"
  eq 'get: an embedded US in a value cannot shift a column' "ab${US}keep" \
    "$(printf '%s' '{"a":"a\u001fb","b":"keep"}' | wt_json_get a b)"

  # Whitespace runs, an empty value and a leading-dash value, read through the documented
  # loop: IFS=$US must not collapse spaces the way IFS-whitespace would.
  eq 'records: whitespace runs, empty and dash-leading values survive' \
    "a b  c${RS}${RS}--flag=x${RS}" "$(jr tricky v)"
  n=0 tvals=''
  while IFS=$US read -r -d "$RS" tv; do
    n=$((n + 1))
    tvals="${tvals}<${tv}>"
  done < <(jr tricky v)
  eq 'records: an element whose only field is empty is still a record' 3 "$n"
  eq 'records: IFS=US does not collapse a run of spaces' '<a b  c><><--flag=x>' "$tvals"

  # No JSON backend at all must be a CALLER error, so a toolless machine can never be
  # mistaken for a repo with no dependencies. `command -v` and `printf` are builtins, so an
  # empty PATH is safe here. Mutation-confirmed: relaxing this guard to `return 0` left
  # every other assertion passing.
  rc_is 'records: no JSON backend is a caller error, not an empty array' 1 \
    "$(printf '%s' '{"d":[{"i":"x"}]}' | (
         wt_has_json() { return 1; }
         wt_json_records d i >/dev/null 2>&1; echo $?) )"
  eq 'records: dotted path inside an element' "SERVER_PORT${RS}" "$(jr nested p.var)"
  eq 'records: non-object elements yield empty fields, not errors' \
    "${RS}${RS}${RS}" "$(jr nonobj a)"
  eq 'records: non-ASCII is not escaped (a proven divergence point)' \
    "café — über${RS}" "$(jr unicode v)"

  # rc 1 is reserved for CALLER errors, so a machine with no backend cannot be mistaken
  # for a repo with no dependencies.
  rc_is 'records: one argument is a usage error' 1 "$(jr deps >/dev/null 2>&1; echo $?)"
  rc_is 'records: no arguments is a usage error' 1 "$(jr >/dev/null 2>&1; echo $?)"

  # A newline inside a value is exactly why records are RS-delimited: `install` is a
  # command string, where a line continuation is legal. Newline-delimited records would
  # silently split this element in two and shift every column after it.
  n=0
  while IFS=$US read -r -d "$RS" v; do
    n=$((n + 1))
    eq 'records: a value containing a newline survives intact' "$(printf 'line1\nline2')" "$v"
  done < <(jr multiline install)
  eq 'records: a newline in a value does not split the record' 1 "$n"

  # The loop idiom in the function's own docs must read every element, last included.
  n=0 seen=''
  while IFS=$US read -r -d "$RS" rdir rlock; do
    n=$((n + 1))
    seen="$seen$rdir:$rlock "
  done < <(jr deps dir lock)
  eq 'records: the documented read loop sees the final element' 2 "$n"
  eq 'records: the read loop splits fields correctly on every element' \
    'vendor:composer.lock node_modules:pnpm-lock.yaml ' "$seen"

  # A UTF-8 BOM is the other proven divergence point: jq accepts it, so python must too,
  # or one teammate gets dependencies and another gets none from the same committed file.
  printf '\357\273\277%s' '{"deps":[{"dir":"vendor"}]}' >"$TMP/bom.json"
  eq 'records: a UTF-8 BOM is tolerated on both backends' "vendor${RS}" \
    "$(wt_json_records deps dir <"$TMP/bom.json")"

  # --- caller safety --------------------------------------------------------
  # The caller runs `set -euo pipefail`; a library function returning non-zero, or
  # referencing an unset variable, must not take the session down. ADR-003.
  out=$(bash -c "set -euo pipefail; . '$LIB'
    wt_read_field nope '{}' >/dev/null || true
    wt_repo_root /nonexistent >/dev/null || true
    wt_main_root /nonexistent >/dev/null || true
    wt_load_profile /nonexistent >/dev/null
    wt_slugify '' >/dev/null
    wt_expand '{name}' >/dev/null
    printf '%s' '{\"deps\":[]}' | wt_json_records deps dir >/dev/null
    printf '%s' 'broken' | wt_json_records deps dir >/dev/null
    wt_json_records >/dev/null 2>&1 || true
    . '$LIB'
    printf SURVIVED" 2>/dev/null)
  eq 'the library never kills a caller under set -euo pipefail' 'SURVIVED' "$out"
  out=$(bash -c "set -u; . '$LIB'; wt_expand '{name}{slug}{port}{worktree}{root}'; printf OK" 2>&1)
  eq 'expand is safe under set -u with nothing set' 'OK' "$out"
}

for BACKEND in jq python3; do
  if [ "$BACKEND" = jq ]; then
    if ! command -v jq >/dev/null 2>&1; then
      if [ -n "${WT_TEST_ALLOW_MISSING_BACKEND:-}" ]; then
        printf 'WARNING: jq not on PATH — cross-backend parity NOT verified\n' >&2
        continue
      fi
      printf 'FAIL: jq not on PATH, so backend parity is untested.\n' >&2
      printf '      Run: nix shell nixpkgs#jq -c tests/test_lib.sh\n' >&2
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

printf '%d passed, %d failed, %d backend(s) exercised\n' "$pass" "$fail" "$backends_run" >&2

# `fail -eq 0` alone cannot tell "everything passed" from "nothing ran".
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ] && [ "$backends_run" -gt 0 ]
