---
name: Test report
about: Something broke (or behaved oddly) while testing a WIP build
title: "[strain] short description of what broke"
labels: bug, wip-testing
---

## What happened

<!-- One or two sentences. "The install died at 40% with an error dialog." -->

## What I expected

## Build

- Strain / release tag: <!-- e.g. latest-laptop -->
- Downloaded on: <!-- date -->
- Flashed with: balenaEtcher <!-- version -->

## Machine

- Make / model:
- CPU:
- GPU:
- RAM:
- Boot mode: <!-- UEFI or BIOS/legacy -->
- Secure Boot: <!-- off / on -->

## Where it broke

- [ ] Wouldn't boot from USB at all
- [ ] Booted, but the live desktop is broken
- [ ] Installer wouldn't start
- [ ] Installer failed partway
- [ ] Installed, but the installed system won't boot
- [ ] Installed and boots, but something is wrong
- [ ] Something else

## Evidence

<!-- Photo of the screen is fine and often best.
     If the INSTALLER failed, the log is the most useful thing you can attach:
       Ctrl+Alt+F3
       sudo cp /root/.cache/calamares/session.log /tmp/
     ...then copy it off, or photograph:
       sudo tail -50 /root/.cache/calamares/session.log -->

## Anything else
