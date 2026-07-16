# ☠ The DANGER testing build

There is a second, deliberately unsafe Refract OS image. This documents what it
is, why it exists, and the guardrails that keep it away from users.

## What it is

A developer-only image that **boots straight to a desktop with no login and no
password**, so a tester can check whether the OS works without typing anything.

It is **not an operating system anyone should use**. Anyone who boots it has an
unauthenticated, `sudo`-capable session. On a real machine that is a wide-open
door.

## How to build it

It is never built by default. It requires an explicit opt-in:

```bash
# locally (on a real Linux build host)
REFRACT_TESTING=1 sudo -E ./build.sh laptop

# via CI: run the build-iso workflow with
#   testing_no_login = true
```

With `REFRACT_TESTING=1`, `build.sh` emits
`config/hooks/0900-DANGER-testing-nologin.chroot`, which:

- enables GDM autologin for `ubuntu` (writing **both** `custom.conf` and
  `daemon.conf`, since Ubuntu reads the former and Debian the latter — guessing
  wrong would silently no-op)
- blanks that user's password
- strips the boot splash (`nosplash systemd.show_status=true`) so kernel output
  is visible
- marks the image as testing in `/etc/os-release`, `/etc/motd`, and
  `/etc/refract-TESTING-BUILD-DO-NOT-USE`

## Why the login screen exists at all in normal builds

The normal image keeps GDM's login screen. It does **not** ship autologin,
because the live ISO's filesystem is what Calamares unpacks onto the installed
system — an autologin left in the live image would follow the user onto their
real machine. The testing build accepts that risk precisely because it must
never reach a real machine.

## The guardrails

The image announces itself at every layer someone might look at:

| Layer | What it says |
|---|---|
| Build output | A large `DANGER` banner on stderr |
| ISO filename | `DANGER-DO-NOT-USE-TESTING-NO-LOGIN-*.iso` |
| ISO volume label | `DANGER-TEST` (the 11-char ISO9660 cap) |
| ISO application id | `*** DANGER - REFRACT OS TESTING BUILD - NO LOGIN - DO NOT USE OR INSTALL ***` |
| CI artifact name | `DANGER-TESTING-NO-LOGIN-refract-os-<strain>` |
| Release tag | `DANGER-testing-no-login-<strain>` — **never** `latest-<strain>` |
| Release title | `☠☠☠ DANGER — TESTING BUILD — NO LOGIN — DO NOT USE ☠☠☠` |
| Running system | `PRETTY_NAME`, `/etc/motd`, `/etc/refract-TESTING-BUILD-DO-NOT-USE` |

**The load-bearing one is the release tag.** Real users download
`latest-<strain>`. A testing build publishes to a different tag entirely, so it
cannot overwrite or masquerade as the real download no matter what else goes
wrong.

## Rules

- Never publish a testing build to `latest-*`.
- Never hand this image to anyone, for any reason.
- If you find one of these on a machine, reflash that machine.
