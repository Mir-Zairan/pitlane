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
  "deps": [{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
            "install":"composer install --no-interaction --no-progress --no-scripts"}],
  "runtime": {"slug":"{name}","port":{"var":"SERVER_PORT","base":3786,"span":200}},
  "timeouts": {"bootstrapSeconds": 420, "seedSeconds": 120}
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
  # SC1091: shellcheck only follows a sourced file with -x, and the gate lints each changed
  # file alone. SC2034/SC2329: WT_SLUG, WT_SKIP_VALIDATION and the stubbed wt_has_json are
  # read by lib.sh, not by this file — they are inputs to the code under test.
  # shellcheck source-path=SCRIPTDIR/../hooks/scripts
  # shellcheck source=lib.sh
  # shellcheck disable=SC1091,SC2034,SC2329
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
  eq 'read_file_field nested number' '420' \
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
  eq 'no profile -> empty shellArgs'  ''    "$PROFILE_SHELLARGS"
  eq 'no profile -> no runtime'       '0'   "$PROFILE_HAS_RUNTIME"
  eq 'no profile -> default timeout'  '600' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'no profile -> path still reported' "$target" "$PROFILE_PATH"
  # A trailing slash on the root must not double up in a user-facing warning.
  wt_load_profile "$pdir/"
  eq 'load_profile normalises a trailing slash' "$target" "$PROFILE_PATH"

  # deps[].lock is validated for existence relative to the root, so the fixture repo needs
  # the lockfile its profile names. Absent, the profile is legitimately invalid.
  : >"$pdir/composer.lock"
  cp "$TMP/profile-v1.json" "$target"
  wt_load_profile "$pdir"
  eq 'v1 profile -> present'       '1' "$PROFILE_PRESENT"
  eq 'v1 profile -> shell'         'nix develop --command' "$PROFILE_SHELL"
  eq 'v1 profile -> has runtime'   '1' "$PROFILE_HAS_RUNTIME"
  eq 'v1 profile -> timeouts read' '420' "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'v1 profile -> seed timeout'  '120' "$PROFILE_SEED_TIMEOUT"
  eq 'v1 profile is silent' '' "$(wt_load_profile "$pdir" 2>&1 >/dev/null)"

  cp "$TMP/profile-minimal.json" "$target"
  wt_load_profile "$pdir"
  eq 'minimal profile -> present'         '1'   "$PROFILE_PRESENT"
  eq 'minimal profile -> no runtime'      '0'   "$PROFILE_HAS_RUNTIME"
  eq 'minimal profile -> default timeout' '600' "$PROFILE_BOOTSTRAP_TIMEOUT"

  # shellArgs, end to end: profile JSON -> PROFILE_SHELLARGS -> the engine's argv construction.
  # It is read POSITIONALLY out of the fifteen-field scalar record, so a path added to
  # wt_profile_scan in the wrong place would hand this variable the value of a different field —
  # and nothing else in the suite would notice. Empty is a THIRD distinct state, not a synonym for
  # "argv": only an absent field may fall back to matching the shell string.
  printf '%s' '{"schemaVersion":1,"shell":"nix-shell --run","shellArgs":"string"}' >"$target"
  wt_load_profile "$pdir"
  eq 'shellArgs "string" is loaded as given'  'string' "$PROFILE_SHELLARGS"
  eq '...alongside the shell it belongs to'   'nix-shell --run' "$PROFILE_SHELL"
  printf '%s' '{"schemaVersion":1,"shell":"nix develop --command","shellArgs":"argv"}' >"$target"
  wt_load_profile "$pdir"
  eq 'shellArgs "argv" is loaded as given'    'argv' "$PROFILE_SHELLARGS"
  printf '%s' '{"schemaVersion":1,"shell":"nix develop --command"}' >"$target"
  wt_load_profile "$pdir"
  eq 'an omitted shellArgs stays empty, not defaulted' '' "$PROFILE_SHELLARGS"
  # An invalid profile is not used at all, so the field must not survive from the previous load.
  printf '%s' '{"schemaVersion":1,"shellArgs":"sideways"}' >"$target"
  wt_load_profile "$pdir" 2>/dev/null
  eq 'an invalid profile leaves shellArgs empty, not half-loaded' '' "$PROFILE_SHELLARGS"
  eq '...and is not present' '0' "$PROFILE_PRESENT"

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
         # shellcheck disable=SC2329  # invoked inside the child-shell string below
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

  # A newline inside a value is why records are RS-delimited AND why desep folds CR/LF to a
  # space. `install` is a command string where a line continuation is legal, and the bash
  # side reads these with a LINE-delimited read — so a preserved newline would truncate the
  # record and blank every field after it. In wt_validate_profile that measurably disabled
  # the entire validator, so folding is the contract, not preservation.
  n=0
  while IFS=$US read -r -d "$RS" v; do
    n=$((n + 1))
    eq 'records: a newline in a value is folded to a space' 'line1 line2' "$v"
  done < <(jr multiline install)
  eq 'records: a newline in a value does not split the record' 1 "$n"
  eq 'records: a CR is folded too (a native-Windows python would emit CRLF)' 'a b' \
    "$(printf '%s' '{"d":[{"v":"a\r\nb"}]}' | wt_json_records d v | tr -d "$RS")"
  # And the same fold in wt_json_get, whose caller reads it with the same line-delimited
  # read: one newline in an early value used to blank every field after it.
  eq 'get: a newline cannot truncate the field list' "x y${US}kept" \
    "$(printf '%s' '{"a":"x\ny","b":"kept"}' | wt_json_get a b)"

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

  # --- wt_json_scan ---------------------------------------------------------
  # The one-invocation reader: a leading tagged scalar record, then one tagged record per
  # element of each named array group. Its value rendering must agree with the other two
  # readers byte for byte, because it is the same document read a different way.
  SCAN='{"schemaVersion":1,"shell":"nix develop --command","copy":[".env",".env.local"],
         "deps":[{"dir":"vendor","lock":"composer.lock"},{"dir":"node_modules","lock":null}],
         "bool":true,"num":7,"obj":{"a":1},"uni":"café"}'
  js() { printf '%s' "$SCAN" | wt_json_scan "$@"; }

  eq 'scan: scalars come back as one tag-0 record' \
    "0${US}1${US}nix develop --command${RS}" "$(js schemaVersion shell)"
  eq 'scan: a missing scalar is empty, exactly as wt_json_get renders it' \
    "0${US}${US}1${RS}" "$(js nope schemaVersion)"
  eq 'scan: booleans, numbers, objects and non-ASCII render as wt_json_get renders them' \
    "0${US}true${US}7${US}{\"a\":1}${US}café${RS}" "$(js bool num obj uni)"
  eq 'scan: one array group is tagged 1, one record per element' \
    "0${US}1${RS}1${US}vendor${US}composer.lock${RS}1${US}node_modules${US}${RS}" \
    "$(js schemaVersion -- deps dir lock)"
  eq 'scan: a second group is tagged 2, and the "." field is the element itself' \
    "0${US}1${RS}1${US}vendor${RS}1${US}node_modules${RS}2${US}.env${RS}2${US}.env.local${RS}" \
    "$(js schemaVersion -- deps dir -- copy .)"
  eq 'scan: an absent array contributes no records at all' \
    "0${US}1${RS}" "$(js schemaVersion -- nosucharray x)"
  eq 'scan: a present-but-not-an-array value contributes no records' \
    "0${US}1${RS}" "$(js schemaVersion -- obj x)"
  eq 'scan: an empty array contributes no records' \
    "0${US}${RS}" "$(printf '%s' '{"deps":[]}' | wt_json_scan nope -- deps dir)"

  # THE PARSE PROOF. The scalar record is emitted whenever the document parsed, so no output
  # at all means it did not — which is what removes wt_json_records' check-parseability-first
  # caveat. Trailing junk and two concatenated documents must fail on BOTH backends, as they
  # do for the other two readers.
  eq 'scan: an unparseable document emits nothing' '' \
    "$(printf 'not json at all' | wt_json_scan a -- b c)"
  eq 'scan: ...and still returns 0, so the two backends stay indistinguishable' 0 \
    "$(printf 'not json at all' | wt_json_scan a -- b c >/dev/null; echo $?)"
  eq 'scan: trailing junk after a valid document emits nothing' '' \
    "$(printf '%s' '{"a":1} junk' | wt_json_scan a -- b c)"
  eq 'scan: two concatenated documents emit nothing' '' \
    "$(printf '%s' '{"a":1}{"a":2}' | wt_json_scan a -- b c)"
  eq 'scan: a UTF-8 BOM is tolerated, as it is by the other readers' "0${US}vendor${RS}" \
    "$(printf '\357\273\277%s' '{"d":"vendor"}' | wt_json_scan d)"

  # Caller errors return 1 and are distinguishable from a data outcome. A malformed group list
  # matters more than it looks: an empty group would renumber every later tag, silently handing
  # one array's records to the branch expecting another's.
  rc_is 'scan: no arguments is a caller error' 1 "$(wt_json_scan >/dev/null 2>&1; echo $?)"
  rc_is 'scan: no scalar path before the first group is a caller error' 1 \
    "$(printf '%s' '{}' | wt_json_scan -- deps dir >/dev/null 2>&1; echo $?)"
  rc_is 'scan: a trailing separator with no array path is a caller error' 1 \
    "$(printf '%s' '{}' | wt_json_scan a -- >/dev/null 2>&1; echo $?)"
  rc_is 'scan: two separators in a row is a caller error' 1 \
    "$(printf '%s' '{}' | wt_json_scan a -- -- deps >/dev/null 2>&1; echo $?)"
  rc_is 'scan: an empty path is a caller error' 1 \
    "$(printf '%s' '{}' | wt_json_scan '' -- deps dir >/dev/null 2>&1; echo $?)"

  # Separator injection. These bytes are LEGAL in JSON as escapes, and the profile arrives
  # from other people's branches, so a value carrying one would otherwise forge a field or end
  # a record early. Both readers strip them; this one must too.
  printf '%s' '{"deps":[{"dir":"a\u001fFORGED","lock":"b\u001eFORGED","strategy":"c\nd\re"}]}' \
    >"$TMP/inject.json"
  eq 'scan: an embedded US, RS, CR or LF cannot forge a field or a record' \
    "0${US}${RS}1${US}aFORGED${US}bFORGED${US}c d e${RS}" \
    "$(wt_json_scan nope -- deps dir lock strategy <"$TMP/inject.json")"

  # Every value shape the renderer branches on, including the ones wt_json_records pins, so the
  # shared program cannot regress on one reader's behalf. Exponent notation is deliberately
  # absent — that divergence is documented and accepted.
  NUMS='{"n":7,"neg":-3,"flt":1.5,"t":true,"f":false,"o":{"a":1},"arr":[1,2],"nul":null,"s":""}'
  eq 'scan: numbers, negatives, floats, booleans, objects, arrays and null all render' \
    "0${US}7${US}-3${US}1.5${US}true${US}false${US}{\"a\":1}${US}[1,2]${US}${US}${RS}" \
    "$(printf '%s' "$NUMS" | wt_json_scan n neg flt t f o arr nul s)"

  # An option-like path must stay DATA. This diverged between the two backends before the `--`
  # was added — jq returned nothing and python returned the value — so it is pinned for every
  # reader, in both scalar and field position.
  eq 'scan: an option-like scalar path is data, not an option' "0${US}x${RS}" \
    "$(printf '%s' '{"-i":"x"}' | wt_json_scan -i)"
  eq 'scan: an option-like field path inside a group is data too' "0${US}${RS}1${US}y${RS}" \
    "$(printf '%s' '{"d":[{"--flag":"y"}]}' | wt_json_scan nope -- d --flag)"

  # No backend at all is a CALLER error, not an empty document. Without the guard a toolless
  # machine returns 0 and no output, which every caller would have to read as a data outcome —
  # the same "no backend looks like an empty repo" confusion wt_json_records guards against.
  rc_is 'scan: no JSON backend is a caller error, not an empty result' 1 \
    "$(printf '%s' '{"a":1}' | bash -c ". '$LIB'
         wt_has_json() { return 1; }
         wt_json_scan a -- deps dir >/dev/null 2>&1; echo \$?")"

  # Agreement with the two readers that now share its backend program. They are wrappers over
  # one implementation, so this pins the WRAPPERS — the tag/record stripping each mode does.
  eq 'scan: its scalar record matches wt_json_get field for field' \
    "$(printf '%s' "$SCAN" | wt_json_get schemaVersion shell uni obj)" \
    "$(s=$(js schemaVersion shell uni obj); s=${s%"$RS"}; printf '%s' "${s#0"$US"}")"
  # Anchored to record starts: an unanchored `s/1<US>//g` would also eat a value that happens
  # to end in the digit 1, and pass only because no fixture has one.
  eq 'scan: its array records match wt_json_records element for element' \
    "$(printf '%s' "$SCAN" | wt_json_records deps dir lock)" \
    "$(js nope -- deps dir lock | sed "s/^0${US}${RS}//; s/${RS}1${US}/${RS}/g; s/^1${US}//")"

  # --- wt_is_safe_relpath ---------------------------------------------------
  # The shape check that runs BEFORE any existence check. Note it tests SEGMENTS, not
  # substrings: a directory legitimately called `..cache` must be accepted, and a
  # substring test would refuse it.
  for good in vendor a/b node_modules .venv vendor/bundle ..cache foo..bar a/..b/c; do
    wt_is_safe_relpath "$good"
    rc_is "safe_relpath accepts $good" 0 $?
  done
  # SC2088: the tilde is DELIBERATELY unexpanded — a literal leading `~` arriving from a
  # committed profile is one of the shapes being rejected, so expanding it here would test
  # the wrong string entirely.
  # shellcheck disable=SC2088
  for bad in '' '.' '/abs' '/' '~/x' '~' '../up' 'a/../b' 'a/..' '../' '..'; do
    wt_is_safe_relpath "$bad"
    rc_is "safe_relpath rejects ${bad:-<empty>}" 1 $?
  done

  # --- wt_unknown_placeholders ----------------------------------------------
  # Must agree with wt_expand about what a placeholder IS. wt_expand passes an unknown
  # brace through verbatim so a shell snippet or an awk program survives, so those must
  # NOT be reported — a wrong report becomes a wrong rejection, which downgrades a working
  # repo to defaults.
  # SC2016: single quotes are the point. These are profile VALUES containing shell and awk
  # syntax that must survive placeholder scanning untouched; expanding them here would test
  # this test's own environment instead of the scanner.
  # shellcheck disable=SC2016
  for known in 'demo_{slug}' '{name}' '{port}' '{worktree}/a' '{root}/b' 'no braces at all' \
               '${FOO}/bin' '${HOME}' 'awk "{print $1}"' 'a{' '{' '{}' 'x${A}{slug}'; do
    wt_unknown_placeholders "$known" >/dev/null
    rc_is "placeholders: nothing to report in $known" 0 $?
  done
  got=$(wt_unknown_placeholders 'demo_{slugg}'); rc=$?
  eq  'placeholders: a typo is reported' 'slugg' "$got"
  rc_is 'placeholders: a typo returns 1' 1 "$rc"
  got=$(wt_unknown_placeholders 'x{PORT}y'); rc=$?
  eq  'placeholders: wrong case is reported' 'PORT' "$got"
  rc_is 'placeholders: wrong case returns 1' 1 "$rc"
  got=$(wt_unknown_placeholders '{a}-{slug}-{b}' | tr '\n' ',')
  eq 'placeholders: several unknowns, knowns skipped' 'a,b,' "$got"
  # A placeholder nested inside another brace. wt_expand leaves {slugg} literal here, so the
  # scanner must report it — a scanner that skipped to the first `}` saw only the fragment
  # `X{slugg` and reported nothing, missing the typo in exactly the inputs that mix a
  # placeholder with shell or awk braces.
  eq 'placeholders: a typo nested inside another brace is still found' 'slugg' \
    "$(wt_unknown_placeholders 'demo_{X{slugg}')"
  # shellcheck disable=SC2016  # a literal shell expansion is the input under test
  eq 'placeholders: and inside a shell default-value expansion' 'slugg' \
    "$(wt_unknown_placeholders '${VAR:-{slugg}}')"
  # The scanner must agree with wt_expand about what actually expands.
  # shellcheck disable=SC2034  # read by wt_expand inside lib.sh, not by this file
  WT_SLUG=realslug
  eq 'placeholders: wt_expand leaves the reported token literal' 'demo_{X{slugg}' \
    "$(wt_expand 'demo_{X{slugg}')"
  eq 'placeholders: and substitutes the one the scanner stays quiet about' 'demo_realslug' \
    "$(wt_expand 'demo_{slug}')"
  unset WT_SLUG

  # --- wt_validate_profile --------------------------------------------------
  VR="$TMP/vrepo"
  mkdir -p "$VR/.claude"
  : >"$VR/composer.lock"
  : >"$VR/pnpm-lock.yaml"
  VCK=$(cksum <"$VR/composer.lock")
  VP="$VR/.claude/worktree-profile.json"
  vw() { printf '%s' "$1" >"$VP"; }
  vv() { wt_validate_profile "$VP" "$VR" 2>/dev/null; }

  vw '{"schemaVersion":1,"shell":"nix develop --command","shellArgs":"argv","copy":[],
       "deps":[{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
                "install":"composer install --no-scripts","verify":"test -r vendor/autoload.php",
                "lockChecksum":"'"$VCK"'"}],
       "timeouts":{"bootstrapSeconds":420,"seedSeconds":120}}'
  eq 'validate: a good profile reports nothing' '' "$(vv)"
  vv >/dev/null 2>&1
  rc_is 'validate: a good profile returns 0' 0 $?

  # Absence is valid everywhere it is meaningful: no deps, no runtime, no timeouts.
  vw '{"schemaVersion":1}'
  eq 'validate: a minimal profile is valid' '' "$(vv)"
  vw '{"schemaVersion":1,"deps":[]}'
  eq 'validate: an empty deps array is valid' '' "$(vv)"
  vw '{"schemaVersion":1,"runtime":{}}'
  eq 'validate: an empty runtime block is valid (means touch nothing)' '' "$(vv)"

  # schemaVersion is the one mandatory key.
  vw '{"shell":"x"}'
  contains 'validate: a missing schemaVersion is a violation' 'schemaVersion: missing' "$(vv)"
  vw '{"schemaVersion":99}'
  contains 'validate: an unknown schemaVersion names the version' '99 is not 1' "$(vv)"

  # EVERY violation is reported, not just the first — a hand-broken profile is usually
  # broken in several places and one-at-a-time reporting means a round trip per mistake.
  vw '{"schemaVersion":99,"shellArgs":"shell",
       "deps":[{"dir":"../../escape","lock":"nope.lock","strategy":"cache","install":"x"},
               {"strategy":"hardlink"}],
       "timeouts":{"bootstrapSeconds":0,"seedSeconds":"abc"},
       "runtime":{"seed":"/etc/passwd"}}'
  got=$(vv)
  eq 'validate: reports all 9 violations in one pass' 9 "$(printf '%s\n' "$got" | grep -c .)"
  contains 'validate: names the offending dep by index'   'deps[0].strategy:' "$got"
  contains 'validate: indexes the SECOND dep as 1'        'deps[1].install:'  "$got"
  contains 'validate: rejects a traversing dir'           'deps[0].dir:'      "$got"
  contains 'validate: rejects a missing lockfile'         'deps[0].lock:'     "$got"
  contains 'validate: rejects a bad shellArgs'            'shellArgs:'        "$got"
  contains 'validate: rejects an absolute runtime.seed'   'runtime.seed:'     "$got"
  vv >/dev/null 2>&1
  rc_is 'validate: a broken profile returns 1' 1 $?

  # THE SEVERITY BOUNDARY: a field with a safe per-field fallback WARNS; a field without
  # one is FATAL. A bad timeout has a fallback (the default is substituted), so it must not
  # discard an otherwise perfect profile — losing every dependency and the toolchain shell
  # because one number is mistyped is the wrong-rejection failure.
  vw '{"schemaVersion":1,"shell":"keep-me","timeouts":{"bootstrapSeconds":0,"seedSeconds":"abc"}}'
  eq 'validate: a bad timeout is NOT a violation' '' "$(vv)"
  err=$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)
  contains 'validate: a bad bootstrap timeout warns instead' 'timeouts.bootstrapSeconds:' "$err"
  contains 'validate: a bad seed timeout warns instead'      'timeouts.seedSeconds:'      "$err"
  contains 'validate: and says the default will be used'     'default will be used'       "$err"
  wt_load_profile "$VR" 2>/dev/null
  eq 'load_profile: a bad timeout does not discard the profile' 1 "$PROFILE_PRESENT"
  eq 'load_profile: the rest of the profile is still used' 'keep-me' "$PROFILE_SHELL"
  eq 'load_profile: and the timeout falls back to the default' 600 "$PROFILE_BOOTSTRAP_TIMEOUT"
  eq 'load_profile: both timeouts fall back' 600 "$PROFILE_SEED_TIMEOUT"

  # Hostile paths, each rejected on SHAPE before the filesystem is consulted. These arrive
  # in a committed file from other people's branches, and consumers act on them with
  # `cp -al`, file writes and deletion.
  # shellcheck disable=SC2088  # a literal `~` is one of the hostile shapes under test
  for hp in '../../../etc/passwd' '/etc/passwd' 'a/../../../etc' '~/x'; do
    vw '{"schemaVersion":1,"deps":[{"dir":"'"$hp"'","lock":"composer.lock","strategy":"hardlink","install":"x"}]}'
    contains "validate: rejects dir $hp" 'must be a relative path inside the repository' "$(vv)"
  done
  vw '{"schemaVersion":1,"runtime":{"env":{"file":"../../x"}}}'
  contains 'validate: rejects a traversing runtime.env.file' 'runtime.env.file:' "$(vv)"
  vw '{"schemaVersion":1,"runtime":{"teardown":"../../rm"}}'
  contains 'validate: rejects a traversing runtime.teardown' 'runtime.teardown:' "$(vv)"

  # skip means the plugin does not act, so only the path SHAPE matters — no install, no
  # lock, no existence requirement.
  vw '{"schemaVersion":1,"deps":[{"strategy":"skip"}]}'
  eq 'validate: skip needs neither install nor lock nor dir' '' "$(vv)"
  vw '{"schemaVersion":1,"deps":[{"strategy":"skip","dir":"../out"}]}'
  contains 'validate: skip still rejects an escaping dir' 'deps[0].dir:' "$(vv)"

  # store is a valid schema value nothing implements: warn, do not invalidate.
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"store","install":"x"}]}'
  eq 'validate: store is not a violation' '' "$(vv)"
  contains 'validate: store warns that no phase implements it' 'reserved schema value' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"

  # Structural type errors on the containers themselves.
  vw '{"schemaVersion":1,"deps":{"dir":"vendor"}}'
  contains 'validate: deps must be an array' 'deps: must be an array' "$(vv)"
  vw '{"schemaVersion":1,"runtime":[]}'
  contains 'validate: runtime must be an object' 'runtime: must be an object' "$(vv)"
  vw '{"schemaVersion":1,"evidence":{"detectionVersion":"one"}}'
  contains 'validate: evidence.detectionVersion must be numeric' 'evidence.detectionVersion:' "$(vv)"
  vw '{"schemaVersion":1,"evidence":{"markers":"composer.lock"}}'
  contains 'validate: evidence.markers must be an array' 'evidence.markers:' "$(vv)"
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"skip","lockChecksum":"not-a-cksum"}]}'
  contains 'validate: a malformed lockChecksum is a violation' 'lockChecksum:' "$(vv)"

  # The timeout SUM, which is what actually has to fit under the hook's own timeout. Each
  # value alone is legal here; together they exceed it, so the platform would kill the hook
  # before either internal guard fired.
  vw '{"schemaVersion":1,"timeouts":{"bootstrapSeconds":600,"seedSeconds":600}}'
  eq 'validate: an over-budget timeout SUM is a warning, not a violation' '' "$(vv)"
  contains 'validate: warns that the timeout sum exceeds the hook timeout' 'over the 600s hook timeout' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"

  # A named-but-absent repo-owned script is a warning: it may land in a later commit, and
  # refusing the whole profile would take the dependency setup down with it.
  vw '{"schemaVersion":1,"runtime":{"seed":".claude/worktree-seed.sh"}}'
  eq 'validate: an absent seed script is not a violation' '' "$(vv)"
  contains 'validate: warns about an absent seed script' 'will do nothing' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"

  # File-level failures.
  eq 'validate: an absent file is a violation' \
    "profile: $TMP/nope.json is not a regular file" "$(wt_validate_profile "$TMP/nope.json" "$VR" 2>/dev/null)"
  eq 'validate: no path at all is a violation' 'profile: no path given' \
    "$(wt_validate_profile '' "$VR" 2>/dev/null)"
  vw '{ not json'
  contains 'validate: an unparseable profile is a violation' 'not parseable as a single JSON document' "$(vv)"
  printf '%s' '{"schemaVersion":1} junk' >"$VP"
  contains 'validate: a document with trailing junk is a violation' 'not parseable' "$(vv)"

  # --- validation is wired into the loader, with NO PARTIAL TRUST -----------
  vw '{"schemaVersion":1,"shell":"good","deps":[{"dir":"vendor","lock":"absent.lock","strategy":"hardlink","install":"x"}]}'
  wt_load_profile "$VR" 2>/dev/null
  eq 'load_profile: an invalid profile is not present at all' 0 "$PROFILE_PRESENT"
  eq 'load_profile: and none of its values are trusted' '' "$PROFILE_SHELL"
  err=$(wt_load_profile "$VR" 2>&1 >/dev/null)
  contains 'load_profile: says why, and names the offending key' 'deps[0].lock' "$err"
  contains 'load_profile: points at the fix' '/worktree-calibrate' "$err"
  vw '{"schemaVersion":1,"shell":"good"}'
  wt_load_profile "$VR" 2>/dev/null
  eq 'load_profile: a valid profile is still loaded' 1 "$PROFILE_PRESENT"
  eq 'load_profile: with its values' 'good' "$PROFILE_SHELL"
  # The escape hatch exists for the calibrate skill, which validates with its own severity.
  # NOT in a ( subshell ): eq's pass/fail counters would increment in the subshell and die
  # with it, so a regression here would print FAIL and still exit 0. Mutation-confirmed.
  vw '{"schemaVersion":1,"shell":"good","deps":[{"dir":"vendor","lock":"absent.lock","strategy":"hardlink","install":"x"}]}'
  # shellcheck disable=SC2034  # read by wt_load_profile inside lib.sh, not by this file
  WT_SKIP_VALIDATION=1
  wt_load_profile "$VR" 2>/dev/null
  eq 'load_profile: WT_SKIP_VALIDATION bypasses validation' 1 "$PROFILE_PRESENT"
  contains 'load_profile: and says the gate is off, so it cannot be silently disabled' \
    'WT_SKIP_VALIDATION is set' "$(wt_load_profile "$VR" 2>&1 >/dev/null)"
  unset WT_SKIP_VALIDATION
  wt_load_profile "$VR" 2>/dev/null
  eq 'load_profile: unsetting the bypass restores validation' 0 "$PROFILE_PRESENT"

  # A dep with no `strategy` at all — the likeliest hand-edit mistake, and a whole rc-1
  # branch that mutation showed was unexercised.
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock"}]}'
  got=$(vv)
  contains 'validate: a dep with no strategy is a violation' 'deps[0].strategy: missing' "$got"
  contains 'validate: and the unknown-strategy arm renders ? not empty' 'strategy "?"' "$got"
  vv >/dev/null 2>&1
  rc_is 'validate: a strategy-less dep returns 1' 1 $?

  # The placeholder CALL SITE, not just the helper: four fields are scanned and the message
  # is reformatted from a newline list into one {a b} token. Mutation showed neutering the
  # whole warning changed no assertion.
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
       "install":"seed demo_{slugg} --port {PORT}"}]}'
  eq 'validate: a botched placeholder is a warning, not a violation' '' "$(vv)"
  err=$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)
  contains 'validate: the placeholder warning names the dep' 'deps[0]:' "$err"
  contains 'validate: and lists every unknown token in one message' '{slugg PORT}' "$err"
  # shellcheck disable=SC2016  # ${FOO} and awk's $1 are literal profile values under test
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"install",
       "install":"install --prefix ${FOO} && awk \"{print $1}\""}]}'
  eq 'validate: shell and awk braces are not reported as placeholders' '' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"
  # The runtime templates, which are the motivating example: a botched slug reaches a
  # database name.
  vw '{"schemaVersion":1,"runtime":{"slug":"{slugg}","env":{"vars":{"DB":"demo_{prot}"}}}}'
  err=$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)
  contains 'validate: runtime.slug is scanned for placeholders' 'slugg' "$err"
  contains 'validate: runtime.env.vars values are scanned too' 'prot' "$err"

  # copy[] is a bare-string array acted on by file operations — the same threat as
  # deps[].dir, and it was completely unchecked.
  vw '{"schemaVersion":1,"copy":["../../../.ssh/id_rsa"]}'
  contains 'validate: a traversing copy entry is a violation' 'copy[0]:' "$(vv)"
  vw '{"schemaVersion":1,"copy":[".env",".env.local"]}'
  eq 'validate: ordinary copy entries are fine' '' "$(vv)"
  vw '{"schemaVersion":1,"copy":[".env","/etc/shadow"]}'
  contains 'validate: copy indexes the offending entry' 'copy[1]:' "$(vv)"
  vw '{"schemaVersion":1,"copy":"env"}'
  contains 'validate: copy must be an array' 'copy: must be an array' "$(vv)"

  # copy[] needs the SAME fail-closed guard deps[] has, and more urgently now that both arrays
  # arrive in one invocation: a stream truncated after the deps records would leave the copy
  # loop with zero iterations and pronounce a traversing entry clean. The stub emits only the
  # scalar record, with a hostile copy[] in field 15, so this assertion fails if the guard is
  # removed. The record is built here and passed through the environment rather than
  # interpolated, because it is made of control characters.
  cpad=''
  cn=0
  while [ "$cn" -lt 13 ]; do cpad="$cpad$US"; cn=$((cn + 1)); done
  # tag 0, schemaVersion 1, fields 2-14 empty, field 15 = copy
  SCALARONLY="0${US}1${cpad}${US}[\"../../../.ssh/id_rsa\"]${RS}"
  vw '{"schemaVersion":1,"copy":["../../../.ssh/id_rsa"]}'
  out=$(SCALARONLY="$SCALARONLY" bash -c ". '$LIB'
    wt_json_scan() { printf '%s' \"\$SCALARONLY\"; }
    wt_validate_profile '$VP' '$VR' 2>/dev/null
    printf '|rc=%s' \$?" 2>/dev/null)
  contains 'validate: a copy array whose records are lost is a violation, not an empty one' \
    'copy: is a non-empty array but could not be read' "$out"
  contains 'validate: and a lost hostile copy entry fails validation' '|rc=1' "$out"

  # deps[] AND copy[] populated together — the demultiplexing the single invocation introduced.
  # A mis-scoped tag filter or an unreset index would hand one array's records to the other
  # branch, and no other fixture in this suite has both.
  vw '{"schemaVersion":1,
       "deps":[{"dir":"vendor","lock":"composer.lock","strategy":"skip"},
               {"dir":"../escape","lock":"composer.lock","strategy":"skip"}],
       "copy":[".env","/etc/shadow"]}'
  got=$(vv)
  contains 'validate: with both arrays, the offending dep is indexed among deps' \
    'deps[1].dir:' "$got"
  contains 'validate: with both arrays, the offending copy entry is indexed among copy' \
    'copy[1]:' "$got"
  eq 'validate: with both arrays, no copy element is mistaken for a dep' 0 \
    "$(printf '%s\n' "$got" | grep -c 'deps\[.*shadow')"
  eq 'validate: with both arrays, exactly the two real violations are reported' 2 \
    "$(printf '%s\n' "$got" | grep -c .)"

  # The pre-read hand-off wt_load_profile uses: passing the scan output must produce exactly
  # what re-reading the file produces, or a load and a calibrate run would disagree about the
  # same profile.
  eq 'validate: a caller-supplied scan gives the same verdict as reading the file' \
    "$(wt_validate_profile "$VP" "$VR")" \
    "$(wt_validate_profile "$VP" "$VR" "$(wt_profile_scan "$VP")")"

  # A JSON *string* beginning with [ or { rendered as `[not-an-array`, which a
  # leading-byte-only type test accepted.
  vw '{"schemaVersion":1,"deps":"[not-an-array"}'
  contains 'validate: a string that starts with [ is not an array' 'deps: must be an array' "$(vv)"
  vw '{"schemaVersion":1,"runtime":"{not-an-object"}'
  contains 'validate: a string that starts with { is not an object' 'runtime: must be an object' "$(vv)"

  # A non-empty deps array that yields no records must NOT be treated as empty: that is how
  # a failed interpreter invocation silently skipped every per-dep check while pronouncing the
  # profile clean. It can only be reached by a reader failure, so the reader is stubbed in a
  # CHILD shell (stubbing here would break every later assertion).
  #
  # The stub emits ONLY the scalar record — tag 0, schemaVersion 1, then empty shell and
  # shellArgs, then a non-empty deps array — which is exactly the partial failure the guard is
  # for now that scalars and records come from ONE invocation. A total reader failure emits
  # nothing at all and is caught earlier, as the next assertion pins.
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"skip"}]}'
  eq 'validate: a readable deps array validates normally' '' "$(vv)"
  out=$(bash -c ". '$LIB'
    wt_json_scan() { printf '0%s1%s%s%s[{\"dir\":\"v\"}]%s' \"\$WT_US\" \"\$WT_US\" \"\$WT_US\" \"\$WT_US\" \"\$WT_RS\"; }
    wt_validate_profile '$VP' '$VR' 2>/dev/null
    printf '|rc=%s' \$?" 2>/dev/null)
  contains 'validate: a deps array whose records are lost is a violation, not an empty one' \
    'could not be read' "$out"
  contains 'validate: and it returns non-zero rather than passing' '|rc=1' "$out"
  # A reader that produces nothing at all cannot be told from an unparseable document, and both
  # are fail-closed.
  out=$(bash -c ". '$LIB'
    wt_json_scan() { return 0; }
    wt_validate_profile '$VP' '$VR' 2>/dev/null
    printf '|rc=%s' \$?" 2>/dev/null)
  contains 'validate: a reader that emits nothing fails closed' 'not parseable' "$out"
  contains 'validate: and returns non-zero' '|rc=1' "$out"
  # The hostile version: a dep that WOULD escape the worktree must not slip through when the
  # records read fails.
  vw '{"schemaVersion":1,"deps":[{"dir":"../../../../etc","lock":"/etc/passwd","strategy":"bogus"}]}'
  out=$(bash -c ". '$LIB'
    wt_json_scan() { printf '0%s1%s%s%s[{\"dir\":\"v\"}]%s' \"\$WT_US\" \"\$WT_US\" \"\$WT_US\" \"\$WT_US\" \"\$WT_RS\"; }
    wt_validate_profile '$VP' '$VR' >/dev/null 2>&1
    printf 'rc=%s' \$?" 2>/dev/null)
  eq 'validate: an unreadable hostile deps array still fails validation' 'rc=1' "$out"

  # One violation per line is a protocol both callers parse. A value containing a newline
  # used to occupy two lines and could forge a line naming a key it does not own.
  vw '{"schemaVersion":1,"deps":[{"dir":"../a\nschemaVersion: FORGED","lock":"composer.lock","strategy":"install","install":"x"}]}'
  got=$(vv)
  eq 'validate: a newline in a value cannot forge a second violation line' 1 \
    "$(printf '%s\n' "$got" | grep -c .)"
  contains 'validate: and the real violation is still reported' 'deps[0].dir:' "$got"

  # The timeout SUM boundary, exactly at and one over.
  vw '{"schemaVersion":1,"timeouts":{"bootstrapSeconds":480,"seedSeconds":120}}'
  eq 'validate: a sum exactly at the hook timeout is silent' '' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"
  vw '{"schemaVersion":1,"timeouts":{"bootstrapSeconds":481,"seedSeconds":120}}'
  contains 'validate: one second over the hook timeout warns' 'over the 600s hook timeout' \
    "$(wt_validate_profile "$VP" "$VR" 2>&1 >/dev/null)"
  # A leading zero is OCTAL to bash arithmetic: $((08 + 120)) is a fatal expansion error
  # that kills a set -e caller, which a sourced library must never do.
  vw '{"schemaVersion":1,"timeouts":{"bootstrapSeconds":"08","seedSeconds":120}}'
  eq 'validate: a leading-zero timeout does not crash the arithmetic' '' "$(vv)"
  out=$(bash -c "set -euo pipefail; . '$LIB'
    wt_validate_profile '$VP' '$VR' >/dev/null 2>&1 || true; printf SURVIVED" 2>/dev/null)
  eq 'validate: a leading-zero timeout does not kill a set -e caller' 'SURVIVED' "$out"

  # No JSON backend: not the profile's fault and not fixable by editing it, so it must not
  # look like a broken profile.
  #
  # Run in a CHILD SHELL, not by stubbing wt_has_json here. Stubbing then unsetting removes
  # the real function, and re-sourcing does not restore it because lib.sh has a
  # double-source guard — which silently broke every later assertion that reads JSON.
  out=$(bash -c ". '$LIB'
    wt_has_json() { return 1; }
    wt_validate_profile '$VP' '$VR' 2>/dev/null
    printf '|rc=%s' \$?" 2>/dev/null)
  eq 'validate: no JSON backend reports no violations, not a broken profile' '|rc=0' "$out"
  err=$(bash -c ". '$LIB'
    wt_has_json() { return 1; }
    wt_validate_profile '$VP' '$VR' 2>&1 >/dev/null" 2>/dev/null)
  contains 'validate: and says which tools are missing' 'jq nor python3' "$err"

  # --- wt_profile_drifted ---------------------------------------------------
  # No call site in this phase; Phase 3 owns wiring it. It must be a checksum and a string
  # compare only — never a re-detection (ADR-002).
  : >"$VR/composer.lock"
  VCK=$(cksum <"$VR/composer.lock")
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"x","lockChecksum":"'"$VCK"'"}]}'
  wt_profile_drifted "$VP" "$VR" >/dev/null 2>&1
  rc_is 'drift: a matching checksum is clean' 0 $?
  printf 'changed' >>"$VR/composer.lock"
  got=$(wt_profile_drifted "$VP" "$VR" 2>/dev/null); rc=$?
  rc_is 'drift: a changed lockfile is drift' 1 "$rc"
  contains 'drift: names the lockfile that changed' 'composer.lock has changed' "$got"
  rm -f "$VR/composer.lock"
  got=$(wt_profile_drifted "$VP" "$VR" 2>/dev/null); rc=$?
  rc_is 'drift: a vanished lockfile is drift' 1 "$rc"
  contains 'drift: says the lockfile is gone' 'no longer exists' "$got"
  : >"$VR/composer.lock"
  # A profile with no recorded evidence simply cannot report drift, and must not pretend to.
  vw '{"schemaVersion":1,"deps":[{"dir":"vendor","lock":"composer.lock","strategy":"hardlink","install":"x"}]}'
  wt_profile_drifted "$VP" "$VR" >/dev/null 2>&1
  rc_is 'drift: no recorded checksum means nothing to report' 0 $?
  wt_profile_drifted "$TMP/nope.json" "$VR" >/dev/null 2>&1
  rc_is 'drift: an absent profile is not drift' 0 $?
  wt_profile_drifted "$VP" '' >/dev/null 2>&1
  rc_is 'drift: no root given is not drift' 0 $?

  # drift is a PUBLIC entry point, so it re-checks the path shape rather than trusting that
  # a caller validated first. Otherwise a lock outside the repo turns it into an
  # existence-and-content oracle, and a lock naming a character device never returns.
  vw '{"schemaVersion":1,"deps":[{"strategy":"skip","dir":"vendor","lock":"../../../../../../etc/passwd","lockChecksum":"0 0"}]}'
  contains 'validate: a skip entry'"'"'s lock is shape-checked too' 'deps[0].lock:' "$(vv)"
  got=$(wt_profile_drifted "$VP" "$VR" 2>/dev/null); rc=$?
  rc_is 'drift: refuses a lock outside the repository' 1 "$rc"
  contains 'drift: says it refused rather than reading it' 'refusing to check it' "$got"
  ne 'drift: did not report a checksum for a path outside the repo' 'has changed' "$got"
  # A non-regular file would make the read never return; -f rather than -e is what stops it.
  if [ -e /dev/zero ]; then
    ln -sf /dev/zero "$VR/zero.lock" 2>/dev/null || true
    vw '{"schemaVersion":1,"deps":[{"strategy":"skip","dir":"vendor","lock":"zero.lock","lockChecksum":"0 0"}]}'
    got=$(timeout 5 bash -c ". '$LIB'; wt_profile_drifted '$VP' '$VR'" 2>/dev/null); rc=$?
    ne 'drift: a character-device lock does not hang the hook' 124 "$rc"
    contains 'drift: and reports it as a vanished lockfile' 'no longer exists' "$got"
    rm -f "$VR/zero.lock"
  fi

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
