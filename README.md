# worktree

Run several Claude Code sessions on the same project at the same time, without them getting in each
other's way.

When Claude Code starts a session in a separate copy of your project, that copy is empty-handed: it has
no settings, no installed packages, and it shares the same database and web address as every other copy.
So one session can break another's work without anyone noticing. This plugin fixes that. Every new copy
comes ready to use and gets its own database and its own address, so each session works on its own.

## How to use it

1. **Install it** in Claude Code:

   ```
   claude plugin marketplace add Mir-Zairan/worktree
   claude plugin install worktree@worktree --scope user
   ```

2. **Set it up once for your project.** Open Claude Code in the project and type:

   ```
   /worktree-calibrate
   ```

   Claude looks at your project, asks you a few questions, and saves the answers. You only do this once
   per project.

3. **Work as usual.** Start a session in its own copy with `claude -w my-task`. It comes ready to run, with
   its own database and address. Start as many as you like.

4. **Tidy up now and then.** When you are finished with some copies, type:

   ```
   /worktree-prune
   ```

   It shows what can be cleaned up and removes only what you choose. Anything with unsaved work is
   always kept.

## License

MIT
