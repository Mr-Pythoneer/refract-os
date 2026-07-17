# Refract OS "Choose Your Modes" — Design Doc

## 1. Motivation

Refract OS ships five runtime modes — `gaming`, `ai`, `server`, `creative`, `normal` — switched by `distro-modectl` (`modes/modectl/distro-modectl:40`). The heavy per-mode payloads (Ollama, ComfyUI, models, Steam, Blender, Docker) are **already not baked into the ISO**; they install on demand via `modes/<mode>/setup/*.sh` (e.g. `modes/ai/setup/01-install-ollama.sh`). Only lightweight bits (gamemode/mangohud/winetricks, Vulkan userspace) live in the strain package lists.

This feature asks one question at install time — **"what is this machine for?"** — and lets the user check any of Gaming / AI / Server / Creative. Normal is always on as the base desktop and is never an item.

It serves two audiences under one tent:

- **The AI crowd** checks the AI box and gets the local-first LLM stack, unchanged.
- **The anti-AI-in-the-OS crowd** leaves AI unchecked and gets a system where AI is not merely hidden but **provably absent** — verifiable with `apt`/`ls`.

The honest framing: because modes are *already* install-on-demand, this feature does not add a capability so much as make an existing strength **legible and selectable**. The one genuinely new guarantee is the HARD level (§2/§4), which requires build-time omission — the on-demand design alone does not deliver provable absence, because the scripts that *could* fetch AI still ship in the ISO (`iso/build.sh:143` rsyncs the whole `modes/` tree, `:212` copies the AI wallpaper).

## 2. The Two Levels

There are two distinct guarantees. They are not interchangeable, and the anti-AI audience needs the second.

### SOFT — hide from the switcher (mode still installable)
The mode's files remain on disk under `/opt/distro/modes/<mode>`, but the switcher no longer advertises or accepts it. Achieved purely at runtime via `/etc/refract/enabled-modes` (§3). Reversible with one command (§5). **This is not provable absence** — `ls /opt/distro/modes/ai` still lists the AI tree, and the setup scripts can still be run manually.

### HARD — build-time omission (provably absent)
The ISO is built with the mode's entire footprint excluded (§4). On the installed system:
- `ls /opt/distro/modes/ai` → nothing
- `ls /usr/local/bin/distro-ai-*` → nothing
- `command -v ollama` → nothing, **and no setup script exists that could ever install it**
- `ls /opt/distro/modes/modectl/profiles/ai.conf` → absent
- `grep VALID_MODES /opt/distro/modes/modectl/distro-modectl` → no `ai`

**Be explicit with the audience:** the SOFT toggle is a convenience, not a guarantee. Anyone who wants to *audit* absence must use a HARD (mode-omitted) build. A per-install HARD helper can approximate this by `rm -rf`-ing the mode's files during Calamares (§3.4), but the strongest, cleanest guarantee is a build that **never ships** the components — see §4. Also note that a per-install deletion does not make the **ISO** AI-free; a skeptic inspecting the squashfs/live session still finds AI files unless the image itself was built with omission.

## 3. Design (installer page + registry + switcher)

Three pieces: a Calamares selection page, a persistent registry file, and a one-line change to how `distro-modectl` populates its mode list.

### 3.1 The installer page — Calamares `packagechooser`

The installer sequence lives in `iso/calamares/settings.conf:14-39` (show → exec → show). The whole `iso/calamares/` tree is rsynced into the image at `iso/build.sh:93-97` with `--delete --exclude README.md`, so **new `modules/*.conf` and an edited `settings.conf` propagate with no `build.sh` change** (pure Calamares config). Note the tree is currently unverified against a running Calamares instance (`iso/calamares/README.md:59-62`).

Use the purpose-built **`packagechooser`** view module:

- It is a **view** module — it goes in `show:` only; upstream states it provides no exec jobs. Putting it in `exec:` does nothing.
- `mode: optionalmultiple` → zero-or-more **checkboxes**. Exactly the "pick any of four" UX. `normal` is not an item.
- `method: legacy` → writes a GlobalStorage key `packagechooser_<instanceId>` holding a **comma-separated list** of selected item ids (empty string if none). Use **legacy, not `method: packages`** — `packages` would route the ids into Calamares' apt module to install as baked packages, but Refract modes are on-demand setup scripts, not apt packages. `legacy` captures the selection only, which is what we want.

**ADD `iso/calamares/modules/packagechooser_modes.conf`:**
```yaml
mode: optionalmultiple
method: legacy
labels:
  step: "Modes"
items:
  - { id: gaming,   name: Gaming,   description: "Steam/Proton, Lutris, gamemode…", screenshot: "gaming.png" }
  - { id: ai,       name: AI,       description: "Local LLMs (Ollama), ComfyUI…",  screenshot: "ai.png" }
  - { id: server,   name: Server,   description: "SSH, Docker, Netdata…",           screenshot: "server.png" }
  - { id: creative, name: Creative, description: "Blender, Kdenlive, FreeCAD…",      screenshot: "creative.png" }
```
No `normal` item; no `packages:` keys (legacy). Missing screenshots fall back to the branding dir and the page still renders (bare). Ship four small PNGs into `iso/calamares/branding/refractos/` (reuse the per-mode wallpapers) for polish.

**ADD `iso/calamares/modules/shellprocess_modes.conf`** (persist the choice into the target root):
```yaml
dontChroot: false
timeout: 60
script:
  - command: "/opt/distro/modes/modectl/distro-apply-mode-selection '${gs[packagechooser_modes]}'"
    timeout: 60
```
`shellprocess` with `dontChroot: false` runs **inside the installed root** and supports `gs[key]` GlobalStorage substitution. `/opt/distro` is already unpacked by the time this runs (see sequencing below).

**EDIT `iso/calamares/settings.conf`:**

(a) Add an `instances:` block so the GS key is named `packagechooser_modes` and the shellprocess uses its own conf:
```yaml
instances:
- { id: modes, module: packagechooser, config: packagechooser_modes.conf }
- { id: modes, module: shellprocess,   config: shellprocess_modes.conf }
```
(b) In `show:` (`settings.conf:15-21`), insert `- packagechooser@modes` after `users`, before `summary` — choice made before the install summary.

(c) In `exec:` (`settings.conf:22-37`), insert `- shellprocess@modes` **after `unpackfs`** (`:25`, so `/opt/distro` exists in the target) and **before `umount`** (`:37`).

### 3.2 The registry contract — `/etc/refract/enabled-modes`

Single source of truth for which modes an install includes. Read by both the switcher and any verifier.

- **Format:** one mode per line; `#` comments and blank lines ignored; whitespace-tolerant. `normal` is always implicitly present (the loader force-appends it).
- **Location:** under `/etc` (persistent). Not `/run` — that tmpfs holds *current* mode (`/run/distro-modectl/current-mode`, `distro-modectl:39`), not *installed* modes.
- **Permissions:** must be **world-readable (0644)** — see gotcha in §3.3.
- **Fallback:** **file absent/unreadable → all five modes** (pre-feature and existing installs are unaffected). File **present but empty or all-garbage → `normal` only**. The fallback-to-all lives *only* in the file-absent branch; do not add an "empty → all" rule, or you would silently re-enable AI on an install that deliberately opted out.
- Ship a **default `/etc/refract/enabled-modes`** via `includes.chroot` so a from-ISO (non-installed) live session behaves predictably.

### 3.3 How `distro-modectl` consumes it

`VALID_MODES` is defined once (`distro-modectl:40`) and read in exactly two places (repo-wide grep confirms only these three hits):
- `usage()` (`:51`) — joins the array with `IFS='|'` to advertise `switch <gaming|ai|server|creative|normal>` (the SOFT hide falls out here for free).
- `do_switch()` (`:323`) — the membership guard `[[ " ${VALID_MODES[*]} " == *" $mode "* ]] || usage` (the enforcement point).

`do_status()` (`:370-380`) does not reference `VALID_MODES` — no change needed. Because both real consumers read the array **by name**, the *only* change required is **how the array gets populated**. Lines 51 and 323 stay byte-for-byte identical.

**EDIT `modes/modectl/distro-modectl:40`** — replace the single hardcoded line with three declarations:
```bash
ALL_MODES=(gaming ai server creative normal)
ENABLED_MODES_FILE="${ENABLED_MODES_FILE:-/etc/refract/enabled-modes}"   # overridable, mirrors GOV_AVAIL_FILE:44
VALID_MODES=()
```

**ADD a loader** immediately above `usage()` (just before `:46`):
```bash
load_valid_modes() {
    if [ ! -r "$ENABLED_MODES_FILE" ]; then
        VALID_MODES=("${ALL_MODES[@]}")   # file absent -> keep all five (back-compat)
        return
    fi
    VALID_MODES=()
    local line tok
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        for tok in $line; do
            [[ " ${ALL_MODES[*]} " == *" $tok "* ]] || continue    # drop unknown tokens
            [[ " ${VALID_MODES[*]} " == *" $tok "* ]] && continue   # dedupe
            VALID_MODES+=("$tok")
        done
    done < "$ENABLED_MODES_FILE"
    [[ " ${VALID_MODES[*]} " == *" normal "* ]] || VALID_MODES+=(normal)   # base always on
}
```

**INVOKE it once**, unconditionally, just before the dispatch guard at `:385` (right before `if [ "${DISTRO_MODECTL_SOURCE:-}" != "1" ]; then`):
```bash
load_valid_modes
```

Net edit: 1 line replaced, ~16 added. Keeping the name `VALID_MODES` means both consumers are already correct; repopulating it from the file gives **both levels for free** — soft-hide (usage advertises only enabled modes) and enforcement (do_switch rejects disabled modes). A deliberate `normal`-only file yields `VALID_MODES=(normal)`: `usage()` prints `switch <normal>` and everything else is rejected — the provably-minimal install.

**Gotchas:**
- **World-readable (0644) is mandatory.** `require_root_for()` (`:55-74`) re-execs `"$0" "$@"`, so the script runs `load_valid_modes` twice — once as the desktop user (pre-sudo pass, gated by `_REFRACT_REEXEC`, doing `apply_theme`/`apply_ai_model`) and once as root. If the file were root-only, the user pass would fall back to `ALL_MODES` and the two passes would disagree. The Calamares helper that writes the file **must chmod 0644**.
- **Sourcing is safe.** `tests/test_modectl.sh:76` sources with `DISTRO_MODECTL_SOURCE=1`; `load_valid_modes` runs at source time and falls back to `ALL_MODES` (no `/etc/refract` file in CI). `ENABLED_MODES_FILE` being overridable lets a test point at a fixture the way `GOV_AVAIL_FILE` (`:44`) does.
- `do_status` still echoes whatever `/run/.../current-mode` records even if that mode was later disabled — informational only, acceptable. Optional: have `do_status` also print `${VALID_MODES[*]}`.

### 3.4 The target-side helper — `distro-apply-mode-selection`

**ADD `modes/modectl/distro-apply-mode-selection`** (~30 lines). Because `build.sh:143` already rsyncs `modes/` into both live and target `/opt/distro`, and `build.sh:162` chmods `+x` any `distro-*` file, **no build.sh change is needed**. It receives the comma list as `$1` (runs in-chroot, so paths are target-native) and does:

- **SOFT:** normalize the comma list to newline-separated tokens and write `/etc/refract/enabled-modes` (chmod 0644). This is the switcher's registry.
- **HARD (optional, per-install provable absence):** for each of `gaming ai server creative` **not** in the list:
  - `rm -rf /opt/distro/modes/<mode>`
  - remove its `/usr/local/bin/distro-<mode>-*` symlinks (created at `build.sh:151-161`)
  - delete `/usr/share/backgrounds/refract/<mode>.png` (copied at `build.sh:212`)
  - for AI specifically, also `rm -f /opt/distro/modes/modectl/profiles/ai.conf` (see §4-H — it is **not** under `modes/ai/`).

**Must handle empty `$1` safely** (quote the expansion): with `optionalmultiple`, an empty selection is a legitimate "plain desktop" outcome that resolves to `normal` only. Do not let it word-split or error. Use `requiredmultiple` in the page conf if at least one non-Normal mode should be forced.

**Substitution syntax (load-bearing):** upstream documents the KEY form as `gs[key]` but the COMMAND form as `${gs[key]}` (its own example: `${gs[branding.bootloader]}`). A bare `gs[key]` is NOT expanded — it passes through literally and silently discards the selection. If the shipped Calamares predates it, the helper receives the literal string `gs[packagechooser_modes]`. Mitigations: confirm the Calamares version at first real install, or fall back to `contextualprocess` keyed on `packagechooser_modes`. Test the substitution and the GS key name on the first VM run — the same first-real-install validation the rest of `iso/calamares/` is waiting on (`README.md:9-12,59-62`).

## 4. The Provably-Absent Build

The per-install helper (§3.4) can delete AI from a target, but the honest, auditable guarantee is a build that **never ships** AI. The image acquires AI through exactly **three baking mechanisms** in `iso/build.sh` — these are the chokepoints — plus the switcher profile/wiring and some advertising text.

### 4.1 Complete AI-component inventory (everything a HARD no-AI build must exclude)

**A. `modes/ai/bin/*` — 8 CLIs** (each symlinked to `/usr/local/bin` by `build.sh:151-161`): `distro-ai-model`, `distro-ai-image`, `distro-ai-ask`, `distro-ai-overlay`, `distro-ai-cloud-toggle`, `distro-ai-bind-hotkey`, `distro-ai-detect-tier` (also writes `/etc/systemd/system/ollama.service.d/10-refract-vulkan.conf` and `~/.config/refract-ai/*` at runtime), `distro-ai-setup`.

**B. `modes/ai/setup/*` — 6 scripts** (`01-install-ollama.sh` … `06-install-alpaca.sh`). These are the **only** path that fetches Ollama/ComfyUI/models/OpenCode/Alpaca; excluding them is what makes AI un-installable via shipped tooling.

**C. `modes/ai/systemd/*` — 2 units** (`ollama.service`, `comfyui.service`). Plus the runtime-generated Vulkan drop-in (written by `distro-ai-detect-tier`, never in the ISO).

**D. `modes/ai/config/*` — 8 files**: `models.catalog.{cpu,entry,mid,high,max,ultra}.json` (**6 tiers — note `entry`, not numeric**) + `opencode.ollama.json`, `opencode.claude-cloud.json`.

**E. `modes/ai/integrations/*`**: `nautilus-ask-ai` + `install.sh`.

**F. `modes/ai/legacy-crucible12/*` — 14 files** (own `distro-ai-preset` CLI, `crucible12@.service`, llama.cpp setup, presets). Lives under `modes/ai/`, so `--exclude=ai/` catches it — but any allowlist enumerating only current `bin/setup/config/systemd` will leak it. Plus `modes/ai/README.md`, `modes/ai/.gitignore`.

**G. The three `iso/build.sh` baking mechanisms:**
- **G1 (`build.sh:143`):** `rsync -a --delete modes drivers → /opt/distro/` copies the **entire** `modes/` tree including all of A–F. → add `--exclude=ai/`.
- **G2 (`build.sh:151-161`):** `DISTRO_BINS` maps the 8 `distro-ai-*` names to `modes/ai/bin` and the loop symlinks each into `/usr/local/bin`. → drop all 8 `[distro-ai-*]` entries so no AI CLI hits PATH.
- **G3 (`build.sh:212`):** `cp branding/out/wallpapers/*.png …` copies **all** wallpapers including `ai.png`. → narrow the glob to exclude `ai.png`.

**H. Switcher profile + wiring:**
- `modes/modectl/profiles/ai.conf` — **NOT under `modes/ai/`**, so `--exclude=ai/` does **not** remove it. Needs a separate deletion, else `switch ai` still resolves a profile.
- `modes/modectl/distro-modectl:40` — remove `ai` from the array (or, with §3.3, derive it from the shipped profile set / `/etc/refract/enabled-modes`).
- `apply_ai_model()` (`~:219-249`, call site `:354`) — auto-runs `distro-ai-detect-tier`/`distro-ai-model` on AI entry; inert once `ai.conf` is gone (only `ai.conf` sets `AI_AUTOSTART_USECASE`), but the code still names AI.

**I. Wallpaper:** `branding/out/wallpapers/ai.png` (baked by G3). An `ls`-visible `ai` artifact even though it is just an image.

**J. Dual-use — review, do NOT auto-strip:** `iso/strains/laptop.list.chroot:35-37` (`mesa-vulkan-drivers`, `libvulkan1`, `vulkan-tools`) are AI-motivated (detect-tier calls `vulkaninfo`) but also serve gaming/creative. `vulkan-tools` is the most AI-specific. `drivers/install-nvidia.sh` is GPU driver install, not AI-only. Blanket removal would cripple gaming.

**K. Advertising text (edit for the honesty promise):**
- `iso/calamares/branding/refractos/show.qml:68` — slideshow slide selling "AI mode … Ollama … ComfyUI". Rsynced at `build.sh:97`. An installer that sells AI on a no-AI image is self-contradictory.
- `iso/calamares/branding/refractos/show.qml:58` — the **intro** slide hardcodes "local-first AI, no cloud assistant required" enumerating all five modes; the per-slide delete does not touch this — genericize separately.
- `iso/config/hooks/0200-refract-identity.chroot:34-35` — MOTD prints "local-first AI" and a `switch gaming|ai|…` hint listing `ai`.
- `iso/README.md:57` — documents the `distro-ai-*` symlinks (doc only).

**Server mode is not AI:** `modes/server/setup/*` is ssh/docker/netdata only. No AI components live outside A–K.

### 4.2 The build flag — mirror `testing_no_login` exactly

The `testing_no_login` pattern (`build.sh:27-39,249-300`; workflow `build-iso.yml:31-35,70,73`) is the template: **"always remove, then conditionally add/keep,"** driven by a workflow_dispatch input forwarded via `sudo -E ./build.sh`.

Add `REFRACT_OMIT_MODES` the same way:

1. **Script default** (near `build.sh:27`): `REFRACT_OMIT_MODES="${REFRACT_OMIT_MODES:-}"; REFRACT_OMIT_MODES="${REFRACT_OMIT_MODES//,/ }"`. Validate each token ∈ `gaming|ai|server|creative`; **reject `normal`**. Collect into `OMITTED=()`.

2. **Omit files** — immediately after the rsync at `:143`, before the symlink loop at `:147`:
   ```bash
   for m in "${OMITTED[@]}"; do
     rm -rf "$INCLUDES/opt/distro/modes/$m"
     rm -f  "$INCLUDES/opt/distro/modes/modectl/profiles/$m.conf"
   done
   ```
   (This removes A–F and H's `ai.conf` for AI.)

3. **Skip PATH symlinks** — in the loop at `:159-161`, derive the mode from `DISTRO_BINS[$bin]` (e.g. `modes/ai/bin → ai`) and `continue` if in `OMITTED`; otherwise the loop creates dangling symlinks to just-deleted bins.

4. **Hard-disable switcher** — sed the **copied** switcher only, never the repo source:
   ```bash
   sed -i "s/^VALID_MODES=(.*/VALID_MODES=(<kept modes>)/" \
     "$INCLUDES/opt/distro/modes/modectl/distro-modectl"
   ```
   (SOFT "hide but keep files" = the same sed **without** step 2's `rm -rf`.)

5. **Strip package-list entries** — post-process the build-only strain copy (already made at `build.sh:69`, not the repo file). Tag AI-exclusive lines in `iso/strains/*.list.chroot` with a trailing `#@omit-if-no:ai`, then:
   ```bash
   for m in "${OMITTED[@]}"; do sed -i "/#@omit-if-no:$m\b/d" "$PACKAGE_LISTS/strain-${STRAIN}.list.chroot"; done
   ```
   Per-line sentinels beat deleting whole strain files because of the dual-use packages in §4.1-J — tag only genuinely AI-exclusive lines.

6. **Strip Calamares slide text** — after the GUI block (`:93-136`), wrap each per-mode Slide (AI slide at `show.qml:67-69`) with `// @slide:ai` / `// @endslide:ai` markers and range-delete from the copy:
   ```bash
   f="$INCLUDES/etc/calamares/branding/refractos/show.qml"
   [ -f "$f" ] && for m in "${OMITTED[@]}"; do sed -i "/\/\/ @slide:$m$/,/\/\/ @endslide:$m$/d" "$f"; done
   ```
   The `[ -f ]` guard is correct: server/cloud strains already have no Calamares (`build.sh:74-77`). **This does not touch the intro sentence at `show.qml:58`** (§4.1-K) — genericize that separately.

7. **Workflow hook** (`build-iso.yml`) — add four `type: boolean`, `default: true` inputs beside `:31-35`: `include_gaming/include_ai/include_server/include_creative` (workflow_dispatch renders booleans as checkboxes — the "what is this machine for?" UX). Compute the omit list from the **unchecked** boxes beside `:70`:
   ```yaml
   REFRACT_OMIT_MODES: >-
     ${{ !inputs.include_ai && 'ai ' || '' }}${{ !inputs.include_gaming && 'gaming ' || '' }}${{ !inputs.include_server && 'server ' || '' }}${{ !inputs.include_creative && 'creative ' || '' }}
   ```
   `sudo -E ./build.sh` (`:73`) already forwards it. Optionally add a post-build assertion step (analog of "Mark testing ISO as DANGEROUS") that greps the tree to prove `/opt/distro/modes/ai` is absent, and suffix the artifact/release name with `-noai`.

**Order matters:** the symlink-skip (3) must key off the same `OMITTED` as the `rm -rf` (2); both run after `:143`. The `VALID_MODES` sed (4) and slide sed (6) operate on copies under `$INCLUDES` — **never** sed the repo-root `modes/modectl/distro-modectl` or `iso/calamares/show.qml`. systemd units need no separate handling: `modes/ai/systemd/*` exist only under `modes/ai/`, so the `rm -rf` covers them, and they were never installed into `/etc/systemd` by the ISO anyway (setup scripts do that post-install).

## 5. Runtime Re-Enable — `distro-modectl modes <verb>`

There is **no post-install first-boot wizard** and none can be bolted onto `gnome-initial-setup` — it is purged + apt-pinned + user-units masked + done-stamped (`iso/config/hooks/0400-polish.chroot:56-79,117-130`). The registry `/etc/refract/enabled-modes` is therefore also the runtime lever. Add a `modes` subcommand to the dispatch case (`distro-modectl:386-398`, currently only `switch`/`status`) with sub-verbs `list/enable/disable/status`:

- **`enable <mode>`:** (a) validate `<mode> ∈ ALL_MODES` and reject `normal`; (b) idempotently append to `/etc/refract/enabled-modes` — needs root, reuse `require_root_for` (`:55-74`); (c) run that mode's setup: for `ai` call `distro-ai-setup --install --yes` **as the desktop user** via `run_as_user` (`:96-108`) because ai-setup **refuses root** (`distro-ai-setup:19-22`, per-user state in `~/.config/refract-ai`); for gaming/creative/server run `modes/<mode>/setup/*.sh` in filename order; (d) optionally chain `do_switch <mode>`.
- **`disable <mode>`:** remove the line (SOFT only — files stay in `/opt/distro`; **not** provable absence). A separate `--purge` variant (apt purge Ollama/ComfyUI/Steam + `rm -rf /opt/distro/modes/<mode>`) is the hard reversal, but the honest guarantee still comes from a HARD build that never shipped it.
- **`list`/`status`:** echo `${VALID_MODES[*]}` and/or the file contents.

The `do_switch` gate from §3.3 already refuses a disabled mode; make its error point at `distro-modectl modes enable <mode>` rather than the bare `usage`. Non-interactive callers must pass `--yes` (`distro-ai-setup:15,26-31`) so a non-TTY caller never hangs on `read`. `apply_ai_model` (`:234-249`) already auto-detects tier on first AI entry (gated on absence of `~/.config/refract-ai/tier`), so the install-on-demand plumbing is ready — only "who records the choice" was missing, and §3 supplies it.

Keep `ALL_MODES` (the immutable catalog of what modes *can* exist) and `/etc/refract/enabled-modes` (the mutable installed subset) separate. Do not rewrite `ALL_MODES` at runtime, or `enable` loses its validation whitelist.

## 6. Non-Goals / Constraints

- **Normal is never deselectable.** It is the always-on base desktop; identity/dconf hooks depend on its profile/theme setup. It is not a `packagechooser` item, is force-appended by the loader (§3.3), and is rejected as an omit target (§4.2 step 1) and as an `enable`/`disable` target (§5).
- **Sequencing.** This is an **install-flow** feature. Per `iso/calamares/README.md:9-12,59-62`, the installer has **not yet completed a real install**. This feature comes *after* that milestone — the packagechooser page, the GS key name, and the in-chroot `shellprocess` helper all need first-real-install validation before they can be trusted.
- **Per-install absence ≠ ISO absence.** The §3.4 helper gives a target with zero AI files, but the ISO still contains `modes/ai` and `ai.png` unless it was built with §4's omission flag. Flag this to the anti-AI audience explicitly — they may audit the image, not just the install.
- **Naming.** The page asks **"what is this machine for?"** — framed as *choosing* what to include, not "disabling modes." Positive selection, big-tent.
- **Dual-use packages are review items, not auto-exclusions** (§4.1-J): stripping `mesa-vulkan-drivers`/`libvulkan1` for AI-absence would break gaming/creative.

## 7. Implementation Checklist

**A. Registry + switcher (runtime SOFT level; foundational):**
1. Edit `modes/modectl/distro-modectl:40` → `ALL_MODES`, `ENABLED_MODES_FILE`, empty `VALID_MODES` (§3.3).
2. Add `load_valid_modes()` above `usage()` (`~:45`); call it unconditionally before the dispatch guard (`~:384`). Leave `:51` and `:323` untouched.
3. Ship a default world-readable `/etc/refract/enabled-modes` (all five) via `includes.chroot` for the live session.
4. Add a fixture-based test (mirror `GOV_AVAIL_FILE`): a 2-line `ENABLED_MODES_FILE` fixture asserting `usage()`/`do_switch` honor it, plus the absent-file → all-five fallback.

**B. Installer page (SOFT selection at install time):**
5. Add `iso/calamares/modules/packagechooser_modes.conf` (`optionalmultiple`, `method: legacy`, 4 items, no `normal`).
6. Add `iso/calamares/modules/shellprocess_modes.conf` (`dontChroot: false`, calls the helper with `${gs[packagechooser_modes]}` — the braces are load-bearing; a bare `gs[...]` is not expanded).
7. Edit `iso/calamares/settings.conf`: `instances:` block + `packagechooser@modes` in `show:` (after `users`) + `shellprocess@modes` in `exec:` (after `unpackfs`, before `umount`).
8. Add `modes/modectl/distro-apply-mode-selection` (writes `/etc/refract/enabled-modes` 0644; optional per-mode HARD `rm -rf`; handles empty `$1`). No `build.sh` change.
9. Add 4 screenshot PNGs to `iso/calamares/branding/refractos/` (reuse per-mode wallpapers).

**C. Runtime re-enable:**
10. Add the `modes` subcommand (`list/enable/disable/status`) to the dispatch case (`distro-modectl:386`), using `require_root_for` and `run_as_user`; make `do_switch`'s refusal point at `modes enable`.

**D. Provably-absent build (HARD level):**
11. Add `REFRACT_OMIT_MODES` default + validation near `build.sh:27` (reject `normal`).
12. Insert the omit `rm -rf` loop after `build.sh:143` (files + `profiles/<mode>.conf`).
13. Add the symlink-skip in the loop at `build.sh:159-161`.
14. Add the `VALID_MODES` sed on the `$INCLUDES` copy after the omit block.
15. Add `#@omit-if-no:<mode>` sentinels to `iso/strains/*.list.chroot` (AI-exclusive lines only) + the strip sed after `build.sh:69`.
16. Add `// @slide:<mode>` markers to `show.qml` + the range-delete sed after the GUI block; genericize the intro sentence at `show.qml:58` separately.
17. Add 4 `include_*` boolean inputs to `build-iso.yml:31-35`; compute `REFRACT_OMIT_MODES` from unchecked boxes beside `:70`; optional `-noai` artifact suffix + absence-assertion step.
18. Edit remaining advertising text for honesty: `0200-refract-identity.chroot:34-35`, `iso/README.md:57`.

**E. Validation (blocked on first real install):**
19. On the first VM install: confirm the packagechooser page renders, the GS key is exactly `packagechooser_modes`, and the `shellprocess` helper runs in-chroot with the **expanded** value (if `gs[]` doesn't expand, fall back to `contextualprocess`).
20. Verify the HARD promise on a no-AI build: `ls /opt/distro/modes/ai`, `ls /usr/local/bin/distro-ai-*`, `ls /opt/distro/modes/modectl/profiles/ai.conf`, `command -v ollama`, `grep VALID_MODES …/distro-modectl` — all clean.