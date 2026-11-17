import sys, math, random
from PIL import Image, ImageDraw, ImageFilter
S = 2048  # draw at 2x, downsample to 1024
random.seed(7)

def lerp(a, b, t): return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))

# The map underneath: pale paper with a street grid, rotated a little.
paper = Image.new("RGB", (S, S), (244, 240, 230))
d = ImageDraw.Draw(paper)
for k in range(-12, 26):
    x = k * 150
    d.line([(x, -200), (x + 520, S + 200)], fill=(222, 216, 203), width=20)
    d.line([(-200, x + 420), (S + 200, x - 100)], fill=(222, 216, 203), width=20)
for cx, cy, r in [(520, 600, 150), (1500, 1380, 190), (1320, 520, 110)]:
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(203, 226, 190))

# The fog: a deep blue-slate veil with soft lighter drifts.
fog = Image.new("RGB", (S, S))
fd = ImageDraw.Draw(fog)
top, bottom = (72, 84, 122), (24, 28, 52)
for y in range(S):
    fd.line([(0, y), (S, y)], fill=lerp(top, bottom, y / S))
drift = Image.new("L", (S, S), 0)
dd = ImageDraw.Draw(drift)
for _ in range(26):
    cx, cy = random.randint(0, S), random.randint(0, S)
    rx, ry = random.randint(260, 620), random.randint(90, 200)
    dd.ellipse([cx - rx, cy - ry, cx + rx, cy + ry], fill=random.randint(40, 95))
drift = drift.filter(ImageFilter.GaussianBlur(110))
fog = Image.composite(Image.new("RGB", (S, S), (150, 164, 205)), fog, drift)

# The ride: a closed loop with a few street-like corners.
pts = [(520, 1560), (420, 860), (700, 400), (1240, 380), (1640, 600), (1660, 1100), (1300, 1200), (1360, 1620), (880, 1700)]
def smooth(points, rounds=2):
    for _ in range(rounds):
        out = []
        for i in range(len(points)):
            a, b = points[i], points[(i + 1) % len(points)]
            out += [(a[0] * .75 + b[0] * .25, a[1] * .75 + b[1] * .25), (a[0] * .25 + b[0] * .75, a[1] * .25 + b[1] * .75)]
        points = out
    return points
loop = smooth(pts)
def stroke(draw, width, fill):
    closed = loop + [loop[0]]
    draw.line(closed, fill=fill, width=width, joint="curve")
    for x, y in loop:
        draw.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=fill)

# Riding clears a swath of fog with a soft edge.
hole = Image.new("L", (S, S), 0)
stroke(ImageDraw.Draw(hole), 290, 255)
hole = hole.filter(ImageFilter.GaussianBlur(26))
img = Image.composite(paper, fog, hole)

# The route line and start marker.
d = ImageDraw.Draw(img)
stroke(d, 96, (92, 64, 242))
sx, sy = loop[1]
d.ellipse([sx - 104, sy - 104, sx + 104, sy + 104], fill=(255, 255, 255))
d.ellipse([sx - 60, sy - 60, sx + 60, sy + 60], fill=(92, 64, 242))

img.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
