# Changelog

## 1.0.0 - 2026-09-07

- First release: keep a list of your own SSH servers in the Omarchy bar. The
  icon turns urgent when a server needs attention; the popup lists every
  server with its live load, RAM and uptime, and offers a console and a
  restart straight from the row.
- Adding a server only requires a name and a host. Port, user, identity file,
  reboot command and timeout all default to whatever `~/.ssh/config` or
  ssh-agent already does for that host, and `Tab` walks the whole form so a
  port and a user never need the mouse.
- One button sets a server up. A server without key-based auth says "Set up a
  key to see load and RAM" rather than only naming the error, and **Set up
  key** generates an SSH key if you have none, installs it with
  `ssh-copy-id`, and checks a key-only login works. That account's password
  is asked for once, in the terminal, by `ssh-copy-id` itself. Nothing here
  ever sees or stores it.
- Load, RAM and uptime are sampled with one small POSIX `sh` script per
  server, piped over stdin rather than copied to the server, so nothing is
  installed or left behind on the remote end. Every server is probed in
  parallel, on its own timer while the popup is open, so several slow,
  network-bound ssh connections never mean waiting out their timeouts one
  after another.
- Load is normalized against each server's own core count, the same way this
  author's Docker plugin normalizes CPU against every core, and memory is
  shown as one fraction in one unit rather than as two unrelated figures.
- Restarting is behind a confirmation dialog that names the server, shows the
  exact command, starts on Cancel, and runs in a terminal that stays open to
  show what happened. An IPC `restart` puts that same dialog on screen rather
  than restarting outright, so a keybinding cannot reboot a machine in one
  step either.
- Never stores, types or asks for a password. Sampling is forced
  non-interactive (`BatchMode=yes`, `NumberOfPasswordPrompts=0`) so it can
  only fail cleanly instead of hanging or prompting, while Connect, Restart
  and Set up key open a real terminal where any password a server still needs
  goes straight into ssh's or `ssh-copy-id`'s own prompt. Host keys are never
  auto-accepted: a new server is trusted the same way any ssh client trusts
  one, by connecting to it once.
- The server list lives in one `servers.json` you can read or edit by hand. A
  saved field can never be read as an ssh flag, control characters are
  refused and stripped so a field can never become a field boundary on the
  wire, and a hand-edited file that breaks a row is contained to that row.
- Tests run in GitHub Actions: the parsing, validation and formatting logic
  under Node's own test runner, a syntax and executable-bit check on all
  three helper scripts, a check that every entry point the manifest names
  exists, and the helpers themselves against a real, throwaway sshd, where
  `stats-all`, `connect`, `restart` and `setup-key` are all exercised for
  real.
