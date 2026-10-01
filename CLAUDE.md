# AI Agent

Instructions for working on this plugin.

## Conventions

- **The engine is general; no repo's identity belongs in it.** The plugin works for any repository.
  Naming *ecosystems* is fine and necessary — `composer`, `pnpm`, `uv`, `flake.nix` are what the
  detection tables are made of. Naming a particular *repository* is not: no local paths, no
  project-specific env vars, database names, ports or ticket prefixes in code, comments, tests or
  examples. When a concrete example genuinely helps, invent a neutral one (`alice/fix-99`).
- **Hooks are deterministic shell.** No model calls, no network, no interactive prompts inside a hook.
  Anything that needs judgement happens in `/worktree-calibrate` and is written to the profile.
- **A hook must never cost the user their session.** On any internal failure, warn on stderr, still emit
  the worktree path, exit 0. A worktree missing its `vendor/` is recoverable; a session that won't start
  is not.
- **stdout is a protocol.** For `WorktreeCreate`, stdout is the worktree path and nothing else. Every
  informational message goes to stderr.
- Shell scripts: `bash`, `set -euo pipefail`, shellcheck-clean, POSIX tools only (no `jq` dependency —
  fall back to `python3`).
- Plugin scripts are referenced as `"${CLAUDE_PLUGIN_ROOT}"/hooks/scripts/<name>.sh`.
- Conventional commits, present tense: `feat(bootstrap): copies gitignored config into new worktrees`.
- No `Co-Authored-By` lines and no generated-with attribution in commits or PR bodies.

## Testing

There is no target repo inside this one. Test against scratch git repositories created under `/tmp`;
the suites in `tests/` do exactly that. Run them with `nix shell nixpkgs#jq -c tests/<suite>.sh` so both
JSON backends are exercised.

Never test a destructive path (teardown, prune, a seed or teardown script) against a real repository
until it has passed against a scratch one.
