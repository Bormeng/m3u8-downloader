#!/usr/bin/env python3
"""Build macOS .icns from a single 1024x1024 PNG.

- Loads source image
- Strips near-white background (white → transparent) since AI-generated icons
  usually come with an opaque white background
- Smoothly fades alpha on the anti-aliased edge so the squircle has a clean cut
- Downscales to all required sizes with LANCZOS
- Outputs PNGs into an iconset directory
"""
import sys
from pathlib import Path
from PIL import Image

SRC = Path("/Users/ming/Documents/Repositories/m3u8-downloader/docs/icon_candidate_1_geometric.png")
DEFAULT_ICONSET = Path("/Users/ming/Documents/Repositories/m3u8-downloader/build/AppIcon.iconset")
ICONSET = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_ICONSET

# Pixels whose R,G,B are all above this threshold are treated as "white background"
# and made transparent.  Pixels below are opaque.  Pixels in between get
# a smooth alpha ramp so anti-aliased edges stay soft.
WHITE_THRESHOLD_LOW  = 235   # below this → fully opaque
WHITE_THRESHOLD_HIGH = 252   # above this → fully transparent

SIZES = [
    ("16x16",         16),
    ("16x16@2x",      32),
    ("32x32",         32),
    ("32x32@2x",      64),
    ("128x128",      128),
    ("128x128@2x",   256),
    ("256x256",      256),
    ("256x256@2x",   512),
    ("512x512",      512),
    ("512x512@2x",  1024),
]

def strip_white_background(img: Image.Image) -> Image.Image:
    """Convert a white-backgrounded image to RGBA with the background removed."""
    img = img.convert("RGBA")
    r, g, b, a = img.split()
    # Compute per-pixel "whiteness" = min(R,G,B), clamped 0-255
    pixels = img.load()
    w, h = img.size
    new_alpha = Image.new("L", (w, h))
    new_alpha_px = new_alpha.load()
    src_alpha = a.load()
    for y in range(h):
        for x in range(w):
            pr, pg, pb, pa = pixels[x, y]
            mn = min(pr, pg, pb)
            if mn >= WHITE_THRESHOLD_HIGH:
                # fully white → transparent
                new_alpha_px[x, y] = 0
            elif mn <= WHITE_THRESHOLD_LOW:
                # clearly non-white → keep opaque (preserve source alpha too)
                new_alpha_px[x, y] = pa
            else:
                # smooth ramp for anti-aliased edge
                t = (WHITE_THRESHOLD_HIGH - mn) / (WHITE_THRESHOLD_HIGH - WHITE_THRESHOLD_LOW)
                new_alpha_px[x, y] = int(pa * t)
    img.putalpha(new_alpha)
    return img

def main():
    ICONSET.mkdir(parents=True, exist_ok=True)
    src = Image.open(SRC)
    print(f"Source: {SRC}  size={src.size}  mode={src.mode}")

    # 1. Strip white background at FULL 1024 size, then downscale with alpha
    #    This keeps the squircle edges crisp at every resolution.
    clean = strip_white_background(src)
    print(f"After white-strip: mode={clean.mode}")

    # Verify: corner pixels should now be (...,0) i.e. transparent
    for (x, y) in [(0, 0), (1023, 0), (0, 1023), (1023, 1023),
                    (512, 0), (512, 1023), (0, 512), (1023, 512)]:
        print(f"  corner ({x},{y}): {clean.getpixel((x, y))}")

    # 2. Downscale to all required sizes
    for suffix, size in SIZES:
        resized = clean.resize((size, size), Image.LANCZOS)
        out = ICONSET / f"icon_{suffix}.png"
        resized.save(out, format="PNG", optimize=True)
        print(f"  wrote {out.name}  {size}x{size}")

    print(f"\nRun:  iconutil -c icns {ICONSET}")

if __name__ == "__main__":
    main()