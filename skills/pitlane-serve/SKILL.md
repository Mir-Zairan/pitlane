---
name: pitlane-serve
description: Start this worktree's app on its own port and URL, or stop the server Pitlane started here — the profile knows the command that serves the worktree, not the main checkout. Use when the session needs the app running (a browser check, an end-to-end test, an API call against it), when a session was told "To run the app, use /pitlane-serve", or when the user asks to start, restart or stop the worktree's dev server.
---

# Pitlane — start this worktree's app

A worktree has its own port, and its env files point at it. The repository's own start command often
hardcodes a port the main checkout's server already holds. Pitlane's profile has the command that serves
*this* worktree (`runtime.serve`). This command starts it detached, records it, and waits until its URL
answers.

## Run it

From the worktree's root:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bootstrap.sh" --serve
```

Run it **in the background** (`run_in_background: true`) and wait for it to finish. It waits for any
setup still running in the background, and then for the app to answer, which can take minutes. The
server keeps running after the command ends; it is detached on purpose.

It prints progress on stderr and ONE line on stdout as its last word. Report that line to the user
in one line:

- `Pitlane: serving at <url>` — the app answers there. Use that URL for the browser check or the
  tests, not a port from the repo's docs or the main checkout.
- `Pitlane: already serving at <url>` — Pitlane's server for this worktree was already running. Use it.
- `Pitlane: already started at <url> (pid …), but it does not answer yet (log: …)` — it is still
  starting, or stuck. Read the end of the log. Run `--serve` again later, or restart it (below).
- `Pitlane: not served — <reason>` — nothing was started, unless the line says the server is still
  running. Relay the reason. Then:
  - `this worktree's setup is not complete — …` or `… has no port yet`: run /pitlane-finish, which
    completes the setup, then run `--serve` again.
  - `… did not answer within …s; the server is still running …` or `the server exited before …
    answered`: read the end of the log the line names and tell the user what it says. Do not keep
    retrying.
  - `something is already answering at <url>`: another process holds this worktree's port. Pitlane
    did not start it and will not stop it. Tell the user.
  - `the profile names no runtime.serve`, or `runtime.serve is refused`, or `runtime.url is unusable`:
    the profile needs fixing; suggest /pitlane-setup.
  - `too little memory is free`: tell the user to close something heavy and try again.
- `Pitlane: not run — the profile's commands are not approved …` — `serve` is a command the branch
  wrote, so it waits for the developer's approval like every other one. Follow **Approval** in
  /pitlane-finish: review, show the user, and approve only on their explicit word.
- `Pitlane: run /pitlane-serve from inside a worktree …` — the session is not in a worktree; say so.

## Restart or stop it

To stop the server Pitlane started here (and only that one), from the worktree's root:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/scripts/bootstrap.sh" --serve-stop
```

It stops the server only if the process is still the one Pitlane recorded starting, checked by its
process start time. It never stops a process by its port. Its one line says what happened:
`stopped the server at <url>`, `no server … is recorded`, `… had already exited`, or `pid … now belongs
to another process … left alone`. Then run `--serve` again to restart, for example after a config
change the server does not reload. Offer a restart when the user wants one.

## The rules

- **Never start the app by another command** while the profile has `runtime.serve` — not `npm run
  dev`, `php -S`, `rails s`, `docker compose up` or the repo's own script. Those know nothing of this
  worktree's port. They collide with the main checkout's server, or serve the wrong checkout, and
  Pitlane cannot stop them later.
- **Never kill a server by its port or by name.** It may be the main checkout's or another worktree's.
  Use `--serve-stop`; it stops only what Pitlane started here.
- **Never edit the profile** to make serving work. `serve` and `url` are the developer's, chosen in
  /pitlane-setup, and an edit needs their approval again. If the command is wrong, say so and suggest
  /pitlane-setup.
