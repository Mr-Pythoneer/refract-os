# What's new in Refract

Notes from the person who made the change, in plain language. `distro-update`
shows you the entries added since your build every time you update, and
`distro-update notes` shows them any time.

FORMAT MATTERS TO THE PARSER. Every entry starts with `## YYYY-MM-DD — Title`,
and **newest goes at the TOP**. distro-update walks this file from the top and
stops at the first heading the machine has already been shown, so an entry
appended at the bottom is never displayed to anyone who is up to date. Adding
one with `>>` is the obvious mistake and it fails silently.

## 2026-08-17 — The update button no longer makes things worse

If a check failed and you pressed the button again, Refract sent another
request. And another. Nothing remembered a recent answer, and nothing noticed
when GitHub replied "you are asking too often, wait five minutes" — so the
answer was always the same vague *could not reach GitHub*, which reads as
"try again". Trying again was the one thing that extended the block.

Switching wifi, plugging in a cable, or turning on a VPN all look like they
should help. A VPN is usually the worst of the three: you share that exit
address with everyone else on the server, and the hourly budget is often
already spent by strangers before you arrive.

Now:

- When GitHub asks this machine to wait, Refract waits, and tells you how long
  is left. It sends nothing at all until then.
- A message that says **rate limit** instead of a connection error, so you
  don't go and change networks over something that isn't a network problem.
- Pressing the button twice within five minutes reuses the answer it already
  has instead of asking again.

None of this is a fault on your machine, and nothing is broken while it waits.

## 2026-08-17 — The download button was broken for low-RAM machines

If you told the picker on the website that your machine had **under 8 GB of
RAM**, the "Download" button gave you a GitHub 404. Every other machine type
worked, which is why it went unnoticed.

The lowspec image is bigger than GitHub's 2 GB limit for a single release file,
so it gets published as two files — `.part00` and `.part01`. The website did not
know that. It built the download link by pasting the edition name into
`refract-os-<name>.iso`, which is correct for the other five editions and points
at a file that has never existed for this one. The people it failed for were
exactly the people the lowspec build is for.

The page now offers both parts, tells you it comes in two pieces, and shows the
one command that joins them back together — for Linux and for Windows.

## 2026-08-17 — "Can't connect to GitHub" now tells you the truth

If an update check failed, it said one thing: *could not reach GitHub*. That
sentence covered at least six completely different problems — no DNS, a network
that blocks GitHub's download servers while allowing github.com itself, a hotel
or school wifi login page answering instead of GitHub, a release that was still
half-uploaded, GitHub's rate limit being used up by somebody else on your
network, and an update whose signature did not check out.

Only one of those is "your connection is down", and it is not the common one.
The worst case was the last: a machine correctly **refusing a bad update** would
tell you your wifi was broken, and nobody would ever look at the real reason.

Now each one says what it actually is, and what to do about it. There is also a
new command that walks the whole chain and shows you exactly which link is
broken:

    distro-update diagnose

It checks DNS, the connection, both download servers separately, your signing
key and its fingerprint, and whether the signature verifies — and tells you that
the first failed line is the one that matters.

## 2026-08-16 — Trackpad gestures

Three fingers up for the overview, three sideways to switch workspace, four up
for all apps. In a browser, two fingers sideways goes back and forward — only in
a browser, because everywhere else that gesture is scrolling and hijacking it
would make every sideways scroll in a spreadsheet navigate away from your work.

**Why there weren't any.** GNOME's own gestures are excellent and only work on
the Wayland session. Refract uses Xorg on Intel graphics on purpose, to avoid a
Wayland startup hang that has left real laptops sitting at a black screen — and
gestures were one of the things that workaround silently cost. Nothing replaced
them until now.

They're set up automatically on your first login, and they trigger the same
things the keyboard shortcuts do, so gestures and shortcuts can't disagree.

If your machine has AMD or NVIDIA graphics — or Intel that boots Wayland fine —
`distro-gestures wayland on` switches to the native ones and gets fractional
scaling and variable refresh rate too. It prints the way back before you reboot,
in case your laptop is one of the ones that hangs.

## 2026-08-16 — Wine, sleep-during-downloads, and automatic update checks

**About Wine — you were right and the docs were wrong.** The website said Gaming
mode gives you "Proton-GE + Wine-staging + Bottles, pre-tuned out of the box".
It doesn't: that stack is over a gigabyte and installs when you enable Gaming
mode, not when you flash the ISO. The claim has been corrected rather than
quietly left there, because expecting Wine to be present was a completely
reasonable thing to expect from what was written.

**The machine now stays awake while something is downloading — but only when
plugged in.** On battery it sleeps as normal, on purpose: a laptop that refuses
to sleep because something is trickling in the background is how you come back
to a flat one. `distro-keepawake status` shows what it sees; `sudo
distro-keepawake disable` turns it off.

**Update checks happen on their own.** Three minutes after you log in and every
six hours after that, instead of once a day. You get a notification the first
time a given build appears, and the Refract menu in the top bar keeps showing
"Update available" until you install it — so a notification you miss or dismiss
doesn't mean you never hear about it again.

## 2026-08-16 — Opening a .exe now tells you what it needs

Wine wasn't broken — it was never installed. Refract leaves it out on purpose:
it's over a gigabyte with the 32-bit stack, and most people never run a Windows
program. But nothing said so, so double-clicking a `.exe` just failed, and the
obvious conclusion was that Wine was broken.

Now a Windows program opens a dialog explaining what the file is and offering to
install Wine, with the download and the password prompt visible in a terminal
rather than happening invisibly. If Wine is already there, it just runs — from
the program's own folder, which a lot of Windows software needs and which a file
manager doesn't do by default.

It also points at **Bottles** (in the app store), which keeps each Windows
program in its own container and is usually less trouble than one shared Wine
setup. `distro-exe status` says what's installed and what currently opens `.exe`
files.

## 2026-08-16 — Downloads no longer die when the screen goes dark

Reported, and it was as bad as it sounds. Refract shipped **no** power policy at
all, so GNOME's default applied: after a few idle minutes the screen blanks, and
a while later the machine suspends itself. Suspending drops every network
connection, so whatever was downloading — a browser download, a Flatpak install,
`apt upgrade` in a terminal — was simply gone. The screen went dark and the
download vanished, with nothing linking the two.

Now: **plugged in, it never suspends itself.** The screen still blanks (that's
just the display, and downloads carry on across it). On battery it still
suspends, because there it's a real feature and the alternative is a flat
battery — after 30 minutes rather than 20.

Refract's own downloads — installing an update, fetching the app catalogue on
first boot — now also hold the machine awake for as long as they run, so an idle
timer can't interrupt one halfway through.

`distro-powerctl status` now shows all of this: when the screen blanks, whether
your machine suspends on mains or battery, and what's currently keeping it awake.

## 2026-08-16 — The rest of the audit

The seven lower-severity findings from the audit, now closed:

**A refused password left the machine half-switched.** Changing mode applied the
visible half first — dock, wallpaper, accent, AI model — and only then asked for
your password. Get it wrong and the desktop said one mode while the system was
still in the other, with no error explaining the gap. It now asks first and
changes nothing if you decline.

**Two accounts on one machine fought over the layout.** Which layout is active
was stored once for the whole system, but a layout is per-person — so a second
user picking one would silently replace the first user's theme the next time they
changed mode. Each account now remembers its own.

**The monitor was freezing its own window.** It ran `nvidia-smi` every second,
and on laptops with a switchable GPU that call wakes the card up and can take
most of a second — during which the window doesn't redraw or respond. Now sampled
every three seconds, and the power profile every fifteen instead of every one.

Also: the keyboard remapper was built from a tag that upstream could move, and is
now pinned to an exact verified commit — it's a root daemon that sees every
keystroke, so it deserved the same check the *themes* already had. The cloud
image shipped SSH open with no firewall at all. A disk mounted at a path with a
space in it made the scratch-space picker create a folder on the wrong drive. And
building the ISO from the repo root half-applied mode omission, because the
script re-derived its own location after moving into it.

## 2026-08-16 — Refract Tips actually arrives now

Tips shipped with a launcher that pointed at a program the updater never put in
place — an icon in the app grid that opened nothing. Two gaps caused it, and both
would have hit any future app the same way:

The updater only created shortcuts for commands whose names begin with
`distro-`, so anything named `refract-` never got one. Monitor and Updates only
worked because the installer had made *their* shortcuts at install time, which
hid the problem until a new app arrived by update — which is the entire point of
having an updater.

And the "show this once on first login" entry was being written to a template
that's only copied when a **new user account** is created. On a machine that
took an update, the person already using it never received it.

Both fixed, and there's now a test that compares the two delivery paths against
each other, so an app that a fresh install gets but an updated machine doesn't
fails CI instead of shipping.

## 2026-08-16 — Past update notes now live in Refract Tips

The notes an update prints scroll away with the terminal, and "when did that
change?" is a question people ask days later — usually because something behaves
differently and they want to know whether it was deliberate.

**Refract Tips** now has a **What's new** page holding every note, newest first,
each collapsed to its title so you can scan for the one you want. Refract Updates
links straight to it, and `distro-update notes` still prints them in a terminal.

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
