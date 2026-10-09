<p align="center">
  <img src="assets/pitlane-banner.svg" alt="Pitlane — parallel Claude Code sessions, each in its own lane" width="720">
</p>

<h1 align="center">Pitlane</h1>

<p align="center"><b><i>Many sessions. One project. No pile-ups.</i></b></p>

<p align="center">
  A <a href="https://claude.com/claude-code">Claude Code</a> plugin that gets every git worktree ready to work in,
  so you can run parallel Claude Code sessions on one project without them colliding.
</p>

<p align="center">
  <a href="https://github.com/Mir-Zairan/pitlane/releases"><img src="https://img.shields.io/badge/version-0.7.1-blue" alt="Version 0.7.1"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Claude%20Code-plugin-d97757" alt="Claude Code plugin">
</p>

## The problem

`claude -w my-task` starts a session in a **worktree**: a second checkout of your project in its own
folder. But that folder has no installed packages, and it shares your database and your app's port
with every other session. Sessions quietly break each other's work.

**Pitlane gets each worktree ready before the session starts:** packages in place, its own database,
its own port.

## Quick start

1. **Install**

   ```
   claude plugin marketplace add Mir-Zairan/pitlane
   claude plugin install pitlane@pitlane --scope user
   ```

2. **Set up your project once.** In your project, run `/pitlane-setup`. Claude asks a few questions
   and shows you the commands it will run, for you to approve.

3. **Work as usual.** Run `claude -w my-task` and start typing. Slow steps (installs, the database)
   finish in the background.

That's it. When you want the app running, type `/pitlane-serve`.

## What you get

- **Packages, fast.** Linked from your main checkout when nothing changed, so it takes a second and
  almost no disk. Installed when the branch changed its lockfile.
- **Its own database and port** for every worktree. Claude is told the address (`WORKTREE_URL`).
- **Your settings** (`.env` and other ignored files) copied in and pointed at that worktree's database.
- **Build output** (such as a front-end bundle) copied from your main checkout, or built if its
  sources changed.
- **The app on request.** `/pitlane-serve` starts it on the worktree's own port.
- **Notes for Claude.** Setup can save a few lines of advice about your project's worktrees. Claude
  sees them only in a worktree, and only after you approve them.
- **An honest status.** Each step is reported as ready, ready with warnings, or missing, with the
  reason.
- **No waiting.** Your first prompt starts at once. Setup runs at low priority, so your machine stays
  usable.
- **Cleanup.** Removing a worktree stops the server Pitlane started there and runs your teardown
  script, which drops that worktree's database. `/pitlane-tidy` clears what old worktrees left behind.
  Claude Code removes a worktree with no changes when its session exits, and Ctrl+C at its exit
  prompt counts as yes. Git can't see what is in a database, so copy out anything you need first, or
  exit with `/exit` and choose to keep the worktree.

## Commands

| Command | Use it to |
|---|---|
| `/pitlane-setup` | Set up a project (once, or after its tooling changes) |
| `/pitlane-finish` | Wait for a worktree's setup to finish, approve held-back commands, or retry a failed install |
| `/pitlane-serve` | Start or stop the worktree's app |
| `/pitlane-tidy` | Remove leftovers from old worktrees, only what you pick |

You never have to run `/pitlane-finish`. Claude does it when it needs something that isn't ready yet.

## Pull requests

`claude -w "#1234"` opens a pull request in its own worktree. **Nothing from it runs until you
approve**, and you're asked again after every new push.

- If the PR doesn't change the lockfile, it gets a private copy of your packages, so none of its code
  runs.
- If it does change the lockfile, approving runs its install, including its package scripts. Read the
  changes first, as you would before installing it by hand.

A PR's worktree never shares package files with your main checkout, so nothing done there can change
your own setup.

## Good to know

- **Pitlane starts nothing by itself.** The app runs only when you ask, with `/pitlane-serve`.
- **It doesn't edit your project's scripts.** If your own start command hardcodes a port, setup tells
  you and uses a command with the worktree's port instead.
- **It only stops what it started.** A server you started by hand is yours to stop.
- **Check setup has finished before trusting a run.** Worktrees live inside your project folder, so
  until their own packages exist, Node or Python may quietly use the main checkout's.

## Requirements

- `bash`, `git`, and `python3` or `jq`, on Linux or macOS.
- **Package managers:** Composer, npm, pnpm, Yarn, Bun, uv, Poetry, Pipenv, Bundler, Mix, Cargo, Go.
- **Toolchains:** Nix, direnv, or tools installed on your machine.
- **Databases:** any. You supply a short script that creates a worktree's database. Pitlane runs it
  with that worktree's name and port.

<details>
<summary><b>Advanced: running the script yourself</b></summary>

The commands call one script, which you can run from inside a worktree:
`bash <plugin>/hooks/scripts/bootstrap.sh <option>`

| Option | What it does |
|---|---|
| `--finish` | Finish setup now |
| `--finish --retry-failed` | The same, and retry an install that failed before |
| `--changed` | List tracked files an install changed |
| `--restore <path>` | Put back one of those files |
| `--serve` / `--serve-stop` | Start or stop the app |
| `--review` / `--approve <fingerprint>` | Show the setup commands, then approve exactly what was shown |

</details>

## License

MIT
