#!/usr/bin/env python3
"""Generate the four layout preview images for the installer's "Look" page.

WHY THIS EXISTS. iso/calamares/modules/packagechooser_layout.conf references
/etc/calamares/branding/refractos/layout-{refract,classic,macos,minimal}.png,
and those four files were never created — the page shipped naming images that do
not exist. A packagechooser with no artwork is four words in a list, which is a
poor way to ask someone to choose how their desktop will look.

WHAT THESE ARE, HONESTLY. They are SCHEMATICS, not screenshots. Each one is
drawn directly from the corresponding modes/layouts/profiles/<id>.conf, so what
you see is what the profile actually sets: dock position, whether the dock is
full-width or floating, which side the window controls sit on, and whether
liquid glass (translucency) is on. If a profile changes, re-run this and the
picture changes with it. Nothing here is decorative licence.

A real screenshot of each layout would be better still, and would need the
screenshot-tour CI to boot a VM, apply each layout and capture it — worth doing,
but it is a different job from "stop shipping references to missing files".

Usage:  python3 branding/make-layout-previews.py
Writes: iso/calamares/branding/refractos/layout-<id>.png  (640x360, matching the
        existing mode images gaming/ai/server/creative.png)
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 640, 360
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "..", "iso", "calamares", "branding", "refractos")

# Straight out of modes/layouts/profiles/*.conf — keep these in sync with the
# profiles, they are the whole point of the drawing.
LAYOUTS = [
    dict(id="refract", name="Refract", dock="LEFT",   extended=False, floating=True,
         buttons="right", glass=True,
         caption="Left dock · liquid glass · GNOME-native styling"),
    dict(id="classic", name="Classic", dock="BOTTOM", extended=True,  floating=False,
         buttons="right", glass=False,
         caption="Full-width taskbar · app grid bottom-left"),
    dict(id="macos",   name="macOS",   dock="BOTTOM", extended=False, floating=True,
         buttons="left",  glass=True,
         caption="Floating dock · traffic-light controls"),
    dict(id="minimal", name="Minimal", dock="OFF",    extended=False, floating=False,
         buttons="right", glass=False,
         caption="Stock GNOME · no dock, no blur"),
]

SPECTRUM = [(255, 59, 48), (255, 149, 0), (255, 214, 10), (52, 199, 89),
            (0, 122, 255), (88, 86, 214), (175, 82, 222)]


def font(size, bold=False):
    for p in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else
              "/System/Library/Fonts/Supplemental/Arial.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except Exception:
            continue
    return ImageFont.load_default()


def wallpaper():
    """The prism streak from the real Refract wallpaper, in miniature."""
    img = Image.new("RGB", (W, H), (14, 14, 17))
    streak = Image.new("RGB", (W, H), (14, 14, 17))
    d = ImageDraw.Draw(streak)
    # A diagonal spectrum fan spreading from upper-left, like light through a prism.
    for i, col in enumerate(SPECTRUM):
        off = i * 13
        d.line([(90, 70 + off), (W + 40, 250 + off * 2)], fill=col, width=16)
    streak = streak.filter(ImageFilter.GaussianBlur(26))
    return Image.blend(img, streak, 0.55)


def panel(img, box, glass, fill=(24, 24, 28), radius=0):
    """Draw a shell surface. Glass layouts get a translucent one over the
    wallpaper; non-glass gets an opaque one. That difference is the feature."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    alpha = 150 if glass else 255
    d.rounded_rectangle(box, radius=radius, fill=fill + (alpha,))
    img.alpha_composite(layer)


def draw(spec):
    img = wallpaper().convert("RGBA")
    d = ImageDraw.Draw(img)

    # GNOME top bar — every layout has one.
    panel(img, [0, 0, W, 20], spec["glass"], (18, 18, 22))
    d.text((W // 2 - 26, 5), "09:41", font=font(11), fill=(220, 220, 225))

    # Application window, with the controls on the side the profile specifies.
    wx0, wy0, wx1, wy1 = 150, 74, 500, 268
    panel(img, [wx0, wy0, wx1, wy1], spec["glass"], (38, 38, 44), radius=8)
    d.rounded_rectangle([wx0, wy0, wx1, wy0 + 26], radius=8, fill=(52, 52, 60))
    d.rectangle([wx0, wy0 + 18, wx1, wy0 + 26], fill=(52, 52, 60))
    if spec["buttons"] == "left":                      # close,minimize,maximize:
        for i, c in enumerate([(255, 95, 87), (255, 189, 46), (40, 200, 64)]):
            d.ellipse([wx0 + 10 + i * 16, wy0 + 8, wx0 + 20 + i * 16, wy0 + 18], fill=c)
    else:                                              # appmenu:minimize,maximize,close
        for i in range(3):
            cx = wx1 - 62 + i * 18
            d.ellipse([cx, wy0 + 8, cx + 10, wy0 + 18], fill=(150, 150, 158))
    for i in range(4):                                  # window content lines
        d.rounded_rectangle([wx0 + 18, wy0 + 44 + i * 22, wx0 + 18 + (250 - i * 38),
                             wy0 + 52 + i * 22], radius=4, fill=(70, 70, 80))

    # Dock / taskbar.
    if spec["dock"] == "LEFT":
        panel(img, [10, 40, 46, 300], spec["glass"], (26, 26, 32), radius=14)
        for i in range(6):
            d.rounded_rectangle([16, 50 + i * 40, 40, 74 + i * 40], radius=6,
                                fill=SPECTRUM[i % len(SPECTRUM)])
    elif spec["dock"] == "BOTTOM" and spec["extended"]:     # fixed, full width
        panel(img, [0, H - 34, W, H], spec["glass"], (24, 24, 28))
        d.rounded_rectangle([8, H - 28, 32, H - 6], radius=5, fill=(200, 200, 210))
        for i in range(5):
            d.rounded_rectangle([44 + i * 30, H - 28, 68 + i * 30, H - 6], radius=5,
                                fill=SPECTRUM[i % len(SPECTRUM)])
    elif spec["dock"] == "BOTTOM":                           # floating
        dw = 6 * 34 + 14
        x0 = (W - dw) // 2
        panel(img, [x0, H - 52, x0 + dw, H - 12], spec["glass"], (26, 26, 32), radius=14)
        for i in range(6):
            d.rounded_rectangle([x0 + 9 + i * 34, H - 45, x0 + 33 + i * 34, H - 19],
                                radius=6, fill=SPECTRUM[i % len(SPECTRUM)])

    # Label, so nobody mistakes a schematic for a photograph. Indented clear of
    # the left dock when there is one, otherwise it sits on top of the icons.
    lx = 60 if spec["dock"] == "LEFT" else 16
    ly = H - 96 if (spec["dock"] == "BOTTOM" and spec["extended"]) else H - 84
    d.text((lx, ly), spec["name"], font=font(22, bold=True), fill=(245, 245, 250))
    d.text((lx, ly + 26), spec["caption"], font=font(11), fill=(178, 178, 190))
    return img.convert("RGB")


def main():
    os.makedirs(OUT, exist_ok=True)
    for spec in LAYOUTS:
        p = os.path.normpath(os.path.join(OUT, f"layout-{spec['id']}.png"))
        draw(spec).save(p)
        print(f"wrote {p}")


if __name__ == "__main__":
    main()
