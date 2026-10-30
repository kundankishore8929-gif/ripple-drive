"""Draws AppIcon.icns: a deep-blue rounded square with three white ripple rings around a drop.
Run with any Python that has Pillow: python make_icon.py (then ./build.sh picks it up)."""
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFilter

S = 1024
here = os.path.dirname(os.path.abspath(__file__))

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
# Background: rounded square with a vertical blue gradient (macOS icon grid: 824 px body, 100 px margin).
grad = Image.new("RGBA", (S, S))
gd = ImageDraw.Draw(grad)
top, bottom = (45, 120, 255), (12, 40, 120)
for y in range(S):
    t = y / (S - 1)
    gd.line([(0, y), (S, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([100, 100, 924, 924], radius=185, fill=255)
img.paste(grad, (0, 0), mask)

# Ripple rings, fading outwards, centred a little low.
rings = Image.new("RGBA", (S, S), (0, 0, 0, 0))
rd = ImageDraw.Draw(rings)
cx, cy = S // 2, 560
for r, w, a in [(150, 30, 255), (250, 26, 170), (345, 22, 95)]:
    rd.ellipse([cx - r, cy - r * 0.62, cx + r, cy + r * 0.62], outline=(255, 255, 255, a), width=w)
rings = Image.composite(rings, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask)
img.alpha_composite(rings)

# The drop above the rings.
drop = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dd = ImageDraw.Draw(drop)
dd.ellipse([cx - 62, 352, cx + 62, 476], fill=(255, 255, 255, 255))
dd.polygon([(cx - 56, 392), (cx, 250), (cx + 56, 392)], fill=(255, 255, 255, 255))
img.alpha_composite(drop.filter(ImageFilter.GaussianBlur(0.6)))

tmp = tempfile.mkdtemp()
iconset = os.path.join(tmp, "AppIcon.iconset")
os.makedirs(iconset)
for size in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = size * scale
        name = "icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else "")
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "AppIcon.icns")], check=True)
img.resize((256, 256), Image.LANCZOS).save(os.path.join(here, "AppIcon-preview.png"))
shutil.rmtree(tmp)
print("wrote AppIcon.icns")
