// Refract Modes — switch what this machine is FOR, from the top bar.
//
// WHY THIS EXISTS. Modes are the distro's headline feature and the only way to
// change one was `distro-modectl switch gaming` in a terminal. Installing two
// modes and then being told to open a terminal to move between them is a
// developer's answer to a desktop user's question.
//
// PRIVILEGE: a mode switch sets the CPU governor and starts/stops services, so
// it needs root. distro-modectl escalates with sudo, which cannot prompt from a
// graphical session with no controlling terminal — so this uses pkexec, which
// pops the normal polkit password dialog. distro-modectl's target_user() was
// taught to read PKEXEC_UID for exactly this path; without that the per-user
// half of a switch (theme, dock, blur, AI model) silently does nothing.
//
// STATE IS READ FROM FILES, NOT CACHED. The active mode lives in
// /run/distro-modectl/current-mode and the installed set in
// /etc/refract/enabled-modes, both written by distro-modectl itself. A switch
// from the terminal therefore updates this menu too, because there is one source
// of truth and the panel is only ever a view of it.

import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import St from 'gi://St';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Dialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

const CURRENT_MODE_FILE = '/run/distro-modectl/current-mode';
const ENABLED_MODES_FILE = '/etc/refract/enabled-modes';
const MODECTL = '/usr/local/bin/distro-modectl';

// UPDATES, IN THE TOP BAR.
//
// The updater already had a GUI (Refract Updates) and a daily notification, and
// neither was reaching anyone: the launcher sits in the app grid under a name
// you have to already know, and the notification is gone the moment it is
// dismissed. So the honest answer to "how do I update" stayed "open a terminal",
// which is not an answer for most people.
//
// This menu is already in the top bar next to Wi-Fi and Bluetooth, and it is
// already the place you go to change what the machine is doing. An update notice
// belongs here. It costs the shell NO network calls and NO polling: distro-update
// writes this marker on every check it performs — CLI, GUI and the daily user
// timer alike — and the same file monitor that already watches the mode files
// watches this one.
const UPDATE_MARKER = GLib.build_filenamev([GLib.get_user_state_dir(), 'refract', 'update-available']);
const UPDATES_APP = '/usr/local/bin/refract-updates';

// 'normal' is the always-on base and is never written to enabled-modes — the
// registry loader force-appends it — so it is added here rather than read.
const BASE_MODE = 'normal';

const LABELS = {
    normal: 'Normal',
    gaming: 'Gaming',
    ai: 'AI',
    server: 'Server',
    creative: 'Creative',
};

const ICONS = {
    normal: 'preferences-desktop-symbolic',
    gaming: 'applications-games-symbolic',
    ai: 'system-run-symbolic',
    server: 'network-server-symbolic',
    creative: 'applications-graphics-symbolic',
};

function readFile(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        if (!ok || !bytes) return '';
        return new TextDecoder().decode(bytes);
    } catch (_e) {
        // Missing file is the normal case before the first switch — not an error.
        return '';
    }
}

function currentMode() {
    const m = readFile(CURRENT_MODE_FILE).trim();
    return m || BASE_MODE;
}

// Present => a newer build exists. The file's CONTENT is the commit; only its
// existence matters here, so a partially-written file can never mislead.
function updateAvailable() {
    try {
        return GLib.file_test(UPDATE_MARKER, GLib.FileTest.EXISTS);
    } catch (_e) {
        return false;
    }
}

function enabledModes() {
    const modes = readFile(ENABLED_MODES_FILE)
        .split('\n')
        .map(l => l.trim())
        .filter(l => l && !l.startsWith('#') && Object.hasOwn(LABELS, l));
    // Base mode always available, always first, never duplicated.
    return [BASE_MODE, ...modes.filter(m => m !== BASE_MODE)];
}

const RefractIndicator = GObject.registerClass(
class RefractIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.0, 'Refract Modes');

        this._box = new St.BoxLayout({ style_class: 'panel-status-menu-box' });
        this._icon = new St.Icon({ style_class: 'system-status-icon' });
        this._label = new St.Label({
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'refract-mode-label',
        });
        // Shown ONLY when an update is pending. A permanent badge is wallpaper
        // — people stop seeing it — so this appears, gets clicked, and goes.
        this._updateDot = new St.Icon({
            style_class: 'system-status-icon',
            icon_name: 'software-update-available-symbolic',
            visible: false,
        });
        this._box.add_child(this._icon);
        this._box.add_child(this._label);
        this._box.add_child(this._updateDot);
        this.add_child(this._box);

        this._monitors = [];
        this._watch(CURRENT_MODE_FILE);
        this._watch(ENABLED_MODES_FILE);
        // The marker's own directory may not exist yet on a machine that has
        // never checked. Watch the PARENT too, so the badge appears the first
        // time a check writes it instead of waiting for a logout.
        this._watch(UPDATE_MARKER);
        this._watch(GLib.path_get_dirname(UPDATE_MARKER));

        this.menu.connect('open-state-changed', (_m, open) => {
            if (open) this._rebuild();
        });

        this._rebuild();
    }

    // File monitors rather than a timer: a switch made in a terminal should be
    // reflected here immediately, and polling a file every few seconds to learn
    // something that changes twice a day is waste.
    _watch(path) {
        try {
            const f = Gio.File.new_for_path(path);
            const mon = f.monitor(Gio.FileMonitorFlags.NONE, null);
            mon.connect('changed', () => this._rebuild());
            this._monitors.push(mon);
        } catch (_e) {
            // A missing /run path before the first switch cannot be monitored.
            // The menu still rebuilds every time it is opened, so this only
            // costs live updates, never correctness.
        }
    }

    _rebuild() {
        const active = currentMode();
        const modes = enabledModes();

        this._label.text = LABELS[active] ?? active;
        this._icon.icon_name = ICONS[active] ?? ICONS[BASE_MODE];

        this.menu.removeAll();

        // FIRST ITEM, above the modes, because it is the thing with a deadline.
        // Only rendered when there is genuinely something to install — an
        // "Updates" entry that is usually a no-op teaches people to skip it.
        const pending = updateAvailable() && GLib.file_test(UPDATES_APP, GLib.FileTest.IS_EXECUTABLE);
        this._updateDot.visible = pending;
        if (pending) {
            const upd = new PopupMenu.PopupImageMenuItem(
                'Update available — install…',
                'software-update-available-symbolic'
            );
            upd.connect('activate', () => this._openUpdates());
            this.menu.addMenuItem(upd);
            this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        }

        const header = new PopupMenu.PopupMenuItem(`Mode: ${LABELS[active] ?? active}`, {
            reactive: false,
            style_class: 'popup-inactive-menu-item',
        });
        this.menu.addMenuItem(header);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        for (const mode of modes) {
            const item = new PopupMenu.PopupImageMenuItem(
                LABELS[mode] ?? mode,
                ICONS[mode] ?? ICONS[BASE_MODE]
            );
            if (mode === active) {
                item.setOrnament(PopupMenu.Ornament.CHECK);
                item.reactive = false;
            } else {
                item.connect('activate', () => this._confirmThenSwitch(mode));
            }
            this.menu.addMenuItem(item);
        }

        // Only one mode installed means nothing to switch between; say so rather
        // than presenting a menu that does nothing.
        if (modes.length <= 1) {
            this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
            const hint = new PopupMenu.PopupMenuItem(
                'Add modes: distro-modectl modes enable <mode>',
                { reactive: false, style_class: 'popup-inactive-menu-item' }
            );
            this.menu.addMenuItem(hint);
        }
    }

    // Opens the window rather than installing straight from the menu. `apply`
    // downloads a tarball and rewrites /opt/distro; doing that behind a menu
    // click with no progress and nowhere to show an error is how an update
    // that failed looks identical to one that worked.
    _openUpdates() {
        try {
            Gio.Subprocess.new([UPDATES_APP], Gio.SubprocessFlags.NONE);
        } catch (e) {
            Main.notifyError('Refract: could not open Refract Updates', e.message ?? String(e));
        }
    }

    // Server mode turns the display manager off. distro-modectl guards that
    // behind CONFIRM_DISPLAY_MANAGER_STOP, and this menu was passing --yes for
    // every mode — so the guard existed and was never once shown to the person
    // it protects. One click plus a password prompt disabled gdm, and the only
    // message shown was "Switched to Server mode."; the machine then booted to
    // a text console with nothing connecting the two. The confirmation has to
    // happen HERE, because there is no terminal for distro-modectl to ask on.
    _confirmThenSwitch(mode) {
        if (mode !== 'server') {
            this._switchTo(mode);
            return;
        }
        const dlg = new Dialog.ModalDialog({ styleClass: 'refract-confirm' });
        dlg.contentLayout.add_child(new St.Label({
            style_class: 'headline',
            text: 'Turn off the desktop?',
        }));
        dlg.contentLayout.add_child(new St.Label({
            text: 'Server mode stops the graphical login from starting at boot.\n' +
                  'This session keeps running, but after the next restart this\n' +
                  'machine comes up at a text console.\n\n' +
                  'Switching to any other mode turns it back on.',
        }));
        dlg.setButtons([
            { label: 'Cancel', action: () => dlg.close(), key: Clutter.KEY_Escape },
            { label: 'Switch to Server', action: () => { dlg.close(); this._switchTo(mode); },
              default: true },
        ]);
        dlg.open();
    }

    _switchTo(mode) {
        try {
            // --yes because there is no terminal to answer on. For Server that
            // is only reached after _confirmThenSwitch has actually asked.
            const proc = Gio.Subprocess.new(
                ['pkexec', MODECTL, 'switch', mode, '--yes'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            proc.communicate_utf8_async(null, null, (p, res) => {
                let ok = false, stderr = '';
                try {
                    const [, , err] = p.communicate_utf8_finish(res);
                    stderr = err ?? '';
                    ok = p.get_successful();
                } catch (e) {
                    stderr = e.message ?? String(e);
                }
                if (ok) {
                    Main.notify('Refract', `Switched to ${LABELS[mode] ?? mode} mode.`);
                } else {
                    // Cancelling the polkit dialog lands here too. Say what
                    // happened rather than failing silently — a switch that
                    // quietly does nothing is the worst outcome.
                    Main.notifyError(
                        'Refract: mode switch failed',
                        stderr.trim().split('\n').slice(-3).join(' ') || 'Authentication cancelled or distro-modectl failed.'
                    );
                }
                this._rebuild();
            });
        } catch (e) {
            Main.notifyError('Refract: could not run distro-modectl', e.message ?? String(e));
        }
    }

    destroy() {
        for (const mon of this._monitors) {
            try { mon.cancel(); } catch (_e) { /* already gone */ }
        }
        this._monitors = [];
        super.destroy();
    }
});

export default class RefractModesExtension extends Extension {
    enable() {
        this._indicator = new RefractIndicator();
        // Placed in the RIGHT box, next to Wi-Fi/Bluetooth/battery. Those live on
        // the right in GNOME, not the left — this sits with the other status
        // indicators, which is where it was asked for in spirit.
        Main.panel.addToStatusArea('refract-modes', this._indicator, 0, 'right');
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
