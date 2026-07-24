from pathlib import Path
import sys

import numpy as np
from PIL import Image, ImageDraw


source_path = Path(sys.argv[1])
light_path = Path(sys.argv[2])
dark_path = Path(sys.argv[3])

light_path.parent.mkdir(parents=True, exist_ok=True)
dark_path.parent.mkdir(parents=True, exist_ok=True)

source = Image.open(source_path).convert("RGBA")
pixels = np.asarray(source).astype(np.float32)
rgb = pixels[:, :, :3]
source_alpha = pixels[:, :, 3:4]

aquamarine = np.array([64.0, 183.0, 184.0])
navy = np.array([0.0, 58.0, 84.0])
axis = navy - aquamarine

# Recover each antialiased pixel's blend position between the two source
# colors, then rebuild it with the endpoints exchanged. Geometry and alpha are
# unchanged; only the light/dark palette is inverted.
blend = np.sum((rgb - aquamarine) * axis, axis=2, keepdims=True) / np.sum(axis * axis)
blend = np.clip(blend, 0.0, 1.0)
inverted_rgb = navy + blend * (aquamarine - navy)

# The source artwork was rendered against the opposite palette color, leaving
# fully opaque square corners. Build a real, antialiased alpha mask for the
# rounded app-icon tile so Dock/App Switcher rendering cannot expose that
# rectangular matte.
width, height = source.size
mask_scale = 4
corner_radius = round(min(width, height) * 0.16)
mask = Image.new("L", (width * mask_scale, height * mask_scale), 0)
draw = ImageDraw.Draw(mask)
draw.rounded_rectangle(
    (0, 0, width * mask_scale - 1, height * mask_scale - 1),
    radius=corner_radius * mask_scale,
    fill=255,
)
mask = mask.resize((width, height), Image.Resampling.LANCZOS)
rounded_alpha = np.asarray(mask).astype(np.float32)[:, :, None]
alpha = source_alpha * rounded_alpha / 255.0

# Replace the source artwork's old prematted boundary with the tile color. The
# four-pixel band is safely outside the tentacle mark and prevents a contrasting
# fringe around the rounded tile after compositing.
inner_mask = Image.new("L", (width * mask_scale, height * mask_scale), 0)
inner_draw = ImageDraw.Draw(inner_mask)
edge_band = 4
inner_draw.rounded_rectangle(
    (
        edge_band * mask_scale,
        edge_band * mask_scale,
        (width - edge_band) * mask_scale - 1,
        (height - edge_band) * mask_scale - 1,
    ),
    radius=(corner_radius - edge_band) * mask_scale,
    fill=255,
)
inner_mask = inner_mask.resize((width, height), Image.Resampling.LANCZOS)
boundary = np.asarray(inner_mask)[:, :, None] < 255
light_rgb = np.where(boundary, aquamarine.reshape(1, 1, 3), rgb)
dark_rgb = np.where(boundary, navy.reshape(1, 1, 3), inverted_rgb)

def make_padded_icon(rgb_values: np.ndarray, background: np.ndarray) -> Image.Image:
    artwork = Image.fromarray(
        np.rint(np.concatenate((rgb_values, alpha), axis=2)).astype(np.uint8),
        mode="RGBA",
    )

    # macOS sizes the complete image canvas in the Dock. Keep transparent
    # breathing room around the tile so its perceived size matches neighboring
    # app icons, then use a larger standard app-icon corner radius.
    inset = round(min(width, height) * 0.115)
    tile_size = min(width, height) - (2 * inset)
    artwork = artwork.resize((tile_size, tile_size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    canvas.paste(artwork, (inset, inset), artwork)

    mask = Image.new("L", (width * mask_scale, height * mask_scale), 0)
    draw = ImageDraw.Draw(mask)
    radius = round(tile_size * 0.24) * mask_scale
    draw.rounded_rectangle(
        (
            inset * mask_scale,
            inset * mask_scale,
            (width - inset) * mask_scale - 1,
            (height - inset) * mask_scale - 1,
        ),
        radius=radius,
        fill=255,
    )
    mask = mask.resize((width, height), Image.Resampling.LANCZOS)
    values = np.asarray(canvas).astype(np.float32)
    tile_mask = np.asarray(mask).astype(np.float32)[:, :, None]
    values[:, :, 3:4] *= tile_mask / 255.0
    values[:, :, :3] = np.where(
        tile_mask < 255.0,
        background.reshape(1, 1, 3),
        values[:, :, :3],
    )
    return Image.fromarray(np.rint(values).astype(np.uint8), mode="RGBA")


make_padded_icon(light_rgb, aquamarine).save(light_path)
make_padded_icon(dark_rgb, navy).save(dark_path)

print(f"light={light_path}")
print(f"dark={dark_path}")
