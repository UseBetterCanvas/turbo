#!/usr/bin/env python3
"""Renders Turbo's app icon: a pup in a graduation cap on a Blurple badge.

Follows the BetterCampus brand: flat color only (no gradients, glow or shadow), the Campy
sticker style (thick #121212 outline), Blurple 600 badge, gold accents.

    pip install pillow numpy
    python3 scripts/make-icon.py      # writes Resources/AppIcon.icns and Resources/AppIcon.png
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

S = 1024
K = 4                     # supersampling
OUT = Path(__file__).resolve().parent.parent / "Resources"

BLURPLE = (79, 73, 243, 255)      # bp-600 #4F49F3
INK = (18, 18, 18, 255)           # Campy outline #121212
GOLD = (255, 198, 92, 255)        # gold-300 #FFC65C
GOLD_DEEP = (133, 86, 0, 255)     # gold-800 #855600
WHITE = (255, 255, 255, 255)
CAP = (33, 33, 33, 255)           # deep-3 #212121
TONGUE = (255, 98, 62, 255)       # bad-400 #FF623E
LINE = 18 * K                     # outline width


def P(x, y):
    return (x * K, y * K)


def bezier(p0, p1, p2, p3, n=48):
    pts = []
    for i in range(n + 1):
        t = i / n
        x = (1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0]
        y = (1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1]
        pts.append(P(x, y))
    return pts


def path(*segments):
    pts = []
    for seg in segments:
        pts.extend(bezier(*seg))
    return pts


def blob(draw, pts, fill):
    """Filled shape with the sticker outline."""
    draw.polygon(pts, fill=fill)
    draw.line(pts + [pts[0]], fill=INK, width=LINE, joint="curve")


def oval(draw, cx, cy, rx, ry, fill, outline=True):
    box = (*P(cx - rx, cy - ry), *P(cx + rx, cy + ry))
    draw.ellipse(box, fill=fill, outline=INK if outline else None, width=LINE if outline else 0)


art = Image.new("RGBA", (S * K, S * K), (0, 0, 0, 0))
d = ImageDraw.Draw(art)

# Floppy ears, behind the head.
left_ear = path(
    ((352, 470), (300, 480), (250, 560), (262, 690)),
    ((262, 690), (270, 770), (340, 790), (372, 730)),
    ((372, 730), (398, 680), (400, 560), (404, 500)),
    ((404, 500), (400, 480), (380, 468), (352, 470)),
)
right_ear = [(2 * 512 * K - x, y) for (x, y) in left_ear]
blob(d, left_ear, GOLD_DEEP)
blob(d, right_ear, GOLD_DEEP)

# Head.
head = path(
    ((512, 418), (650, 418), (722, 500), (722, 610)),
    ((722, 610), (722, 742), (630, 812), (512, 812)),
    ((512, 812), (394, 812), (302, 742), (302, 610)),
    ((302, 610), (302, 500), (374, 418), (512, 418)),
)
blob(d, head, GOLD)

# Muzzle with a little tongue.
d.rounded_rectangle((*P(482, 724), *P(542, 800)), radius=30 * K, fill=TONGUE, outline=INK, width=LINE)
oval(d, 512, 690, 118, 82, WHITE)
# Nose.
nose = path(
    ((512, 676), (480, 676), (462, 662), (464, 648)),
    ((464, 648), (466, 632), (490, 628), (512, 628)),
    ((512, 628), (534, 628), (558, 632), (560, 648)),
    ((560, 648), (562, 662), (544, 676), (512, 676)),
)
d.polygon(nose, fill=INK)
# Mouth.
d.line([P(512, 676), P(512, 704)], fill=INK, width=12 * K)
d.arc((*P(462, 676), *P(512, 724)), start=20, end=160, fill=INK, width=12 * K)
d.arc((*P(512, 676), *P(562, 724)), start=20, end=160, fill=INK, width=12 * K)

# Eyes with a catchlight.
for ex in (432, 592):
    oval(d, ex, 588, 27, 30, INK, outline=False)
    oval(d, ex + 9, 578, 9, 9, WHITE, outline=False)

# Cheek blush.
for cx in (380, 644):
    oval(d, cx, 664, 26, 15, (255, 158, 112, 255), outline=False)

# Graduation cap: skull cap, then the board, then the tassel.
skull = path(
    ((396, 470), (396, 420), (400, 392), (408, 380)),
    ((408, 380), (470, 396), (554, 396), (616, 380)),
    ((616, 380), (624, 392), (628, 420), (628, 470)),
    ((628, 470), (560, 448), (464, 448), (396, 470)),
)
blob(d, skull, CAP)
board = [P(512, 248), P(782, 340), P(512, 432), P(242, 340)]
d.polygon(board, fill=CAP)
d.line(board + [board[0]], fill=INK, width=LINE, joint="curve")
# Tassel cord from the button, over the edge, down.
cord = [P(512, 338), P(700, 372), P(704, 380)] + bezier((704, 380), (720, 420), (720, 470), (716, 510))
d.line(cord, fill=GOLD, width=14 * K, joint="curve")
d.ellipse((*P(494, 322), *P(530, 356)), fill=GOLD, outline=INK, width=8 * K)
tassel = [P(700, 500), P(732, 500), P(744, 586), P(688, 586)]
d.polygon(tassel, fill=GOLD)
d.line(tassel + [tassel[0]], fill=INK, width=10 * K, joint="curve")
for tx in (702, 716, 730):
    d.line([P(tx, 540), P(tx + (tx - 716) * 0.25, 584)], fill=GOLD_DEEP, width=5 * K)

art = art.resize((S, S), Image.LANCZOS)

# Badge: macOS squircle on the 824pt grid, flat Blurple.
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) + 0.5
body = 824
f = np.abs((xx - S / 2) / (body / 2)) ** 5 + np.abs((yy - S / 2) / (body / 2)) ** 5
mask = np.clip((1.006 - f) / 0.012, 0, 1)
badge = np.zeros((S, S, 4), np.uint8)
badge[..., :3] = BLURPLE[:3]
badge[..., 3] = (mask * 255).astype(np.uint8)
icon = Image.fromarray(badge, "RGBA")
icon.alpha_composite(art)

# Clip the artwork to the badge.
alpha = np.minimum(np.asarray(icon)[..., 3], (mask * 255).astype(np.uint8))
icon.putalpha(Image.fromarray(alpha))

OUT.mkdir(exist_ok=True)
icon.save(OUT / "AppIcon.png")
icon.save(OUT / "AppIcon.icns", sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])
print("wrote", OUT / "AppIcon.icns")
