"""Build a lightweight 32-frame wing-flap sprite from the approved MT butterfly.

Only the four wings move; the body, antenna and sweeping tail stay fixed.
The source stays the original approved transparent MT illustration.
"""
from __future__ import annotations

import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/assets/mt_butterfly_approved.png"
OUTPUT = ROOT / "src/assets/mt_butterfly_flight_sheet.png"
FRAMES = 32
SIZE = 128
PIVOT = 286


def mask_polygon(size, points):
    mask = Image.new("L", size)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(0.7))


def wing_transform(layer, width_factor):
    # Inverse affine mapping folds each wing toward the stationary thorax.
    factor = max(0.38, width_factor)
    inv = 1.0 / factor
    return layer.transform(
        layer.size,
        Image.Transform.AFFINE,
        (inv, 0, PIVOT * (1 - inv), 0, 1, 0),
        resample=Image.Resampling.BICUBIC,
    )


def main():
    original = Image.open(SOURCE).convert("RGBA")
    assert original.size == (512, 512), original.size

    # Regions are distinct, so the left/right wings do not collide visually.
    polygons = [
        [(126, 64), (228, 78), (292, 211), (301, 294), (280, 303), (196, 263), (148, 224)],
        [(153, 240), (224, 253), (293, 291), (285, 321), (237, 352), (180, 366), (159, 325)],
        [(282, 286), (315, 244), (377, 186), (476, 166), (487, 201), (422, 283), (364, 322), (296, 312)],
        [(279, 298), (340, 304), (364, 330), (334, 377), (266, 381)],
    ]
    wing_parts = []
    combined = Image.new("L", original.size)
    for poly in polygons:
        mask = mask_polygon(original.size, poly)
        part = original.copy()
        part.putalpha(Image.frombytes("L", original.size, bytes(
            min(p, m) for p, m in zip(original.getchannel("A").tobytes(), mask.tobytes())
        )))
        wing_parts.append(part)
        combined = Image.frombytes("L", original.size, bytes(
            max(p, m) for p, m in zip(combined.tobytes(), mask.tobytes())
        ))

    # Keep the antenna, body and long extended tail perfectly still.
    fixed = original.copy()
    fixed.putalpha(Image.frombytes("L", original.size, bytes(
        round(a * (255 - m) / 255) for a, m in zip(original.getchannel("A").tobytes(), combined.tobytes())
    )))
    # Cover the wing seams using the stable central thorax.
    body = original.copy()
    body_mask = Image.new("L", original.size)
    ImageDraw.Draw(body_mask).ellipse((276, 284, 303, 326), fill=255)
    body.putalpha(Image.frombytes("L", original.size, bytes(
        min(a, m) for a, m in zip(original.getchannel("A").tobytes(), body_mask.tobytes())
    )))

    sheet = Image.new("RGBA", (SIZE * 8, SIZE * 4), (0, 0, 0, 0))
    preview_frames = []
    for index in range(FRAMES):
        phase = 2 * math.pi * index / FRAMES
        # Slow approach to fully open and fast turnaround give a natural flap rhythm.
        open_amount = (0.5 + 0.5 * math.cos(phase)) ** 0.68
        left_factor = 0.42 + 0.58 * open_amount
        right_factor = 0.43 + 0.57 * (0.5 + 0.5 * math.cos(phase + 0.12)) ** 0.68
        frame = Image.new("RGBA", original.size)
        for part, factor in zip(wing_parts, (left_factor, left_factor, right_factor, right_factor)):
            frame.alpha_composite(wing_transform(part, factor))
        frame.alpha_composite(fixed)
        frame.alpha_composite(body)
        frame.thumbnail((SIZE - 8, SIZE - 8), Image.Resampling.LANCZOS)
        tile = Image.new("RGBA", (SIZE, SIZE))
        tile.alpha_composite(frame, ((SIZE - frame.width) // 2, (SIZE - frame.height) // 2))
        sheet.alpha_composite(tile, ((index % 8) * SIZE, (index // 8) * SIZE))
        preview_frames.append(tile)

    sheet.save(OUTPUT, optimize=True)
    preview_path = ROOT / "src/assets/mt_butterfly_flight_preview.gif"
    preview_frames[0].save(preview_path, save_all=True, append_images=preview_frames[1:],
                           duration=65, loop=0, disposal=2, transparency=0)
    print(f"{OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
