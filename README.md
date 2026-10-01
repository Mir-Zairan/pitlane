<p align="center">
  <img src="assets/pitlane-banner.svg" alt="Pitlane — parallel Claude Code sessions, each in its own lane" width="720">
</p>

<p align="center"><b><i>Many sessions. One project. No pile-ups.</i></b></p>

When Claude Code starts a session in a separate copy of your project, that copy is empty-handed: it has
no settings, no installed packages, and it shares the same database and web address as every other copy.
So one session can break another's work without anyone noticing. Pitlane fixes that: like a pit lane readies a car before it goes back out, it readies each copy before a session starts. Every new copy
comes ready to use and gets its own database and its own address, so each session works on its own.

## What it does

| Feature | What you get |
|---|---|
| **Settings** | Copies `.env` and other ignored config into each copy |
| **Packages** | Linked from your main copy when unchanged, so it's instant and uses no extra disk |
| **Database & port** | Each copy gets its own, so sessions never clash |
| **Pull requests** | `claude -w "#1234"` opens a PR, set up like any other copy |
| **Reopening** | A copy that's already set up opens in seconds |
| **Slow starts** | Tells you what's missing; `/pitlane-finish` completes it |
| **Cleanup** | `/pitlane-tidy` removes old copies, never unsaved work |

Your app's server is not started for you: each copy is ready, and you run it when you need it.

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

   Claude looks at your project, asks you a few questions, and saves the answers. You only do this once
   per project.

3. **Work as usual.** Start a session in its own copy with `claude -w my-task`. It comes ready to run, with
   its own database and address. Start as many as you like.

4. **If a copy was not fully ready.** The first start in a new copy can be slow — a toolchain to
   download, a large install. Pitlane does the quick steps first and, if time runs out, tells the session
   what is still missing. To finish it, type:

   ```
   /pitlane-finish
   ```

5. **Tidy up now and then.** When you are finished with some copies, type:

   ```
   /pitlane-tidy
   ```

   It shows what can be cleaned up and removes only what you choose. Anything with unsaved work is
   always kept.

## License

MIT
