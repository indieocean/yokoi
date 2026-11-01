#!/usr/bin/env python3
"""Draws the DMG window background (assets/dmg/background.png and @2x) in the README header's style.

Needs Pillow (pip install pillow). The header's fonts, Inter and JetBrains Mono (both SIL OFL), are downloaded
into build/fonts on first run.
The PNGs are committed, so releases don't need to run this.
Icon positions must match scripts/dmg-settings.py.
"""
import math
import os
import random
import urllib.request
import zipfile

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 660, 400                    # window content size in points
APP, APPS = (170, 190), (490, 190)  # icon centers (dmg-settings.py)
BG = (14, 16, 22)
PURPLE = (139, 108, 255)
CYAN = (34, 211, 238)
TEXT = (125, 133, 151)
WORDMARK = [(255, 255, 255), (232, 224, 255), (168, 140, 255), (120, 160, 255), (52, 204, 240)]  # header gradient
ACCENT = [(139, 108, 255), (34, 211, 238)]  # "garbage collected"
FONTS = os.path.join(os.path.dirname(__file__), "..", "build", "fonts")
INTER = ("https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip", "InterVariable.ttf")
MONO = ("https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip",
        "fonts/variable/JetBrainsMono[wght].ttf")
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "dmg")


def font_file(source):
    """Path to a font from a release archive, downloading it into build/fonts the first time."""
    url, member = source
    path = os.path.join(FONTS, os.path.basename(member))
    if not os.path.exists(path):
        os.makedirs(FONTS, exist_ok=True)
        archive = os.path.join(FONTS, os.path.basename(url))
        urllib.request.urlretrieve(url, archive)
        with zipfile.ZipFile(archive) as z, open(path, "wb") as out:
            out.write(z.read(member))
    return path


def inter(size, weight, optical=None):
    """Inter at `size` px and `weight` (100-900). The optical size follows the text size unless given."""
    font = ImageFont.truetype(font_file(INTER), size)
    font.set_variation_by_axes([optical or max(14, min(32, size)), weight])  # axes: optical size, weight
    return font


def mono(size, weight):
    """JetBrains Mono at `size` px and `weight` (100-800)."""
    font = ImageFont.truetype(font_file(MONO), size)
    font.set_variation_by_axes([weight])
    return font


def glow(size, center, radius, color, alpha, scale):
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy, r = center[0] * scale, center[1] * scale, radius * scale
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color + (alpha,))
    return layer.filter(ImageFilter.GaussianBlur(r * 0.55))


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def tracked(draw, xy, text, font, fill, tracking=0.0):
    """Draws `text` with letter spacing `tracking` (in em, negative is tighter), keeping kerning.
    Returns the advance width."""
    x, y = xy
    em = font.size
    for i, ch in enumerate(text):
        # Prefix widths include kerning between earlier pairs.
        offset = draw.textlength(text[:i], font=font) + i * tracking * em
        draw.text((x + offset, y), ch, font=font, fill=fill)
    return draw.textlength(text, font=font) + (len(text) - 1) * tracking * em


def tracked_length(text, font, tracking=0.0):
    return ImageDraw.Draw(Image.new("L", (1, 1))).textlength(text, font=font) + (len(text) - 1) * tracking * font.size


def gradient_text(img, text, font, top, stops, left=None, tracking=0.0):
    """Draws `text` at `top` (centered unless `left` is given), filled with a left-to-right gradient."""
    d = ImageDraw.Draw(img)
    bx, by, _, by2 = d.textbbox((0, 0), text, font=font)
    w, h = round(tracked_length(text, font, tracking) - bx + font.size * 0.1), by2 - by
    mask = Image.new("L", (w, h), 0)
    tracked(ImageDraw.Draw(mask), (-bx, -by), text, font, 255, tracking)
    w = mask.getbbox()[2] if mask.getbbox() else w
    mask = mask.crop((0, 0, w, h))
    fill = Image.new("RGBA", (w, h))
    px = fill.load()
    for x in range(w):
        f = x / max(1, w - 1) * (len(stops) - 1)
        i = min(int(f), len(stops) - 2)
        c = mix(stops[i], stops[i + 1], f - i)
        for y in range(h):
            px[x, y] = c + (255,)
    fill.putalpha(mask)
    x = round((img.width - w) / 2) if left is None else round(left + bx)
    img.alpha_composite(fill, (x, round(top + by)))


def draw(scale):
    size = (W * scale, H * scale)
    img = Image.new("RGBA", size, BG + (255,))
    img.alpha_composite(glow(size, APP, 150, PURPLE, 70, scale))
    img.alpha_composite(glow(size, APPS, 130, CYAN, 34, scale))

    # Translucent shapes go on their own layer: drawing them straight onto `img` would replace pixels, not blend.
    overlay = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(overlay)
    # Faint grid.
    step = 32 * scale
    for x in range(0, size[0], step):
        d.line((x, 0, x, size[1]), fill=(255, 255, 255, 9), width=1)
    for y in range(0, size[1], step):
        d.line((0, y, size[0], y), fill=(255, 255, 255, 9), width=1)

    # Pixel particles, denser toward the top right like the header.
    rng = random.Random(7)
    for _ in range(70):
        x, y = rng.uniform(0, W), rng.uniform(0, H)
        if abs(y - APP[1]) < 95 and (abs(x - APP[0]) < 95 or abs(x - APPS[0]) < 95):
            continue  # keep the icons clean
        s = rng.choice([1.5, 2, 2, 3]) * scale
        c = mix(PURPLE, CYAN, x / W)
        a = rng.randint(35, 100)
        d.rectangle((x * scale, y * scale, x * scale + s, y * scale + s), fill=c + (a,))

    # Arrow from the app to Applications, purple to cyan.
    x0, x1, y = (APP[0] + 84) * scale, (APPS[0] - 84) * scale, APP[1] * scale - 6 * scale
    head = 11 * scale
    dash, gap = 10 * scale, 7 * scale
    count = int((x1 - head * 1.4 - x0 + gap) // (dash + gap))
    for i in range(count):
        x = x0 + i * (dash + gap)
        c = mix(PURPLE, CYAN, (x - x0) / (x1 - x0))
        d.rounded_rectangle((x, y - 2 * scale, x + dash, y + 2 * scale), radius=2 * scale, fill=c + (230,))
    d.polygon([(x1, y), (x1 - head * 1.3, y - head), (x1 - head * 1.3, y + head)], fill=CYAN + (240,))
    img.alpha_composite(overlay)
    d = ImageDraw.Draw(img)

    # Wordmark and tagline, as in the README header.
    # Text cut of ExtraBold, tracked tight: matches the header's width and stroke weight.
    gradient_text(img, "Yokoi", inter(48 * scale, 800, optical=14), 16 * scale, WORDMARK, tracking=-0.075)
    d = ImageDraw.Draw(img)
    tagline, t = inter(15 * scale, 400), -0.01
    lead, accent = "Your Mac, ", "garbage collected"
    x = (size[0] - tracked_length(lead + accent, tagline, t)) / 2
    top = 80 * scale
    advance = tracked(d, (x, top), lead, tagline, (200, 204, 214, 255), t) + t * tagline.size
    gradient_text(img, accent, tagline, top, ACCENT, left=x + advance, tracking=t)
    d = ImageDraw.Draw(img)

    # Terminal line, as in the README header.
    regular, bold = mono(13 * scale, 400), mono(13 * scale, 700)
    parts = [("$ ", CYAN, regular), ("drag ", (230, 232, 238), bold), ("Yokoi", (183, 156, 255), regular),
             (" → ", TEXT, regular), ("Applications", (200, 204, 214), regular)]
    widths = [d.textlength(text, font=f) for text, _, f in parts]
    pad, gap, cursor = 16 * scale, 6 * scale, 8 * scale
    box_w, box_h = sum(widths) + gap + cursor + 2 * pad, 36 * scale
    bx, by = (size[0] - box_w) / 2, 314 * scale
    box = Image.new("RGBA", size, (0, 0, 0, 0))
    ImageDraw.Draw(box).rounded_rectangle((bx, by, bx + box_w, by + box_h), radius=10 * scale,
                                          fill=(255, 255, 255, 8), outline=(255, 255, 255, 28), width=scale)
    img.alpha_composite(box)
    d = ImageDraw.Draw(img)
    x, cy = bx + pad, by + box_h / 2
    for (text, color, f), w in zip(parts, widths):
        d.text((x, cy), text, font=f, fill=color + (255,), anchor="lm")
        x += w
    d.rectangle((x + gap, cy - 8 * scale, x + gap + cursor, cy + 8 * scale), fill=CYAN + (255,))
    return img.convert("RGB")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    draw(1).save(os.path.join(OUT, "background.png"))
    draw(2).save(os.path.join(OUT, "background@2x.png"))
    print("wrote", os.path.abspath(OUT))
