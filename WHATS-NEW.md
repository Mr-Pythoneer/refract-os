# What's new in Refract

Notes from the person who made the change, in plain language. `distro-update`
shows you the entries added since your build every time you update, and
`distro-update notes` shows them any time.

FORMAT MATTERS TO THE PARSER. Every entry starts with `## YYYY-MM-DD — Title`,
and **newest goes at the TOP**. distro-update walks this file from the top and
stops at the first heading the machine has already been shown, so an entry
appended at the bottom is never displayed to anyone who is up to date. Adding
one with `>>` is the obvious mistake and it fails silently.

## 2026-08-16 — Updates are signed now

The one thing the audit found that wasn't fixed on the day: your laptop
downloaded updates and ran them as administrator, and the only thing vouching
for that code was HTTPS. HTTPS proves you reached GitHub. It does not prove the
code is the code that was published — and a network that inspects traffic (very
common at schools and workplaces) can sit in the middle of that.

Now every update carries a signature, like a wax seal. The matching key is baked
into the OS itself, so your machine checks the seal before installing anything
and refuses outright if it doesn't match. Nothing on the network can forge it.

One exception, and it's announced on screen: the update that *installs* the key
can't itself be checked, because there's nothing to check it against yet. Every
update after that one is verified.

## 2026-08-16 — Security and bug audit: fixes

An adversarial audit of the whole repo raised 25 issues; 19 survived
verification. The ones that could actually break a machine are fixed:

**Server mode could leave you with no desktop.** Switching to Server turns the
graphical login off — but nothing ever turned it back on, so switching back to
Normal said "Now in: Normal mode" and changed nothing. The next reboot came up
at a text console with nothing connecting the two events. Worse, the top-bar
switcher was auto-confirming the warning that exists for this, so one click and
a password did it silently. Now leaving Server restores your desktop, and the
top-bar menu asks first, in plain words.

**Docker setup broke apt system-wide.** The server mode's Docker script built
its package source from Refract's codename ("forge") instead of Ubuntu's, so it
pointed at a repository that doesn't exist. Docker never installed, and the
broken source file was left behind — every later update check on the machine
reported an error from then on. Fixed, and it now cleans up after itself if the
download fails.

**Updating could resurrect a mode you deliberately left out.** If you built or
installed without AI mode, the updater's file sync put the whole thing back and
returned its commands to your PATH. It now detects what was left out and keeps
it out.

**Battery time remaining was wrong on many laptops.** On batteries that report
charge rather than energy, the calculation forgot the pack voltage — an ~11x
error, so four hours of runtime displayed as twenty-four minutes.

Also fixed: you couldn't read your own system logs (the installer never put your
account in the `adm` group); the monitor was reading every process's status file
once a second even with that page off screen; every mode switch claimed it had
applied a macOS theme regardless of your actual layout; the update window showed
raw colour codes as little boxes; and turning on SSH from Server mode left it
blocked by the firewall with nothing saying so.

Still open and needing a decision: the updater trusts HTTPS alone — there is no
signature on what it downloads. Fixing that properly means signed releases, and
it's the next thing worth doing.

## 2026-08-16 — Updating no longer means opening a terminal

The updater always had a window — you just had no way to find it. It's now in
the top bar: the same Refract menu you use to switch modes shows **Update
available — install…** when there's one waiting, with a badge on the panel icon.
One click opens it.

The desktop notification never worked either. It was being killed a second after
it appeared, before it could handle a click, so at best you saw it flash past.
Fixed. And the app-grid entry now matches searches for "software update",
"check for updates" and "install updates", not just "refract".

Behind all of that: the updater couldn't previously update its *own* launchers,
notifications or services, only the commands. So every improvement to how
updates reach you could only have arrived by reinstalling. It can now, which is
why you're reading this.

## 2026-08-16 — Switching modes no longer wipes your dock

Switching to Gaming used to replace your entire dock with Steam, Lutris and
Bottles — and since none of those ship with Refract, the dock came out empty.
Chrome, Files, Terminal, Settings, the app store and anything you'd pinned
yourself: gone. Switching back didn't bring them back either.

Now a mode's apps are *added* to your dock and removed again when you leave,
and anything you pinned yourself is never touched. If your dock was already
wiped, the first mode switch after this update puts it back.

## 2026-08-16 — The app store had no icons, screenshots or ratings

All one bug, and an embarrassing one. Refract strips a 22 MB metadata cache out
of the ISO to keep it under the size limit, with a note saying it gets rebuilt
on demand — except nothing ever rebuilt it. That cache is where every app icon,
screenshot, description and star rating comes from, and Software can't offer you
an app it has no entry for, which is why some things wouldn't install.

It's now rebuilt automatically on the first boot with a network, quietly and at
low priority. If the store still looks wrong, `distro-appstore status` will tell
you exactly which piece is missing and `distro-appstore fix` will repair it.

## 2026-08-16 — One app per job

The app grid had three activity monitors and two software updaters. Nobody chose
that — Ubuntu's desktop pulls its own versions in automatically, and Refract's
sat next to them.

Refract Monitor now has a **Processes** page that lists everything running and
can end a stuck program, so it genuinely replaces GNOME's System Monitor, and
the duplicates are hidden. Nothing is uninstalled — `sudo distro-appgrid restore`
brings every icon back, and `distro-appgrid status` shows what's hidden and why.

## 2026-08-16 — AI mode now actually runs at full speed

AI mode was running on the balanced power profile, which meant the CPU never
reached its sustained limit while a model was generating. It was the only heavy
mode that wasn't set to performance. Now it pins the CPU, the power profile and
the GPU clocks — local models should be noticeably faster.

## 2026-08-16 — Normal mode manages your battery

Unplug in Normal mode and the system drops to power-saver by itself; plug back
in and it returns to balanced. Nothing to click.

Only Normal. Gaming, AI and Creative are you explicitly asking for performance,
and quietly turning one down when you unplug would undo that with nothing on
screen to explain why the machine got slower. `sudo distro-powerctl disable`
turns the whole thing off.

## 2026-08-16 — Tips, for anyone new to this

A **Refract Tips** app, shown once on first login. Five pages covering modes,
battery, apps, the look, and updates — all specific to Refract, nothing you'd
already know from using Ubuntu. Every tip that mentions a tool has a button that
opens it.

## 2026-08-16 — Fingerprint login: finding out why it isn't offered

Settings hides the fingerprint option for four different reasons and shows you
the same nothing for all of them. `distro-fingerprint status` tells them apart —
it reads the USB bus directly and names the sensor.

Fair warning: on recent ThinkPads the answer is often that the sensor is
"match-on-chip" and needs a driver Ubuntu only distributes to OEMs. That's not
something Refract can install. But you'll know in ten seconds instead of losing
an afternoon to it.
