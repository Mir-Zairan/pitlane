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
  <a href="https://github.com/Mir-Zairan/pitlane/releases"><img src="https://img.shields.io/github/v/tag/Mir-Zairan/pitlane?label=version" alt="Latest version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/Mir-Zairan/pitlane" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Claude%20Code-plugin-d97757" alt="Claude Code plugin">
</p>

When Claude Code starts a session in a separate copy of your project (a git worktree, which is what
`claude -w` makes), that copy has its own files, and even your `.env` if you list it in
`.worktreeinclude`. But it has no installed packages, and because every copy has the same `.env`, they
all share one database and one web address.
So one session can break another's work without anyone noticing, and a browser pointed at your app
shows whichever session started its server first. Pitlane fixes that: like a pit lane readies a car before it goes back out, it readies each copy before a session starts. Every new copy
comes ready to use and gets its own database and its own address, so each session works on its own.

## What it does

| Feature | What you get |
|---|---|
| **Settings** | Copies `.env` and other ignored config into each copy, then points it at that copy's own database and port |
| **Packages** | Linked from your main copy when unchanged, so it's instant and uses no extra disk. A branch that changed its lockfile links from another finished copy with the same lockfile instead (never from a pull request's copy), and installs only when there is none. Files a package manager rewrites in place (Composer's autoloader, npm's `.package-lock.json`) are real copies, so a command run in one copy never reaches the main one |
| **Honest status** | A check you approve decides whether packages are installed, not the installer's exit code. Each is reported as ready, ready with warnings, or missing with the reason, and any tracked file an install changed is named and never put back without your word |
| **Database & port** | Each copy gets its own, so sessions never clash. Claude's own shell gets `WORKTREE_PORT` and `WORKTREE_URL` too, and a subagent in a worktree of its own is told that worktree's |
| **Build output** | Ignored build output (a front-end bundle, say) is copied from your main copy when its sources match, or built in the background when they don't |
| **Your app, on request** | `/pitlane-serve` starts the app on that copy's own port and tells Claude the address |
| **Pull requests** | `claude -w "#1234"` opens a PR in its own copy. You approve its setup before anything runs, and again after each new push |
| **Approved commands only** | Nothing a branch's setup would run is run until you approve it, so a PR can't run code on your machine just by being opened |
| **Reopening** | A copy that's already set up opens in seconds |
| **No waiting** | Installs, builds and the database finish in the background, so your first prompt starts at once |
| **Light on your machine** | Setup runs at low priority under a memory cap, so it can't freeze your desktop |
| **Cleanup** | Removing a copy stops the server Pitlane started there, and `/pitlane-tidy` stops one left running and removes old copies, never unsaved work |

### What it does not do

- **It starts nothing on its own.** Each copy is ready to run; the app runs only when you or Claude ask
  for it with `/pitlane-serve`.
- **It never edits your project's own scripts.** If a start command hardcodes its port, or a test helper
  pins its own database, `/pitlane-setup` points it out and writes a command that uses the copy's port
  instead. Changing the script is up to you.
- **It stops only what it started.** A server you started by hand, in any copy, is yours to stop:
  Pitlane never stops a process because of the port it holds or the folder it runs in.
- **A copy inside your main checkout can reach the main checkout's packages.** `claude -w` puts copies
  under `.claude/worktrees/`, so while a copy's own `node_modules` (or similar) is missing, Node and
  Python can quietly find the main checkout's instead. Wait for setup (`/pitlane-finish`) before
  trusting a run.

## Works with

- **Package managers:** Composer, npm, pnpm, Yarn, Bun, uv, Poetry, Pipenv, Bundler, Mix, Cargo and Go
  modules. Pitlane spots them from their lockfiles.
- **Toolchains:** Nix flakes and `shell.nix`, direnv, or plain tools on your machine. A devcontainer
  is spotted too, and you point Pitlane at the container command yourself.
- **Databases and services:** any. You give Pitlane a short script that creates a copy's database
  (MySQL, PostgreSQL, a Docker container, whatever your project uses); it runs it with that copy's own
  name and port, and a matching script removes it again.

It needs `bash`, `git`, and either `python3` or `jq`, on Linux or macOS.

## How to use it

1. **Install it** in Claude Code:

   ```
   claude plugin marketplace add Mir-Zairan/pitlane
   claude plugin install pitlane@pitlane --scope user
   ```

2. **Set it up once for your project.** Open Claude Code in the project and type:

   ```
   /pitlane-setup
   ```

   Claude looks at your project, asks you a few questions, saves the answers, and shows you the
   commands setup will run so you can approve them. You only do this once per project. If those
   commands later change, in your branch or someone else's, Pitlane holds them back until you approve
   the new version with `/pitlane-finish`.

3. **Work as usual.** Start a session in its own copy with `claude -w my-task` and type your first
   prompt straight away. Settings, linked packages and the port are done before it; installs and the
   database finish in the background a few minutes later, and Claude waits for them before running
   anything that needs them. Start as many copies as you like.

4. **Only if you need it.** You never have to finish a setup by hand. Type `/pitlane-finish` only to
   wait for the background setup yourself, say before starting the server in the first few minutes, or
   when the session says setup was held back (not enough memory, a toolchain that failed to start,
   commands waiting for your approval):

   ```
   /pitlane-finish
   ```

5. **Run the app when you need it.** Type `/pitlane-serve`. It waits for setup, starts the app on this
   copy's port, and replies `serving at <url>` or why it could not. `/pitlane-serve` stops it again,
   and so does removing the copy.

6. **Tidy up now and then.** When you are finished with some copies, type:

   ```
   /pitlane-tidy
   ```

   It shows what can be cleaned up and removes only what you choose. Anything with unsaved work is
   always kept.

## Commands

| Command | What it does |
|---|---|
| `/pitlane-setup` | Looks at the project once and saves how a copy is set up |
| `/pitlane-finish` | Waits for or completes a copy's setup, and reports what is ready |
| `/pitlane-serve` | Starts the copy's app on its own port, or stops the one Pitlane started |
| `/pitlane-tidy` | Finds what old copies left behind and removes what you choose |

The skills call one script, which you can also run yourself from inside a copy as
`bash <plugin>/hooks/scripts/bootstrap.sh <option>`:

| Option | What it does |
|---|---|
| `--finish` | Completes the setup now, with an hour to do it rather than the session start's budget |
| `--finish --retry-failed` | The same, and also retries an install that failed before (it is not retried on its own until the lockfile or command changes) |
| `--changed` | Lists the tracked files an install changed |
| `--restore <path>` | Puts back one file `--changed` listed, and nothing else |
| `--serve` / `--serve-stop` | Starts the app, or stops the server Pitlane started |
| `--review` / `--approve <fingerprint>` | Shows the setup commands, then approves exactly what was shown |

## Questions

**Is it safe to open someone else's pull request?** Pitlane runs nothing from it without asking. It
copies settings and assigns the port, then shows you the setup commands and waits for your approval,
and it asks again after every new push. Approving lets the install run the pull request's own package
scripts, so read its changes first, as you would before installing it by hand.

**Does it slow down starting a session?** No. Only the quick steps run before your first prompt;
installs and the database finish in the background.

**Can I use it without a database?** Yes. Without one, Pitlane just copies settings and installs or
links packages.

## License

MIT
