# Refract OS — persist the installer's two packagechooser selections.
#
# WHY THIS MODULE EXISTS, AND WHY IT IS NOT shellprocess.
#
# This replaces shellprocess@layout and shellprocess@modes, both of which could
# NEVER have worked. They referenced ${gs[packagechooser_layout]} and
# ${gs[packagechooser_modes]}, and Calamares' shellprocess does not support any
# such syntax. Its expander (libcalamares/utils/CommandList.cpp, get_gs_expander)
# inserts exactly three names — ROOT, USER and LANG — and upstream's own
# shellprocess.conf says so: "Variables are written as ${var}, e.g. ${ROOT}".
# Anything else is an unknown macro, and CommandList::run() aborts the job with
#     "The commands use variables that are not defined.
#      Missing variables are: gs[packagechooser_layout]."
# which is precisely how install-smoke run 31581430815 died — AFTER unpackfs had
# already written 5.96 GB, i.e. at the point where a failed install leaves a
# half-installed disk.
#
# The gs[...] form was borrowed in good faith from contextualprocess.conf, where
# names like branding.bootloader ARE GlobalStorage keys. That is a property of
# contextualprocess's config schema, not a shellprocess expansion. The two got
# conflated and both configs inherited the mistake.
#
# contextualprocess would have been the natural fix, and it IS correct for the
# layout (one value out of four). It cannot express the modes selection:
# packagechooser joins the chosen ids with ',' from
# QItemSelectionModel::selectedIndexes(), which Qt documents as unsorted, so
# "gaming,ai" and "ai,gaming" are both reachable and contextualprocess only does
# exact string matching. Covering it would take all 65 orderings of the subsets.
#
# A python job reads GlobalStorage directly and sidesteps the whole problem.
# Calamares in this image is built with python support (its own log prints
# ".. Using PyBind11"), and settings.conf adds /etc/calamares/custom-modules to
# modules-search so this directory is found.
#
# THIS JOB NEVER FAILS THE INSTALL. Losing a cosmetic preference is a papercut;
# failing here would abort an install whose filesystem is already written, which
# is the worst outcome available. Every path returns None, and problems are
# logged for the session log instead.

import os

import libcalamares


LAYOUTS = ("refract", "classic", "macos", "minimal")
DEFAULT_LAYOUT = "refract"
VALID_MODES = ("gaming", "ai", "server", "creative")


def pretty_name():
    return "Saving your look and mode choices"


def _log(msg):
    try:
        libcalamares.utils.debug("refractselections: {}".format(msg))
    except Exception:
        pass


def _gs(key):
    """GlobalStorage value as a string, or '' — never raises, never returns None."""
    try:
        if not libcalamares.globalstorage.contains(key):
            _log("GlobalStorage has no key {!r}".format(key))
            return ""
        value = libcalamares.globalstorage.value(key)
        return "" if value is None else str(value)
    except Exception as e:
        _log("could not read {!r}: {}".format(key, e))
        return ""


def _write_layout(root):
    """Write /etc/refract/layout. Whitelisted: an unknown or empty choice
    becomes 'refract', because Refract is the documented default and a blank
    file would read to distro-layoutctl as an unknown layout."""
    choice = _gs("packagechooser_layout").strip()
    if choice not in LAYOUTS:
        if choice:
            _log("layout {!r} is not one of {} — using {}".format(choice, LAYOUTS, DEFAULT_LAYOUT))
        else:
            _log("no layout chosen — using {}".format(DEFAULT_LAYOUT))
        choice = DEFAULT_LAYOUT

    target = os.path.join(root, "etc", "refract")
    try:
        os.makedirs(target, exist_ok=True)
        path = os.path.join(target, "layout")
        with open(path, "w") as f:
            f.write(choice + "\n")
        os.chmod(path, 0o644)
        _log("wrote layout {!r} to {}".format(choice, path))
    except Exception as e:
        _log("FAILED to write layout: {}".format(e))


def _modes_from_package_operations():
    """Mode ids ticked on the netinstall Modes page.

    Reads GlobalStorage `packageOperations`, keeps entries written by our own
    instance, and turns the refract-mode-<id> sentinels back into mode ids. Every
    step is defensive: this runs late in an install whose filesystem is already
    written, so a surprise in the structure must degrade to "no modes selected"
    rather than raise."""
    ids = []
    try:
        if not libcalamares.globalstorage.contains("packageOperations"):
            _log("no packageOperations in GlobalStorage — nothing ticked on Modes")
            return ids
        ops = libcalamares.globalstorage.value("packageOperations") or []
        for op in ops:
            if not isinstance(op, dict):
                continue
            # 'source' is the module instance key. Ours is netinstall@modes; a
            # future second netinstall page must not leak into the mode registry.
            src = str(op.get("source", ""))
            if src and "modes" not in src:
                continue
            # BOTH KEYS. netinstall's Config::finalizeGlobalStorage splits the
            # selection by isCritical(): critical groups go to "install",
            # EVERYTHING ELSE goes to "try_install". None of the Modes groups set
            # critical, so all five landed in try_install — and reading only
            # "install" found nothing, every time. That is why an install with
            # Normal + Gaming + AI ticked produced a machine with only Normal
            # (observed on hardware, 2026-08-16). Reading both is correct whether
            # or not a group is ever marked critical later.
            for entry in (op.get("install") or []) + (op.get("try_install") or []):
                # Entries are usually plain strings, but the schema also allows
                # {"package": name, ...} maps for pre/post-script forms.
                name = entry.get("package", "") if isinstance(entry, dict) else str(entry)
                if name.startswith("refract-mode-"):
                    ids.append(name[len("refract-mode-"):])
    except Exception as e:
        _log("could not read packageOperations: {}".format(e))
    _log("Modes page selected: {}".format(ids or "(none)"))
    return ids


def _apply_modes():
    """Hand the mode selection to distro-apply-mode-selection inside the target.

    The ids are filtered against VALID_MODES first: the value is a comma-joined
    list in unspecified order, and on an image built with REFRACT_OMIT_MODES the
    chooser cannot offer an omitted mode anyway — but filtering means a stale or
    unexpected id can never reach a script running as root in the target."""
    # The Modes page is netinstall (the only stock module with real checkboxes),
    # so the selection does NOT arrive as a packagechooser string. netinstall
    # records it in GlobalStorage under `packageOperations` as a list of maps:
    #     [{"install": ["refract-mode-gaming", ...], "source": "netinstall@modes"}]
    # Those names are SENTINELS, never packages — there is no packages module in
    # the exec sequence, so nothing is ever handed to apt. Confirmed against
    # libcalamares/packages/Globals.cpp (additions()), which is what writes the key.
    raw = ",".join(_modes_from_package_operations())
    # 'normal' is selectable on the Modes page but is the always-on base, and
    # distro-apply-mode-selection documents that it is NEVER written to the
    # registry (load_valid_modes force-appends it). Drop it here silently —
    # it is a legitimate choice, not an unknown one.
    picked = [p.strip() for p in raw.split(",") if p.strip()]
    chosen = [m for m in picked if m in VALID_MODES]
    known = [m for m in picked if m in VALID_MODES + ("normal",)]
    selection = ",".join(chosen)
    if picked and not known:
        _log("none of {!r} are known modes — treating as no selection".format(raw))

    helper = "/opt/distro/modes/modectl/distro-apply-mode-selection"
    try:
        # target_env_call runs inside the installed system, which is where
        # /opt/distro and the mode registry live.
        rc = libcalamares.utils.target_env_call([helper, selection])
        if rc != 0:
            _log("{} exited {} for selection {!r}".format(helper, rc, selection))
        else:
            _log("applied modes {!r}".format(selection))
    except Exception as e:
        _log("could not run {}: {}".format(helper, e))


def run():
    root = ""
    try:
        root = libcalamares.globalstorage.value("rootMountPoint") or ""
    except Exception as e:
        _log("no rootMountPoint: {}".format(e))

    if not root or not os.path.isdir(root):
        # Nothing sane to write to. Still not a failure — see header.
        _log("rootMountPoint {!r} is not a directory; skipping".format(root))
        return None

    _write_layout(root)
    _apply_modes()
    return None
