# shellcheck shell=bash
# SC2034: the STACK_* variables set here are read by tests/test_stacks.sh, which sources this file.
# shellcheck disable=SC2034
#
# Invented example repositories, one per stack, for tests/test_stacks.sh — sourced, never run.
#
# Each stack is three functions over one name:
#
#   stack_tools_<stack>   prints the commands it needs as `command=nixpkgs-attribute` words. Those on
#                         the host are used as they are; the rest come from `nix shell`, which then
#                         becomes the profile's `shell` wrapper too. A command with no attribute
#                         (`docker=`) cannot be fetched, so the stack skips without it.
#   fixture_<stack> <dir> writes the repository into an already `git init`ed <dir>, builds its
#                         lockfile and the main checkout's dependency directory with the real tool
#                         (network allowed), writes the profile with write_profile, and sets:
#                           STACK_DEPDIRS   main-checkout dependency dirs that must stay byte-identical
#                           STACK_LINKDIRS  those of them the profile hardlinks, which the worktree
#                                           must share inodes with rather than reinstall
#                           STACK_PROBE     shell run in a worktree, through the toolchain, that must
#                                           print STACK_EXPECT when the dependencies are usable
#                           STACK_EXPECT    what STACK_PROBE prints; {slug} and {port} stand for the
#                                           worktree's own
#                           STACK_ENVFILE   the profile's env file ('' when there is no runtime)
#                         It returns non-zero when the tool could not build the fixture (offline, a
#                         registry down), which the suite reports as a SKIP, not a plugin failure.
#
# Every name in here is invented. Dependencies are one tiny, dependency-free package per ecosystem.
#
# Expects from the sourcing suite: STACK_SHELL (the wrapper, '' for the host), tc (runs a command
# string in a directory through that wrapper), STACK_DB (where seeds stand in for databases) and
# STACK_PORT_BASE.

# The profile every runtime-isolating stack gets: the toolchain wrapper, the deps given, a port and
# an env file, and a seed/teardown pair that create and remove "$STACK_DB/<slug>" — a database stand-in
# outside the worktree, so "allocated" and "released" are both observable after the directory is gone.
write_profile() {  # $1 = repo, $2 = deps[] body, $3 = env file, $4 = extra env.vars body (may be '')
  local repo=$1 deps=$2 envfile=$3 extra=${4-}
  mkdir -p "$repo/.claude"
  cat >"$repo/.claude/worktree-profile.json" <<JSON
{
  "schemaVersion": 1,
  "shell": "$STACK_SHELL",
  "shellArgs": "argv",
  "copy": [],
  "deps": [$deps],
  "runtime": {
    "slug": "{slug}",
    "port": { "var": "APP_PORT", "base": $STACK_PORT_BASE, "span": 200 },
    "env": { "file": "$envfile", "vars": { "APP_DATABASE": "fixture_{slug}"$extra } },
    "seed": ".claude/worktree-seed.sh",
    "teardown": ".claude/worktree-teardown.sh"
  },
  "timeouts": { "bootstrapSeconds": 420, "seedSeconds": 120 }
}
JSON
  # shellcheck disable=SC2016  # the $WT_* references belong to the scripts, not to this file.
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'printf "%%s\\n" "$WT_PORT" > "%s/$WT_SLUG"\n' "$STACK_DB"
  } >"$repo/.claude/worktree-seed.sh"
  # shellcheck disable=SC2016
  {
    printf '#!/usr/bin/env bash\nset -eu\n'
    printf 'rm -f "%s/$WT_SLUG"\n' "$STACK_DB"
  } >"$repo/.claude/worktree-teardown.sh"
  chmod +x "$repo/.claude/worktree-seed.sh" "$repo/.claude/worktree-teardown.sh"
  STACK_ENVFILE=$envfile
}

# A gitignored config file the developer keeps in the main checkout, which .worktreeinclude carries.
write_dev_config() {  # $1 = repo, $@ = further .gitignore lines
  local repo=$1
  shift
  printf '.claude/worktrees/\n.env\n.env.local\n' >"$repo/.gitignore"
  [ "$#" -gt 0 ] && printf '%s\n' "$@" >>"$repo/.gitignore"
  printf '.env\n' >"$repo/.worktreeinclude"
  printf 'APP_NAME=fixture\n' >"$repo/.env"
}

# --- 1. pnpm workspace: two packages, one depending on the other through workspace:* ----------------

stack_tools_pnpm() { echo node=nodejs pnpm=pnpm; }
fixture_pnpm() {
  local r=$1
  write_dev_config "$r" 'node_modules/'
  mkdir -p "$r/packages/lib" "$r/packages/web"
  printf '{ "name": "fixture-root", "private": true }\n' >"$r/package.json"
  printf 'packages:\n  - "packages/*"\n' >"$r/pnpm-workspace.yaml"
  printf '{ "name": "@fixture/lib", "version": "1.0.0", "main": "index.js", "dependencies": { "is-number": "7.0.0" } }\n' \
    >"$r/packages/lib/package.json"
  printf 'module.exports = require("is-number");\n' >"$r/packages/lib/index.js"
  printf '{ "name": "@fixture/web", "version": "1.0.0", "dependencies": { "@fixture/lib": "workspace:*" } }\n' \
    >"$r/packages/web/package.json"
  printf 'process.stdout.write(require("@fixture/lib")(5) ? "ok" : "broken");\n' >"$r/packages/web/probe.js"
  tc "$r" 'pnpm install' || return 1
  write_profile "$r" '{"dir":"node_modules","lock":"pnpm-lock.yaml","strategy":"install",
    "install":"pnpm install --frozen-lockfile","verify":"test -d node_modules/.pnpm"}' .env.local
  STACK_DEPDIRS='node_modules packages/lib/node_modules packages/web/node_modules'
  STACK_PROBE='cd packages/web && node probe.js'
  STACK_EXPECT=ok
}

# --- 2. npm: real bytes per project, so node_modules is hardlinked ----------------------------------

stack_tools_npm() { echo node=nodejs npm=nodejs; }
fixture_npm() {
  local r=$1
  write_dev_config "$r" 'node_modules/'
  printf '{ "name": "fixture-npm", "version": "1.0.0", "private": true, "dependencies": { "is-number": "7.0.0" } }\n' \
    >"$r/package.json"
  printf 'process.stdout.write(require("is-number")(5) ? "ok" : "broken");\n' >"$r/probe.js"
  tc "$r" 'npm install --no-audit --no-fund' || return 1
  write_profile "$r" '{"dir":"node_modules","lock":"package-lock.json","strategy":"hardlink",
    "install":"npm ci --no-audit --no-fund","verify":"test -r node_modules/is-number/package.json"}' .env.local
  STACK_DEPDIRS=node_modules STACK_LINKDIRS=node_modules
  STACK_PROBE='node probe.js'
  STACK_EXPECT=ok
}

# --- 3. bun: its own global cache, so it installs ---------------------------------------------------

stack_tools_bun() { echo bun=bun; }
fixture_bun() {
  local r=$1
  write_dev_config "$r" 'node_modules/'
  printf '{ "name": "fixture-bun", "version": "1.0.0", "private": true, "dependencies": { "is-number": "7.0.0" } }\n' \
    >"$r/package.json"
  printf 'process.stdout.write(require("is-number")(5) ? "ok" : "broken");\n' >"$r/probe.js"
  tc "$r" 'bun install --save-text-lockfile' || return 1
  write_profile "$r" '{"dir":"node_modules","lock":"bun.lock","strategy":"install",
    "install":"bun install --frozen-lockfile"}' .env.local
  STACK_DEPDIRS=node_modules
  STACK_PROBE='bun probe.js'
  STACK_EXPECT=ok
}

# --- 4. Python with uv: a .venv per worktree, installed from uv's cache -----------------------------

stack_tools_uv() { echo uv=uv python3=python3; }
fixture_uv() {
  local r=$1
  write_dev_config "$r" '.venv/' '__pycache__/'
  # No [build-system]: uv treats the project as virtual and installs only its dependencies, so a
  # sync leaves no egg-info behind in the worktree.
  cat >"$r/pyproject.toml" <<'TOML'
[project]
name = "fixture-app"
version = "0.1.0"
requires-python = ">=3.8"
dependencies = ["six"]
TOML
  printf 'import six, sys\nsys.stdout.write("ok" if six.PY3 else "broken")\n' >"$r/probe.py"
  tc "$r" 'uv lock -q && uv sync -q --frozen' || return 1
  write_profile "$r" '{"dir":".venv","lock":"uv.lock","strategy":"install","install":"uv sync --frozen",
    "verify":"test -x .venv/bin/python"}' .env.local
  STACK_DEPDIRS=.venv
  STACK_PROBE='.venv/bin/python probe.py'
  STACK_EXPECT=ok
}

# --- 5. composer: vendor/ hardlinked from the main checkout -----------------------------------------

stack_tools_composer() { echo php=php composer=phpPackages.composer; }
fixture_composer() {
  local r=$1
  write_dev_config "$r" 'vendor/'
  printf '{ "name": "fixture/app", "require": { "psr/log": "^3.0" } }\n' >"$r/composer.json"
  printf '<?php\nrequire __DIR__ . "/vendor/autoload.php";\necho interface_exists("Psr\\\\Log\\\\LoggerInterface") ? "ok" : "broken";\n' \
    >"$r/probe.php"
  tc "$r" 'composer install --no-interaction --no-progress --quiet' || return 1
  write_profile "$r" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
    "install":"composer install --no-interaction --no-progress","verify":"test -r vendor/autoload.php"}' .env.local
  STACK_DEPDIRS=vendor STACK_LINKDIRS=vendor
  STACK_PROBE='php probe.php'
  STACK_EXPECT=ok
}

# --- 6. Ruby bundler, vendored into vendor/bundle ---------------------------------------------------

stack_tools_bundler() { echo ruby=ruby bundle=ruby; }
fixture_bundler() {
  local r=$1
  # .bundle/config is what tells bundler the gems are vendored. It is the developer's, gitignored,
  # and reaches the worktree through .worktreeinclude like any other local config.
  write_dev_config "$r" 'vendor/bundle/' '.bundle/'
  printf '.bundle/config\n' >>"$r/.worktreeinclude"
  printf "source 'https://rubygems.org'\ngem 'rack', '~> 3.0'\n" >"$r/Gemfile"
  printf 'require "rack"\nprint(defined?(Rack::RELEASE) ? "ok" : "broken")\n' >"$r/probe.rb"
  tc "$r" 'bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet' || return 1
  write_profile "$r" '{"dir":"vendor/bundle","lock":"Gemfile.lock","strategy":"hardlink",
    "install":"bundle install","verify":"test -d vendor/bundle/ruby"}' .env.local
  STACK_DEPDIRS=vendor/bundle STACK_LINKDIRS=vendor/bundle
  STACK_PROBE='bundle exec ruby probe.rb'
  STACK_EXPECT=ok
}

# --- 7. Rust cargo: no per-project dependency dir (CARGO_HOME is shared), runtime only ---------------

stack_tools_cargo() { echo cargo=cargo rustc=rustc cc=gcc; }
fixture_cargo() {
  local r=$1
  write_dev_config "$r" 'target/'
  mkdir -p "$r/src"
  printf '[package]\nname = "fixture-app"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\nitoa = "1"\n' \
    >"$r/Cargo.toml"
  printf 'fn main() {\n    let mut b = itoa::Buffer::new();\n    print!("{}", if b.format(5) == "5" { "ok" } else { "broken" });\n}\n' \
    >"$r/src/main.rs"
  tc "$r" 'cargo generate-lockfile -q && cargo fetch -q' || return 1
  write_profile "$r" '{"dir":null,"lock":"Cargo.lock","strategy":"skip","install":"cargo fetch"}' .env.local
  STACK_DEPDIRS=''
  # --offline proves the worktree builds from the cache the main checkout filled, with nothing copied.
  STACK_PROBE='cargo run -q --offline'
  STACK_EXPECT=ok
}

# --- 8. Go modules: GOMODCACHE is shared, runtime only ----------------------------------------------

stack_tools_go() { echo go=go; }
fixture_go() {
  local r=$1
  write_dev_config "$r"
  printf 'module example.com/fixture\n\ngo 1.21\n' >"$r/go.mod"
  printf 'package main\n\nimport (\n\t"fmt"\n\n\t"github.com/google/uuid"\n)\n\nfunc main() {\n\tif uuid.Nil.String() == "00000000-0000-0000-0000-000000000000" {\n\t\tfmt.Print("ok")\n\t} else {\n\t\tfmt.Print("broken")\n\t}\n}\n' \
    >"$r/main.go"
  tc "$r" 'go get github.com/google/uuid@v1.6.0 >/dev/null 2>&1 && go mod tidy && go mod download' || return 1
  write_profile "$r" '{"dir":null,"lock":"go.sum","strategy":"skip","install":"go mod download"}' .env.local
  STACK_DEPDIRS=''
  STACK_PROBE='GOPROXY=off go run .'
  STACK_EXPECT=ok
}

# --- 9. A PHP application with a JS front-end: composer + pnpm in one repo --------------------------

stack_tools_monorepo() { echo php=php composer=phpPackages.composer node=nodejs pnpm=pnpm; }
fixture_monorepo() {
  local r=$1
  write_dev_config "$r" 'vendor/' 'node_modules/'
  printf '{ "name": "fixture/shop", "require": { "psr/log": "^3.0" } }\n' >"$r/composer.json"
  printf '<?php\nrequire __DIR__ . "/vendor/autoload.php";\necho interface_exists("Psr\\\\Log\\\\LoggerInterface") ? "ok" : "broken";\n' \
    >"$r/probe.php"
  printf '{ "name": "fixture-shop-assets", "private": true, "dependencies": { "is-number": "7.0.0" } }\n' >"$r/package.json"
  printf 'process.stdout.write(require("is-number")(5) ? "ok" : "broken");\n' >"$r/probe.js"
  tc "$r" 'composer install --no-interaction --no-progress --quiet && pnpm install' || return 1
  write_profile "$r" '{"dir":"vendor","lock":"composer.lock","strategy":"hardlink",
      "install":"composer install --no-interaction --no-progress","verify":"test -r vendor/autoload.php"},
    {"dir":"node_modules","lock":"pnpm-lock.yaml","strategy":"install","install":"pnpm install --frozen-lockfile"}' .env.local
  STACK_DEPDIRS='vendor node_modules' STACK_LINKDIRS=vendor
  STACK_PROBE='php probe.php && node probe.js'
  STACK_EXPECT=okok
}

# --- 10. No profile at all: the hooks must leave everything alone -----------------------------------

stack_tools_noprofile() { echo node=nodejs npm=nodejs; }
fixture_noprofile() {
  local r=$1
  # A .env in the main checkout and NO .worktreeinclude: anything that shows up in the worktree was
  # put there by the plugin.
  printf '.claude/worktrees/\n.env\nnode_modules/\n' >"$r/.gitignore"
  printf 'APP_NAME=fixture\n' >"$r/.env"
  printf '{ "name": "fixture-plain", "version": "1.0.0", "private": true, "dependencies": { "is-number": "7.0.0" } }\n' \
    >"$r/package.json"
  tc "$r" 'npm install --no-audit --no-fund' || return 1
  STACK_DEPDIRS=node_modules
  STACK_PROBE=''
  STACK_EXPECT=''
  STACK_ENVFILE=''
}

# --- 11. A docker-compose service: runtime isolation only, no container is started ------------------

stack_tools_compose() { echo docker=; }
fixture_compose() {
  local r=$1
  printf '.claude/worktrees/\n.env\n' >"$r/.gitignore"
  cat >"$r/compose.yaml" <<'YAML'
services:
  web:
    image: nginx:alpine
    ports:
      - "${APP_PORT:-8080}:80"
YAML
  docker compose version >/dev/null 2>&1 || return 1
  # Compose reads .env for both interpolation and the project name, so the profile's env file IS
  # .env: the port and the project name are what two worktrees' stacks would otherwise collide on.
  write_profile "$r" '' .env ', "COMPOSE_PROJECT_NAME": "fixture_{slug}"'
  STACK_DEPDIRS=''
  # `config` resolves the file without a daemon: it prints the project name and published port the
  # worktree's stack WOULD use.
  STACK_PROBE='docker compose config 2>/dev/null | sed -n "s/^name: //p; s/^ *published: \"*\([0-9]*\)\"*$/\1/p" | paste -sd: -'
  STACK_EXPECT='fixture_{slug}:{port}'
}
