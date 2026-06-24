# Server mode

Per DESIGN.md §4: SSH, Docker, monitoring, headless-capable. Run in order:

```bash
./setup/01-install-ssh.sh       # requires an authorized_keys entry first, see script output
./setup/02-install-docker.sh
./setup/03-install-netdata.sh
./setup/verify-server.sh
```

Then `distro-modectl switch server` applies the power-saving CPU/power
profile and (with confirmation) disables the display manager so the box
boots to a text console.

## What's covered

- **SSH**: hardened by default (key-only auth, no root login) — but the script refuses to disable password auth until it confirms an `authorized_keys` entry exists, so it can't lock you out of your own machine
- **Docker**: installed from Docker's own apt repo, not Ubuntu's (usually older / sometimes a different fork). User added to the `docker` group — that's root-equivalent access by Docker's own design, not something to "fix"
- **Netdata**: installed via its official kickstart script with `--disable-telemetry`, matching the project's local-first stance

## Known gaps / unverified

- `verify-server.sh` checks services are installed and active, but cannot verify the box actually boots and stays usable with **zero display attached** — that needs an actual headless boot test on real hardware/VM, not something checkable from inside a running session.
- Netdata's install method is a curl-pipe-to-shell kickstart script — that's Netdata's own only currently-maintained install path, not a shortcut taken here. Worth reviewing their kickstart script before running it if that's a concern (URL is in the script's comment).
- `fail2ban` is mentioned as optional in `01-install-ssh.sh`'s output but not installed automatically — intentional, didn't want to add an extra security-relevant service nobody asked for by default.
