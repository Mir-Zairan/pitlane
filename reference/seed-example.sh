#!/usr/bin/env bash
#
# ============================================================================
#  A TEMPLATE. It does not work as it stands, and it is not meant to.
# ============================================================================
#
# Copy it into your own repository — `.claude/worktree-seed.sh` is the usual place — name that path
# in your profile's `runtime.seed`, then replace the two marked sections with commands that suit
# your database. The `exit 1` sentinel below is there so that an unedited copy announces itself
# instead of quietly reporting success; delete it when you have finished.
#
# WHAT THIS SCRIPT IS FOR. The plugin gives every worktree its own port and writes its own env
# overrides, but it cannot know how to give it its own DATABASE: nothing in a repository states
# that some variable selects a tenant, or how to clone one. That judgement is yours, so this half
# lives in your repo and the plugin only calls it.
#
# ----------------------------------------------------------------------------
# THE CONTRACT — what the plugin guarantees when it runs this
# ----------------------------------------------------------------------------
#
#   Working directory   the worktree, not the main checkout.
#   Shell               whatever your profile's `shell` says, so your project's toolchain is on
#                       PATH exactly as it is for the install commands.
#   Environment         WT_NAME      the worktree name as given, e.g. alice/fix-99
#                       WT_SLUG      that name sanitised to [a-z0-9_], e.g. alice_fix_99.
#                                    THIS is what to name things after — never WT_NAME, which is
#                                    raw branch text and can contain anything.
#                       WT_PORT      the port derived for this worktree, or empty if the profile
#                                    does not configure one
#                       WT_PATH      absolute path of the worktree
#                       WT_ROOT      absolute path of the main checkout
#                       WT_ENV_FILE  the override file the plugin wrote, relative to WT_PATH
#   Time limit          `timeouts.seedSeconds`, or whatever is LEFT of the bootstrap budget if
#                       that is less. Overrun is not a crash — the script is stopped and the
#                       session continues.
#   Exit code           0 means seeded. Anything else warns and the session continues anyway; the
#                       plugin records the failure and will NOT retry until this file changes, so
#                       a broken seed does not cost you the timeout on every session.
#   How often           once. After a success the plugin skips this script until either its
#                       contents or the worktree's slug change.
#
# Values arrive as ENVIRONMENT, never as arguments and never substituted into a command line, so
# there is nothing here for a strange branch name to break out of.
#
# NOT EXECUTABLE? The plugin skips a seed script without the executable bit and tells you to run
# `chmod +x` on it. That is deliberate: `chmod` does not change a file's contents, so treating it
# as a failure would fingerprint the file and then refuse to retry it.
#
# ----------------------------------------------------------------------------
# THE RULES THIS FILE FOLLOWS, AND SO SHOULD YOURS
# ----------------------------------------------------------------------------
#
# 1. IT ONLY EVER CREATES. There is no DROP, no TRUNCATE, no reset, no "recreate if it exists"
#    anywhere in this file, and you should not add one. This runs unattended, on every new
#    worktree, from a script committed for your whole team — it is the single easiest place to be
#    helpful and catastrophic. Removing state is teardown's job, and teardown is a separate,
#    equally careful decision.
#
# 2. IT CHECKS BEFORE IT WRITES. The plugin refuses to seed when it can see that another live
#    worktree already owns this slug, but it cannot see a database that was made some other way —
#    by a colleague, by an older version of this script, or by hand. So the script asks. If the
#    target already exists, that is a success, not a reason to overwrite: the worktree gets the
#    data that is there.
#
# 3. NO CREDENTIALS IN HERE. This file is committed. Read them from the environment or from the
#    `.env` the plugin copied into the worktree — which is exactly why it copies it.
#
# 4. IT IS SAFE TO RUN TWICE. A hook can be interrupted, and the plugin retries a seed it could not
#    confirm finished.

# SC2317/SC2329/SC2034: everything below the sentinel is deliberately UNREACHABLE until a developer
# deletes that line, and target_exists() is deliberately uncalled-looking for the same reason. That
# is the whole design of a template that must not run as it stands — see the sentinel's own
# comment. SOURCE is likewise unused until section 2 is filled in. The directive sits BEFORE the
# first command so it applies to the whole file.
# shellcheck disable=SC2317,SC2329,SC2034
set -euo pipefail

# ----------------------------------------------------------------------------
# Guard rails — keep these
# ----------------------------------------------------------------------------

# Without a slug there is nothing to name anything after, and carrying on would act on whatever a
# half-set variable happened to hold.
if [ -z "${WT_SLUG:-}" ]; then
  echo "worktree-seed: WT_SLUG is empty — refusing to guess a database name" >&2
  exit 1
fi

# DELETE THIS LINE ONCE YOU HAVE EDITED THE REST.
# It is here so an unedited copy says so, loudly, instead of exiting 0 and reporting a worktree as
# seeded when nothing happened — which would ship a silently no-op seed step to your whole team.
echo "worktree-seed.sh is still the unedited template — see the comments in it" >&2; exit 1

# The name this worktree's data lives under. It must agree with whatever your profile's
# `runtime.env.vars` writes into the override file, or the app will read one database while this
# script fills another. Keep the two in step: if the profile says `demo_{slug}`, say `demo_` here.
TARGET="demo_${WT_SLUG}"

# The database to copy from. A dedicated, known-good template is much safer than your live
# development database — cloning that one couples every new worktree to whatever state it is in.
SOURCE="${WORKTREE_SEED_SOURCE:-demo_template}"

# ----------------------------------------------------------------------------
# 1. Does it already exist?  ← REPLACE with the check your database actually needs
# ----------------------------------------------------------------------------
#
# This is the ownership check rule 2 describes, and it is the reason the plugin can afford to run
# this unattended. Only your repo knows how to ask the question.
#
#   MySQL/MariaDB:  mysql -N -e "SHOW DATABASES LIKE '${TARGET}'" | grep -q .
#   PostgreSQL:     psql -tAc "SELECT 1 FROM pg_database WHERE datname='${TARGET}'" | grep -q 1
#   SQLite:         [ -f "var/${TARGET}.sqlite" ]
#   Docker volume:  docker volume inspect "${TARGET}" >/dev/null 2>&1
#
target_exists() {
  echo "worktree-seed: replace target_exists() with a real check" >&2
  return 1
}

if target_exists; then
  echo "worktree-seed: ${TARGET} already exists — leaving it as it is" >&2
  exit 0
fi

# ----------------------------------------------------------------------------
# 2. Create it.  ← REPLACE with the clone your database actually needs
# ----------------------------------------------------------------------------
#
#   MySQL/MariaDB:  mysql -e "CREATE DATABASE \`${TARGET}\`"
#                   mysqldump "${SOURCE}" | mysql "${TARGET}"
#   PostgreSQL:     createdb -T "${SOURCE}" "${TARGET}"
#   SQLite:         cp "var/${SOURCE}.sqlite" "var/${TARGET}.sqlite"
#
# If your app needs migrations run afterwards, run them HERE, against ${TARGET} — not against
# whatever the ambient environment points at. Sourcing the override file the plugin just wrote is
# usually the simplest way to be sure:
#
#   set -a; . "${WT_PATH}/${WT_ENV_FILE}"; set +a
#
echo "worktree-seed: replace this section with the clone your database needs" >&2
exit 1

# A note on what you have when this returns 0: the worktree has its own port, its own override
# file, and its own data. Phase 5's teardown will run `runtime.teardown` — a separate script,
# written under the same rules, and the only place a DROP belongs.
