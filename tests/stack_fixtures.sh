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
#                         (network allowed), runs detect_deps for the deps[] /pitlane-setup would
#                         propose, writes the profile with write_profile, and sets:
#                           STACK_DEPDIRS   main-checkout dependency dirs that must stay byte-identical
#                           STACK_LINKDIRS  those of them the stack expects hardlinked, which the
#                                           worktree must share inodes with rather than reinstall —
#                                           checked against what detection chose
#                           STACK_OWNFILES  files (globs allowed) the worktree's OWN installed tree
#                                           must hold, at least one under every dependency dir that
#                                           is not hardlinked: a worktree sits inside the main
#                                           checkout, so a runtime that walks up the tree would
#                                           find main's and pass without them
#                           STACK_PROBE     shell run in a worktree, through the toolchain, that must
#                                           print STACK_EXPECT when the dependencies are usable. It
#                                           gets PROBE_ROOT (the worktree) and checks that what it
#                                           loaded resolved inside it, not in the main checkout
#                           STACK_EXPECT    what STACK_PROBE prints; {slug} and {port} stand for the
#                                           worktree's own
#                           STACK_ENVFILE   the profile's env file ('' when there is no runtime)
#                           STACK_SERVE     runtime.serve, set BEFORE write_profile, which then adds
#                                           it with `url` http://localhost:{port}/ ('' = no serve)
#                           STACK_SERVE_PATH, STACK_SERVE_EXPECT
#                                           what /pitlane-serve's app must answer at that path of
#                                           its URL; {port} stands for the worktree's own
#                           STACK_INPLACE   shell run in the first worktree, through the toolchain, that
#                                           rewrites files of a hardlinked dir IN PLACE (ADR-022); the
#                                           main checkout's copy must keep its bytes and inodes
#                           STACK_INPLACE_NET the same for a command that needs the registry: one that
#                                           fails is reported, not counted. Tracked files either changes
#                                           are restored after it
#                           STACK_ARTIFACTS the artifacts[] body, set BEFORE write_profile ('' = none)
#                           STACK_ART_FILE  a file the build writes: the worktree with unchanged
#                                           inputs holds a copy of the main checkout's
#                           STACK_ART_CHANGE shell run in the second worktree before its session
#                                           starts, committing a change to an input, so its build
#                                           output is built rather than taken from main. A branch
#                                           must hold the commit too, or teardown keeps it as work
#                           STACK_ART_EXPECT what STACK_ART_FILE then holds
#                         It returns non-zero when the tool could not build the fixture (offline, a
#                         registry down), which the suite reports as a SKIP, not a plugin failure.
#
# Every name in here is invented. Dependencies are one tiny, dependency-free package per ecosystem.
#
# Expects from the sourcing suite: STACK_SHELL (the wrapper, '' for the host), tc (runs a command
# string in a directory through that wrapper), STACK_DB (where seeds stand in for databases),
# STACK_PORT_BASE and SCRIPTS (the plugin's hooks/scripts).

# The deps[] body /pitlane-setup would write for $1: every `dep` record detect.sh proposes, with its
# dir, lock, strategy, install and verify as detected — so the suite proves the detection defaults
# against real installs. Where detection withholds a verify (a `no default verify:` depNote), the
# developer supplies one; here that is a `dir=verify` argument, and supplying one detection already
# proposes is a fixture error. A hardlinked entry gets `copy` from its `depCopy` records, `[]` when
# there are none, as setup writes it. Sets STACK_DEPS (the JSON body), STACK_DETECTED_LINKDIRS (the
# dirs it chose to hardlink), STACK_COPY (each copy path, joined to its dir) and STACK_DETECT_ERRORS
# ('' when the fixture and detection agree).
detect_deps() {  # $1 = repo, $@ = dir=verify for the entries detection gives none
  local repo=$1 out
  shift
  out=$(WT_SKIP_PROBES=1 bash "$SCRIPTS/detect.sh" "$repo" 2>/dev/null | python3 -c '
import json, sys
supplied = dict(a.split("=", 1) for a in sys.argv[1:])
entries, links, errors, copies = [], [], [], []
lines = [line.rstrip("\n").split("\t") for line in sys.stdin]
copy_of = {}
for f in lines:
    if f[0] == "depCopy":
        copy_of.setdefault(f[1], []).append(f[2])
for f in lines:
    if f[0] != "dep":
        continue
    _, n, d, lock, strategy, install, verify = (f + [""] * 7)[:7]
    if d in supplied:
        if verify:
            errors.append("detection proposes a verify for %s (%s); the fixture must not override it" % (d, verify))
        verify = supplied.pop(d)
    elif not verify and d and strategy != "skip":
        errors.append("detection withholds a verify for %s and the fixture supplies none" % d)
    entry = {"dir": d or None, "lock": lock, "strategy": strategy, "install": install, "verify": verify}
    if strategy == "hardlink":
        links.append(d)
        entry["copy"] = copy_of.get(n, [])
        copies += [d + "/" + c for c in entry["copy"]]
    entries.append(json.dumps(entry))
errors += ["the fixture supplies a verify for %s, which detection does not propose" % d for d in supplied]
print(" ".join(links))
print(" ".join(copies))
print("; ".join(errors))
print(",\n    ".join(entries))
' "$@") || { STACK_DEPS='' STACK_DETECTED_LINKDIRS='' STACK_COPY='' STACK_DETECT_ERRORS='detect.sh or its conversion failed'; return 0; }
  { read -r STACK_DETECTED_LINKDIRS; read -r STACK_COPY; read -r STACK_DETECT_ERRORS; STACK_DEPS=$(cat); } <<<"$out"
}

# The profile every runtime-isolating stack gets: the toolchain wrapper, the deps given, a port and
# an env file, and a seed/teardown pair that create and remove "$STACK_DB/<slug>" — a database stand-in
# outside the worktree, so "allocated" and "released" are both observable after the directory is gone.
write_profile() {  # $1 = repo, $2 = deps[] body, $3 = env file, $4 = extra env.vars body (may be '')
  local repo=$1 deps=$2 envfile=$3 extra=${4-} serve='' artifacts=''
  mkdir -p "$repo/.claude"
  [ -z "${STACK_SERVE:-}" ] || serve=",
    \"serve\": \"$STACK_SERVE\",
    \"url\": \"http://localhost:{port}/\""
  [ -z "${STACK_ARTIFACTS:-}" ] || artifacts="
  \"artifacts\": [$STACK_ARTIFACTS],"
  cat >"$repo/.claude/worktree-profile.json" <<JSON
{
  "schemaVersion": 1,
  "shell": "$STACK_SHELL",
  "shellArgs": "argv",
  "copy": [],
  "deps": [$deps],$artifacts
  "runtime": {
    "slug": "{slug}",
    "port": { "var": "APP_PORT", "base": $STACK_PORT_BASE, "span": 200 },
    "env": { "file": "$envfile", "vars": { "APP_DATABASE": "fixture_{slug}"$extra } },
    "seed": ".claude/worktree-seed.sh",
    "teardown": ".claude/worktree-teardown.sh"$serve
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

# Probes that pass only when the package resolved inside the worktree (PROBE_ROOT), not in the main
# checkout a parent-directory lookup would reach.
write_node_probe() {  # $1 = file; requires is-number
  cat >"$1" <<'JS'
const p = require.resolve("is-number");
const own = p.startsWith(process.env.PROBE_ROOT + "/");
process.stdout.write(own && require("is-number")(5) ? "ok" : "broken: " + p);
JS
}
write_php_probe() {  # $1 = file; requires psr/log through composer's autoloader
  cat >"$1" <<'PHP'
<?php
require __DIR__ . "/vendor/autoload.php";
$file = (new ReflectionClass("Psr\\Log\\LoggerInterface"))->getFileName();
echo strpos($file, getenv("PROBE_ROOT") . "/") === 0 ? "ok" : "broken: $file";
PHP
}

# --- 1. pnpm workspace: two packages, one depending on the other through workspace:* ----------------

stack_tools_pnpm() { echo node=nodejs pnpm=pnpm; }
fixture_pnpm() {
  local r=$1
  write_dev_config "$r" 'node_modules/' 'public/build/'
  mkdir -p "$r/packages/lib" "$r/packages/web" "$r/assets"
  printf '{ "name": "fixture-root", "private": true, "scripts": { "build": "node build.js" } }\n' >"$r/package.json"
  # A front-end build of the shape bundlers leave: an output file and a manifest naming it.
  printf 'export const version = 1;\n' >"$r/assets/app.js"
  cat >"$r/build.js" <<'JS'
const fs = require("fs");
fs.mkdirSync("public/build", { recursive: true });
fs.writeFileSync("public/build/app.js", "/* built */ " + fs.readFileSync("assets/app.js", "utf8"));
fs.writeFileSync("public/build/manifest.json", JSON.stringify({ "assets/app.js": { file: "app.js" } }));
JS
  printf 'packages:\n  - "packages/*"\n' >"$r/pnpm-workspace.yaml"
  printf '{ "name": "@fixture/lib", "version": "1.0.0", "main": "index.js", "dependencies": { "is-number": "7.0.0" } }\n' \
    >"$r/packages/lib/package.json"
  printf 'module.exports = require("is-number");\n' >"$r/packages/lib/index.js"
  printf '{ "name": "@fixture/web", "version": "1.0.0", "dependencies": { "@fixture/lib": "workspace:*" } }\n' \
    >"$r/packages/web/package.json"
  # Both the workspace package and the registry package it uses must resolve inside the worktree.
  cat >"$r/packages/web/probe.js" <<'JS'
const path = require("path"), root = process.env.PROBE_ROOT + "/";
const lib = require.resolve("@fixture/lib");
const num = require.resolve("is-number", { paths: [path.dirname(lib)] });
const own = lib.startsWith(root) && num.startsWith(root);
process.stdout.write(own && require("@fixture/lib")(5) ? "ok" : "broken: " + lib + " " + num);
JS
  tc "$r" 'pnpm install && pnpm run build' || return 1
  detect_deps "$r"
  STACK_ARTIFACTS='{"dir": "public/build", "inputs": ["assets", "build.js", "pnpm-lock.yaml"],
    "build": "pnpm run build", "verify": "test -f public/build/manifest.json"}'
  STACK_ART_FILE=public/build/app.js
  STACK_ART_CHANGE="printf 'export const version = 2;\\n' >assets/app.js && git commit -qam 'change an input' && git branch fixture-input-change"
  STACK_ART_EXPECT='/* built */ export const version = 2;'
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS='node_modules packages/lib/node_modules packages/web/node_modules'
  STACK_OWNFILES='node_modules/.modules.yaml packages/lib/node_modules/is-number/package.json
    packages/web/node_modules/@fixture/lib/package.json'
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
  write_node_probe "$r/probe.js"
  # The app /pitlane-serve starts: it answers only if is-number resolves inside its own checkout.
  cat >"$r/server.js" <<'JS'
const port = Number(process.argv[2]);
require("http").createServer((req, res) => {
  const p = require.resolve("is-number");
  res.end((p.startsWith(process.cwd() + "/") ? "ok" : "broken: " + p) + " " + port);
}).listen(port, "127.0.0.1");
JS
  tc "$r" 'npm install --no-audit --no-fund' || return 1
  detect_deps "$r"
  STACK_SERVE='node server.js {port}' STACK_SERVE_PATH=/ STACK_SERVE_EXPECT='ok {port}'
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS=node_modules STACK_LINKDIRS=node_modules
  # Measured: adds the package and rewrites node_modules/.package-lock.json in place.
  STACK_INPLACE_NET='npm install --no-audit --no-fund isarray@2.0.5'
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
  write_node_probe "$r/probe.js"
  tc "$r" 'bun install --save-text-lockfile' || return 1
  # bun writes no marker of a finished install, so detection proposes no verify; the developer names
  # a package this repo always installs, as /pitlane-setup asks them to.
  detect_deps "$r" 'node_modules=test -f node_modules/is-number/package.json'
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS=node_modules
  STACK_OWNFILES=node_modules/is-number/package.json
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
  cat >"$r/probe.py" <<'PY'
import os, six, sys
own = six.__file__.startswith(os.environ["PROBE_ROOT"] + "/")
sys.stdout.write("ok" if own and six.PY3 else "broken: " + six.__file__)
PY
  tc "$r" 'uv lock -q && uv sync -q --frozen' || return 1
  detect_deps "$r"
  # The worktree's own venv serves the worktree, whose env file names its own port.
  STACK_SERVE='.venv/bin/python -m http.server {port} --bind 127.0.0.1'
  STACK_SERVE_PATH=/.env.local STACK_SERVE_EXPECT='APP_PORT={port}'
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS=.venv
  STACK_OWNFILES='.venv/lib/python*/site-packages/six.py'
  STACK_PROBE='.venv/bin/python probe.py'
  STACK_EXPECT=ok
}

# --- 5. composer: vendor/ hardlinked from the main checkout -----------------------------------------

stack_tools_composer() { echo php=php composer=phpPackages.composer; }
fixture_composer() {
  local r=$1
  write_dev_config "$r" 'vendor/'
  printf '{ "name": "fixture/app", "require": { "psr/log": "^3.0" } }\n' >"$r/composer.json"
  write_php_probe "$r/probe.php"
  cat >"$r/serve.php" <<'PHP'
<?php
require __DIR__ . "/vendor/autoload.php";
$file = (new ReflectionClass("Psr\\Log\\LoggerInterface"))->getFileName();
echo (strpos($file, __DIR__ . "/") === 0 ? "ok" : "broken: $file") . " " . $_SERVER["SERVER_PORT"];
PHP
  tc "$r" 'composer install --no-interaction --no-progress --quiet' || return 1
  detect_deps "$r"
  # Through the profile's nix shell: php is not on the host.
  STACK_SERVE='php -S 127.0.0.1:{port} serve.php' STACK_SERVE_PATH=/ STACK_SERVE_EXPECT='ok {port}'
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS=vendor STACK_LINKDIRS=vendor
  # Measured: both rewrite vendor/composer/autoload_*.php and installed.* in place.
  STACK_INPLACE='composer dump-autoload -o --quiet'
  STACK_INPLACE_NET='composer require --quiet --no-interaction --no-progress psr/container:^2.0'
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
  cat >"$r/probe.rb" <<'RB'
require "rack"
gem = Gem.loaded_specs["rack"].full_gem_path
own = gem.start_with?(ENV["PROBE_ROOT"] + "/")
print(own && defined?(Rack::RELEASE) ? "ok" : "broken: #{gem}")
RB
  tc "$r" 'bundle config set --local path vendor/bundle >/dev/null && bundle install --quiet' || return 1
  detect_deps "$r"
  write_profile "$r" "$STACK_DEPS" .env.local
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
  detect_deps "$r"
  write_profile "$r" "$STACK_DEPS" .env.local
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
  detect_deps "$r"
  write_profile "$r" "$STACK_DEPS" .env.local
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
  write_php_probe "$r/probe.php"
  printf '{ "name": "fixture-shop-assets", "private": true, "dependencies": { "is-number": "7.0.0" } }\n' >"$r/package.json"
  write_node_probe "$r/probe.js"
  tc "$r" 'composer install --no-interaction --no-progress --quiet && pnpm install' || return 1
  detect_deps "$r"
  write_profile "$r" "$STACK_DEPS" .env.local
  STACK_DEPDIRS='vendor node_modules' STACK_LINKDIRS=vendor
  STACK_OWNFILES='node_modules/.modules.yaml node_modules/is-number/package.json'
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
