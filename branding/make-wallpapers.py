#!/usr/bin/env python3
"""
Generates the Refract OS desktop wallpapers.

WHY THESE LOOK THE WAY THEY DO
------------------------------
The previous wallpapers put the logo, the wordmark in tracked-out caps, AND the
marketing tagline ("one install / five modes / local-first AI") in a centred
stack on the desktop background. No shipping OS does that -- macOS ships
abstract art, Windows ships the bloom -- because a wallpaper is the surface you
stare at all day, not ad space. Branding on it is the single loudest "hobby
distro" signal a desktop can send.

So: no text, no logo, no wordmark. The brand idea survives as the ARTWORK
itself -- one white beam entering at the left, an implied prism, and five
coloured rays dispersing across the frame. Same concept as the mark, expressed
as light instead of as a badge.

Constraints a desktop background actually has to satisfy, all deliberate here:
  * Dark and quiet in the middle, where windows and dialogs sit. Peak
    brightness is held well under white so text on top always wins.
  * Interest pushed off-centre (upper-left origin, rays sweeping down-right) so
    a centred window doesn't cover the whole composition.
  * Per-mode variants are the SAME artwork with one ray brought up and the rest
    dimmed -- so switching modes reads as the same system in a different state,
    not six unrelated pictures. `base` keeps all five balanced and is what the
    login screen and the default desktop use.
  * Dithered. Wide dark gradients band badly on 8-bit panels; a light noise
    floor breaks the banding up. This is the difference between "looks
    rendered" and "looks cheap" on a real screen.

Usage:  python3 branding/make-wallpapers.py
Writes: branding/out/wallpapers/{base,normal,gaming,ai,server,creative}.png
"""

import os
import random
from PIL import Image, ImageDraw, ImageFilter, ImageChops

W, H = 2560, 1440
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out", "wallpapers")

# The five refracted rays, in real dispersion order (least deviated first) --
# the same order and the same hexes as the logo, the mode cards on the site and
# distro-modectl's per-mode themes. Keep in sync with docs/index.html's --m-*.
RAYS = [
    ("gaming",   (0xff, 0x5a, 0x52)),
    ("normal",   (0xff, 0xa2, 0x3d)),
    ("server",   (0x7b, 0xc0, 0x43)),
    ("ai",       (0x4a, 0x9d, 0xf0)),
    ("creative", (0xe8, 0x57, 0xa0)),
]

# Prism point: off-centre, upper-left third. Rays sweep down and right from
# here, leaving the lower-left and the centre comparatively empty for windows.
ORIGIN = (0.30 * W, 0.34 * H)
ANGLES = [7.0, 13.0, 19.0, 25.0, 31.0]     # degrees below horizontal, per ray


def base_gradient():
    """Near-black vertical wash, warmed very slightly toward the top-left."""
    top, bottom = (0x0e, 0x10, 0x16), (0x06, 0x07, 0x09)
    grad = Image.new("RGB", (1, H))
    px = grad.load()
    for y in range(H):
        t = y / (H - 1)
        # ease-out so most of the frame sits at the dark end
        t = t ** 0.75
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((W, H), Image.BILINEAR)


def ray_layer(index, strength):
    """One dispersed ray: a wedge widening from the prism point, blurred soft."""
    import math
    name, colour = RAYS[index]
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    if strength <= 0:
        return layer
    d = ImageDraw.Draw(layer)

    ang = math.radians(ANGLES[index])
    ox, oy = ORIGIN
    length = W * 1.15
    ex, ey = ox + length * math.cos(ang), oy + length * math.sin(ang)

    # Wedge: near-zero at the prism, widening as the light travels.
    half_start, half_end = 3.0, 0.052 * H
    nx, ny = -math.sin(ang), math.cos(ang)      # unit normal
    d.polygon(
        [
            (ox + nx * half_start, oy + ny * half_start),
            (ex + nx * half_end,   ey + ny * half_end),
            (ex - nx * half_end,   ey - ny * half_end),
            (ox - nx * half_start, oy - ny * half_start),
        ],
        fill=tuple(round(c * strength) for c in colour),
    )
    layer = layer.filter(ImageFilter.GaussianBlur(46))

    # Fade along travel so rays dissolve instead of hitting the frame edge.
    fade = Image.linear_gradient("L").rotate(90, expand=False).resize((W, H))
    fade = fade.point(lambda p: max(0, 255 - p))          # bright at left
    fade = fade.point(lambda p: int(255 * (p / 255) ** 0.45))
    return ImageChops.multiply(layer, Image.merge("RGB", (fade, fade, fade)))


def incoming_beam():
    """The single white beam before dispersion, entering from off-canvas left."""
    import math
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    ox, oy = ORIGIN
    ang = math.radians(-14.0)                  # travelling down-right into the prism
    sx, sy = ox - W * 0.42 * math.cos(ang), oy - W * 0.42 * math.sin(ang)
    d.line([(sx, sy), (ox, oy)], fill=(120, 124, 134), width=5)
    layer = layer.filter(ImageFilter.GaussianBlur(18))

    # Brighter, tighter core on top of the soft halo.
    core = Image.new("RGB", (W, H), (0, 0, 0))
    ImageDraw.Draw(core).line([(sx, sy), (ox, oy)], fill=(150, 154, 166), width=2)
    core = core.filter(ImageFilter.GaussianBlur(3))
    return ImageChops.add(layer, core)


def dither(img, amount=1):
    """Break up gradient banding — wide dark gradients posterise badly on 8-bit.

    amount=1 is a measured choice, not a guess. Rendering the gradient with no
    dither and stretching its contrast shows hard quantisation steps, so some
    dither is genuinely required. But per-pixel noise is incompressible, and PNG
    size climbs steeply with it (measured, 2560x1440, optimize=True):

        dither=0  0.33 MB   visible banding
        dither=1  1.30 MB   banding broken
        dither=2  1.75 MB
        dither=3  2.02 MB

    At 1 the steps are already dissolved; 2 and 3 only get smoother under ~30x
    contrast amplification nobody will ever apply to their desktop. That margin
    matters more than it first looks: these six files ship inside the ISO, and
    the lowspec strain clears the publish threshold by about ONE mebibyte
    (measured 2026-08-07: ISO 2143289344 B against the 2045 MiB limit in
    build-iso.yml, 4 MiB under GitHub's hard 2 GiB asset cap). At dither=3 the
    extra ~4 MB would push lowspec straight past the hard cap. Raising this
    value is therefore a release-shape decision, not a taste one — re-measure
    lowspec before touching it.
    """
    rnd = random.Random(20260804)          # fixed seed: byte-identical rebuilds
    noise = Image.new("L", (W, H))
    noise.putdata([rnd.randint(0, amount) for _ in range(W * H)])
    return ImageChops.add(img, Image.merge("RGB", (noise, noise, noise)))


def build(emphasis=None):
    """emphasis=None -> all five balanced; otherwise that ray leads."""
    img = base_gradient()
    img = ImageChops.screen(img, incoming_beam())
    for i, (name, _) in enumerate(RAYS):
        if emphasis is None:
            s = 0.60                       # balanced full spectrum
        elif name == emphasis:
            s = 0.95                       # this mode leads
        else:
            s = 0.16                       # others recede but stay present
        img = ImageChops.screen(img, ray_layer(i, s))
    return dither(img)


# Calamares' packagechooser shows a preview image per selectable mode
# (iso/calamares/modules/packagechooser_modes.conf `screenshot:`). Those four
# PNGs were hand-copied from the OLD text-laden wallpapers and were NOT updated
# when the wallpapers were regenerated, so the installer went on previewing a
# desktop the OS no longer ships — wordmark, tagline and all. Generating them
# here is what stops that drifting again: same source artwork, one command.
#
# 'normal' is absent on purpose: it is the always-on base desktop, never a
# selectable item in the chooser (see docs/mode-selection-design.md).
#
# Downscaled to 640x360, which is both plenty for a chooser thumbnail and a size
# WIN — the stale full-resolution copies were ~245 KB each; these are ~40 KB.
# That matters: lowspec clears the publish threshold by about 1 MiB.
PREVIEW = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "iso", "calamares", "branding", "refractos")
PREVIEW_SIZE = (640, 360)
PREVIEW_MODES = ["gaming", "ai", "server", "creative"]


def main():
    os.makedirs(OUT, exist_ok=True)
    targets = [("base", None)] + [(n, n) for n, _ in RAYS]
    rendered = {}
    for name, emphasis in targets:
        img = build(emphasis)
        rendered[name] = img
        path = os.path.join(OUT, f"{name}.png")
        img.save(path, optimize=True)
        print(f"wrote {path} ({os.path.getsize(path) // 1024} KB)")

    preview_dir = os.path.normpath(PREVIEW)
    if os.path.isdir(preview_dir):
        for name in PREVIEW_MODES:
            path = os.path.join(preview_dir, f"{name}.png")
            rendered[name].resize(PREVIEW_SIZE, Image.LANCZOS).save(path, optimize=True)
            print(f"wrote {path} ({os.path.getsize(path) // 1024} KB, installer preview)")
    else:
        print(f"NOTE: {preview_dir} missing — installer previews not written")


if __name__ == "__main__":
    main()
